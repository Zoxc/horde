//! A hash table with lock-free reads.
//!
//! It is based on the table from the `hashbrown` crate.

use crate::{
    collect::{self, Pin, pin},
    raw::{DELETED, EMPTY, bitmask::BitMask, imp::Group},
    scopeguard::guard,
    util::{StaticUnsafeCell, align_up, cold_path, likely, make_insert_hash, unlikely},
};
use core::ptr::NonNull;
use parking_lot::{Mutex, MutexGuard};
use std::sync::atomic::{AtomicPtr, AtomicUsize};
use std::{
    alloc::{Layout, alloc, dealloc, handle_alloc_error},
    cmp, fmt,
    hash::BuildHasher,
    iter::{FromIterator, FusedIterator},
    marker::PhantomData,
    mem,
    sync::atomic::{AtomicBool, AtomicU8, Ordering},
};
use std::{borrow::Borrow, hash::Hash};
use std::{cell::Cell, collections::hash_map::RandomState};

mod code;
mod tests;

#[inline]
fn hasher<K: Hash, V, S: BuildHasher>(hash_builder: &S, val: &(K, V)) -> u64 {
    make_insert_hash(hash_builder, &val.0)
}

#[inline]
fn eq<Q, K, V>(key: &Q) -> impl Fn(&(K, V)) -> bool + '_
where
    K: Borrow<Q>,
    Q: ?Sized + Eq,
{
    move |x| key.eq(x.0.borrow())
}

/// A reference to a hash table bucket containing a `T`.
///
/// This is a pointer to the element itself.
struct Bucket<T> {
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
    fn as_ptr(&self) -> *mut T {
        unsafe { self.ptr.as_ptr().sub(1) }
    }
    #[inline]
    unsafe fn next_n(&self, offset: usize) -> Self {
        unsafe {
            Self {
                ptr: NonNull::new_unchecked(self.ptr.as_ptr().sub(offset)),
            }
        }
    }
    #[inline]
    unsafe fn drop(&self) {
        unsafe {
            self.as_ptr().drop_in_place();
        }
    }
    #[inline]
    unsafe fn write(&self, val: T) {
        unsafe {
            self.as_ptr().write(val);
        }
    }
    #[inline]
    unsafe fn as_ref<'a>(&self) -> &'a T {
        unsafe { &*self.as_ptr() }
    }
    #[inline]
    unsafe fn as_mut<'a>(&self) -> &'a mut T {
        unsafe { &mut *self.as_ptr() }
    }
}

impl<K, V> Bucket<(K, V)> {
    #[inline]
    pub unsafe fn as_pair_ref<'a>(&self) -> (&'a K, &'a V) {
        unsafe {
            let pair = &*self.as_ptr();
            (&pair.0, &pair.1)
        }
    }
}

/// A handle to a [SyncTable] with read access.
///
/// It is acquired either by a pin, or by exclusive access to the table.
pub struct Read<'a, K, V, S = DefaultHashBuilder> {
    table: &'a SyncTable<K, V, S>,
}

impl<K, V, S> Copy for Read<'_, K, V, S> {}
impl<K, V, S> Clone for Read<'_, K, V, S> {
    fn clone(&self) -> Self {
        *self
    }
}

/// A handle to a [SyncTable] with write access.
pub struct Write<'a, K, V, S = DefaultHashBuilder> {
    table: &'a SyncTable<K, V, S>,
}

/// A handle to a [SyncTable] with write access protected by a lock.
pub struct LockedWrite<'a, K, V, S = DefaultHashBuilder> {
    table: &'a SyncTable<K, V, S>,
    _guard: MutexGuard<'a, ()>,
}

impl<'a, K, V, S> LockedWrite<'a, K, V, S> {
    /// Creates a [Write] handle which gives access to write operations.
    ///
    /// This does not prune old tables.
    #[inline]
    pub fn write(&mut self) -> Write<'_, K, V, S> {
        Write { table: self.table }
    }

    /// Creates a [Read] handle which gives access to read operations.
    #[inline]
    pub fn read(&self) -> Read<'_, K, V, S> {
        Read { table: self.table }
    }

    /// Returns a reference to the table's `BuildHasher`.
    #[inline]
    pub fn hasher(&self) -> &'a S {
        &self.table.hash_builder
    }
}

/// Default hash builder for [SyncTable].
pub type DefaultHashBuilder = RandomState;

/// A hash table with lock-free reads.
///
/// It is based on the table from the `hashbrown` crate.
pub struct SyncTable<K, V, S = DefaultHashBuilder> {
    hash_builder: S,

    current: AtomicPtr<TableInfo>,

    lock: Mutex<()>,

    // A linked list of retired tables. When the list is empty the head points to the static
    // empty table and the tail is `None`. `try_prune_tables` relies on the head sentinel to read
    // `can_free` without first testing for an empty list.
    retired_head: Cell<TableInfoRef>,
    retired_tail: Cell<Option<TableInfoRef>>,

    // Mark `K` and `V` as invariant and tell dropck that we own instances of `K` and `V`.
    marker: PhantomData<(K, V, fn(K, V) -> (K, V))>,
}

struct TableInfo {
    // Mask to get an index from a hash value. The value is one less than the
    // number of buckets in the table.
    // If this is 0, this table must be the static `EMPTY_TABLE`.
    bucket_mask: usize,

    // Number of elements that can be inserted before we need to grow the table
    growth_left: AtomicUsize,

    // Number of elements that has been removed from the table
    tombstones: AtomicUsize,

    can_free: AtomicBool,

    // The next entry in the retired linked list
    next_retired: Cell<TableInfoRef>,
}

impl TableInfo {
    #[inline]
    fn num_ctrl_bytes(&self) -> usize {
        self.buckets() + Group::WIDTH
    }

    /// Returns the number of buckets in the table.
    #[inline]
    fn buckets(&self) -> usize {
        self.bucket_mask + 1
    }

