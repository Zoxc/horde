#![cfg(test)]

use super::RawTable;

#[test]
fn high_align() {
    #[repr(align(64))]
    #[derive(Clone, PartialEq)]
    struct A(u64);

    let table = RawTable::new();

    table.find(1, |a| a == &A(1));

    table.insert(1, A(1), |a| a.0);
}

#[test]
fn rehash() {
    let table = RawTable::new();
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

    //table.resize(hasher);

    for i in 0..100 {
        unsafe {
            assert_eq!(table.find(i, |x| *x == i).map(|b| b.read()), Some(i));
        }
        assert!(table.find(i + 100, |x| *x == i + 100).is_none());
    }
}
