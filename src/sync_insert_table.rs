use crate::{
    raw::{
        bitmask::{BitMask, BitMaskIter},
        imp::Group,
    },
    scopeguard::guard,
    util::{equivalent_key, make_hash, make_hasher, make_insert_hash},
};
use core::ptr::NonNull;
use crossbeam_utils::atomic::AtomicCell;
use parking_lot::{Mutex, MutexGuard};
use std::{
    alloc::{handle_alloc_error, Allocator, Global, Layout, LayoutError},
    cell::UnsafeCell,
    collections::hash_map::RandomState,
    hash::BuildHasher,
    intrinsics::{likely, unlikely},
    iter::FusedIterator,
    marker::PhantomData,
    mem,
    sync::atomic::{AtomicU8, Ordering},
};
use std::{borrow::Borrow, hash::Hash};
mod code;
mod tests;

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

pub struct Locked<'a, T, S> {
    table: &'a SyncInsertTable<T, S>,
    _guard: MutexGuard<'a, ()>,
}

/// A raw hash table with an unsafe API.
pub struct SyncInsertTable<T, S = RandomState> {
    hash_builder: S,

    current: AtomicCell<TableRef<T>>,

    lock: Mutex<()>,

    old: UnsafeCell<Vec<TableRef<T>>>,

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

    /// Sets a control byte, and possibly also the replicated control byte at
    /// the end of the array.
    #[inline]
    unsafe fn set_ctrl(&self, index: usize, ctrl: u8) {
        // Replicate the first Group::WIDTH control bytes at the end of
        // the array without using a branch:
        // - If index >= Group::WIDTH then index == index2.
        // - Otherwise index2 == self.bucket_mask + 1 + index.
        //
        // The very last replicated control byte is never actually read because
        // we mask the initial index for unaligned loads, but we write it
        // anyways because it makes the set_ctrl implementation simpler.
        //
        // If there are fewer buckets than Group::WIDTH then this code will
        // replicate the buckets at the end of the trailing group. For example
        // with 2 buckets and a group size of 4, the control bytes will look
        // like this:
        //
        //     Real    |             Replicated
        // ---------------------------------------------
        // | [A] | [B] | [EMPTY] | [EMPTY] | [A] | [B] |
        // ---------------------------------------------
        let index2 = ((index.wrapping_sub(Group::WIDTH)) & self.bucket_mask) + Group::WIDTH;

        *self.ctrl(index) = ctrl;
        *self.ctrl(index2) = ctrl;
    }

    /// Sets a control byte, and possibly also the replicated control byte at
    /// the end of the array. Same as set_ctrl, but uses release stores.
    #[inline]
    unsafe fn set_ctrl_release(&self, index: usize, ctrl: u8) {
        let index2 = ((index.wrapping_sub(Group::WIDTH)) & self.bucket_mask) + Group::WIDTH;

        (*(self.ctrl(index) as *mut AtomicU8)).store(ctrl, Ordering::Release);
        (*(self.ctrl(index2) as *mut AtomicU8)).store(ctrl, Ordering::Release);
    }

    /// Sets a control byte to the hash, and possibly also the replicated control byte at
    /// the end of the array.
    #[inline]
    unsafe fn set_ctrl_h2(&self, index: usize, hash: u64) {
        self.set_ctrl(index, h2(hash))
    }

    #[inline]
    unsafe fn record_item_insert_at(&mut self, index: usize, hash: u64) {
        self.growth_left -= 1;
        self.set_ctrl_release(index, h2(hash));
        self.items += 1;
    }

    /// Searches for an empty or deleted bucket which is suitable for inserting
    /// a new element and sets the hash for that slot.
    ///
    /// There must be at least 1 empty bucket in the table.
    #[inline]
    unsafe fn prepare_insert_slot(&self, hash: u64) -> (usize, u8) {
        let index = self.find_insert_slot(hash);
        let old_ctrl = *self.ctrl(index);
        self.set_ctrl_h2(index, hash);
        (index, old_ctrl)
    }

