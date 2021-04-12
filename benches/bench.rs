// This benchmark suite contains some benchmarks along a set of dimensions:
//   Hasher: std default (SipHash) and crate default (AHash).
//   Int key distribution: low bit heavy, top bit heavy, and random.
//   Task: basic functionality: insert, insert_erase, lookup, lookup_fail, iter
#![feature(test)]

extern crate test;

use std::hash::Hasher;

use concurrent::{
    qsbr::{pin, Pin},
    sync_insert_table::SyncInsertTable,
};
use test::{black_box, Bencher};

fn intern_map() -> SyncInsertTable<(u64, u64)> {
    let m = SyncInsertTable::new();
    for i in 0..50000 {
        let mut s = std::collections::hash_map::DefaultHasher::new();
        s.write_u64(i);
        let s = s.finish();
        if s % 100 > 40 {
            m.map_insert(i, i * 2);
        }
    }
    m
}

#[inline(never)]
fn intern3_value(table: &SyncInsertTable<(u64, u64)>, k: u64, v: u64, pin: &Pin) -> u64 {
    let hash = table.hash_any(&k);
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

#[bench]
fn intern3(b: &mut Bencher) {
    let m = intern_map();

    pin(|pin| {
        b.iter(|| {
            let m2 = m.read(pin).clone(SyncInsertTable::hasher);
            for i in 0..50000 {
                let mut result = intern3_value(&m2, i, i * 2, pin);
                black_box(&mut result);
            }
        })
    })
}

#[inline(never)]
fn intern_value(table: &SyncInsertTable<(u64, u64)>, k: u64, v: u64, pin: &Pin) -> u64 {
    let hash = table.hash_any(&k);
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

#[bench]
fn intern(b: &mut Bencher) {
    let m = intern_map();

    pin(|pin| {
        b.iter(|| {
            let m2 = m.read(pin).clone(SyncInsertTable::hasher);
            for i in 0..50000 {
                let mut result = intern_value(&m2, i, i * 2, pin);
                black_box(&mut result);
            }
        })
    })
}

#[inline(never)]
fn intern4_value(table: &SyncInsertTable<(u64, u64)>, k: u64, v: u64, pin: &Pin) -> u64 {
    let hash = table.hash_any(&k);
    let p = match table.read(pin).get_potential(hash, |v| v.0 == k) {
        Ok(v) => return v.1,
        Err(p) => p,
    };

    let mut write = table.lock();

    write.reserve_one(SyncInsertTable::hasher);

    let p = p.refresh(write.read(), hash, |v| v.0 == k);

    match p {
        Ok(v) => v.1,
        Err(p) => {
            p.try_insert_new(&mut write, hash, (k, v));
            v
        }
    }
}

#[bench]
fn intern4(b: &mut Bencher) {
    let m = intern_map();

    pin(|pin| {
        b.iter(|| {
            let m2 = m.read(pin).clone(SyncInsertTable::hasher);
            for i in 0..50000 {
                let mut result = intern4_value(&m2, i, i * 2, pin);
                black_box(&mut result);
            }
        })
    })
}

#[bench]
fn insert(b: &mut Bencher) {
    #[inline(never)]
    fn iter(m: &SyncInsertTable<(i32, i32)>, i: i32) {
        m.map_insert(i, i * 2);
    }

    b.iter(|| {
        let mut m = SyncInsertTable::new();
        for i in (0..20000i32).step_by(4) {
            iter(&m, i);
        }
        black_box(&mut m);
    })
}

#[bench]
fn insert_with_try_potential(b: &mut Bencher) {
    #[inline(never)]
    fn iter(m: &SyncInsertTable<(i32, i32)>, i: i32) {
        let hash = m.hash_any(&i);
        let mut write = m.lock();
        write.reserve_one(SyncInsertTable::hasher);
        match write.read().get_potential(hash, |&(k, _)| k == i) {
            Ok(_) => (),
            Err(p) => {
                p.try_insert_new(&mut write, hash, (i, i * 2));
            }
        };
    }

    b.iter(|| {
        let mut m = SyncInsertTable::new();
        for i in (0..20000i32).step_by(4) {
            iter(&m, i);
        }
        black_box(&mut m);
    })
}

#[bench]
fn insert_with_potential(b: &mut Bencher) {
    #[inline(never)]
    fn iter(m: &SyncInsertTable<(i32, i32)>, i: i32) {
        let hash = m.hash_any(&i);
        let mut write = m.lock();
        match write.read().get_potential(hash, |&(k, _)| k == i) {
            Ok(_) => (),
            Err(p) => {
                p.insert_new(&mut write, hash, (i, i * 2), SyncInsertTable::hasher);
            }
        };
    }

    b.iter(|| {
        let mut m = SyncInsertTable::new();
        for i in (0..20000i32).step_by(4) {
            iter(&m, i);
        }
        black_box(&mut m);
    })
}

#[bench]
fn insert_regular(b: &mut Bencher) {
    #[inline(never)]
    fn iter(m: &SyncInsertTable<(i32, i32)>, i: i32) {
        let hash = m.hash_any(&i);
        let mut write = m.lock();
        match write.read().get(hash, |&(k, _)| k == i) {
            Some(_) => (),
            None => {
                write.insert_new(hash, (i, i * 2), SyncInsertTable::hasher);
            }
        };
    }

    b.iter(|| {
        let mut m = SyncInsertTable::new();
        for i in (0..20000i32).step_by(4) {
            iter(&m, i);
        }
        black_box(&mut m);
    })
}