    /// The number of items in the table. It can race if the writer lock is not held.
    #[inline]
    fn items(&self) -> usize {
        // We load `tombstones` first here. Every tombstone we see here is one slot
        // which cannot appear in the following `growth_left` load as each tombstone
        // uses up one of the `growth_left` slots before the change to `tombstones` happens.
        // This means tombstones + growth_left may never exceed capacity and
        // the computation will never underflow.
        let tombstones = self.tombstones.load(Ordering::Acquire);

        bucket_mask_to_capacity(self.bucket_mask)
            - tombstones
            - self.growth_left.load(Ordering::Acquire)
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
#[derive(Copy, Clone, PartialEq, Eq)]
struct TableInfoRef {
    ptr: NonNull<TableInfo>,
}

impl TableInfoRef {
    #[inline]
    const unsafe fn new(ptr: *mut TableInfo) -> Self {
        unsafe {
            Self {
                ptr: NonNull::new_unchecked(ptr),
            }
        }
    }

    #[inline]
    fn as_ptr(self) -> *mut TableInfo {
        self.ptr.as_ptr()
    }

    unsafe fn info(&self) -> &TableInfo {
        unsafe { self.ptr.as_ref() }
    }

    unsafe fn info_mut(&mut self) -> &mut TableInfo {
        unsafe { self.ptr.as_mut() }
    }

    /// Returns a pointer to a control byte.
    #[inline]
    unsafe fn ctrl(self, index: usize) -> *mut u8 {
        unsafe {
            debug_assert!(index < self.info().num_ctrl_bytes());

            let offset =
                align_up(mem::size_of::<TableInfo>(), mem::align_of::<Group>()).unwrap_unchecked();

            let ctrl = self.as_ptr().cast::<u8>().add(offset);

            ctrl.add(index)
        }
    }

    /// Returns a control byte accessing it using an acquire load
    #[inline]
    unsafe fn ctrl_acquire(self, index: usize) -> u8 {
        unsafe { (&*(self.ctrl(index) as *const AtomicU8)).load(Ordering::Acquire) }
    }

    /// Sets a control byte, and possibly also the replicated control byte at
    /// the end of the array.
    ///
    /// # Safety
    /// The stores are not atomic, so no other thread may access the table.
    #[inline]
    unsafe fn set_ctrl(self, index: usize, ctrl: u8) {
        unsafe {
            // Replicate the first Group::WIDTH control bytes at the end of
            // the array without using a branch:
            // - If index >= Group::WIDTH then index == index2.
            // - Otherwise index2 == self.bucket_mask + 1 + index.
            //
            // The very last replicated control byte is never actually read because
            // we mask the initial index for unaligned loads, but we write it
            // anyways because it makes the set_ctrl implementation simpler.
            //
            // Tables always have at least Group::WIDTH buckets, so the replica of a
            // bucket always lands in the trailing group and the two groups never
            // overlap: `capacity_to_buckets` floors the bucket count at Group::WIDTH
            // and `TableRef::allocate` asserts it. The only smaller table is the
            // static empty one, which is never written to.
            let index2 =
                ((index.wrapping_sub(Group::WIDTH)) & self.info().bucket_mask) + Group::WIDTH;

            *self.ctrl(index) = ctrl;
            *self.ctrl(index2) = ctrl;
        }
    }

    /// Sets a control byte, and possibly also the replicated control byte at
    /// the end of the array. Same as set_ctrl, but uses release stores.
    #[inline]
    unsafe fn set_ctrl_release(self, index: usize, ctrl: u8) {
        unsafe {
            let index2 =
                ((index.wrapping_sub(Group::WIDTH)) & self.info().bucket_mask) + Group::WIDTH;

            (*(self.ctrl(index) as *mut AtomicU8)).store(ctrl, Ordering::Release);
            (*(self.ctrl(index2) as *mut AtomicU8)).store(ctrl, Ordering::Release);
        }
    }

    /// Sets a control byte to the hash, and possibly also the replicated control byte at
    /// the end of the array.
    ///
    /// # Safety
    /// The stores are not atomic, so no other thread may access the table.
    #[inline]
    unsafe fn set_ctrl_h2(self, index: usize, hash: u64) {
        unsafe { self.set_ctrl(index, h2(hash)) }
    }

    /// Marks the bucket at `index` as full with the tag of `hash`.
    #[inline]
    unsafe fn record_item_insert_at(self, index: usize, hash: u64) {
        unsafe {
            self.info().growth_left.store(
                self.info().growth_left.load(Ordering::Relaxed) - 1,
                Ordering::Release,
            );
            self.set_ctrl_release(index, h2(hash));
        }
    }

    /// Searches for an empty bucket which is suitable for inserting a new element
    /// and sets the hash for that slot.
    ///
    /// Tombstones are never reused: a lookup stops only on an empty bucket, so filling a
    /// `DELETED` bucket in the middle of a probe sequence would hide the elements behind it.
    ///
    /// There must be at least 1 empty bucket in the table.
    ///
    /// # Safety
    /// The stores are not atomic, so no other thread may access the table.
    #[inline]
    unsafe fn prepare_insert_slot(self, hash: u64) -> usize {
        unsafe {
            let index = self.find_insert_slot(hash);
            self.set_ctrl_h2(index, hash);
            index
        }
    }

    /// Searches for an empty bucket which is suitable for inserting a new element.
    ///
    /// There must be at least 1 empty bucket in the table.
    #[inline]
    unsafe fn find_insert_slot(self, hash: u64) -> usize {
        unsafe {
            let mut probe_seq = self.info().probe_seq(hash);
            loop {
                let group = Group::load(self.ctrl(probe_seq.pos));
                if let Some(bit) = group.match_empty().lowest_set_bit() {
                    let result = (probe_seq.pos + bit) & self.info().bucket_mask;

                    return result;
                }
                probe_seq.move_next(self.info().bucket_mask);
            }
        }
    }

    #[inline]
    fn empty() -> Self {
        #[repr(C)]
        struct EmptyTable {
            info: TableInfo,
            control_bytes: [Group; 2], // 2 groups to fit Group::WIDTH + 1 bytes
        }

        const EMPTY_TABLE_REF: TableInfoRef =
            unsafe { TableInfoRef::new((&raw const (*EMPTY_TABLE.get()).info).cast_mut()) };

        // SAFETY: The `next_retired` `Cell` of the static table is never accessed;
        // `RetiredIter` stops at it and it is never retired itself.
        static EMPTY_TABLE: StaticUnsafeCell<EmptyTable> = unsafe {
            StaticUnsafeCell::new(EmptyTable {
                info: TableInfo {
                    bucket_mask: 0,
                    growth_left: AtomicUsize::new(0),
                    tombstones: AtomicUsize::new(0),
                    can_free: AtomicBool::new(false),
                    next_retired: Cell::new(EMPTY_TABLE_REF),
                },
                control_bytes: [Group::EMPTY; 2],
            })
        };

        EMPTY_TABLE_REF
    }

    #[inline]
    fn retired_iter(self) -> RetiredIter {
        RetiredIter { next: self }
    }
}

struct RetiredIter {
    next: TableInfoRef,
}

impl Iterator for RetiredIter {
    type Item = TableInfoRef;

    #[inline]
    fn next(&mut self) -> Option<Self::Item> {
        if self.next == TableInfoRef::empty() {
            None
        } else {
            let table = self.next;
            self.next = unsafe { table.info().next_retired.get() };
            Some(table)
        }
    }
}

#[repr(transparent)]
struct TableRef<T> {
    info: TableInfoRef,

    marker: PhantomData<*mut T>,
}

impl<T> Copy for TableRef<T> {}
impl<T> Clone for TableRef<T> {
    #[inline]
    fn clone(&self) -> Self {
        *self
    }
}

impl<T> TableRef<T> {
    #[inline]
    fn from(info: TableInfoRef) -> Self {
        Self {
            info,
            marker: PhantomData,
        }
    }

    #[inline]
    fn empty() -> Self {
        Self::from(TableInfoRef::empty())
    }

    #[inline]
    fn layout(bucket_count: usize) -> Option<(Layout, usize)> {
        // There can be padding at the start of the layout if the alignment of `T` is smaller than `TableInfo`.
        // Buckets are accessed relatively from the start of `TableInfo` and not from the start of the layout.
        let buckets_size = mem::size_of::<T>().checked_mul(bucket_count)?;

        // Align TableInfo to Group so there's a fixed offset for use in `TableInfoRef::ctrl
        let info_offset = align_up(
            buckets_size,
            mem::align_of::<TableInfo>().max(mem::align_of::<Group>()),
        )?;

        let after_info = info_offset.checked_add(mem::size_of::<TableInfo>())?;
        let ctrl_offset = align_up(after_info, mem::align_of::<Group>())?;
        let ctrl_size = bucket_count.checked_add(Group::WIDTH)?;
        let size = ctrl_offset.checked_add(ctrl_size)?;
        let align = mem::align_of::<T>()
            .max(mem::align_of::<TableInfo>())
            .max(mem::align_of::<Group>());
        let layout = Layout::from_size_align(size, align).ok()?;
        Some((layout, info_offset))
    }

    /// Allocates a table with `bucket_count` buckets.
    ///
    /// `bucket_count` must be a power of two of at least `Group::WIDTH`, which
    /// is what `capacity_to_buckets` returns. 0 underflows `bucket_mask`, 1
    /// leaves a `bucket_mask` of 0, which `free` and `clone` take as the marker
    /// for the static `EMPTY_TABLE` and would therefore neither deallocate nor
    /// copy, and any other value is not a usable mask for `ctrl` and
    /// `set_ctrl`.
    #[inline]
    fn allocate(bucket_count: usize) -> Self {
        debug_assert!(
            bucket_count.is_power_of_two() && bucket_count >= Group::WIDTH,
            "bucket count must be a power of two of at least the group width"
        );

        let (layout, info_offset) = Self::layout(bucket_count).expect("capacity overflow");

        let ptr =
            NonNull::new(unsafe { alloc(layout) }).unwrap_or_else(|| handle_alloc_error(layout));

        let info = unsafe { TableInfoRef::new(ptr.as_ptr().add(info_offset) as *mut TableInfo) };

        let result = Self {
            info,
            marker: PhantomData,
        };

        unsafe {
            result.info.as_ptr().write(TableInfo {
                bucket_mask: bucket_count - 1,
                growth_left: AtomicUsize::new(bucket_mask_to_capacity(bucket_count - 1)),
                tombstones: AtomicUsize::new(0),
                can_free: AtomicBool::new(false),
                next_retired: Cell::new(TableInfoRef::empty()),
            });

            result
                .info
                .ctrl(0)
                .write_bytes(EMPTY, result.info().num_ctrl_bytes());
        }

        result
    }

    #[inline]
    unsafe fn free(self) {
        unsafe {
            if self.info().bucket_mask > 0 {
                let _dealloc = guard(self, |table| {
                    let (layout, info_offset) =
                        Self::layout(table.info().buckets()).unwrap_unchecked();
                    dealloc(table.info.as_ptr().cast::<u8>().sub(info_offset), layout)
                });

                if mem::needs_drop::<T>() {
                    for index in 0..self.info().buckets() {
                        // We drop `DELETED` buckets too here as they are not dropped
                        // when they are removed.
                        if *self.info.ctrl(index) != EMPTY {
                            self.bucket(index).drop();
                        }
                    }
                }
            }
        }
    }

    fn from_maybe_empty_iter<
        S,
        I: Iterator<Item = T>,
        H: Fn(&S, &T) -> u64,
        const CHECK_LEN: bool,
    >(
        mut iter: I,
        iter_size: usize,
        capacity: usize,
        hash_builder: &S,
        hasher: H,
    ) -> TableRef<T> {
        if iter_size == 0 {
            debug_assert!(iter.next().is_none());

            if capacity > 0 {
                let buckets = capacity_to_buckets(capacity).expect("capacity overflow");
                TableRef::allocate(buckets)
            } else {
                TableRef::empty()
            }
        } else {
            let buckets =
                capacity_to_buckets(cmp::max(iter_size, capacity)).expect("capacity overflow");
            unsafe {
                TableRef::from_iter::<_, _, _, CHECK_LEN>(iter, buckets, hash_builder, hasher)
            }
        }
    }

    /// Allocates a new table and fills it with the content of an iterator
    ///
    /// # Safety
    /// `buckets` must be valid for `allocate`. With `CHECK_LEN` disabled the
    /// copy loop has no bound, so `iter` must then yield at most as many items
    /// as `buckets` gives capacity for.
    unsafe fn from_iter<S, I: Iterator<Item = T>, H: Fn(&S, &T) -> u64, const CHECK_LEN: bool>(
        iter: I,
        buckets: usize,
        hash_builder: &S,
        hasher: H,
    ) -> TableRef<T> {
        unsafe {
            let mut new_table = TableRef::allocate(buckets);

            let mut guard = guard(Some(new_table), |new_table| {
                new_table.map(|new_table| new_table.free());
            });

            let mut growth_left = *new_table.info_mut().growth_left.get_mut();

            // Copy all elements to the new table.
            for item in iter {
                if CHECK_LEN && growth_left == 0 {
                    debug_assert!(false, "excess items in iterator");
                    break;
                }

                // This may panic.
                let hash = hasher(hash_builder, &item);

                // We can use a simpler version of insert() here since:
                // - we know there is enough space in the table.
                // - all elements are unique.
                // - the table is still private to this thread, so the control bytes can be
                //   written non-atomically.
                let index = new_table.info.prepare_insert_slot(hash);

                new_table.bucket(index).write(item);

                growth_left -= 1;
            }

            *new_table.info_mut().growth_left.get_mut() = growth_left;

            *guard = None;

            new_table
        }
    }

    unsafe fn info(&self) -> &TableInfo {
        unsafe { self.info.info() }
    }

    unsafe fn info_mut(&mut self) -> &mut TableInfo {
        unsafe { self.info.info_mut() }
    }

    #[inline]
    unsafe fn bucket_past_last(&self) -> *mut T {
        self.info.as_ptr() as *mut T
    }

    /// Returns a pointer to an element in the table.
    #[inline]
    unsafe fn bucket(&self, index: usize) -> Bucket<T> {
        unsafe {
            debug_assert!(index < self.info().buckets());

            Bucket {
                ptr: NonNull::new_unchecked(self.bucket_past_last().sub(index)),
            }
        }
    }

    /// Returns an iterator over every element in the table. It is up to
    /// the caller to ensure that the table outlives the `RawIterRange`.
    /// Because we cannot make the `next` method unsafe on the `RawIterRange`
    /// struct, we have to make the `iter` method unsafe.
    #[inline]
    unsafe fn iter(&self) -> RawIterRange<T> {
        unsafe {
            let data = Bucket {
                ptr: NonNull::new_unchecked(self.bucket_past_last()),
            };
            RawIterRange::new(self.info.ctrl(0), data, self.info().buckets())
        }
    }

    /// Searches for an element in the table.
    #[inline]
    unsafe fn search<R>(
        &self,
        hash: u64,
        mut eq: impl FnMut(&T) -> bool,
        mut stop: impl FnMut(&Group, &ProbeSeq) -> Option<R>,
    ) -> Result<(usize, Bucket<T>), R> {
        unsafe {
            let h2_hash = h2(hash);
            let mut probe_seq = self.info().probe_seq(hash);
            let mut group = Group::load(self.info.ctrl(probe_seq.pos));
            let mut bitmask = group.match_byte(h2_hash).into_iter();

            loop {
                if let Some(bit) = bitmask.next() {
                    let index = (probe_seq.pos + bit) & self.info().bucket_mask;

                    let bucket = self.bucket(index);
                    if likely(eq(bucket.as_ref())) {
                        return Ok((index, bucket));
                    }

                    // Look at the next bit
                    continue;
                }

                if let Some(stop) = stop(&group, &probe_seq) {
                    return Err(stop);
                }

                probe_seq.move_next(self.info().bucket_mask);
                group = Group::load(self.info.ctrl(probe_seq.pos));
                bitmask = group.match_byte(h2_hash).into_iter();
            }
        }
    }

    /// Searches for an element in the table.
    #[inline]
    unsafe fn find(&self, hash: u64, eq: impl FnMut(&T) -> bool) -> Option<(usize, Bucket<T>)> {
        unsafe {
            self.search(hash, eq, |group, _| {
                if likely(group.match_empty().any_bit_set()) {
                    Some(())
                } else {
                    None
                }
            })
            .ok()
        }
    }

    /// Searches for an element in the table.
    #[inline]
    unsafe fn find_potential(
        &self,
        hash: u64,
        eq: impl FnMut(&T) -> bool,
    ) -> Result<(usize, Bucket<T>), PotentialSlot<'static>> {
        unsafe {
            self.search(hash, eq, |group, probe_seq| {
                let bit = group.match_empty().lowest_set_bit();
                if likely(bit.is_some()) {
                    let index = (probe_seq.pos + bit.unwrap_unchecked()) & self.info().bucket_mask;
                    Some(PotentialSlot {
                        table_info: self.info,
                        index,
                        marker: PhantomData,
                    })
                } else {
                    None
                }
            })
        }
    }
}

impl<T: Clone> TableRef<T> {
    /// Allocates a table with `buckets` buckets and clones the contents of the current table
    /// into it, hashing every element with `hasher`.
    unsafe fn clone_table<S>(
        &self,
        hash_builder: &S,
        buckets: usize,
        hasher: impl Fn(&S, &T) -> u64,
    ) -> TableRef<T> {
        unsafe {
            debug_assert!(bucket_mask_to_capacity(buckets - 1) >= self.info().items());

            TableRef::from_iter::<_, _, _, false>(
                self.iter().map(|bucket| bucket.as_ref().clone()),
                buckets,
                hash_builder,
                hasher,
            )
        }
    }
}

#[cfg(feature = "nightly")]
unsafe impl<#[may_dangle] K, #[may_dangle] V, S> Drop for SyncTable<K, V, S> {
    #[inline]
    fn drop(&mut self) {
        self.drop_impl();
    }
}

