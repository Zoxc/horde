// This benchmark suite contains some benchmarks along a set of dimensions:
//   Hasher: std default (SipHash) and crate default (AHash).
//   Int key distribution: low bit heavy, top bit heavy, and random.
//   Task: basic functionality: insert, insert_erase, lookup, lookup_fail, iter
#![feature(test)]

extern crate test;

use concurrent::{
    qsbr::{pin, Pin},
    sync_insert_table::SyncInsertTable,
};
use test::{black_box, Bencher};

#[bench]
fn insert(b: &mut Bencher) {
    b.iter(|| {
        let mut m = SyncInsertTable::new();
        for i in (0..1000).step_by(4) {
            m.map_insert(i, i * 2);
        }
        black_box(&mut m);
    })
}

#[inline(never)]
fn intern_slow_value(table: &SyncInsertTable<(u64, u64)>, k: u64, v: u64, pin: &Pin) -> u64 {
    match table.read(pin).get(k, |v| v.0 == k) {
        Some(v) => return v.1,
        None => (),
    };

    let mut write = table.lock();
    match write.read().get(k, |v| v.0 == k) {
        Some(v) => v.1,
        None => {
            write.insert_new(k, (k, v), |v| v.0);
            v
        }
    }
}

#[bench]
fn intern_slow(b: &mut Bencher) {
    let m = SyncInsertTable::new();
    for i in (0..1000).step_by(2) {
        m.map_insert(i, i * 2);
    }

    pin(|pin| {
        b.iter(|| {
            let m2 = m.read(pin).clone(|k| m.map_hash_key(&k.0));
            for i in 0..1000 {
                let mut result = intern_slow_value(&m2, i, i * 2, pin);
                black_box(&mut result);
            }
        })
    })
}

#[inline(never)]
fn intern_value(table: &SyncInsertTable<(u64, u64)>, k: u64, v: u64, pin: &Pin) -> u64 {
    let p = match table.read(pin).get_potential(k, |v| v.0 == k) {
        Ok(v) => return v.1,
        Err(p) => p,
    };

    let mut write = table.lock();
    match p.get(write.read(), k, |v| v.0 == k) {
        Some(v) => v.1,
        None => {
            p.insert_new(&mut write, k, (k, v), |v| v.0);
            v
        }
    }
}

#[bench]
fn intern(b: &mut Bencher) {
    let m = SyncInsertTable::new();
    for i in (0..1000).step_by(2) {
        m.map_insert(i, i * 2);
    }

    pin(|pin| {
        b.iter(|| {
            let m2 = m.read(pin).clone(|k| m.map_hash_key(&k.0));
            for i in 0..1000 {
                let mut result = intern_value(&m2, i, i * 2, pin);
                black_box(&mut result);
            }
        })
    })
}
