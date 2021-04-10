use std::collections::HashMap;

use super::{RawTable, TableRef};

#[no_mangle]
unsafe fn bucket_index(t: TableRef<usize>, i: usize) -> *mut usize {
    t.bucket(i).as_ptr()
}

#[no_mangle]
unsafe fn ctrl_index(t: TableRef<usize>, i: usize) -> *mut u8 {
    t.info().ctrl(i)
}

#[no_mangle]
unsafe fn first_bucket(t: TableRef<usize>) -> *mut usize {
    t.bucket_before_first()
}

#[no_mangle]
unsafe fn last_bucket(t: TableRef<usize>) -> *mut usize {
    t.bucket_past_last()
}

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