#[cfg(not(feature = "nightly"))]
impl<K, V, S> Drop for SyncTable<K, V, S> {
    #[inline]
    fn drop(&mut self) {
        self.drop_impl();
    }
}

unsafe impl<K: Send, V: Send, S: Send> Send for SyncTable<K, V, S> {}
unsafe impl<K: Send + Sync, V: Send + Sync, S: Sync> Sync for SyncTable<K, V, S> {}

impl<K, V, S: Default> Default for SyncTable<K, V, S> {
    #[inline]
    fn default() -> Self {
        Self::new_with(Default::default(), 0)
    }
}

impl<K, V> SyncTable<K, V, DefaultHashBuilder> {
    /// Creates an empty [SyncTable].
    ///
    /// The hash map is initially created with a capacity of 0, so it will not allocate until it
    /// is first inserted into.
    #[inline]
    pub fn new() -> Self {
        Self::default()
    }
}

impl<K, V, S> SyncTable<K, V, S> {
    #[inline]
    fn drop_impl(&mut self) {
        unsafe {
            collect::cancel_by_ids(
                self.retired_head
                    .get_mut()
                    .retired_iter()
                    .filter(|table| !table.info().can_free.load(Ordering::Acquire))
                    .map(|table| &table.info().can_free as *const AtomicBool),
            );

            self.current().free();

            for info in self.retired_head.get_mut().retired_iter() {
                TableRef::<(K, V)>::from(info).free();
            }
        }
    }

