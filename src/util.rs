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
pub(crate) struct StaticUnsafeCell<T> {
    value: UnsafeCell<T>,
}

impl<T> StaticUnsafeCell<T> {
    /// # Safety
    /// Any part of `value` which is not `Sync` must never be accessed.
    pub(crate) const unsafe fn new(value: T) -> Self {
        Self {
            value: UnsafeCell::new(value),
        }
    }

    /// Returns a pointer to the wrapped value.
    #[inline]
    pub(crate) const fn get(&self) -> *mut T {
        self.value.get()
    }
}

// SAFETY: Upheld by the caller of `new`.
unsafe impl<T> Sync for StaticUnsafeCell<T> {}

/// Leaks `value` and marks it as a root for Miri's leak check, so neither it nor anything
/// reachable from it is reported as leaked. Used by tests which deliberately leak.
#[cfg(test)]
pub(crate) fn leak_as_miri_root<T>(value: T) -> &'static T {
    let leaked: &'static T = Box::leak(Box::new(value));

    #[cfg(miri)]
    {
        unsafe extern "Rust" {
            /// Marks the block `ptr` points to, and everything reachable from it, as memory
            /// which is intentionally still allocated when the program terminates.
            fn miri_static_root(ptr: *const u8);
        }

        // SAFETY: `leaked` points to the start of a live allocation.
        unsafe { miri_static_root(leaked as *const T as *const u8) };
    }

    leaked
}
