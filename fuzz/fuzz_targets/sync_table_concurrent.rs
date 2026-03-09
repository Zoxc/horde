#![no_main]

use horde::{
    collect::{collect, pin, release},
    SyncTable,
};
use libfuzzer_sys::fuzz_target;
use std::{sync::Barrier, thread};

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

    fn next_bool(&mut self) -> bool {
        self.next().is_some_and(|byte| byte & 1 == 1)
    }
}

#[derive(Clone)]
enum Op {
    Insert {
        key: u8,
        value: u8,
        use_hash: bool,
    },
    InsertNew {
        key: u8,
        value: u8,
        use_hash: bool,
    },
    Remove {
        key: u8,
        use_hash: bool,
    },
    Replace {
        items: Vec<(u8, u8)>,
        capacity: usize,
    },
    ReserveOne,
}

#[derive(Clone)]
struct Step {
    op: Op,
    before: Model,
    after: Model,
    focus: u8,
    probe: u8,
    loops: usize,
}

fn maybe_hash(table: &SyncTable<u8, u8>, key: u8, use_hash: bool) -> Option<u64> {
    use_hash.then(|| table.hash_key(&key))
}

fn model_snapshot(model: &Model) -> Vec<(u8, u8)> {
    model
        .iter()
        .enumerate()
        .filter_map(|(key, value)| value.map(|value| (key as u8, value)))
        .collect()
}

fn assert_table_matches(table: &SyncTable<u8, u8>, model: &Model) {
    let expected = model_snapshot(model);

    pin(|pin| {
        let read = table.read(pin);
        let mut actual: Vec<_> = read.iter().map(|(key, value)| (*key, *value)).collect();
        actual.sort_unstable();

        assert_eq!(actual, expected);
        assert_eq!(read.len(), expected.len());
        assert!(read.capacity() >= expected.len());

        for key in 0..=u8::MAX {
            let hash = table.hash_key(&key);
            assert_eq!(
                read.get(&key, Some(hash)).map(|(_, value)| *value),
                model[key as usize]
            );
        }
    });
}

fn interesting_keys(step: &Step) -> [u8; 3] {
    let primary = match step.op {
        Op::Insert { key, .. } | Op::InsertNew { key, .. } | Op::Remove { key, .. } => key,
        Op::Replace { .. } | Op::ReserveOne => step.focus,
    };

    [primary, step.focus, step.probe]
}

fn assert_racy_reads(table: &SyncTable<u8, u8>, step: &Step) {
    for _ in 0..step.loops {
        pin(|pin| {
            let read = table.read(pin);

            for key in interesting_keys(step) {
                let hash = table.hash_key(&key);
                let before = step.before[key as usize];
                let after = step.after[key as usize];

                let current = read.get(&key, Some(hash)).map(|(_, value)| *value);
                assert!(current == before || current == after);

                let from_hash = read
                    .get_from_hash(hash, |candidate| *candidate == key)
                    .map(|(_, value)| *value);
                assert!(from_hash == before || from_hash == after);

                let with_eq = read
                    .get_with_eq(hash, |candidate, _| *candidate == key)
                    .map(|(_, value)| *value);
                assert!(with_eq == before || with_eq == after);
            }

            let mut seen = [false; 256];
            for (key, value) in read.iter() {
                let index = *key as usize;
                let previous = std::mem::replace(&mut seen[index], true);
                let current = Some(*value);

                assert!(!previous);
                assert!(current == step.before[index] || current == step.after[index]);
            }
        });

        thread::yield_now();
    }
}

