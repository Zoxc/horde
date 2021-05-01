// This benchmark suite contains some benchmarks along a set of dimensions:
//   Hasher: std default (SipHash) and crate default (AHash).
//   Int key distribution: low bit heavy, top bit heavy, and random.
//   Task: basic functionality: insert, insert_erase, lookup, lookup_fail, iter
#![feature(test)]

extern crate test;

use std::hash::Hasher;

use horde::{
    collect::{pin, Pin},
    sync_table::SyncTable,
};
use test::{black_box, Bencher};

fn intern_map() -> SyncTable<u64, u64> {
    let mut m = SyncTable::new();
    for i in 0..50000 {
        let mut s = std::collections::hash_map::DefaultHasher::new();
        s.write_u64(i);
        let s = s.finish();
        if s % 100 > 40 {
            m.write().insert(i, i * 2, None);
        }
    }
    m
}

#[inline(never)]
fn intern3_value(table: &SyncTable<u64, u64>, k: u64, v: u64, pin: Pin<'_>) -> u64 {
    let hash = table.hash_any(&k);
    match table.read(pin).get(&k, Some(hash)) {
        Some(v) => return *v.1,
        None => (),
    };

    let mut write = table.lock();
    match write.read().get(&k, Some(hash)) {
        Some(v) => *v.1,
        None => {
            write.insert_new(k, v, Some(hash));
            v
        }
    }
}

#[bench]
fn intern3(b: &mut Bencher) {
    let m = intern_map();

    pin(|pin| {
        b.iter(|| {
            let m2 = m.clone();
            for i in 0..50000 {
                let mut result = intern3_value(&m2, i, i * 2, pin);
                black_box(&mut result);
            }
        })
    })
}

#[inline(never)]
fn intern_value(table: &SyncTable<u64, u64>, k: u64, v: u64, pin: Pin<'_>) -> u64 {
    let hash = table.hash_any(&k);
    let p = match table.read(pin).get_potential(&k, Some(hash)) {
        Ok(v) => return *v.1,
        Err(p) => p,
    };

    let mut write = table.lock();
    match p.get(write.read(), &k, Some(hash)) {
        Some(v) => *v.1,
        None => {
            p.insert_new(&mut write, k, v, Some(hash));
            v
        }
    }
}

#[bench]
fn intern(b: &mut Bencher) {
    let m = intern_map();

    pin(|pin| {
        b.iter(|| {
            let m2 = m.clone();
            for i in 0..50000 {
                let mut result = intern_value(&m2, i, i * 2, pin);
                black_box(&mut result);
            }
        })
    })
}

#[inline(never)]
fn intern4_value(table: &SyncTable<u64, u64>, k: u64, v: u64, pin: Pin<'_>) -> u64 {
    let hash = table.hash_any(&k);
    let p = match table.read(pin).get_potential(&k, Some(hash)) {
        Ok(v) => return *v.1,
        Err(p) => p,
    };

    let mut write = table.lock();

    write.reserve_one();

    let p = p.refresh(table.read(pin), &k, Some(hash));

    match p {
        Ok(v) => *v.1,
        Err(p) => {
            p.try_insert_new(&mut write, k, v, Some(hash));
            v
        }
    }
}

#[bench]
fn intern4(b: &mut Bencher) {
    let m = intern_map();

    pin(|pin| {
        b.iter(|| {
            let m2 = m.clone();
            for i in 0..50000 {
                let mut result = intern4_value(&m2, i, i * 2, pin);
                black_box(&mut result);
            }
        })
    })
}

#[inline(never)]
fn intern5_value(table: &SyncTable<u64, u64>, k: u64, v: u64, pin: Pin<'_>) -> u64 {
    let hash = table.hash_any(&k);
    let p = match table.read(pin).get_potential(&k, Some(hash)) {
        Ok(v) => return *v.1,
        Err(p) => p,
    };

    let mut write = table.lock();

    write.reserve_one();

    let p = p.refresh(table.read(pin), &k, Some(hash));

    match p {
        Ok(v) => *v.1,
        Err(p) => {
            unsafe { p.insert_new_unchecked(&mut write, k, v, Some(hash)) };
            v
        }
    }
}

#[bench]
fn intern5(b: &mut Bencher) {
    let m = intern_map();

    pin(|pin| {
        b.iter(|| {
            let m2 = m.clone();
            for i in 0..50000 {
                let mut result = intern5_value(&m2, i, i * 2, pin);
                black_box(&mut result);
            }
        })
    })
}

#[bench]
fn insert(b: &mut Bencher) {
    #[inline(never)]
    fn iter(m: &SyncTable<i32, i32>, i: i32) {
        m.lock().insert(i, i * 2, None);
    }

    b.iter(|| {
        let mut m = SyncTable::new();
        for i in (0..20000i32).step_by(4) {
            iter(&m, i);
        }
        black_box(&mut m);
    })
}

#[bench]
fn insert_with_try_potential(b: &mut Bencher) {
    #[inline(never)]
    fn iter(m: &SyncTable<i32, i32>, i: i32, pin: Pin<'_>) {
        let hash = m.hash_any(&i);
        let mut write = m.lock();
        write.reserve_one();
        match m.read(pin).get_potential(&i, Some(hash)) {
            Ok(_) => (),
            Err(p) => {
                p.try_insert_new(&mut write, i, i * 2, Some(hash));
            }
        };
    }

    pin(|pin| {
        b.iter(|| {
            let mut m = SyncTable::new();
            for i in (0..20000i32).step_by(4) {
                iter(&m, i, pin);
            }
            black_box(&mut m);
        })
    })
}

#[bench]
fn insert_with_unchecked_potential(b: &mut Bencher) {
    #[inline(never)]
    fn iter(m: &SyncTable<i32, i32>, i: i32, pin: Pin<'_>) {
        let hash = m.hash_any(&i);
        let mut write = m.lock();
        write.reserve_one();
        match m.read(pin).get_potential(&i, Some(hash)) {
            Ok(_) => (),
            Err(p) => {
                unsafe { p.insert_new_unchecked(&mut write, i, i * 2, Some(hash)) };
            }
        };
    }

    pin(|pin| {
        b.iter(|| {
            let mut m = SyncTable::new();
            for i in (0..20000i32).step_by(4) {
                iter(&m, i, pin);
            }
            black_box(&mut m);
        })
    })
}

#[bench]
fn insert_with_potential(b: &mut Bencher) {
    #[inline(never)]
    fn iter(m: &SyncTable<i32, i32>, i: i32, pin: Pin<'_>) {
        let hash = m.hash_any(&i);
        let mut write = m.lock();
        match m.read(pin).get_potential(&i, Some(hash)) {
            Ok(_) => (),
            Err(p) => {
                p.insert_new(&mut write, i, i * 2, Some(hash));
            }
        };
    }

    pin(|pin| {
        b.iter(|| {
            let mut m = SyncTable::new();
            for i in (0..20000i32).step_by(4) {
                iter(&m, i, pin);
            }
            black_box(&mut m);
        })
    })
}

#[bench]
fn insert_regular(b: &mut Bencher) {
    #[inline(never)]
    fn iter(m: &SyncTable<i32, i32>, i: i32) {
        let hash = m.hash_any(&i);
        let mut write = m.lock();
        match write.read().get(&i, Some(hash)) {
            Some(_) => (),
            None => {
                write.insert_new(i, i * 2, Some(hash));
            }
        };
    }

    b.iter(|| {
        let mut m = SyncTable::new();
        for i in (0..20000i32).step_by(4) {
            iter(&m, i);
        }
        black_box(&mut m);
    })
}
