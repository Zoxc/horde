#![cfg(test)]

use super::SyncInsertTable;
use crate::qsbr::pin;
use crate::qsbr::release;
use std::collections::hash_map::RandomState;

#[test]
fn high_align() {
    #[repr(align(64))]
    #[derive(Clone, PartialEq)]
    struct A(u64);

    let table = SyncInsertTable::new();

    table.find(1, |a| a == &A(1));

    table.lock().insert_new(1, A(1), |a| a.0);

    release();
}

#[test]
fn test_create_capacity_zero() {
    let m = SyncInsertTable::new_with(RandomState::new(), 0);

    assert!(m.map_insert(1, 1).is_none());

    assert!(m.map_get(&1).is_some());
    assert!(m.map_get(&0).is_none());

    release();
}

#[test]
fn test_insert() {
    let m = SyncInsertTable::new();
    assert_eq!(m.len(), 0);
    assert!(m.map_insert(1, 2).is_none());
    assert_eq!(m.len(), 1);
    assert!(m.map_insert(2, 4).is_none());
    assert_eq!(m.len(), 2);
    assert_eq!(m.map_get(&1).unwrap(), 2);
    assert_eq!(m.map_get(&2).unwrap(), 4);

    release();
}

#[test]
fn test_iter() {
    let m = SyncInsertTable::new();
    assert!(m.map_insert(1, 2).is_none());
    assert!(m.map_insert(5, 3).is_none());
    assert!(m.map_insert(2, 4).is_none());
    assert!(m.map_insert(9, 4).is_none());

    pin(|pin| {
        let mut v: Vec<(i32, i32)> = m.read(pin).iter().map(|i| *i).collect();
        v.sort_by_key(|k| k.0);

        assert_eq!(v, vec![(1, 2), (2, 4), (5, 3), (9, 4)]);
    });

    release();
}

#[test]
fn test_insert_conflicts() {
    let m = SyncInsertTable::new_with(RandomState::default(), 4);
    assert!(m.map_insert(1, 2).is_none());
    assert!(m.map_insert(5, 3).is_none());
    assert!(m.map_insert(9, 4).is_none());
    assert_eq!(m.map_get(&9).unwrap(), 4);
    assert_eq!(m.map_get(&5).unwrap(), 3);
    assert_eq!(m.map_get(&1).unwrap(), 2);

    release();
}

#[test]
fn test_expand() {
    let m = SyncInsertTable::new();

    assert_eq!(m.len(), 0);

    let mut i = 0;
    let old_raw_cap = unsafe { m.current.load().info().buckets() };
    while old_raw_cap == unsafe { m.current.load().info().buckets() } {
        m.map_insert(i, i);
        i += 1;
    }

    assert_eq!(m.len(), i);

    release();
}

#[test]
fn test_find() {
    let m = SyncInsertTable::new();
    assert!(m.map_get(&1).is_none());
    m.map_insert(1, 2);
    match m.map_get(&1) {
        None => panic!(),
        Some(v) => assert_eq!(v, 2),
    }

    release();
}

#[test]
fn test_capacity_not_less_than_len() {
    let a: SyncInsertTable<(i32, i32)> = SyncInsertTable::new();
    let mut item = 0;

    for _ in 0..116 {
        a.map_insert(item, 0);
        item += 1;
    }

    pin(|pin| {
        assert!(a.read(pin).capacity() > a.len());

        let free = a.read(pin).capacity() - a.len();
        for _ in 0..free {
            a.map_insert(item, 0);
            item += 1;
        }

        assert_eq!(a.len(), a.read(pin).capacity());

        // Insert at capacity should cause allocation.
        a.map_insert(item, 0);
        assert!(a.read(pin).capacity() > a.len());
    });

    release();
}

#[test]
fn rehash() {
    let table = SyncInsertTable::new();
    let hasher = |i: &u64| *i;
    for i in 0..100 {
        table.lock().insert_new(i, i, hasher);
    }

    pin(|pin| {
        for i in 0..100 {
            assert_eq!(table.read(pin).get(i, |x| *x == i).map(|b| *b), Some(i));
            assert!(table.read(pin).get(i + 100, |x| *x == i + 100).is_none());
        }
    });

    release();
}
