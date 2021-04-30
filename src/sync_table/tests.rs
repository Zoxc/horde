#![cfg(test)]

use super::SyncTable;
use crate::collect::pin;
use crate::collect::release;
use crate::collect::Pin;
use std::collections::hash_map::RandomState;
use std::{
    collections::{hash_map::DefaultHasher, HashMap},
    hash::Hasher,
};

#[test]
fn high_align() {
    #[repr(align(64))]
    #[derive(Clone, PartialEq)]
    struct A(u64);

    let table = SyncTable::new();

    table.find(1, |a| a == &A(1));

    table.lock().insert_new(1, A(1), |_, a| a.0);

    release();
}

#[test]
fn test_create_capacity_zero() {
    let m = SyncTable::new_with(RandomState::new(), 0);

    assert!(m.lock().map_insert(1, 1).is_none());

    assert!(m.lock().read().map_get(&1).is_some());
    assert!(m.lock().read().map_get(&0).is_none());

    release();
}

#[test]
fn test_replace() {
    let m = SyncTable::new();
    m.lock().map_insert(2, 7);
    m.lock().map_insert(5, 3);
    m.lock().replace(vec![(3, 4)], 0, SyncTable::map_hasher);
    assert_eq!(*m.lock().read().map_get(&3).unwrap(), 4);
    assert_eq!(m.lock().read().map_get(&2), None);
    assert_eq!(m.lock().read().map_get(&5), None);
    m.lock().replace(vec![], 0, SyncTable::map_hasher);
    assert_eq!(m.lock().read().map_get(&3), None);
    assert_eq!(m.lock().read().map_get(&2), None);
    assert_eq!(m.lock().read().map_get(&5), None);
    release();
}

#[test]
fn test_remove() {
    let m = SyncTable::new();
    m.lock().map_insert(2, 7);
    m.lock().map_insert(5, 3);
    m.lock().remove(m.hash_any(&2), |v| v.0 == 2);
    m.lock().remove(m.hash_any(&5), |v| v.0 == 5);
    assert_eq!(m.lock().read().map_get(&2), None);
    assert_eq!(m.lock().read().map_get(&5), None);
    assert_eq!(m.lock().read().len(), 0);
    release();
}

#[test]
fn test_insert() {
    let m = SyncTable::new();
    assert_eq!(m.lock().read().len(), 0);
    assert!(m.lock().map_insert(1, 2).is_none());
    assert_eq!(m.lock().read().len(), 1);
    assert!(m.lock().map_insert(2, 4).is_none());
    assert_eq!(m.lock().read().len(), 2);
    assert_eq!(*m.lock().read().map_get(&1).unwrap(), 2);
    assert_eq!(*m.lock().read().map_get(&2).unwrap(), 4);

    release();
}

#[test]
fn test_iter() {
    let m = SyncTable::new();
    assert!(m.lock().map_insert(1, 2).is_none());
    assert!(m.lock().map_insert(5, 3).is_none());
    assert!(m.lock().map_insert(2, 4).is_none());
    assert!(m.lock().map_insert(9, 4).is_none());

    pin(|pin| {
        let mut v: Vec<(i32, i32)> = m.read(pin).iter().map(|i| *i).collect();
        v.sort_by_key(|k| k.0);

        assert_eq!(v, vec![(1, 2), (2, 4), (5, 3), (9, 4)]);
    });

    release();
}

#[test]
fn test_insert_conflicts() {
    let m = SyncTable::new_with(RandomState::default(), 4);
    assert!(m.lock().map_insert(1, 2).is_none());
    assert!(m.lock().map_insert(5, 3).is_none());
    assert!(m.lock().map_insert(9, 4).is_none());
    assert_eq!(*m.lock().read().map_get(&9).unwrap(), 4);
    assert_eq!(*m.lock().read().map_get(&5).unwrap(), 3);
    assert_eq!(*m.lock().read().map_get(&1).unwrap(), 2);

    release();
}

#[test]
fn test_expand() {
    let m = SyncTable::new();

    assert_eq!(m.lock().read().len(), 0);

    let mut i = 0;
    let old_raw_cap = unsafe { m.current().info().buckets() };
    while old_raw_cap == unsafe { m.current().info().buckets() } {
        m.lock().map_insert(i, i);
        i += 1;
    }

    assert_eq!(m.lock().read().len(), i);

    release();
}

#[test]
fn test_find() {
    let m = SyncTable::new();
    assert!(m.lock().read().map_get(&1).is_none());
    m.lock().map_insert(1, 2);
    match m.lock().read().map_get(&1) {
        None => panic!(),
        Some(v) => assert_eq!(*v, 2),
    }

    release();
}