    /// Searches for an empty or deleted bucket which is suitable for inserting
    /// a new element.
    ///
    /// There must be at least 1 empty bucket in the table.
    #[inline]
    unsafe fn find_insert_slot(&self, hash: u64) -> usize {
        let mut probe_seq = self.probe_seq(hash);
        loop {
            let group = Group::load(self.ctrl(probe_seq.pos));
            if let Some(bit) = group.match_empty_or_deleted().lowest_set_bit() {
                let result = (probe_seq.pos + bit) & self.bucket_mask;

                // In tables smaller than the group width, trailing control
                // bytes outside the range of the table are filled with
                // EMPTY entries. These will unfortunately trigger a
                // match, but once masked may point to a full bucket that
                // is already occupied. We detect this situation here and
                // perform a second scan starting at the begining of the
                // table. This second scan is guaranteed to find an empty
                // slot (due to the load factor) before hitting the trailing
                // control bytes (containing EMPTY).
                if unlikely(is_full(*self.ctrl(result))) {
                    debug_assert!(self.bucket_mask < Group::WIDTH);
                    debug_assert_ne!(probe_seq.pos, 0);
                    return Group::load_aligned(self.ctrl(0))
                        .match_empty_or_deleted()
                        .lowest_set_bit_nonzero();
                }

                return result;
            }
            probe_seq.move_next(self.bucket_mask);
        }
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
    fn empty() -> Self {
        // FIXME: Figure out if we need this to be aligned to `T`, even though no references to `T`
        // should be created from it.
        // There can be padding bytes at the end of a real layout to make it a multiple of the
        // alignment, but these aren't accessed in practise.
        #[repr(C)]
        struct EmptyTable {
            info: TableInfo,
            control_bytes: [Group; 1],
        }

        if cfg!(debug_assertions) {
            let real = Self::layout(0).unwrap().0;
            let dummy = Layout::new::<EmptyTable>().align_to(real.align()).unwrap();
            debug_assert_eq!(real, dummy);
        }

        let empty: &'static EmptyTable = &EmptyTable {
            info: TableInfo {
                bucket_mask: 0,
                growth_left: 0,
                items: 0,
            },
            control_bytes: [Group::EMPTY; 1],
        };

        Self {
            data: unsafe { NonNull::new_unchecked(empty as *const EmptyTable as *mut TableInfo) },
            marker: PhantomData,
        }
    }

    #[inline]
    fn layout(bucket_count: usize) -> Result<(Layout, usize), LayoutError> {
        let buckets = Layout::new::<T>().repeat(bucket_count)?.0;
        let info = Layout::new::<TableInfo>();
        let control =
            Layout::array::<u8>(bucket_count + Group::WIDTH)?.align_to(mem::align_of::<Group>())?;
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
            *result.info_mut() = TableInfo {
                bucket_mask: bucket_count - 1,
                growth_left: bucket_mask_to_capacity(bucket_count - 1),
                items: 0,
            };

            result
                .info()
                .ctrl(0)
                .write_bytes(EMPTY, result.info().num_ctrl_bytes());
        }

