use crate::raw::{
    bitmask::BitMaskIter,
    imp::{BitMaskWord, Group},
};
use core::ptr::NonNull;
use crossbeam_utils::atomic::AtomicCell;
use parking_lot::{lock_api::RawMutex as RawMutex_, RawMutex};
use std::{
    alloc::{self, handle_alloc_error, Allocator, Global, Layout, LayoutError},
    intrinsics::{likely, unlikely},
    marker::PhantomData,
    mem, ptr,
};

/// A reference to a hash table bucket containing a `T`.
///
/// This is usually just a pointer to the element itself. However if the element
/// is a ZST, then we instead track the index of the element in the table so
/// that `erase` works properly.
pub struct Bucket<T> {
    // Actually it is pointer to next element than element itself
    // this is needed to maintain pointer arithmetic invariants
    // keeping direct pointer to element introduces difficulty.
    // Using `NonNull` for variance and niche layout
    ptr: NonNull<T>,
}

impl<T> Clone for Bucket<T> {
    #[inline]
    fn clone(&self) -> Self {
        Self { ptr: self.ptr }
    }
}

impl<T> Bucket<T> {
    #[inline]
    pub fn as_ptr(&self) -> *mut T {
        if mem::size_of::<T>() == 0 {
            // Just return an arbitrary ZST pointer which is properly aligned
            mem::align_of::<T>() as *mut T
        } else {
            unsafe { self.ptr.as_ptr().sub(1) }
        }
    }
    #[inline]
    unsafe fn next_n(&self, offset: usize) -> Self {
        let ptr = if mem::size_of::<T>() == 0 {
            (self.ptr.as_ptr() as usize + offset) as *mut T
        } else {
            self.ptr.as_ptr().sub(offset)
        };
        Self {
            ptr: NonNull::new_unchecked(ptr),
        }
    }
    #[inline]
    pub unsafe fn drop(&self) {
        self.as_ptr().drop_in_place();
    }
    #[inline]
    pub unsafe fn read(&self) -> T {
        self.as_ptr().read()
    }
    #[inline]
    pub unsafe fn write(&self, val: T) {
        self.as_ptr().write(val);
    }
    #[inline]
    pub unsafe fn as_ref<'a>(&self) -> &'a T {
        &*self.as_ptr()
    }
    #[inline]
    pub unsafe fn as_mut<'a>(&self) -> &'a mut T {
        &mut *self.as_ptr()
    }
    #[inline]
    pub unsafe fn copy_from_nonoverlapping(&self, other: &Self) {
        self.as_ptr().copy_from_nonoverlapping(other.as_ptr(), 1);
    }
}

/// A raw hash table with an unsafe API.
pub struct RawTable<T> {
    current: AtomicCell<Option<TableRef<T>>>,

    lock: RawMutex,

    // Tell dropck that we own instances of T.
    marker: PhantomData<T>,
}

struct TableInfo {
    // Mask to get an index from a hash value. The value is one less than the
    // number of buckets in the table.
    bucket_mask: usize,

    // Number of elements that can be inserted before we need to grow the table
    growth_left: usize,

    // Number of elements in the table, only really used by len()
    items: usize,
}

impl TableInfo {
    #[inline]
    fn num_ctrl_bytes(&self) -> usize {
        self.buckets() + Group::WIDTH
    }

    /// Returns the number of buckets in the table.
    #[inline]
    pub fn buckets(&self) -> usize {
        self.bucket_mask + 1
    }

    /// Returns a pointer to a control byte.
    #[inline]
    unsafe fn ctrl(&self, index: usize) -> *mut u8 {
        debug_assert!(index < self.num_ctrl_bytes());

        let info = Layout::new::<TableInfo>();
        let control = Layout::new::<Group>();
        let offset = info.extend(control).unwrap().1;

        let ctrl = (self as *const TableInfo as *mut u8).add(offset);

        ctrl.add(index)
    }

    /// Returns an iterator-like object for a probe sequence on the table.
    ///
    /// This iterator never terminates, but is guaranteed to visit each bucket
    /// group exactly once. The loop using `probe_seq` must terminate upon
    /// reaching a group containing an empty bucket.
    #[inline]
    unsafe fn probe_seq(&self, hash: u64) -> ProbeSeq {
        ProbeSeq {
            pos: h1(hash) & self.bucket_mask,
            stride: 0,
        }
    }
}

#[repr(transparent)]
struct TableRef<T> {
    data: NonNull<TableInfo>,

    marker: PhantomData<*mut T>,
}

impl<T> Copy for TableRef<T> {}
impl<T> Clone for TableRef<T> {
    #[inline]
    fn clone(&self) -> Self {
        Self {
            data: self.data,
            marker: self.marker,
        }
    }
}