    /// Creates an empty [SyncTable] with the specified capacity, using `hash_builder`
    /// to hash the elements or keys.
    ///
    /// The hash map will be able to hold at least `capacity` elements without
    /// reallocating. If `capacity` is 0, the hash map will not allocate.
    #[inline]
    pub fn new_with(hash_builder: S, capacity: usize) -> Self {
        Self {
            hash_builder,
            current: AtomicPtr::new(
                if capacity > 0 {
                    TableRef::<(K, V)>::allocate(
                        capacity_to_buckets(capacity).expect("capacity overflow"),
                    )
                } else {
                    TableRef::empty()
                }
                .info
                .as_ptr(),
            ),
            retired_head: Cell::new(TableInfoRef::empty()),
            retired_tail: Cell::new(None),
            marker: PhantomData,
            lock: Mutex::new(()),
        }
    }

    /// Returns a reference to the table's `BuildHasher`.
    #[inline]
    pub fn hasher(&self) -> &S {
        &self.hash_builder
    }

    /// Gets a reference to the underlying mutex that protects writes.
    #[inline]
    pub fn mutex(&self) -> &Mutex<()> {
        &self.lock
    }

    /// Creates a [Read] handle from a pinned region.
    ///
    /// Use [crate::collect::pin] to get a `Pin` instance.
    #[inline]
    pub fn read<'a>(&'a self, pin: Pin<'a>) -> Read<'a, K, V, S> {
        let _pin = pin;
        Read { table: self }
    }

