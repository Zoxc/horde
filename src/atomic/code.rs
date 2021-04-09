use std::collections::HashMap;

use super::{RawTable, TableRef};

#[no_mangle]
fn alloc_test(bucket_count: usize) -> TableRef<usize> {
    TableRef::allocate(bucket_count)
}

#[no_mangle]
fn find_test(table: &RawTable<usize>) -> Option<usize> {
    unsafe { table.find(5, |a| *a == 5).map(|b| *b.as_ref()) }
}

#[no_mangle]
fn insert_test(table: &mut RawTable<u64>) {
    table.insert(5, 5, |a| *a);
}

#[no_mangle]
fn find_test2(table: &HashMap<usize, ()>) -> Option<usize> {
    table.get_key_value(&5).map(|b| *b.0)
}
