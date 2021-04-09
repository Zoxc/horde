use crate::raw::imp::{BitMaskWord, Group};
use core::ptr::NonNull;
use crossbeam_utils::atomic::AtomicCell;
use parking_lot::{lock_api::RawMutex as RawMutex_, RawMutex};
use std::{
    alloc::{self, handle_alloc_error, Allocator, Global, Layout, LayoutError},
    marker::PhantomData,
    ptr,
};

/// A raw hash table with an unsafe API.
pub struct RawTable<T: Clone> {
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

#[repr(transparent)]
struct TableRef<T> {
    data: NonNull<TableInfo>,

    marker: PhantomData<*mut T>,
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
                growth_left: bucket_count,
                items: 0,
            };
        }

        result
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

    /// Out-of-line slow path for `reserve` and `try_reserve`.
    #[cold]
    #[inline(never)]
    fn reserve_rehash(&self, additional: usize, hasher: impl Fn(&T) -> u64) {}
}
