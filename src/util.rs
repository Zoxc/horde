use core::hash::{BuildHasher, Hash};
use std::cell::UnsafeCell;

#[allow(dead_code)]
pub(crate) const NO_ASM: bool = cfg_select! {
    feature = "nightly" => {
        cfg!(any(
            miri,
            sanitize = "address",
            sanitize = "hwaddress",
            sanitize = "memory",
            sanitize = "thread"
        ))
    }
    _ => { cfg!(miri) }
};

#[inline]
pub(crate) fn likely(value: bool) -> bool {
    #[cfg(feature = "nightly")]
    {
        std::hint::likely(value)
    }

    #[cfg(not(feature = "nightly"))]
    {
        value
    }
}

#[inline]
pub(crate) fn unlikely(value: bool) -> bool {
    #[cfg(feature = "nightly")]
    {
        std::hint::unlikely(value)
    }

    #[cfg(not(feature = "nightly"))]
    {
        value
    }
}

#[inline(never)]
#[cold]
pub(crate) fn cold_path<F: FnOnce() -> R, R>(f: F) -> R {
    f()
}

#[inline]
pub(crate) fn make_insert_hash<K: Hash + ?Sized, S>(hash_builder: &S, val: &K) -> u64
where
    S: BuildHasher,
{
    hash_builder.hash_one(val)
}

#[inline]
pub(crate) fn align_up(value: usize, align: usize) -> Option<usize> {
    debug_assert!(align.is_power_of_two());
    value
        .checked_add(align - 1)
        .map(|value| value & !(align - 1))
}

/// An [UnsafeCell] for use in a `static` whose non-`Sync` parts are never accessed.
#[repr(transparent)]
pub(crate) struct StaticUnsafeCell<T>(pub(crate) UnsafeCell<T>);

impl<T> StaticUnsafeCell<T> {
    /// # Safety
    /// Any part of `value` which is not `Sync` must never be accessed.
    pub(crate) const unsafe fn new(value: T) -> Self {
        Self(UnsafeCell::new(value))
    }
}

// SAFETY: Upheld by the caller of `new`.
unsafe impl<T> Sync for StaticUnsafeCell<T> {}
