use crate::{
    qsbr::{pin, Pin},
    scopeguard::guard,
};
use core::ptr::NonNull;
use crossbeam_utils::atomic::AtomicCell;
use parking_lot::{Mutex, MutexGuard};
use std::{
    alloc::{handle_alloc_error, Allocator, Global, Layout, LayoutError},
    cell::UnsafeCell,
    intrinsics::unlikely,
    iter::FromIterator,
    marker::PhantomData,
    mem,
    ops::{Deref, DerefMut},
    slice::Iter,
    sync::atomic::Ordering,
};
use std::{
    cmp,
    ptr::slice_from_raw_parts,
    sync::{atomic::AtomicUsize, Arc},
};

mod code;
mod tests;

/// A reference to the table which can read from it. It is acquired either by a pin,
/// or by exclusive access to the table.
#[derive(Clone, Copy)]
pub struct Read<'a, T> {
    table: &'a SyncPushVec<T>,
}

/// A reference to the table which can write to it. It is acquired either by a lock,
/// or by exclusive access to the table.
pub struct Write<'a, T> {
    table: &'a SyncPushVec<T>,
}

/// A reference to the table which can write to it. It is acquired either by a lock.
pub struct LockedWrite<'a, T> {
    table: Write<'a, T>,
    _guard: MutexGuard<'a, ()>,
}

impl<'a, T> Deref for LockedWrite<'a, T> {
    type Target = Write<'a, T>;

    #[inline]
    fn deref(&self) -> &Self::Target {
        &self.table
    }
}

impl<'a, T> DerefMut for LockedWrite<'a, T> {
    #[inline]
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.table
    }
}

pub struct SyncPushVec<T> {
    current: AtomicCell<TableRef<T>>,

    lock: Mutex<()>,

    old: UnsafeCell<Vec<Arc<DestroyTable<T>>>>,

    // Tell dropck that we own instances of T.
    marker: PhantomData<T>,
}

struct TableInfo {
    items: AtomicUsize,
    capacity: usize,
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
        if cfg!(debug_assertions) {
            let real = Self::layout(0).unwrap().0;
            let dummy = Layout::new::<TableInfo>().align_to(real.align()).unwrap();
            debug_assert_eq!(real, dummy);
        }

        // FIXME: Figure out if we need this to be aligned to `T`, even though no references to `T`
        // should be created from it.
        // There can be padding bytes at the end of a real layout to make it a multiple of the
        // alignment, but these aren't accessed in practise.
        static EMPTY: TableInfo = TableInfo {
            capacity: 0,
            items: AtomicUsize::new(0),
        };

