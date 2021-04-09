#![cfg_attr(
    feature = "nightly",
    feature(
        test,
        core_intrinsics,
        dropck_eyepatch,
        min_specialization,
        extend_one,
        allocator_api,
        slice_ptr_get,
        nonnull_slice_from_raw_parts,
        maybe_uninit_array_assume_init
    )
)]
#![feature(alloc_layout_extra, option_result_unwrap_unchecked)]

extern crate alloc;

#[macro_use]
mod macros;

pub mod atomic;
mod atomic_test;
pub mod raw;
mod scopeguard;

pub mod map;

struct OnDrop<F: Fn()>(pub F);

impl<F: Fn()> OnDrop<F> {
    /// Forgets the function which prevents it from running.
    /// Ensure that the function owns no memory, otherwise it will be leaked.
    #[inline]
    fn disable(self) {
        std::mem::forget(self);
    }
}

impl<F: Fn()> Drop for OnDrop<F> {
    #[inline]
    fn drop(&mut self) {
        (self.0)();
    }
}

/// The error type for `try_reserve` methods.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum TryReserveError {
    /// Error due to the computed capacity exceeding the collection's maximum
    /// (usually `isize::MAX` bytes).
    CapacityOverflow,

    /// The memory allocator returned an error
    AllocError {
        /// The layout of the allocation request that failed.
        layout: alloc::alloc::Layout,
    },
}

/// The error type for [`RawTable::get_each_mut`](crate::raw::RawTable::get_each_mut),
/// [`HashMap::get_each_mut`], and [`HashMap::get_each_key_value_mut`].
#[cfg(feature = "nightly")]
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum UnavailableMutError {
    /// The requested entry is not present in the table.
    Absent,
    /// The requested entry is present, but a mutable reference to it was already created and
    /// returned from this call to `get_each_mut` or `get_each_key_value_mut`.
    ///
    /// Includes the index of the existing mutable reference in the returned array.
    Duplicate(usize),
}