    /// Creates a [Write] handle without checking for exclusive access.
    ///
    /// # Safety
    ///
    /// It's up to the caller to ensure no other [Write] handle, [LockedWrite] handle or `&mut self`
    /// borrow exists at the same time, through a happens-before relationship, across all threads.
    #[inline]
    pub unsafe fn unsafe_write(&self) -> Write<'_, K, V, S> {
        Write::new_and_prune(self)
    }

    /// Creates a [Write] handle without checking for exclusive access.
    ///
    /// This does not prune old tables unlike [SyncTable::unsafe_write].
    /// Instead [Write::prune] must be manually called to free old tables.
    ///
    /// # Safety
    ///
    /// It's up to the caller to ensure no other [Write] handle, [LockedWrite] handle or `&mut self`
    /// borrow exists at the same time, through a happens-before relationship, across all threads.
    #[inline]
    pub unsafe fn unsafe_write_no_prune(&self) -> Write<'_, K, V, S> {
        Write { table: self }
    }

    /// Creates a [Write] handle from a mutable reference.
    #[inline]
    pub fn write(&mut self) -> Write<'_, K, V, S> {
        Write::new_and_prune(self)
    }

    /// Creates a [Write] handle from a mutable reference.
    ///
    /// This does not prune old tables unlike [SyncTable::write].
    /// Instead [Write::prune] must be manually called to free old tables.
    #[inline]
    pub fn write_no_prune(&mut self) -> Write<'_, K, V, S> {
        Write { table: self }
    }

    /// Creates a [LockedWrite] handle by taking the underlying mutex that protects writes.
    #[inline]
    pub fn lock(&self) -> LockedWrite<'_, K, V, S> {
        let mut lock = self.lock_no_prune();
        lock.write().prune();
        lock
    }

    /// Creates a [LockedWrite] handle by taking the underlying mutex that protects writes.
    ///
    /// This does not prune old tables unlike [SyncTable::lock].
    /// Instead [Write::prune] must be manually called to free old tables.
    #[inline]
    pub fn lock_no_prune(&self) -> LockedWrite<'_, K, V, S> {
        let guard = self.lock.lock();

        LockedWrite {
            table: self,
            _guard: guard,
        }
    }

    /// Creates a [LockedWrite] handle from a guard protecting the underlying mutex that protects writes.
    ///
    /// # Panics
    ///
    /// Panics if `guard` does not guard this table's mutex.
    #[inline]
    pub fn lock_from_guard<'a>(&'a self, guard: MutexGuard<'a, ()>) -> LockedWrite<'a, K, V, S> {
        let mut lock = self.lock_from_guard_no_prune(guard);
        lock.write().prune();
        lock
    }

    /// Creates a [LockedWrite] handle from a guard protecting the underlying mutex that protects writes.
    ///
    /// This does not prune old tables unlike [SyncTable::lock_from_guard].
    /// Instead [Write::prune] must be manually called to free old tables.
    ///
    /// # Panics
    ///
    /// Panics if `guard` does not guard this table's mutex.
    #[inline]
    pub fn lock_from_guard_no_prune<'a>(
        &'a self,
        guard: MutexGuard<'a, ()>,
    ) -> LockedWrite<'a, K, V, S> {
        // Verify that we are target of the guard
        assert_eq!(
            &self.lock as *const _,
            MutexGuard::mutex(&guard) as *const _
        );

        LockedWrite {
            table: self,
            _guard: guard,
        }
    }

    #[inline]
    fn current(&self) -> TableRef<(K, V)> {
        unsafe { TableRef::from(TableInfoRef::new(self.current.load(Ordering::Acquire))) }
    }
}

impl<K, V, S: BuildHasher> SyncTable<K, V, S> {
    #[inline]
    fn unwrap_hash<Q>(&self, key: &Q, hash: Option<u64>) -> u64
    where
        K: Borrow<Q>,
        Q: ?Sized + Hash,
    {
        match hash {
            Some(hash) => {
                // A hash which disagrees with the table's hasher puts the element outside its
                // own probe sequence, so it is lost to later lookups.
                debug_assert_eq!(hash, self.hash_key(key), "hash does not match the key");
                hash
            }
            None => self.hash_key(key),
        }
    }

    /// Hashes a key with the table's hasher.
    #[inline]
    pub fn hash_key<Q>(&self, key: &Q) -> u64
    where
        K: Borrow<Q>,
        Q: ?Sized + Hash,
    {
        make_insert_hash(&self.hash_builder, key)
    }

    /// Gets a mutable reference to the value of an element in the table.
    ///
    /// `hash` must be a hash of `key` from the table's hasher if present.
    #[inline]
    pub fn get_mut<Q>(&mut self, key: &Q, hash: Option<u64>) -> Option<(&K, &mut V)>
    where
        K: Borrow<Q>,
        Q: ?Sized + Eq + Hash,
    {
        let hash = self.unwrap_hash(key, hash);

        unsafe {
            self.current().find(hash, eq(key)).map(|(_, bucket)| {
                let pair = bucket.as_mut();
                (&pair.0, &mut pair.1)
            })
        }
    }
}

impl<'a, K, V, S: BuildHasher> Read<'a, K, V, S> {
    /// Gets a reference to an element in the table or a potential location
    /// where that element could be.
    ///
    /// `hash` must be a hash of `key` from the table's hasher if present.
    #[inline]
    pub fn get_potential<Q>(
        self,
        key: &Q,
        hash: Option<u64>,
    ) -> Result<(&'a K, &'a V), PotentialSlot<'a>>
    where
        K: Borrow<Q>,
        Q: ?Sized + Eq + Hash,
    {
        let hash = self.table.unwrap_hash(key, hash);

        unsafe {
            match self.table.current().find_potential(hash, eq(key)) {
                Ok((_, bucket)) => Ok(bucket.as_pair_ref()),
                Err(slot) => Err(slot),
            }
        }
    }

    /// Gets a reference to an element in the table.
    ///
    /// `hash` must be a hash of `key` from the table's hasher if present.
    #[inline]
    pub fn get<Q>(self, key: &Q, hash: Option<u64>) -> Option<(&'a K, &'a V)>
    where
        K: Borrow<Q>,
        Q: ?Sized + Eq + Hash,
    {
        let hash = self.table.unwrap_hash(key, hash);

        unsafe {
            self.table
                .current()
                .find(hash, eq(key))
                .map(|(_, bucket)| bucket.as_pair_ref())
        }
    }