        Self {
            data: unsafe { NonNull::new_unchecked(&EMPTY as *const TableInfo as *mut TableInfo) },
            marker: PhantomData,
        }
    }

    #[inline]
    fn layout(capacity: usize) -> Result<(Layout, usize), LayoutError> {
        let info = Layout::new::<TableInfo>();
        let data = Layout::new::<T>().repeat(capacity)?.0;
        info.extend(data)
    }

    #[inline]
    fn allocate(capacity: usize) -> Self {
        let (layout, _) = Self::layout(capacity).expect("capacity overflow");

        let ptr: NonNull<u8> = Global
            .allocate(layout)
            .map(|ptr| ptr.cast())
            .unwrap_or_else(|_| handle_alloc_error(layout));

        let mut result = Self {
            data: ptr.cast(),
            marker: PhantomData,
        };

        unsafe {
            *result.info_mut() = TableInfo {
                capacity,
                items: AtomicUsize::new(0),
            };
        }

        result
    }

    #[inline]
    unsafe fn free(self) {
        let items = self.info().items.load(Ordering::Relaxed);
        if items > 0 {
            if mem::needs_drop::<T>() {
                for i in 0..items {
                    self.data(i).drop_in_place();
                }
            }
            Global.deallocate(
                self.data.cast(),
                Self::layout(self.info().capacity).unwrap_unchecked().0,
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
    unsafe fn first(&self) -> *mut T {
        let offset = Self::layout(0).unwrap_unchecked().1;
        (self.data.as_ptr() as *const u8).add(offset) as *mut T
    }

    /// Returns a pointer to an element in the table.
    #[inline]
    unsafe fn data(&self, index: usize) -> *mut T {
        debug_assert!(index < self.info().items.load(Ordering::Acquire));

        self.first().add(index)
    }
}

impl<T: Clone> TableRef<T> {
    /// Allocates a new table of a different size and moves the contents of the
    /// current table into it.
    fn clone(&self, new_capacity: usize) -> TableRef<T> {
        unsafe {
            let mut new_table = TableRef::<T>::allocate(new_capacity);

            let mut guard = guard(Some(new_table), |new_table| {
                new_table.map(|new_table| new_table.free());
            });

            let iter = (*slice_from_raw_parts(
                self.first() as *const T,
                self.info().items.load(Ordering::Relaxed),
            ))
            .iter();

            // Copy all elements to the new table.
            for (index, item) in iter.enumerate() {
                new_table.first().add(index).write(item.clone());

                // Write items per iteration in case `clone` panics.
                *new_table.info_mut().items.get_mut() = index + 1;
            }

            *guard = None;

            new_table
        }
    }
}

struct DestroyTable<T> {
    table: TableRef<T>,
    lock: Mutex<bool>,
}

impl<T> DestroyTable<T> {
    unsafe fn run(&self) {
        let mut status = self.lock.lock();
        if !*status {
            *status = true;
            self.table.free();
        }
    }
}

unsafe impl<#[may_dangle] T> Drop for SyncPushVec<T> {
    #[inline]
    fn drop(&mut self) {
        unsafe {
            self.current.load().free();
            for table in self.old.get_mut() {
                table.run();
            }
        }
    }
}

unsafe impl<T: Send> Send for SyncPushVec<T> {}
unsafe impl<T: Send> Sync for SyncPushVec<T> {}

impl<T> Default for SyncPushVec<T> {
    #[inline]
    fn default() -> Self {
        Self::new()
    }
}

impl<T> SyncPushVec<T> {
    #[inline]
    pub fn new() -> Self {
        Self::with_capacity(0)
    }

    #[inline]
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            current: AtomicCell::new(if capacity > 0 {
                TableRef::allocate(capacity)
            } else {
                TableRef::empty()
            }),
            old: UnsafeCell::new(Vec::new()),
            marker: PhantomData,
            lock: Mutex::new(()),
        }
    }

    /// Gets a mutable reference to an element in the table.
    #[inline]
    pub fn get_mut(&mut self, index: usize) -> Option<&mut T> {
        let table = self.current.load();
        unsafe {
            if index < table.info().items.load(Ordering::Acquire) {
                Some(&mut *table.data(index))
            } else {
                None
            }
        }
    }

    #[inline]
    pub fn mutex(&self) -> &Mutex<()> {
        &self.lock
    }

    #[inline]
    pub fn read<'a>(&'a self, _pin: &'a Pin) -> Read<'a, T> {
        Read { table: self }
    }

    #[inline]
    pub unsafe fn unsafe_write(&self) -> Write<'_, T> {
        Write { table: self }
    }

    #[inline]
    pub fn write(&mut self) -> Write<'_, T> {
        Write { table: self }
    }

    /// Returns the number of elements in the table.
    #[inline]
    pub fn len(&self) -> usize {
        pin(|pin| self.read(pin).len())
    }

    #[inline]
    pub fn lock(&self) -> LockedWrite<'_, T> {
        LockedWrite {
            table: Write { table: self },
            _guard: self.lock.lock(),
        }
    }

    #[inline]
    pub fn lock_from_guard<'a>(&'a self, guard: MutexGuard<'a, ()>) -> LockedWrite<'a, T> {
        // Verify that we are target of the guard
        assert_eq!(
            &self.lock as *const _,
            MutexGuard::mutex(&guard) as *const _
        );

        LockedWrite {
            table: Write { table: self },
            _guard: guard,
        }
    }
}

