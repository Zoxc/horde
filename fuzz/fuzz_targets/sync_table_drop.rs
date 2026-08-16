#![no_main]

//! Fuzzes `SyncTable` with a value type that has drop glue and a high alignment, so that
//! the element-dropping loop in `TableRef::free` and the alignment arithmetic in
//! `TableRef::layout` are exercised. `sync_table.rs` uses `(u8, u8)`, which has neither.

use horde::{
    SyncTable,
    collect::{collect, pin, release},
};
use libfuzzer_sys::fuzz_target;
use std::sync::atomic::{AtomicUsize, Ordering};

/// Number of `Value`s which have been created but not yet dropped.
static LIVE: AtomicUsize = AtomicUsize::new(0);

/// Deliberately over-aligned relative to the key so the table needs padding, and with drop
/// glue so `needs_drop::<(u8, Value)>()` holds.
#[repr(align(32))]
#[derive(Debug)]
struct Value {
    byte: u8,
}

impl Value {
    fn new(byte: u8) -> Self {
        LIVE.fetch_add(1, Ordering::Relaxed);
        Self { byte }
    }
}

impl Clone for Value {
    fn clone(&self) -> Self {
        Self::new(self.byte)
    }
}

impl Drop for Value {
    fn drop(&mut self) {
        LIVE.fetch_sub(1, Ordering::Relaxed);
    }
}

type Model = [Option<u8>; 256];

struct Input<'a> {
    data: &'a [u8],
    index: usize,
}

impl<'a> Input<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, index: 0 }
    }

    fn next(&mut self) -> Option<u8> {
        let byte = self.data.get(self.index).copied();
        self.index += usize::from(byte.is_some());
        byte
    }
}

fn assert_table_matches(table: &SyncTable<u8, Value>, model: &Model) {
    pin(|pin| {
        let read = table.read(pin);

        let mut actual: Vec<_> = read.iter().map(|(key, value)| (*key, value.byte)).collect();
        actual.sort_unstable();

        let expected: Vec<_> = model
            .iter()
            .enumerate()
            .filter_map(|(key, value)| value.map(|value| (key as u8, value)))
            .collect();

        assert_eq!(actual, expected);
        assert_eq!(read.len(), expected.len());

        for key in 0..=u8::MAX {
            assert_eq!(
                read.get(&key, None).map(|(_, value)| value.byte),
                model[key as usize]
            );
        }
    });
}

fn fuzz_sync_table_drop(data: &[u8]) {
    release();
    collect();

    let live_before = LIVE.load(Ordering::Relaxed);

    let mut input = Input::new(data);
    let table = SyncTable::<u8, Value>::new();
    let mut model: Model = [None; 256];

    for step in 0..64 {
        let Some(op) = input.next() else {
            break;
        };

        let key = input.next().unwrap_or(0);
        let byte = input.next().unwrap_or(0);
        let index = key as usize;

        match op % 6 {
            0 => {
                let inserted = table.lock().write().insert(key, Value::new(byte), None);
                assert_eq!(inserted, model[index].is_none());
                if inserted {
                    model[index] = Some(byte);
                }
            }
            1 => {
                if model[index].is_none() {
                    let mut lock = table.lock();
                    let mut write = lock.write();
                    let inserted = write.insert_new(key, Value::new(byte), None);
                    assert_eq!((*inserted.0, inserted.1.byte), (key, byte));
                    model[index] = Some(byte);
                }
            }
            2 => {
                let removed = table
                    .lock()
                    .write()
                    .remove(&key, None)
                    .map(|(key, value)| (*key, value.byte));
                assert_eq!(removed, model[index].take().map(|byte| (key, byte)));
            }
            3 => {
                let len = input.next().map_or(0, |byte| (byte as usize) % 16);
                let capacity = input.next().map_or(0, usize::from);
                let mut replacement: Model = [None; 256];

                for _ in 0..len {
                    let key = input.next().unwrap_or(0);
                    let byte = input.next().unwrap_or(0);
                    replacement[key as usize] = Some(byte);
                }

                let items: Vec<_> = replacement
                    .iter()
                    .enumerate()
                    .filter_map(|(key, byte)| byte.map(|byte| (key as u8, Value::new(byte))))
                    .collect();

                table.lock().write().replace(items, capacity);
                model = replacement;
            }
            4 => {
                let cloned = table.clone();
                assert_table_matches(&cloned, &model);
            }
            5 => {
                table.lock().write().reserve_one();
            }
            _ => unreachable!(),
        }

        assert_table_matches(&table, &model);

        if step % 8 == 0 {
            release();
            collect();
        }
    }

    drop(table);

    for _ in 0..3 {
        release();
        collect();
    }

    // Dropping the table must have dropped every value it ever owned, including the ones
    // sitting in retired tables.
    assert_eq!(LIVE.load(Ordering::Relaxed), live_before);
}

fuzz_target!(|data: &[u8]| {
    fuzz_sync_table_drop(data);
});