impl<T> TableRef<T> {
    #[inline]
    fn layout(bucket_count: usize) -> Result<(Layout, usize), LayoutError> {
        let buckets = Layout::new::<T>().repeat(bucket_count)?.0;
        let info = Layout::new::<TableInfo>();
        let control = Layout::new::<Group>()
            .repeat(bucket_count / Group::WIDTH)?
            .0;
        let (total, info_offet) = buckets.extend(info)?;
        Ok((total.extend(control)?.0, info_offet))
    }

    #[inline]
    fn allocate(bucket_count: usize) -> Self {
        let (layout, info_offset) = Self::layout(bucket_count).expect("capacity overflow");

        let ptr: NonNull<u8> = Global
            .allocate(layout)
            .map(|ptr| ptr.cast())
            .unwrap_or_else(|_| handle_alloc_error(layout));

        let info =
            unsafe { NonNull::new_unchecked(ptr.as_ptr().add(info_offset) as *mut TableInfo) };

        let mut result = Self {
            data: info,
            marker: PhantomData,
        };

        unsafe {
            *result.data.as_mut() = TableInfo {
                bucket_mask: bucket_count - 1,
                growth_left: bucket_mask_to_capacity(bucket_count - 1),
                items: 0,
            };
        }

        result
    }

    unsafe fn info(&self) -> &TableInfo {
        self.data.as_ref()
    }

    /// Returns a pointer to an element in the table.
    #[inline]
    pub unsafe fn bucket(&self, index: usize) -> Bucket<T> {
        debug_assert!(index < self.info().buckets());

        let info_offset = Self::layout(self.info().buckets()).unwrap_unchecked().1;

        let start = (self as *const TableRef<T> as *const u8).sub(info_offset) as *mut T;

        Bucket {
            ptr: NonNull::new_unchecked(start.add(index)),
        }
    }

    /// Returns an iterator over occupied buckets that could match a given hash.
    ///
    /// In rare cases, the iterator may return a bucket with a different hash.
    ///
    /// It is up to the caller to ensure that the `RawTable` outlives the
    /// `RawIterHash`. Because we cannot make the `next` method unsafe on the
    /// `RawIterHash` struct, we have to make the `iter_hash` method unsafe.
    #[inline]
    pub unsafe fn iter_hash(&self, hash: u64) -> RawIterHash<'_, T> {
        RawIterHash::new(*self, self.info(), hash)
    }
}

impl<T: Clone> RawTable<T> {
    #[inline]
    pub fn new() -> Self {
        Self {
            current: AtomicCell::new(None),
            marker: PhantomData,
            lock: RawMutex::INIT,
        }
    }

    /// Searches for an element in the table.
    #[inline]
    pub fn find(&self, hash: u64, mut eq: impl FnMut(&T) -> bool) -> Option<Bucket<T>> {
        let table = self.current.load();
        let table = if unlikely(table.is_none()) {
            return None;
        } else {
            table.unwrap()
        };

        unsafe {
            for bucket in table.iter_hash(hash) {
                let elm = bucket.as_ref();
                if likely(eq(elm)) {
                    return Some(bucket);
                }
            }
            None
        }
    }
    /*
    /// Inserts a new element into the table, and returns its raw bucket.
    ///
    /// This does not check if the given element already exists in the table.
    #[inline]
    pub fn insert(&mut self, hash: u64, value: T, hasher: impl Fn(&T) -> u64) -> NonNull<T> {
        let table = self.current.load();

        let table = if unlikely(table.is_none()) {
            self.reserve_rehash(1, hasher)
        } else {
            table.unwrap()
        };

        table.find_insert_slot(hash);
        /*
        unsafe {
            let mut index = self.table.find_insert_slot(hash);

            // We can avoid growing the table once we have reached our load
            // factor if we are replacing a tombstone. This works since the
            // number of EMPTY slots does not change in this case.
            let old_ctrl = *self.table.ctrl(index);
            if unlikely(self.table.growth_left == 0 && special_is_empty(old_ctrl)) {
                self.reserve(1, hasher);
                index = self.table.find_insert_slot(hash);
            }

            self.table.record_item_insert_at(index, old_ctrl, hash);

            let bucket = self.bucket(index);
            bucket.write(value);
            bucket
        }*/
    }

    /// Out-of-line slow path for `reserve` and `try_reserve`.
    #[cold]
    #[inline(never)]
    fn reserve_rehash(&self, additional: usize, hasher: impl Fn(&T) -> u64) -> TableRef<T> {}*/
}