impl<'a, T> Read<'a, T> {
    /// Gets a reference to an element in the table.
    #[inline]
    pub fn get(&self, index: usize) -> Option<&'a T> {
        let table = self.table.current.load();
        unsafe {
            if index < table.info().items.load(Ordering::Acquire) {
                Some(&mut *table.data(index))
            } else {
                None
            }
        }
    }

    /// Returns the number of elements the map can hold without reallocating.
    #[inline]
    pub fn capacity(&self) -> usize {
        unsafe { self.table.current.load().info().capacity }
    }

    /// Returns the number of elements in the table.
    #[inline]
    pub fn len(&self) -> usize {
        unsafe {
            self.table
                .current
                .load()
                .info()
                .items
                .load(Ordering::Acquire)
        }
    }

    #[inline]
    pub fn iter(&self) -> Iter<'a, T> {
        let table = self.table.current.load();
        unsafe {
            (*slice_from_raw_parts(
                table.first() as *const T,
                table.info().items.load(Ordering::Acquire),
            ))
            .iter()
        }
    }
}

impl<'a, T> Write<'a, T> {
    #[inline]
    pub fn read(&self) -> Read<'_, T> {
        Read { table: self.table }
    }
}

impl<'a, T: Clone> Write<'a, T> {
    /// Inserts a new element into the end of the table, and returns a refernce to it along
    /// with its index.
    #[inline]
    pub fn push(&mut self, value: T) -> (&'a T, usize) {
        let mut table = self.table.current.load();
        unsafe {
            let items = table.info().items.load(Ordering::Relaxed);

            if unlikely(items == table.info().capacity) {
                table = self.expand_by_one();
            }

            let result = table.first().add(items);

            result.write(value);

            table.info().items.store(items + 1, Ordering::Release);

            (&*result, items)
        }
    }

    #[cold]
    #[inline(never)]
    fn expand_by_one(&self) -> TableRef<T> {
        self.expand_by(1)
    }

    // Tiny Vecs are dumb. Skip to:
    // - 8 if the element size is 1, because any heap allocators is likely
    //   to round up a request of less than 8 bytes to at least 8 bytes.
    // - 4 if elements are moderate-sized (<= 1 KiB).
    // - 1 otherwise, to avoid wasting too much space for very short Vecs.
    const MIN_NON_ZERO_CAP: usize = if mem::size_of::<T>() == 1 {
        8
    } else if mem::size_of::<T>() <= 1024 {
        4
    } else {
        1
    };

    fn expand_by(&self, additional: usize) -> TableRef<T> {
        let table = self.table.current.load();

        let items = unsafe { table.info().items.load(Ordering::Relaxed) };
        let capacity = unsafe { table.info().capacity };

        // Avoid `Option::ok_or_else` because it bloats LLVM IR.
        let required_cap = match items.checked_add(additional) {
            Some(required_cap) => required_cap,
            None => panic!("capacity overflow"),
        };

        // This guarantees exponential growth. The doubling cannot overflow
        // because `cap <= isize::MAX` and the type of `cap` is `usize`.
        let cap = cmp::max(capacity * 2, required_cap);
        let cap = cmp::max(Self::MIN_NON_ZERO_CAP, cap);

        let new_table = table.clone(cap);

        self.table.current.store(new_table);

        pin(|pin| {
            let destroy = Arc::new(DestroyTable {
                table,
                lock: Mutex::new(false),
            });

            unsafe {
                (*self.table.old.get()).push(destroy.clone());

                pin.defer_unchecked(move || destroy.run());
            }
        });

        new_table
    }
}

impl<T: Clone> FromIterator<T> for SyncPushVec<T> {
    #[inline]
    fn from_iter<I: IntoIterator<Item = T>>(iter: I) -> Self {
        let iter = iter.into_iter();
        let mut map = Self::with_capacity(iter.size_hint().0);
        let mut write = map.write();
        iter.for_each(|v| {
            write.push(v);
        });
        map
    }
}