        result
    }

    #[inline]
    unsafe fn free(self) {
        if self.info().items > 0 {
            self.iter().drop_elements();
            Global.deallocate(
                NonNull::new_unchecked(self.bucket_before_first() as *mut u8),
                Self::layout(self.info().buckets()).unwrap_unchecked().0,
            )
        }
    }

    unsafe fn info(&self) -> &TableInfo {
        self.data.as_ref()
    }

    unsafe fn info_mut(&mut self) -> &mut TableInfo {
        self.data.as_mut()
    }

    #[inline]
    pub unsafe fn bucket_before_first(&self) -> *mut T {
        self.bucket_past_last().sub(self.info().buckets())
    }

    #[inline]
    pub unsafe fn bucket_past_last(&self) -> *mut T {
        let buckets = Layout::new::<T>()
            .repeat(self.info().buckets())
            .unwrap_unchecked()
            .0;
        let buckets_size = buckets.size();
        let info = Layout::new::<TableInfo>();
        let info_offet = buckets.extend(info).unwrap_unchecked().1;
        let info_padding = info_offet - buckets_size;
        (self.data.as_ptr() as *const u8).sub(info_padding) as *mut T
    }

    /// Returns a pointer to an element in the table.
    #[inline]
    pub unsafe fn bucket(&self, index: usize) -> Bucket<T> {
        debug_assert!(index < self.info().buckets());

        Bucket {
            ptr: NonNull::new_unchecked(self.bucket_past_last().sub(index)),
        }
    }

    /// Returns an iterator over occupied buckets that could match a given hash.
    ///
    /// In rare cases, the iterator may return a bucket with a different hash.
    ///
    /// It is up to the caller to ensure that the `SyncInsertTable` outlives the
    /// `RawIterHash`. Because we cannot make the `next` method unsafe on the
    /// `RawIterHash` struct, we have to make the `iter_hash` method unsafe.
    #[inline]
    pub unsafe fn iter_hash(&self, hash: u64) -> RawIterHash<'_, T> {
        RawIterHash::new(*self, self.info(), hash)
    }

    /// Returns an iterator over every element in the table. It is up to
    /// the caller to ensure that the `SyncInsertTable` outlives the `RawIter`.
    /// Because we cannot make the `next` method unsafe on the `RawIter`
    /// struct, we have to make the `iter` method unsafe.
    #[inline]
    pub unsafe fn iter(&self) -> RawIter<T> {
        let data = Bucket {
            ptr: NonNull::new_unchecked(self.bucket_past_last()),
        };
        RawIter {
            iter: RawIterRange::new(self.info().ctrl(0), data, self.info().buckets()),
            items: self.info().items,
        }
    }

    /// Searches for an element in the table.
    #[inline]
    unsafe fn find(&self, hash: u64, mut eq: impl FnMut(&T) -> bool) -> Option<Bucket<T>> {
        for bucket in self.iter_hash(hash) {
            let elm = bucket.as_ref();
            if likely(eq(elm)) {
                return Some(bucket);
            }
        }
        None
    }
}

unsafe impl<#[may_dangle] T, S> Drop for SyncInsertTable<T, S> {
    #[inline]
    fn drop(&mut self) {
        unsafe {
            self.current.load().free();
            for table in self.old.get_mut() {
                table.free();
            }
        }
    }
}

unsafe impl<T: Send, S> Send for SyncInsertTable<T, S> {}
unsafe impl<T: Send, S> Sync for SyncInsertTable<T, S> {}

impl<T, S: Default> Default for SyncInsertTable<T, S> {
    fn default() -> Self {
        Self::new_with(Default::default(), 0)
    }
}

impl<T> SyncInsertTable<T, RandomState> {
    #[inline]
    pub fn new() -> Self {
        Self::default()
    }
}

impl<T, S> SyncInsertTable<T, S> {
    #[inline]
    pub fn new_with(hash_builder: S, capacity: usize) -> Self {
        Self {
            hash_builder,
            current: AtomicCell::new(if capacity > 0 {
                TableRef::allocate(capacity_to_buckets(capacity).expect("capacity overflow"))
            } else {
                TableRef::empty()
            }),
            old: UnsafeCell::new(Vec::new()),
            marker: PhantomData,
            lock: Mutex::new(()),
        }
    }

    /// Searches for an element in the table.
    #[inline]
    fn find(&self, hash: u64, eq: impl FnMut(&T) -> bool) -> Option<Bucket<T>> {
        unsafe { self.current.load().find(hash, eq) }
    }

    /// Gets a reference to an element in the table.
    #[inline]
    pub fn get(&self, hash: u64, eq: impl FnMut(&T) -> bool) -> Option<&T> {
        // Avoid `Option::map` because it bloats LLVM IR.
        match self.find(hash, eq) {
            Some(bucket) => Some(unsafe { bucket.as_ref() }),
            None => None,
        }
    }

    /// Gets a mutable reference to an element in the table.
    #[inline]
    pub fn get_mut(&mut self, hash: u64, eq: impl FnMut(&T) -> bool) -> Option<&mut T> {
        // Avoid `Option::map` because it bloats LLVM IR.
        match self.find(hash, eq) {
            Some(bucket) => Some(unsafe { bucket.as_mut() }),
            None => None,
        }
    }