fn apply_step(table: &SyncTable<u8, u8>, step: &Step) {
    match &step.op {
        Op::Insert {
            key,
            value,
            use_hash,
        } => {
            let inserted = table
                .lock()
                .insert(*key, *value, maybe_hash(table, *key, *use_hash));
            assert_eq!(inserted, step.before[*key as usize].is_none());
        }
        Op::InsertNew {
            key,
            value,
            use_hash,
        } => {
            if step.before[*key as usize].is_none() {
                let hash = maybe_hash(table, *key, *use_hash);
                let mut write = table.lock();
                let inserted = write.insert_new(*key, *value, hash);
                assert_eq!((*inserted.0, *inserted.1), (*key, *value));
            }
        }
        Op::Remove { key, use_hash } => {
            let removed = table
                .lock()
                .remove(key, maybe_hash(table, *key, *use_hash))
                .map(|(found_key, found_value)| (*found_key, *found_value));
            assert_eq!(
                removed,
                step.before[*key as usize].map(|value| (*key, value))
            );
        }
        Op::Replace { items, capacity } => {
            table.lock().replace(items.clone(), *capacity);
        }
        Op::ReserveOne => {
            table.lock().reserve_one();
        }
    }
}

fn build_steps(data: &[u8]) -> Vec<Step> {
    let mut input = Input::new(data);
    let mut model = [None; 256];
    let mut steps = Vec::new();

    for _ in 0..32 {
        let Some(tag) = input.next() else {
            break;
        };

        let before = model;
        let focus = input.next().unwrap_or(tag);
        let probe = input.next().unwrap_or(focus.wrapping_add(1));
        let loops = input.next().map_or(1, |byte| usize::from(byte % 8 + 1));

        let op = match tag % 5 {
            0 => {
                let key = input.next().unwrap_or(focus);
                let value = input.next().unwrap_or(probe);
                let use_hash = input.next_bool();

                if model[key as usize].is_none() {
                    model[key as usize] = Some(value);
                }

                Op::Insert {
                    key,
                    value,
                    use_hash,
                }
            }
            1 => {
                let key = input.next().unwrap_or(focus);
                let value = input.next().unwrap_or(probe);
                let use_hash = input.next_bool();

                if model[key as usize].is_none() {
                    model[key as usize] = Some(value);
                }

                Op::InsertNew {
                    key,
                    value,
                    use_hash,
                }
            }
            2 => {
                let key = input.next().unwrap_or(focus);
                let use_hash = input.next_bool();
                model[key as usize] = None;

                Op::Remove { key, use_hash }
            }
            3 => {
                let len = input.next().map_or(0, |byte| (byte as usize) % 24);
                let capacity = input.next().map_or(0, usize::from);
                let mut replacement = [None; 256];

                for _ in 0..len {
                    let key = input.next().unwrap_or(0);
                    let value = input.next().unwrap_or(0);
                    replacement[key as usize] = Some(value);
                }

                let items = model_snapshot(&replacement);
                model = replacement;

                Op::Replace { items, capacity }
            }
            4 => Op::ReserveOne,
            _ => unreachable!(),
        };

        steps.push(Step {
            op,
            before,
            after: model,
            focus,
            probe,
            loops,
        });
    }

    steps
}

fn fuzz_sync_table_concurrent(data: &[u8]) {
    release();
    collect();

    let steps = build_steps(data);
    let table = SyncTable::<u8, u8>::new();
    let barrier = Barrier::new(2);

    thread::scope(|scope| {
        scope.spawn(|| {
            for step in &steps {
                assert_table_matches(&table, &step.before);
                barrier.wait();
                assert_racy_reads(&table, step);
                barrier.wait();
                assert_table_matches(&table, &step.after);

                if step.loops % 2 == 0 {
                    let cloned = table.clone();
                    assert_table_matches(&cloned, &step.after);
                }

                if step.loops % 3 == 0 {
                    release();
                    collect();
                }
            }

            release();
        });

        scope.spawn(|| {
            for step in &steps {
                barrier.wait();
                thread::yield_now();
                apply_step(&table, step);
                thread::yield_now();
                barrier.wait();

                if step.loops % 5 == 0 {
                    release();
                    collect();
                }
            }

            release();
        });
    });

    drop(table);

    for _ in 0..3 {
        release();
        collect();
    }
}

fuzz_target!(|data: &[u8]| {
    fuzz_sync_table_concurrent(data);
});
