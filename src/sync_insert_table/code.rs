use std::collections::HashMap;

use super::{SyncInsertTable, TableRef};

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
fn len_test(table: &SyncInsertTable<u64>) {
    table.len();
}

#[no_mangle]
fn find_test(table: &SyncInsertTable<usize>) -> Option<usize> {
    unsafe { table.find(5, |a| *a == 5).map(|b| *b.as_ref()) }
}

#[no_mangle]
fn insert_test(table: &SyncInsertTable<u64>) {
    table.lock().insert_new(5, 5, |a| *a);
}

#[no_mangle]
unsafe fn insert_test2(table: &SyncInsertTable<u64>) {
    table.unsafe_write().insert_new(5, 5, |a| *a);
}

#[no_mangle]
unsafe fn insert_slot_test(table: TableRef<usize>, hash: u64) -> usize {
    table.info().find_insert_slot(hash)
}

#[no_mangle]
fn find_test2(table: &HashMap<usize, ()>) -> Option<usize> {
    table.get_key_value(&5).map(|b| *b.0)
}
