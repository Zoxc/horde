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
    /// Whether the readers hold a `PotentialSlot` across the racy window. Kept separate
    /// from `loops` so it does not shadow the `loops` based reclamation cases.
    potential: bool,
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

/// The key the step's operation acts on, or `focus` for the whole-table operations.
fn primary_key(step: &Step) -> u8 {
    match step.op {
        Op::Insert { key, .. } | Op::InsertNew { key, .. } | Op::Remove { key, .. } => key,
        Op::Replace { .. } | Op::ReserveOne => step.focus,
    }
}

fn interesting_keys(step: &Step) -> [u8; 3] {
    [primary_key(step), step.focus, step.probe]
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
                .write()
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
                let mut lock = table.lock();
                let mut write = lock.write();
                let inserted = write.insert_new(*key, *value, hash);
                assert_eq!((*inserted.0, *inserted.1), (*key, *value));
            }
        }
        Op::Remove { key, use_hash } => {
            let removed = table
                .lock()
                .write()
                .remove(key, maybe_hash(table, *key, *use_hash))
                .map(|(found_key, found_value)| (*found_key, *found_value));
            assert_eq!(
                removed,
                step.before[*key as usize].map(|value| (*key, value))
            );
        }
        Op::Replace { items, capacity } => {
            table.lock().write().replace(items.clone(), *capacity);
        }
        Op::ReserveOne => {
            table.lock().write().reserve_one();
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
        let control = input.next().unwrap_or(0);
        let loops = usize::from(control % 8 + 1);
        let potential = control & 0b1000 != 0;

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
            potential,
        });
    }

    steps
}

/// Every value each key ever holds in any step, used by the unbarriered mode where the
/// reader cannot know which step the writer is on.
fn possible_values(steps: &[Step]) -> Vec<[bool; 256]> {
    let mut possible = vec![[false; 256]; 256];

    for step in steps {
        for model in [&step.before, &step.after] {
            for (key, value) in model.iter().enumerate() {
                if let Some(value) = value {
                    possible[key][*value as usize] = true;
                }
            }
        }
    }

    possible
}

/// Invariants which hold no matter where the writer is: keys are unique within a snapshot
/// and every value read was written at some point.
fn assert_monotone_reads(table: &SyncTable<u8, u8>, possible: &[[bool; 256]]) {
    pin(|pin| {
        let read = table.read(pin);

        let mut seen = [false; 256];
        for (key, value) in read.iter() {
            let index = *key as usize;
            assert!(!std::mem::replace(&mut seen[index], true));
            assert!(possible[index][*value as usize]);
        }

        for key in 0..=u8::MAX {
            let hash = table.hash_key(&key);

            if let Some((found_key, value)) = read.get(&key, Some(hash)) {
                assert_eq!(*found_key, key);
                assert!(possible[key as usize][*value as usize]);
            }
        }
    });
}

const READERS: usize = 2;

/// Readers and the writer step in lockstep, so the reads outside the racy window can be
/// checked against the exact model.
fn run_barriered(table: &SyncTable<u8, u8>, steps: &[Step]) {
    let barrier = Barrier::new(READERS + 1);

    thread::scope(|scope| {
        for _ in 0..READERS {
            scope.spawn(|| {
                for step in steps {
                    assert_table_matches(table, &step.before);

                    if step.potential {
                        // Hold a `PotentialSlot` derived before the writer runs across the
                        // whole racy window, then check it still agrees with the table.
                        pin(|pin| {
                            let read = table.read(pin);
                            // Derive the slot from the key the writer is about to touch,
                            // so the step's transition lands on this very slot instead of
                            // on it only by coincidence.
                            let key = primary_key(step);
                            let hash = table.hash_key(&key);
                            let potential = read.get_potential(&key, Some(hash));

                            barrier.wait();
                            assert_racy_reads(table, step);
                            barrier.wait();

                            let before = step.before[key as usize];
                            let after = step.after[key as usize];

                            match potential {
                                Ok((found_key, value)) => {
                                    assert_eq!(*found_key, key);
                                    assert_eq!(Some(*value), before);
                                }
                                Err(slot) => {
                                    assert!(before.is_none());

                                    assert_eq!(
                                        slot.get(read, &key, Some(hash)).map(|(_, value)| *value),
                                        after
                                    );

                                    match slot.refresh(read, &key, Some(hash)) {
                                        Ok((found_key, value)) => {
                                            assert_eq!(*found_key, key);
                                            assert_eq!(Some(*value), after);
                                        }
                                        Err(_) => assert!(after.is_none()),
                                    }
                                }
                            }
                        });
                    } else {
                        barrier.wait();

                        assert_racy_reads(table, step);

                        // Inside the racy window, so reclamation can run while the writer works.
                        if step.loops % 3 == 0 {
                            release();
                            collect();
                        }

                        barrier.wait();
                    }

                    assert_table_matches(table, &step.after);

                    if step.loops % 2 == 0 {
                        let cloned = table.clone();
                        assert_table_matches(&cloned, &step.after);
                    }
                }

                release();
            });
        }

        scope.spawn(|| {
            for step in steps {
                barrier.wait();
                thread::yield_now();
                apply_step(table, step);
                thread::yield_now();

                if step.loops % 5 == 0 {
                    release();
                    collect();
                }

                barrier.wait();
            }

            release();
        });
    });
}

/// No barriers at all, so readers can be several steps behind or ahead of the writer.
/// Only invariants which hold for every interleaving are checked.
fn run_unbarriered(table: &SyncTable<u8, u8>, steps: &[Step]) {
    let possible = possible_values(steps);

    thread::scope(|scope| {
        for _ in 0..READERS {
            scope.spawn(|| {
                for step in steps {
                    for _ in 0..step.loops {
                        assert_monotone_reads(table, &possible);
                        thread::yield_now();
                    }

                    if step.loops % 3 == 0 {
                        release();
                        collect();
                    }
                }

                release();
            });
        }

        scope.spawn(|| {
            for step in steps {
                // The writer is still the only writer, so the model is exact for it.
                apply_step(table, step);
                thread::yield_now();

                if step.loops % 5 == 0 {
                    release();
                    collect();
                }
            }

            release();
        });
    });

    // The readers never write, so once they have all joined the table must have landed
    // exactly on the last step's model. Nothing inside the run can check this, since the
    // readers cannot tell which step the writer is on.
    if let Some(last) = steps.last() {
        assert_table_matches(table, &last.after);
    }
}

fn fuzz_sync_table_concurrent(data: &[u8]) {
    release();
    collect();

    let steps = build_steps(data);
    let table = SyncTable::<u8, u8>::new();

    if data.last().is_some_and(|byte| byte & 1 == 1) {
        run_unbarriered(&table, &steps);
    } else {
        run_barriered(&table, &steps);
    }

    drop(table);

    for _ in 0..3 {
        release();
        collect();
    }
}

fuzz_target!(|data: &[u8]| {
    fuzz_sync_table_concurrent(data);
});