/// Returns the maximum effective capacity for the given bucket mask, taking
/// the maximum load factor into account.
#[inline]
fn bucket_mask_to_capacity(bucket_mask: usize) -> usize {
    if bucket_mask < 8 {
        // For tables with 1/2/4/8 buckets, we always reserve one empty slot.
        // Keep in mind that the bucket mask is one less than the bucket count.
        bucket_mask
    } else {
        // For larger tables we reserve 12.5% of the slots as empty.
        ((bucket_mask + 1) / 8) * 7
    }
}

/// Primary hash function, used to select the initial bucket to probe from.
#[inline]
#[allow(clippy::cast_possible_truncation)]
fn h1(hash: u64) -> usize {
    // On 32-bit platforms we simply ignore the higher hash bits.
    hash as usize
}

/// Secondary hash function, saved in the low 7 bits of the control byte.
#[inline]
#[allow(clippy::cast_possible_truncation)]
fn h2(hash: u64) -> u8 {
    // Grab the top 7 bits of the hash. While the hash is normally a full 64-bit
    // value, some hash functions (such as FxHash) produce a usize result
    // instead, which means that the top 32 bits are 0 on 32-bit platforms.
    let hash_len = usize::min(mem::size_of::<usize>(), mem::size_of::<u64>());
    let top7 = hash >> (hash_len * 8 - 7);
    (top7 & 0x7f) as u8 // truncation
}

/// Probe sequence based on triangular numbers, which is guaranteed (since our
/// table size is a power of two) to visit every group of elements exactly once.
///
/// A triangular probe has us jump by 1 more group every time. So first we
/// jump by 1 group (meaning we just continue our linear scan), then 2 groups
/// (skipping over 1 group), then 3 groups (skipping over 2 groups), and so on.
///
/// Proof that the probe will visit every group in the table:
/// <https://fgiesen.wordpress.com/2015/02/22/triangular-numbers-mod-2n/>
struct ProbeSeq {
    pos: usize,
    stride: usize,
}

impl ProbeSeq {
    #[inline]
    fn move_next(&mut self, bucket_mask: usize) {
        // We should have found an empty bucket by now and ended the probe.
        debug_assert!(
            self.stride <= bucket_mask,
            "Went past end of probe sequence"
        );

        self.stride += Group::WIDTH;
        self.pos += self.stride;
        self.pos &= bucket_mask;
    }
}

/// Iterator over occupied buckets that could match a given hash.
///
/// In rare cases, the iterator may return a bucket with a different hash.
pub struct RawIterHash<'a, T> {
    table: TableRef<T>,
    inner: RawIterHashInner<'a>,
    _marker: PhantomData<T>,
}

struct RawIterHashInner<'a> {
    table: &'a TableInfo,

    // The top 7 bits of the hash.
    h2_hash: u8,

    // The sequence of groups to probe in the search.
    probe_seq: ProbeSeq,

    group: Group,

    // The elements within the group with a matching h2-hash.
    bitmask: BitMaskIter,
}

impl<'a, T> RawIterHash<'a, T> {
    #[inline]
    fn new(table: TableRef<T>, info: &'a TableInfo, hash: u64) -> Self {
        RawIterHash {
            table,
            inner: RawIterHashInner::new(info, hash),
            _marker: PhantomData,
        }
    }
}
impl<'a> RawIterHashInner<'a> {
    #[inline]
    fn new(table: &'a TableInfo, hash: u64) -> Self {
        unsafe {
            let h2_hash = h2(hash);
            let probe_seq = table.probe_seq(hash);
            let group = Group::load(table.ctrl(probe_seq.pos));
            let bitmask = group.match_byte(h2_hash).into_iter();

            RawIterHashInner {
                table,
                h2_hash,
                probe_seq,
                group,
                bitmask,
            }
        }
    }
}

impl<'a, T> Iterator for RawIterHash<'a, T> {
    type Item = Bucket<T>;

    fn next(&mut self) -> Option<Bucket<T>> {
        unsafe {
            match self.inner.next() {
                Some(index) => Some(self.table.bucket(index)),
                None => None,
            }
        }
    }
}

impl<'a> Iterator for RawIterHashInner<'a> {
    type Item = usize;

    fn next(&mut self) -> Option<Self::Item> {
        unsafe {
            loop {
                if let Some(bit) = self.bitmask.next() {
                    let index = (self.probe_seq.pos + bit) & self.table.bucket_mask;
                    return Some(index);
                }
                if likely(self.group.match_empty().any_bit_set()) {
                    return None;
                }
                self.probe_seq.move_next(self.table.bucket_mask);
                self.group = Group::load(self.table.ctrl(self.probe_seq.pos));
                self.bitmask = self.group.match_byte(self.h2_hash).into_iter();
            }
        }
    }
}
