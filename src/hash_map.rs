use crate::util::make_insert_hash;
use std::hash::Hash;
use std::{borrow::Borrow, hash::BuildHasher};

/// Hashes the first element of a pair with the `hash_builder` passed.
/// This is useful to treat the table as a hash map and can be passed to methods
/// expecting a hasher.
#[inline]
pub fn hasher<K: Hash, V, S: BuildHasher>(hash_builder: &S, val: &(K, V)) -> u64 {
    make_insert_hash(hash_builder, &val.0)
}

#[inline]
pub fn eq<Q, K, V>(k: &Q) -> impl Fn(&(K, V)) -> bool + '_
where
    K: Borrow<Q>,
    Q: ?Sized + Eq,
{
    move |x| k.eq(x.0.borrow())
}
