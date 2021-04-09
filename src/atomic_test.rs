#![cfg(test)]

use crate::atomic::RawTable;

#[test]
fn rehash() {
    let mut table = RawTable::new();
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