#[test]
fn test_capacity_not_less_than_len() {
    let a: SyncTable<(i32, i32)> = SyncTable::new();
    let mut item = 0;

    for _ in 0..116 {
        a.lock().map_insert(item, 0);
        item += 1;
    }

    pin(|pin| {
        assert!(a.read(pin).capacity() > a.read(pin).len());

        let free = a.read(pin).capacity() - a.read(pin).len();
        for _ in 0..free {
            a.lock().map_insert(item, 0);
            item += 1;
        }

        assert_eq!(a.read(pin).len(), a.read(pin).capacity());

        // Insert at capacity should cause allocation.
        a.lock().map_insert(item, 0);
        assert!(a.read(pin).capacity() > a.read(pin).len());
    });

    release();
}

#[test]
fn rehash() {
    let table = SyncTable::new();
    for i in 0..100 {
        table
            .lock()
            .insert_new(table.hash_any(&i), i, SyncTable::hasher);
    }

    pin(|pin| {
        for i in 0..100 {
            assert_eq!(
                table
                    .read(pin)
                    .get(table.hash_any(&i), |x| *x == i)
                    .map(|b| *b),
                Some(i)
            );
            assert!(table
                .read(pin)
                .get(table.hash_any(&(i + 100)), |x| *x == i + 100)
                .is_none());
        }
    });

    release();
}

const INTERN_SIZE: u64 = if cfg!(miri) { 35 } else { 26334 };
const HIT_RATE: u64 = 84;

fn assert_equal(a: &mut SyncTable<(u64, u64)>, b: &HashMap<u64, u64>) {
    let mut ca: Vec<_> = b.iter().map(|v| (*v.0, *v.1)).collect();
    ca.sort();
    let mut cb: Vec<_> = a.write().read().iter().map(|v| (v.0, v.1)).collect();
    cb.sort();
    assert_eq!(ca, cb);
}

fn test_interning(intern: impl Fn(&SyncTable<(u64, u64)>, u64, u64, Pin<'_>) -> bool) {
    let mut control = HashMap::new();
    let mut test = SyncTable::new();

    for i in 0..INTERN_SIZE {
        let mut s = DefaultHasher::new();
        s.write_u64(i);
        let s = s.finish();
        if s % 100 > (100 - HIT_RATE) {
            test.lock().map_insert(i, i * 2);
            control.insert(i, i * 2);
        }
    }

    assert_equal(&mut test, &control);

    pin(|pin| {
        for i in 0..INTERN_SIZE {
            assert_eq!(
                intern(&test, i, i * 2, pin),
                control.insert(i, i * 2).is_some()
            )
        }
    });

    assert_equal(&mut test, &control);

    release();
}

#[test]
fn intern_potential() {
    fn intern(table: &SyncTable<(u64, u64)>, k: u64, v: u64, pin: Pin<'_>) -> bool {
        let hash = table.hash_any(&k);
        let p = match table.read(pin).get_potential(hash, |v| v.0 == k) {
            Ok(_) => return true,
            Err(p) => p,
        };

        let mut write = table.lock();
        match p.get(write.read(), hash, |v| v.0 == k) {
            Some(v) => {
                v.1;
                true
            }
            None => {
                p.insert_new(&mut write, hash, (k, v), SyncTable::map_hasher);
                false
            }
        }
    }

    test_interning(intern);
}

#[test]
fn intern_get_insert() {
    fn intern(table: &SyncTable<(u64, u64)>, k: u64, v: u64, pin: Pin<'_>) -> bool {
        let hash = table.hash_any(&k);
        match table.read(pin).get(hash, |v| v.0 == k) {
            Some(_) => return true,
            None => (),
        };

        let mut write = table.lock();
        match write.read().get(hash, |v| v.0 == k) {
            Some(_) => true,
            None => {
                write.insert_new(hash, (k, v), SyncTable::map_hasher);
                false
            }
        }
    }

    test_interning(intern);
}

#[test]
fn intern_potential_try() {
    fn intern(table: &SyncTable<(u64, u64)>, k: u64, v: u64, pin: Pin<'_>) -> bool {
        let hash = table.hash_any(&k);
        let p = match table.read(pin).get_potential(hash, |v| v.0 == k) {
            Ok(_) => return true,
            Err(p) => p,
        };

        let mut write = table.lock();

        write.reserve_one(SyncTable::map_hasher);

        let p = p.refresh(table.read(pin), hash, |v| v.0 == k);

        match p {
            Ok(_) => true,
            Err(p) => {
                p.try_insert_new(&mut write, hash, (k, v)).unwrap();
                false
            }
        }
    }

    test_interning(intern);
}
