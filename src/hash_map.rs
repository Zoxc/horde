//! Functions to treat a `SyncTable` as a hash map.

use crate::util::make_insert_hash;
use std::hash::Hash;
use std::{borrow::Borrow, hash::BuildHasher};

/// Hashes the first element of a pair with the `hash_builder` passed.
/// This is useful to pass to `SyncTable` methods expecting a hash function.
#[inline]
pub fn hasher<K: Hash, V, S: BuildHasher>(hash_builder: &S, val: &(K, V)) -> u64 {
    make_insert_hash(hash_builder, &val.0)
}

/// Returns a fucntion comparing the first element of a pair with `key`.
/// This is useful to pass to `SyncTable` methods expecting a equality function.
#[inline]
pub fn eq<Q, K, V>(key: &Q) -> impl Fn(&(K, V)) -> bool + '_
where
    K: Borrow<Q>,
    Q: ?Sized + Eq,
{
    move |x| key.eq(x.0.borrow())
}
