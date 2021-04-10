#![cfg(test)]

use super::SyncInsertTable;

#[test]
fn high_align() {
    #[repr(align(64))]
    #[derive(Clone, PartialEq)]
    struct A(u64);

    let table = SyncInsertTable::new();

    table.find(1, |a| a == &A(1));

    table.insert(1, A(1), |a| a.0);
}

#[test]
fn test_capacity_not_less_than_len() {
    let mut a = SyncInsertTable::new();
    let mut item = 0;

    for _ in 0..116 {
        a.insert(item, 0);
        item += 1;
    }

    assert!(a.capacity() > a.len());

    let free = a.capacity() - a.len();
    for _ in 0..free {
        a.insert(item, 0);
        item += 1;
    }

    assert_eq!(a.len(), a.capacity());

    // Insert at capacity should cause allocation.
    a.insert(item, 0);
    assert!(a.capacity() > a.len());
}

#[test]
fn rehash() {
    let table = SyncInsertTable::new();
    let hasher = |i: &u64| *i;
    for i in 0..100 {
        table.insert(i, i, hasher);
    }

    for i in 0..100 {
        unsafe {
            assert_eq!(table.find(i, |x| *x == i).map(|b| b.read()), Some(i));
        }
        assert!(table.find(i + 100, |x| *x == i + 100).is_none());
    }
}