    /// Gets a reference to an element in the table, using a closure to find the match.
    #[inline]
    pub fn get_from_hash(
        self,
        hash: u64,
        mut is_match: impl FnMut(&K) -> bool,
    ) -> Option<(&'a K, &'a V)> {
        unsafe {
            self.table
                .current()
                .find(hash, move |(k, _)| is_match(k))
                .map(|(_, bucket)| bucket.as_pair_ref())
        }
    }
}

impl<'a, K, V, S> Read<'a, K, V, S> {
    /// Gets a reference to an element in the table with a custom equality function.
    #[inline]
    pub fn get_with_eq(
        self,
        hash: u64,
        mut eq: impl FnMut(&K, &V) -> bool,
    ) -> Option<(&'a K, &'a V)> {
        unsafe {
            self.table
                .current()
                .find(hash, |(k, v)| eq(k, v))
                .map(|(_, bucket)| bucket.as_pair_ref())
        }
    }

    /// Returns the number of elements the map can hold without reallocating.
    ///
    /// This value may be inaccurate if there's concurrent writers.
    #[inline]
    pub fn capacity(self) -> usize {
        let table = self.table.current();
        unsafe {
            // Tombstones may never exceed the capacity, so this won't underflow.
            bucket_mask_to_capacity(table.info().bucket_mask)
                - table.info().tombstones.load(Ordering::Acquire)
        }
    }

    /// Returns the number of elements in the table.
    ///
    /// This value may be inaccurate if there's concurrent writers.
    #[inline]
    pub fn len(self) -> usize {
        unsafe { self.table.current().info().items() }
    }

    /// An iterator visiting all key-value pairs in arbitrary order.
    /// The iterator element type is `(&'a K, &'a V)`.
    #[inline]
    pub fn iter(self) -> Iter<'a, K, V> {
        let table = self.table.current();

        // Here we tie the lifetime of self to the iter.
        unsafe {
            Iter {
                inner: table.iter(),
                marker: PhantomData,
            }
        }
    }

    #[allow(dead_code)]
    fn dump(self)
    where
        K: std::fmt::Debug,
        V: std::fmt::Debug,
    {
        let table = self.table.current();

        println!("Table dump:");

        unsafe {
            for i in 0..table.info().buckets() {
                if table.info.ctrl_acquire(i) == EMPTY {
                    println!("[#{:x}]", i);
                } else {
                    println!(
                        "[#{:x}, ${:x}, {:?}]",
                        i,
                        table.info.ctrl_acquire(i),
                        table.bucket(i).as_ref()
                    );
                }
            }
        }

        println!("--------");
    }
}

impl<K: Hash + Clone, V: Clone, S: Clone + BuildHasher> Clone for SyncTable<K, V, S> {
    /// Cloning can give an inconsistent view of the table if there are concurrent writers.
    /// Hold [SyncTable::lock] across the clone if a consistent view is needed.
    fn clone(&self) -> SyncTable<K, V, S> {
        pin(|_pin| {
            let table = self.current();

            unsafe {
                let buckets = table.info().buckets();
                let hash_builder = self.hash_builder.clone();

                SyncTable {
                    current: AtomicPtr::new(
                        if table.info().bucket_mask > 0 {
                            // Hash with the new hash builder as it
                            // may not be equivalent to the old
                            table.clone_table(&hash_builder, buckets, hasher)
                        } else {
                            TableRef::empty()
                        }
                        .info
                        .as_ptr(),
                    ),
                    hash_builder,
                    retired_head: Cell::new(TableInfoRef::empty()),
                    retired_tail: Cell::new(None),
                    marker: PhantomData,
                    lock: Mutex::new(()),
                }
            }
        })
    }
}

impl<'a, K, V, S> Write<'a, K, V, S> {
    #[inline]
    fn new_and_prune(table: &'a SyncTable<K, V, S>) -> Self {
        let mut write = Self { table };
        write.try_prune_tables();
        write
    }

    /// Frees old unused tables
    #[inline]
    pub fn prune(&mut self) {
        self.try_prune_tables();
    }

    /// Creates a [Read] handle which gives access to read operations.
    #[inline]
    pub fn read(&self) -> Read<'_, K, V, S> {
        Read { table: self.table }
    }

    /// Returns a reference to the table's `BuildHasher`.
    #[inline]
    pub fn hasher(&self) -> &'a S {
        &self.table.hash_builder
    }
}

impl<'a, K, V: Clone, S: BuildHasher> Write<'a, K, V, S> {
    /// Removes an element from the table, and returns a reference to it if was present.
    ///
    /// The element will only be dropped after the internal table currently in use is replaced
    /// for example by `replace` or due to expansion.
    ///
    /// `hash` must be a hash of `key` from the table's hasher if present.
    #[inline]
    pub fn remove<Q>(&mut self, key: &Q, hash: Option<u64>) -> Option<(&K, &V)>
    where
        K: Borrow<Q>,
        Q: ?Sized + Eq + Hash,
    {
        // V: Clone bound is not currently needed,
        // but would allow for a downsizing of the table

        let hash = self.table.unwrap_hash(key, hash);

        let table = self.table.current();

        unsafe {
            table.find(hash, eq(key)).map(|(index, bucket)| {
                debug_assert!(is_full(table.info.ctrl_acquire(index)));
                table.info.set_ctrl_release(index, DELETED);

                // Increase the tombstone count after `DELETED` is set.
                // This ensures a reader which sees `n` tombstones
                // also will see at least `n` `DELETED` slots.
                table.info().tombstones.store(
                    table.info().tombstones.load(Ordering::Relaxed) + 1,
                    Ordering::Release,
                );
                bucket.as_pair_ref()
            })
        }
    }
}

impl<'a, K: Hash + Eq + Clone, V: Clone, S: BuildHasher> Write<'a, K, V, S> {
    /// Inserts a element into the table.
    /// Returns `false` if it already exists and doesn't update the value.
    ///
    /// `hash` must be a hash of `key` from the table's hasher if present.
    #[inline]
    pub fn insert(&mut self, key: K, value: V, hash: Option<u64>) -> bool {
        let hash = self.table.unwrap_hash(&key, hash);

        let mut table = self.table.current();

        unsafe {
            if unlikely(table.info().growth_left.load(Ordering::Relaxed) == 0) {
                table = self.expand_by_one();
            }

            match table.find_potential(hash, eq(&key)) {
                Ok(_) => false,
                Err(slot) => {
                    slot.insert_new_unchecked(self, key, value, Some(hash));
                    true
                }
            }
        }
    }
}

