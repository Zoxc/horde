use std::collections::HashMap;

use crate::qsbr::Pin;

use super::{PotentialSlot, Read, SyncInsertTable, TableRef, Write};

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
fn get_potential_test(table: &SyncInsertTable<usize>, pin: &Pin) -> Result<usize, PotentialSlot> {
    table.read(pin).get_potential(5, |a| *a == 5).map(|b| *b)
}

#[no_mangle]
fn potential_get_test(potential: PotentialSlot, table: Read<'_, usize>) -> Option<usize> {
    potential.get(table, 5, |a| *a == 5).map(|b| *b)
}

#[no_mangle]
fn potential_insert(potential: PotentialSlot, mut table: Write<'_, usize>) {
    potential.insert_new(&mut table, 5, 5, |_, h| *h as u64);
}

#[no_mangle]
unsafe fn potential_insert_opt(mut table: Write<'_, usize>, index: usize) {
    let potential = PotentialSlot {
        bucket_mask: (*(table.table.current.as_ptr() as *const TableRef<usize>))
            .info()
            .bucket_mask,
        index,
    };
    potential.insert_new(&mut table, 5, 5, |_, h| *h as u64);
}

#[no_mangle]
fn find_test(table: &SyncInsertTable<usize>, val: usize, hash: u64) -> Option<usize> {
    unsafe { table.find(hash, |a| *a == val).map(|b| *b.as_ref()) }
}

#[no_mangle]
fn insert_test(table: &SyncInsertTable<u64>) {
    table.lock().insert_new(5, 5, |_, a| *a);
}

#[no_mangle]
fn map_insert_test(table: &mut SyncInsertTable<(u64, u64)>) {
    table.write().map_insert(5, 5);
}

#[no_mangle]
unsafe fn insert_test2(table: &SyncInsertTable<u64>) {
    table.unsafe_write().insert_new(5, 5, |_, a| *a);
}

#[no_mangle]
unsafe fn insert_slot_test(table: TableRef<usize>, hash: u64) -> usize {
    table.info().find_insert_slot(hash)
}

#[no_mangle]
fn find_test2(table: &HashMap<usize, ()>) -> Option<usize> {
    table.get_key_value(&5).map(|b| *b.0)
}

#[no_mangle]
fn intern_triple_test(table: &SyncInsertTable<(u64, u64)>, k: u64, v: u64, pin: &Pin) -> u64 {
    let hash = table.hash(&k);
    match table.read(pin).get(hash, |v| v.0 == k) {
        Some(v) => return v.1,
        None => (),
    };

    let mut write = table.lock();
    match write.read().get(hash, |v| v.0 == k) {
        Some(v) => v.1,
        None => {
            write.insert_new(hash, (k, v), SyncInsertTable::hasher);
            v
        }
    }
}

#[no_mangle]
fn intern_try_test(table: &SyncInsertTable<(u64, u64)>, k: u64, v: u64, pin: &Pin) -> u64 {
    let hash = table.hash(&k);
    let p = match table.read(pin).get_potential(hash, |v| v.0 == k) {
        Ok(v) => return v.1,
        Err(p) => p,
    };

    let mut write = table.lock();
    match p.get(write.read(), hash, |v| v.0 == k) {
        Some(v) => v.1,
        None => {
            p.try_insert_new(&mut write, hash, (k, v));
            v
        }
    }
}

#[no_mangle]
fn intern_test(table: &SyncInsertTable<(u64, u64)>, k: u64, v: u64, pin: &Pin) -> u64 {
    let hash = table.hash(&k);
    let p = match table.read(pin).get_potential(hash, |v| v.0 == k) {
        Ok(v) => return v.1,
        Err(p) => p,
    };

    let mut write = table.lock();
    match p.get(write.read(), hash, |v| v.0 == k) {
        Some(v) => v.1,
        None => {
            p.insert_new(&mut write, hash, (k, v), SyncInsertTable::hasher);
            v
        }
    }
}
