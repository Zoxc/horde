use core::hash::{BuildHasher, Hash};

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
pub(crate) fn align_up(value: usize, align: usize) -> usize {
    debug_assert!(align.is_power_of_two());
    (value + align - 1) & !(align - 1)
}
