#![no_main]

use horde::{
    collect::{collect, pin, release},
    SyncTable,
};
use libfuzzer_sys::fuzz_target;

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
            let expected = model[key as usize];

            assert_eq!(
                read.get(&key, Some(hash)).map(|(_, value)| *value),
                expected
            );
            assert_eq!(
                read.get_from_hash(hash, |candidate| *candidate == key)
                    .map(|(_, value)| *value),
                expected
            );
            assert_eq!(
                read.get_with_eq(hash, |candidate, _| *candidate == key)
                    .map(|(_, value)| *value),
                expected
            );
        }
    });
}

fn apply_potential_insert(
    table: &SyncTable<u8, u8>,
    model: &mut Model,
    key: u8,
    value: u8,
    mode: u8,
) {
    let hash = maybe_hash(table, key, mode & 1 != 0);

    pin(|pin| match table.read(pin).get_potential(&key, hash) {
        Ok((found_key, found_value)) => {
            assert_eq!(Some(*found_value), model[key as usize]);
            assert_eq!(*found_key, key);
        }
        Err(slot) => {
            assert!(model[key as usize].is_none());

            if mode & 0b10 != 0 {
                assert!(slot.get(table.read(pin), &key, hash).is_none());
            }

            let slot = if mode & 0b100 != 0 {
                match slot.refresh(table.read(pin), &key, hash) {
                    Ok(_) => panic!("slot unexpectedly occupied after refresh"),
                    Err(slot) => slot,
                }
            } else {
                slot
            };

            let mut write = table.lock();

            let inserted = if mode & 0b1000 != 0 {
                write.reserve_one();

                let slot = match slot.refresh(table.read(pin), &key, hash) {
                    Ok(_) => panic!("slot unexpectedly occupied after reserve_one"),
                    Err(slot) => slot,
                };

                slot.try_insert_new(&mut write, key, value, hash)
                    .expect("slot remained vacant after refresh")
            } else {
                slot.insert_new(&mut write, key, value, hash)
            };

            assert_eq!((*inserted.0, *inserted.1), (key, value));
            model[key as usize] = Some(value);
        }
    });
}

fn fuzz_sync_table(data: &[u8]) {
    release();
    collect();

    let mut input = Input::new(data);
    let mut table = SyncTable::<u8, u8>::new();
    let mut model = [None; 256];

    for step in 0..64 {
        let Some(op) = input.next() else {
            break;
        };

        let key = input.next().unwrap_or(0);
        let value = input.next().unwrap_or(0);
        let index = key as usize;

        match op % 9 {
            0 => {
                let hash = maybe_hash(&table, key, input.next_bool());
                let inserted = table.lock().insert(key, value, hash);
                let expected = model[index].is_none();

                assert_eq!(inserted, expected);
                if expected {
                    model[index] = Some(value);
                }
            }
            1 => {
                let hash = maybe_hash(&table, key, input.next_bool());

                if model[index].is_none() {
                    let mut write = table.lock();
                    let inserted = write.insert_new(key, value, hash);
                    assert_eq!((*inserted.0, *inserted.1), (key, value));
                    model[index] = Some(value);
                } else {
                    pin(|pin| {
                        assert_eq!(
                            table.read(pin).get(&key, hash).map(|(_, current)| *current),
                            model[index]
                        );
                    });
                }
            }
            2 => {
                let hash = maybe_hash(&table, key, input.next_bool());
                let removed = table
                    .lock()
                    .remove(&key, hash)
                    .map(|(key, value)| (*key, *value));
                let expected = model[index].take().map(|value| (key, value));

                assert_eq!(removed, expected);
            }
            3 => {
                let len = input.next().map_or(0, |byte| (byte as usize) % 16);
                let capacity = input.next().map_or(0, usize::from);
                let mut replacement = [None; 256];

                for _ in 0..len {
                    let replacement_key = input.next().unwrap_or(0);
                    let replacement_value = input.next().unwrap_or(0);
                    replacement[replacement_key as usize] = Some(replacement_value);
                }

                let items = model_snapshot(&replacement);
                let item_count = items.len();
                table.lock().replace(items, capacity);
                model = replacement;

                pin(|pin| {
                    let read = table.read(pin);
                    assert!(read.capacity() >= capacity.max(item_count));
                });
            }
            4 => {
                let hash = maybe_hash(&table, key, input.next_bool());
                let expected = model[index];

                pin(|pin| {
                    let read = table.read(pin);
                    assert_eq!(read.get(&key, hash).map(|(_, current)| *current), expected);
                });
            }
            5 => apply_potential_insert(&table, &mut model, key, value, input.next().unwrap_or(0)),
            6 => {
                let hash = maybe_hash(&table, key, input.next_bool());

                match table.get_mut(&key, hash) {
                    Some((found_key, found_value)) => {
                        assert_eq!(Some(*found_value), model[index]);
                        assert_eq!(*found_key, key);
                        *found_value = value;
                        model[index] = Some(value);
                    }
                    None => assert!(model[index].is_none()),
                }
            }
            7 => {
                let cloned = table.clone();
                assert_table_matches(&cloned, &model);
            }
            8 => {
                table.lock().reserve_one();
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
}

fuzz_target!(|data: &[u8]| {
    fuzz_sync_table(data);
});