    /// Returns the number of elements the map can hold without reallocating.
    ///
    /// This number is a lower bound; the table might be able to hold
    /// more, but is guaranteed to be able to hold at least this many.
    #[inline]
    pub fn capacity(&self) -> usize {
        unsafe {
            let table = self.current.load();
            let info = table.info();
            info.items + info.growth_left
        }
    }

    /// Returns the number of elements in the table.
    #[inline]
    pub fn len(&self) -> usize {
        unsafe { self.current.load().info().items }
    }

    /// Returns the number of buckets in the table.
    #[inline]
    pub fn buckets(&self) -> usize {
        // FIXME: Needs to hold QSBR token to be safe
        unsafe { self.current.load().info().buckets() }
    }

    #[inline]
    pub fn mutex(&self) -> &Mutex<()> {
        &self.lock
    }

    #[inline]
    pub fn lock(&self) -> Locked<'_, T, S> {
        Locked {
            table: self,
            _guard: self.lock.lock(),
        }
    }

    #[inline]
    pub fn lock_from_guard<'a>(&'a self, guard: MutexGuard<'a, ()>) -> Locked<'a, T, S> {
        // Verify that we are target of the guard
        assert_eq!(
            &self.lock as *const _,
            MutexGuard::mutex(&guard) as *const _
        );

        Locked {
            table: self,
            _guard: guard,
        }
    }

    #[inline]
    pub fn iter(&self) -> RawIter<T> {
        let table = self.current.load();
        unsafe { table.iter() }
    }
}

impl<'a, T: Clone, S> Locked<'a, T, S> {
    /// Inserts a new element into the table, and returns its raw bucket.
    ///
    /// This does not check if the given element already exists in the table.
    #[inline]
    pub fn insert_new(&self, hash: u64, value: T, hasher: impl Fn(&T) -> u64) -> Bucket<T> {
        let mut table = self.table.current.load();

        unsafe {
            if unlikely(table.info().growth_left == 0) {
                table = self.reserve(1, &hasher);
            }

            let index = table.info().find_insert_slot(hash);

            let bucket = table.bucket(index);
            bucket.write(value);

            table.info_mut().record_item_insert_at(index, hash);

            bucket
        }
    }

    /// Out-of-line slow path for `reserve` and `try_reserve`.
    #[cold]
    #[inline(never)]
    fn reserve(&self, additional: usize, hasher: &impl Fn(&T) -> u64) -> TableRef<T> {
        let table = self.table.current.load();

        // Avoid `Option::ok_or_else` because it bloats LLVM IR.
        let new_items = match unsafe { table.info() }.items.checked_add(additional) {
            Some(new_items) => new_items,
            None => panic!("capacity overflow"),
        };

        let full_capacity = bucket_mask_to_capacity(unsafe { table.info().bucket_mask });

        let new_capacity = usize::max(new_items, full_capacity + 1);

        unsafe {
            debug_assert!(table.info().items <= new_capacity);
        }

        let buckets = capacity_to_buckets(new_capacity).expect("capacity overflow");

        let table = self.resize(buckets, hasher);

        self.table.current.store(table);
        table
    }

    /// Allocates a new table of a different size and moves the contents of the
    /// current table into it.
    fn resize(&self, buckets: usize, hasher: impl Fn(&T) -> u64) -> TableRef<T> {
        let table = self.table.current.load();
        unsafe {
            let mut new_table = TableRef::allocate(buckets);

            new_table.info_mut().items = table.info().items;
            new_table.info_mut().growth_left -= table.info().items;

            let mut guard = guard(Some(new_table), |new_table| {
                new_table.map(|new_table| new_table.free());
            });

            // Copy all elements to the new table.
            for item in table.iter() {
                // This may panic.
                let hash = hasher(item.as_ref());

                // We can use a simpler version of insert() here since:
                // - there are no DELETED entries.
                // - we know there is enough space in the table.
                // - all elements are unique.
                let (index, _) = new_table.info().prepare_insert_slot(hash);

                // FIXME: Scheme to drop items on panic?

                // Clone may panic
                new_table.bucket(index).write(item.as_ref().clone());
            }

            *guard = None;

            (*self.table.old.get()).push(table);

            new_table
        }
    }
}

