#![cfg(code)]

use std::collections::HashMap;
use std::marker::PhantomData;

use crate::collect::Pin;

use super::{PotentialSlot, Read, SyncTable, TableRef, Write};

#[unsafe(no_mangle)]
unsafe fn bucket_index(t: TableRef<(usize, usize)>, i: usize) -> *mut (usize, usize) {
    unsafe { t.bucket(i).as_ptr() }
}

#[unsafe(no_mangle)]
unsafe fn ctrl_index(t: TableRef<(usize, usize)>, i: usize) -> *mut u8 {
    unsafe { t.info.ctrl(i) }
}

#[unsafe(no_mangle)]
unsafe fn first_bucket(t: TableRef<(usize, usize)>) -> *mut (usize, usize) {
    unsafe { t.bucket_before_first() }
}

#[unsafe(no_mangle)]
unsafe fn last_bucket(t: TableRef<(usize, usize)>) -> *mut (usize, usize) {
    unsafe { t.bucket_past_last() }
}

#[unsafe(no_mangle)]
fn alloc_test(bucket_count: usize) -> TableRef<(usize, usize)> {
    TableRef::allocate(bucket_count)
}

#[unsafe(no_mangle)]
fn len_test(table: &mut SyncTable<u64, u64>) {
    table.write().read().len();
}

#[unsafe(no_mangle)]
fn get_potential_test<'a>(
    table: &'a SyncTable<usize, usize>,
    pin: Pin<'a>,
) -> Result<usize, PotentialSlot<'a>> {
    table.read(pin).get_potential(&5, None).map(|(_, v)| *v)
}

#[unsafe(no_mangle)]
fn potential_get_test(
    potential: PotentialSlot<'_>,
    table: Read<'_, usize, usize>,
) -> Option<usize> {
    potential.get(table, &5, None).map(|(_, v)| *v)
}

#[unsafe(no_mangle)]
fn potential_insert(potential: PotentialSlot<'_>, mut table: Write<'_, usize, usize>) {
    potential.insert_new(&mut table, 5, 5, None);
}

#[unsafe(no_mangle)]
unsafe fn potential_insert_opt(mut table: Write<'_, usize, usize>, index: usize) {
    let potential = PotentialSlot {
        table_info: table.table.current().info,
        index,
        marker: PhantomData,
    };
    potential.insert_new(&mut table, 5, 5, None);
}

#[unsafe(no_mangle)]
fn find_test(table: &SyncTable<usize, usize>, val: usize, hash: u64) -> Option<usize> {
    unsafe {
        table
            .current()
            .find(hash, |(key, _)| *key == val)
            .map(|(_, bucket)| *bucket.as_pair_ref().1)
    }
}

#[unsafe(no_mangle)]
fn insert_test(table: &SyncTable<u64, u64>) {
    table.lock().insert_new(5, 5, None);
}

#[unsafe(no_mangle)]
fn map_insert_test(table: &mut SyncTable<u64, u64>) {
    table.write().insert(5, 5, None);
}

#[unsafe(no_mangle)]
unsafe fn insert_test2(table: &SyncTable<u64, u64>) {
    unsafe { table.unsafe_write() }.insert_new(5, 5, None);
}

#[unsafe(no_mangle)]
unsafe fn insert_slot_test(table: TableRef<(usize, usize)>, hash: u64) -> usize {
    unsafe { table.info.find_insert_slot(hash) }
}

#[unsafe(no_mangle)]
fn find_test2(table: &HashMap<usize, ()>) -> Option<usize> {
    table.get_key_value(&5).map(|b| *b.0)
}

#[unsafe(no_mangle)]
fn intern_triple_test(table: &SyncTable<u64, u64>, k: u64, v: u64, pin: Pin<'_>) -> u64 {
    let hash = table.hash_key(&k);
    match table.read(pin).get(&k, Some(hash)) {
        Some((_, v)) => return *v,
        None => (),
    };

    let mut write = table.lock();
    match write.read().get(&k, Some(hash)) {
        Some((_, v)) => *v,
        None => {
            write.insert_new(k, v, Some(hash));
            v
        }
    }
}

#[unsafe(no_mangle)]
fn intern_try_test(table: &SyncTable<u64, u64>, k: u64, v: u64, pin: Pin<'_>) -> u64 {
    let hash = table.hash_key(&k);
    let p = match table.read(pin).get_potential(&k, Some(hash)) {
        Ok((_, v)) => return *v,
        Err(p) => p,
    };

    let mut write = table.lock();
    match p.get(write.read(), &k, Some(hash)) {
        Some((_, v)) => *v,
        None => {
            p.try_insert_new(&mut write, k, v, Some(hash));
            v
        }
    }
}

#[unsafe(no_mangle)]
fn intern_test(table: &SyncTable<u64, u64>, k: u64, v: u64, pin: Pin<'_>) -> u64 {
    let hash = table.hash_key(&k);
    let p = match table.read(pin).get_potential(&k, Some(hash)) {
        Ok((_, v)) => return *v,
        Err(p) => p,
    };

    let mut write = table.lock();
    match p.get(write.read(), &k, Some(hash)) {
        Some((_, v)) => *v,
        None => {
            p.insert_new(&mut write, k, v, Some(hash));
            v
        }
    }
}

#[unsafe(no_mangle)]
fn intern_refresh_test(
    table: &SyncTable<u64, u64>,
    k: u64,
    v: u64,
    hash: u64,
    pin: Pin<'_>,
) -> u64 {
    let p = match table.read(pin).get_potential(&k, Some(hash)) {
        Ok((_, v)) => return *v,
        Err(p) => p,
    };

    let mut write = table.lock();

    write.reserve_one();

    let p = p.refresh(table.read(pin), &k, Some(hash));

    match p {
        Ok((_, v)) => *v,
        Err(p) => {
            p.try_insert_new(&mut write, k, v, Some(hash));
            v
        }
    }
}