impl<'a, K: Hash + Clone, V: Clone, S: BuildHasher> Write<'a, K, V, S> {
    /// Inserts a new element into the table, and returns a reference to it.
    ///
    /// An element with the same `key` must not be in the table already.
    ///
    /// `hash` must be a hash of `key` from the table's hasher if present.
    #[inline]
    pub fn insert_new(&mut self, key: K, value: V, hash: Option<u64>) -> (&K, &V) {
        let hash = self.table.unwrap_hash(&key, hash);

        let mut table = self.table.current();

        unsafe {
            if unlikely(table.info().growth_left.load(Ordering::Relaxed) == 0) {
                table = self.expand_by_one();
            }

            let index = table.info.find_insert_slot(hash);

            let bucket = table.bucket(index);
            bucket.write((key, value));

            table.info.record_item_insert_at(index, hash);

            bucket.as_pair_ref()
        }
    }

    /// Reserve room for one more element.
    #[inline]
    pub fn reserve_one(&mut self) {
        let table = self.table.current();

        if unlikely(unsafe { table.info().growth_left.load(Ordering::Relaxed) } == 0) {
            self.expand_by_one();
        }
    }

    #[cold]
    #[inline(never)]
    fn expand_by_one(&mut self) -> TableRef<(K, V)> {
        self.expand_by(1)
    }

    /// Makes room for `additional` more elements by replacing the current table with a freshly
    /// allocated one holding clones of its elements, and returns the new table.
    fn expand_by(&mut self, additional: usize) -> TableRef<(K, V)> {
        let table = self.table.current();

        // Avoid `Option::ok_or_else` because it bloats LLVM IR.
        let new_items = match unsafe { table.info() }.items().checked_add(additional) {
            Some(new_items) => new_items,
            None => panic!("capacity overflow"),
        };

        let full_capacity = bucket_mask_to_capacity(unsafe { table.info().bucket_mask });

        let new_capacity = if new_items <= full_capacity / 2 {
            // Mostly tombstones, so aim for a new table which is at least 50% empty.
            new_items * 2 // This cannot overflow as it's at most `full_capacity`
        } else {
            // The `full_capacity + 1` cannot overflow as any
            // `bucket_mask_to_capacity` result is always below usize::MAX.
            usize::max(new_items, full_capacity + 1)
        };

        unsafe {
            debug_assert!(table.info().items() <= new_capacity);
        }

        let buckets = capacity_to_buckets(new_capacity).expect("capacity overflow");

        let new_table = unsafe { table.clone_table(&self.table.hash_builder, buckets, hasher) };

        self.replace_table(new_table);

        new_table
    }
}

impl<'a, K, V, S> Write<'a, K, V, S> {
    #[inline]
    fn try_prune_tables(&mut self) {
        if unlikely(unsafe {
            self.table
                .retired_head
                .get()
                .info()
                .can_free
                .load(Ordering::Acquire)
        }) {
            self.prune_tables();
        }
    }

    #[cold]
    #[inline(never)]
    fn prune_tables(&mut self) {
        unsafe {
            let head = &self.table.retired_head;
            while head.get().info().can_free.load(Ordering::Acquire) {
                // Remove from the list before calling `free` to avoid double free if a destructor panics.
                let table = head.get();
                head.set(table.info().next_retired.get());
                if self.table.retired_tail.get() == Some(table) {
                    self.table.retired_tail.set(None);
                }

                TableRef::<(K, V)>::from(table).free();
            }
        }
    }

    fn replace_table(&mut self, new_table: TableRef<(K, V)>) {
        let table = self.table.current();

        self.table
            .current
            .store(new_table.info.as_ptr(), Ordering::Release);

        if table.info == TableInfoRef::empty() {
            return;
        }

        // Add the old table to the `next_retired` list
        unsafe {
            table.info().next_retired.set(TableInfoRef::empty());

            match self.table.retired_tail.get() {
                Some(tail) => tail.info().next_retired.set(table.info),
                None => self.table.retired_head.set(table.info),
            }
            self.table.retired_tail.set(Some(table.info));
        }

        // Keep ownership of retired tables in `self` so forgetting the container leaks instead of
        // running drop glue after borrowed data has expired.
        unsafe {
            collect::defer_by_id(&table.info().can_free);
        }
    }
}

impl<K: Hash, V, S: BuildHasher> Write<'_, K, V, S> {
    /// Replaces the content of the table with the content of the iterator.
    /// All the elements must be unique.
    /// `capacity` specifies the new capacity if it's greater than the length of the iterator.
    #[inline]
    pub fn replace<I: IntoIterator<Item = (K, V)>>(&mut self, iter: I, capacity: usize) {
        let iter = iter.into_iter();

        let (min, max) = iter.size_hint();

        let table = if max == Some(min) {
            // The iterator reports an exact length,
            // but `CHECK_LEN` is still needed to avoid UB for buggy iterators.
            TableRef::from_maybe_empty_iter::<_, _, _, true>(
                iter,
                min,
                capacity,
                &self.table.hash_builder,
                hasher,
            )
        } else {
            let elements: Vec<_> = iter.collect();
            let len = elements.len();
            TableRef::from_maybe_empty_iter::<_, _, _, false>(
                elements.into_iter(),
                len,
                capacity,
                &self.table.hash_builder,
                hasher,
            )
        };

        self.replace_table(table);
    }
}

impl<K: Eq + Hash + Clone, V: Clone, S: BuildHasher + Default> FromIterator<(K, V)>
    for SyncTable<K, V, S>
{
    fn from_iter<I: IntoIterator<Item = (K, V)>>(iter: I) -> Self {
        let iter = iter.into_iter();
        let mut map = Self::new_with(S::default(), iter.size_hint().0);
        {
            let mut write = map.write();
            iter.for_each(|(k, v)| {
                write.insert(k, v, None);
            });
        }
        map
    }
}

/// Represents where a value would be if inserted.
///
/// Created by calling `get_potential` on [Read]. All methods on this type takes a table handle
/// and this must be a handle to the same table `get_potential` was called on. Operations also must
/// be on the same element as given to `get_potential`. The operations have a fast path for when
/// the element is still missing.
#[derive(Copy, Clone)]
pub struct PotentialSlot<'a> {
    table_info: TableInfoRef,
    index: usize,
    marker: PhantomData<&'a TableInfo>,
}

impl<'a> PotentialSlot<'a> {
    #[inline]
    unsafe fn is_empty<T>(self, table: TableRef<T>) -> bool {
        unsafe {
            let index = self.index;

            // Check that we are still looking at the same table,
            // otherwise our index could be out of date due to expansion,
            // a `replace` call, or mixing up a different table.
            table.info.as_ptr() == self.table_info.as_ptr()
                && self.table_info.ctrl_acquire(index) == EMPTY
        }
    }