impl<K: Eq + Hash + Clone, V: Clone, S: BuildHasher> SyncInsertTable<(K, V), S> {
    #[inline]
    pub fn map_get<Q: ?Sized>(&self, k: &Q) -> Option<&V>
    where
        K: Borrow<Q>,
        Q: Hash + Eq,
    {
        let hash = make_hash::<K, Q, S>(&self.hash_builder, k);
        // Avoid `Option::map` because it bloats LLVM IR.

        match self.get(hash, equivalent_key(k)) {
            Some(&(_, ref v)) => Some(v),
            None => None,
        }
    }

    #[inline]
    pub fn map_insert(&mut self, k: K, v: V) -> Option<(K, V)> {
        let hash = make_insert_hash(&self.hash_builder, &k);
        let locked = self.lock();
        let table = self.current.load();
        if unsafe { table.find(hash, equivalent_key(&k)).is_some() } {
            Some((k, v))
        } else {
            locked.insert_new(hash, (k, v), make_hasher::<K, _, V, S>(&self.hash_builder));
            None
        }
    }
}

/// Returns the maximum effective capacity for the given bucket mask, taking
/// the maximum load factor into account.
#[inline]
fn bucket_mask_to_capacity(bucket_mask: usize) -> usize {
    if bucket_mask < 16 {
        // For tables with 1/2/4/8 buckets, we always reserve one empty slot.
        // Keep in mind that the bucket mask is one less than the bucket count.
        bucket_mask
    } else {
        // For larger tables we reserve 12.5% of the slots as empty.
        ((bucket_mask + 1) / 8) * 7
    }
}

/// Returns the number of buckets needed to hold the given number of items,
/// taking the maximum load factor into account.
///
/// Returns `None` if an overflow occurs.
// Workaround for emscripten bug emscripten-core/emscripten-fastcomp#258
#[cfg_attr(target_os = "emscripten", inline(never))]
#[cfg_attr(not(target_os = "emscripten"), inline)]
fn capacity_to_buckets(cap: usize) -> Option<usize> {
    debug_assert_ne!(cap, 0);

    // For small tables we require at least 1 empty bucket so that lookups are
    // guaranteed to terminate if an element doesn't exist in the table.
    if cap < 16 {
        // We don't bother with a table size of 2 buckets since that can only
        // hold a single element. Instead we skip directly to a 4 bucket table
        // which can hold 3 elements.
        return Some(if cap < 4 { 4 } else { 16 });
    }

    // Otherwise require 1/8 buckets to be empty (87.5% load)
    //
    // Be careful when modifying this, calculate_layout relies on the
    // overflow check here.
    let adjusted_cap = cap.checked_mul(8)? / 7;

    // Any overflows will have been caught by the checked_mul. Also, any
    // rounding errors from the division above will be cleaned up by
    // next_power_of_two (which can't overflow because of the previous divison).
    Some(adjusted_cap.next_power_of_two())
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

/// Control byte value for an empty bucket.
const EMPTY: u8 = 0b1111_1111;

/// Checks whether a control byte represents a full bucket (top bit is clear).
#[inline]
fn is_full(ctrl: u8) -> bool {
    ctrl & 0x80 == 0
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

    #[inline]
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

    #[inline]
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

/// Iterator over a sub-range of a table. Unlike `RawIter` this iterator does
/// not track an item count.
pub(crate) struct RawIterRange<T> {
    // Mask of full buckets in the current group. Bits are cleared from this
    // mask as each element is processed.
    current_group: BitMask,

    // Pointer to the buckets for the current group.
    data: Bucket<T>,

    // Pointer to the next group of control bytes,
    // Must be aligned to the group size.
    next_ctrl: *const u8,

    // Pointer one past the last control byte of this range.
    end: *const u8,
}

impl<T> RawIterRange<T> {
    /// Returns a `RawIterRange` covering a subset of a table.
    ///
    /// The control byte address must be aligned to the group size.
    #[inline]
    unsafe fn new(ctrl: *const u8, data: Bucket<T>, len: usize) -> Self {
        debug_assert_ne!(len, 0);
        debug_assert_eq!(ctrl as usize % Group::WIDTH, 0);
        let end = ctrl.add(len);

        // Load the first group and advance ctrl to point to the next group
        let current_group = Group::load_aligned(ctrl).match_full();
        let next_ctrl = ctrl.add(Group::WIDTH);

        Self {
            current_group,
            data,
            next_ctrl,
            end,
        }
    }
}

// We make raw iterators unconditionally Send and Sync, and let the PhantomData
// in the actual iterator implementations determine the real Send/Sync bounds.
unsafe impl<T> Send for RawIterRange<T> {}
unsafe impl<T> Sync for RawIterRange<T> {}

impl<T> Clone for RawIterRange<T> {
    #[inline]
    fn clone(&self) -> Self {
        Self {
            data: self.data.clone(),
            next_ctrl: self.next_ctrl,
            current_group: self.current_group,
            end: self.end,
        }
    }
}

impl<T> Iterator for RawIterRange<T> {
    type Item = Bucket<T>;

    #[inline]
    fn next(&mut self) -> Option<Bucket<T>> {
        unsafe {
            loop {
                if let Some(index) = self.current_group.lowest_set_bit() {
                    self.current_group = self.current_group.remove_lowest_bit();
                    return Some(self.data.next_n(index));
                }

                if self.next_ctrl >= self.end {
                    return None;
                }

                // We might read past self.end up to the next group boundary,
                // but this is fine because it only occurs on tables smaller
                // than the group size where the trailing control bytes are all
                // EMPTY. On larger tables self.end is guaranteed to be aligned
                // to the group size (since tables are power-of-two sized).
                self.current_group = Group::load_aligned(self.next_ctrl).match_full();
                self.data = self.data.next_n(Group::WIDTH);
                self.next_ctrl = self.next_ctrl.add(Group::WIDTH);
            }
        }
    }
}

impl<T> FusedIterator for RawIterRange<T> {}

/// Iterator which returns a raw pointer to every full bucket in the table.
///
/// For maximum flexibility this iterator is not bound by a lifetime, but you
/// must observe several rules when using it:
/// - You must not free the hash table while iterating (including via growing/shrinking).
/// - It is fine to erase a bucket that has been yielded by the iterator.
/// - Erasing a bucket that has not yet been yielded by the iterator may still
///   result in the iterator yielding that bucket (unless `reflect_remove` is called).
/// - It is unspecified whether an element inserted after the iterator was
///   created will be yielded by that iterator (unless `reflect_insert` is called).
/// - The order in which the iterator yields bucket is unspecified and may
///   change in the future.
pub struct RawIter<T> {
    pub(crate) iter: RawIterRange<T>,
    items: usize,
}

impl<T> RawIter<T> {
    unsafe fn drop_elements(&mut self) {
        if mem::needs_drop::<T>() && self.len() != 0 {
            for item in self {
                item.drop();
            }
        }
    }
}

impl<T> Clone for RawIter<T> {
    #[inline]
    fn clone(&self) -> Self {
        Self {
            iter: self.iter.clone(),
            items: self.items,
        }
    }
}

impl<T> Iterator for RawIter<T> {
    type Item = Bucket<T>;

    #[inline]
    fn next(&mut self) -> Option<Bucket<T>> {
        if let Some(b) = self.iter.next() {
            self.items -= 1;
            Some(b)
        } else {
            // We don't check against items == 0 here to allow the
            // compiler to optimize away the item count entirely if the
            // iterator length is never queried.
            debug_assert_eq!(self.items, 0);
            None
        }
    }

    #[inline]
    fn size_hint(&self) -> (usize, Option<usize>) {
        (self.items, Some(self.items))
    }
}

impl<T> ExactSizeIterator for RawIter<T> {}
impl<T> FusedIterator for RawIter<T> {}