    /// Gets a reference to an element in the table.
    ///
    /// `hash` must be a hash of `key` from the table's hasher if present.
    ///
    /// `table` and `key` must match the values given when `self` was
    /// created using a `get_potential` or `refresh` call.
    #[inline]
    pub fn get<'b, Q, K, V, S: BuildHasher>(
        self,
        table: Read<'b, K, V, S>,
        key: &Q,
        hash: Option<u64>,
    ) -> Option<(&'b K, &'b V)>
    where
        K: Borrow<Q>,
        Q: ?Sized + Eq + Hash,
    {
        unsafe {
            if likely(self.is_empty(table.table.current())) {
                return None;
            }
        }

        cold_path(|| table.get(key, hash))
    }

    /// Returns a new up-to-date potential slot.
    /// This can be useful if there could have been insertions since the slot was derived
    /// and you want to use `insert_new`.
    ///
    /// `hash` must be a hash of `key` from the table's hasher if present.
    ///
    /// `table` and `key` must match the values given when `self` was
    /// created using a `get_potential` or `refresh` call.
    #[inline]
    pub fn refresh<Q, K, V, S: BuildHasher>(
        self,
        table: Read<'a, K, V, S>,
        key: &Q,
        hash: Option<u64>,
    ) -> Result<(&'a K, &'a V), PotentialSlot<'a>>
    where
        K: Borrow<Q>,
        Q: ?Sized + Eq + Hash,
    {
        unsafe {
            if likely(self.is_empty(table.table.current())) {
                return Err(self);
            }
        }

        cold_path(|| table.get_potential(key, hash))
    }

    #[inline]
    unsafe fn insert<'b, K, V>(
        self,
        table: TableRef<(K, V)>,
        value: (K, V),
        hash: u64,
    ) -> (&'b K, &'b V) {
        unsafe {
            let index = self.index;
            let bucket = table.bucket(index);
            bucket.write(value);

            table.info.record_item_insert_at(index, hash);

            let pair = bucket.as_ref();
            (&pair.0, &pair.1)
        }
    }

    /// Inserts a new element into the table, and returns a reference to it.
    ///
    /// An element with the same `key` must not be in the table already.
    ///
    /// `hash` must be a hash of `key` from the table's hasher if present.
    ///
    /// `table` and `key` must match the values given when `self` was
    /// created using a `get_potential` or `refresh` call.
    #[inline]
    pub fn insert_new<'b, K: Hash + Clone, V: Clone, S: BuildHasher>(
        self,
        table: &'b mut Write<'_, K, V, S>,
        key: K,
        value: V,
        hash: Option<u64>,
    ) -> (&'b K, &'b V) {
        let hash = table.table.unwrap_hash(&key, hash);

        unsafe {
            let table = table.table.current();

            if likely(self.is_empty(table) && table.info().growth_left.load(Ordering::Relaxed) > 0)
            {
                debug_assert_eq!(self.index, table.info.find_insert_slot(hash));

                return self.insert(table, (key, value), hash);
            }
        }

        cold_path(|| table.insert_new(key, value, Some(hash)))
    }

    /// Inserts a new element into the table, and returns a reference to it.
    ///
    /// An element with the same `key` must not be in the table already.
    ///
    /// `hash` must be a hash of `key` from the table's hasher if present.
    ///
    /// `key` must match the value given when `self` was created using a
    /// `get_potential` or `refresh` call.
    ///
    /// # Safety
    /// - `table` must match the value given when `self` was created using a
    ///   `get_potential` or `refresh` call.
    /// - There must not have been any insertions or `replace` calls to the table since `self`
    ///   was derived.
    /// - There must be capacity left in the current table.
    #[inline]
    unsafe fn insert_new_unchecked<'b, K: Hash, V, S: BuildHasher>(
        self,
        table: &'b mut Write<'_, K, V, S>,
        key: K,
        value: V,
        hash: Option<u64>,
    ) -> (&'b K, &'b V) {
        unsafe {
            let hash = table.table.unwrap_hash(&key, hash);

            let table = table.table.current();

            debug_assert!(self.is_empty(table));
            debug_assert!(table.info().growth_left.load(Ordering::Relaxed) > 0);

            self.insert(table, (key, value), hash)
        }
    }
}

/// An iterator over the entries of a [SyncTable].
///
/// This `struct` is created by the [Read::iter] method on [Read]. See its
/// documentation for more.
pub struct Iter<'a, K, V> {
    inner: RawIterRange<(K, V)>,
    marker: PhantomData<&'a (K, V)>,
}

impl<K, V> Clone for Iter<'_, K, V> {
    #[inline]
    fn clone(&self) -> Self {
        Iter {
            inner: self.inner.clone(),
            marker: PhantomData,
        }
    }
}

impl<K: fmt::Debug, V: fmt::Debug> fmt::Debug for Iter<'_, K, V> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_list().entries(self.clone()).finish()
    }
}

impl<'a, K, V> Iterator for Iter<'a, K, V> {
    type Item = (&'a K, &'a V);

    #[inline]
    fn next(&mut self) -> Option<(&'a K, &'a V)> {
        self.inner
            .next()
            .map(|bucket| unsafe { bucket.as_pair_ref() })
    }
}

impl<K, V> FusedIterator for Iter<'_, K, V> {}

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
    let result = if cap < 8 {
        // We don't bother with a table size of 2 buckets since that can only
        // hold a single element. Instead we skip directly to a 4 bucket table
        // which can hold 3 elements.
        if cap < 4 { 4 } else { 8 }
    } else {
        // Otherwise require 1/8 buckets to be empty (87.5% load)
        //
        // Be careful when modifying this, calculate_layout relies on the
        // overflow check here.
        let adjusted_cap = cap.checked_mul(8)? / 7;

        // Any overflows will have been caught by the checked_mul. Also, any
        // rounding errors from the division above will be cleaned up by
        // next_power_of_two (which can't overflow because of the previous divison).
        adjusted_cap.next_power_of_two()
    };

    // Have at least the number of buckets required to fill a group.
    // This avoids logic to deal with control bytes not associated with a bucket
    // when batch processing a group.
    Some(usize::max(result, Group::WIDTH))
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

/// Iterator over a sub-range of a table.
struct RawIterRange<T> {
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
        unsafe {
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

/// Get a suitable shard index from a hash when sharding the hash table.
///
/// `shards` must be a power of 2.
#[inline]
pub fn shard_index_by_hash(hash: u64, shards: usize) -> usize {
    assert!(shards.is_power_of_two());
    let shard_bits = shards.trailing_zeros() as usize;

    // Assume the hash is potentially just a `usize` which can be smaller than u64
    let hash_len_bits = usize::min(mem::size_of::<usize>(), mem::size_of::<u64>()) * 8;

    // Ignore the top 7 bits as we use these for bucket hashes and get the next `shard_bits` highest bits.
    // hashbrown also uses the lowest bits, so we can't use those
    let shift = (hash_len_bits - 7).saturating_sub(shard_bits);
    let bits = (hash >> shift) as usize;
    bits & (shards - 1)
}
