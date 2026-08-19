#![cfg(test)]

use super::{SyncTable, TableRef};
use crate::collect::Pin;
use crate::collect::enter_test;
use crate::collect::pin;
use crate::collect::release;
use crate::util::leak_as_miri_root;
use std::collections::hash_map::RandomState;
use std::mem;
use std::{
    collections::{HashMap, hash_map::DefaultHasher},
    hash::Hasher,
    sync::Arc,
    sync::Barrier,
    sync::atomic::{AtomicUsize, Ordering},
    thread,
};

#[test]
fn layout_rejects_bucket_storage_above_isize_max_bytes() {
    let bucket_count = (isize::MAX as usize / mem::size_of::<u16>()) + 1;

    assert!(TableRef::<u16>::layout(bucket_count).is_none());
}

#[test]
fn layout_rejects_control_bytes_above_isize_max() {
    assert!(TableRef::<()>::layout(isize::MAX as usize).is_none());
}

#[test]
fn high_align() {
    let _test = enter_test();
    #[repr(align(64))]
    #[derive(Clone, Eq, PartialEq, Hash)]
    struct A(u64);

    let mut table = SyncTable::new();

    table.get_mut(&A(1), None);

    table.lock().write().insert_new(A(1), 1, None);

    release();
}

#[test]
fn low_align_with_padding_before_table_info() {
    let _test = enter_test();
    let m = SyncTable::<u8, ()>::new();

    assert!(m.lock().write().insert(1, (), None));
    assert!(m.lock().write().insert(2, (), None));
    assert!(m.lock().write().insert(3, (), None));

    let write = m.lock();
    let read = write.read();
    assert!(read.get(&1, None).is_some());
    assert!(read.get(&2, None).is_some());
    assert!(read.get(&3, None).is_some());
    assert_eq!(read.iter().count(), 3);

    release();
}

#[test]
fn test_create_capacity_zero() {
    let _test = enter_test();
    let m = SyncTable::new_with(RandomState::new(), 0);

    assert!(m.lock().write().insert(1, 1, None));

    assert!(m.lock().read().get(&1, None).is_some());
    assert!(m.lock().read().get(&0, None).is_none());

    release();
}

#[test]
fn clone_empty_reuses_static_table() {
    let _test = enter_test();
    let m = SyncTable::<i32, i32>::new();
    let cloned = m.clone();

    assert_eq!(m.current().info.as_ptr(), cloned.current().info.as_ptr());

    release();
}

#[test]
fn clone_rehashes_a_non_empty_table() {
    let _test = enter_test();

    const KEYS: u64 = 100;

    // Heap allocated values, so a shallow copy is a double free Miri sees.
    let m: SyncTable<u64, String> = SyncTable::new();
    for i in 0..KEYS {
        assert!(m.lock().write().insert(i, format!("v{i}"), None));
    }

    let cloned = m.clone();

    // Its own allocation, neither the original's table nor the static empty one.
    assert_ne!(m.current().info.as_ptr(), cloned.current().info.as_ptr());
    assert_eq!(cloned.lock().read().capacity(), m.lock().read().capacity());
    assert_eq!(cloned.lock().read().len(), KEYS as usize);

    // The clone hashes with a fresh `RandomState`, so finding these again means every element
    // was placed by the clone's own hash rather than copied into the original's bucket.
    for i in 0..KEYS {
        assert_eq!(
            cloned.lock().read().get(&i, None).map(|(_, v)| v.clone()),
            Some(format!("v{i}"))
        );
    }
    assert_eq!(cloned.lock().read().get(&KEYS, None), None);

    // The two tables are independent.
    assert!(cloned.lock().write().insert(KEYS, "extra".to_owned(), None));
    assert_eq!(m.lock().read().get(&KEYS, None), None);

    drop(cloned);

    for i in 0..KEYS {
        assert_eq!(
            m.lock().read().get(&i, None).map(|(_, v)| v.clone()),
            Some(format!("v{i}"))
        );
    }
}

#[test]
fn clone_rehashes_with_the_clones_own_hasher() {
    let _test = enter_test();

    const KEYS: u64 = 40;

    let m: SyncTable<u64, u64, ShiftingHashBuilder> =
        SyncTable::new_with(ShiftingHashBuilder(0), KEYS as usize);

    for i in 0..KEYS {
        assert!(m.lock().write().insert(i, i, None));
    }

    let cloned = m.clone();

    // Placed by the clone's hashes, so found by them too.
    for i in 0..KEYS {
        assert_eq!(cloned.lock().read().get(&i, None).map(|(_, v)| *v), Some(i));
    }

    // The original still finds its elements under its own hashes.
    for i in 0..KEYS {
        assert_eq!(m.lock().read().get(&i, None).map(|(_, v)| *v), Some(i));
    }
}

#[test]
fn test_replace() {
    let _test = enter_test();
    let m = SyncTable::new();
    m.lock().write().insert(2, 7, None);
    m.lock().write().insert(5, 3, None);
    m.lock().write().replace(vec![(3, 4)], 0);
    assert_eq!(*m.lock().read().get(&3, None).unwrap().1, 4);
    assert_eq!(m.lock().read().get(&2, None), None);
    assert_eq!(m.lock().read().get(&5, None), None);
    m.lock().write().replace(vec![], 0);
    assert_eq!(m.lock().read().get(&3, None), None);
    assert_eq!(m.lock().read().get(&2, None), None);
    assert_eq!(m.lock().read().get(&5, None), None);
    release();
}

#[test]
fn replace_empty_preserves_requested_capacity() {
    let _test = enter_test();
    let m = SyncTable::<i32, i32>::new();

    m.lock().write().replace(Vec::new(), 100);

    pin(|pin| {
        assert_eq!(m.read(pin).len(), 0);
        assert!(m.read(pin).capacity() >= 100);
    });

    release();
}

#[test]
fn replace_then_forget_leaks_retired_values() {
    let _test = enter_test();

    #[derive(Clone)]
    struct DropCounter(Arc<AtomicUsize>);

    impl Drop for DropCounter {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    let drops = Arc::new(AtomicUsize::new(0));
    let table = SyncTable::new_with(RandomState::new(), 1);

    assert!(
        table
            .lock()
            .write()
            .insert(1usize, DropCounter(drops.clone()), None)
    );
    table
        .lock()
        .write()
        .replace(Vec::<(usize, DropCounter)>::new(), 0);

    leak_as_miri_root(table);

    crate::collect::collect();

    assert_eq!(drops.load(Ordering::SeqCst), 0);
}

/// Swapping whole `LockedWrite`s is the one detaching operation that still compiles.
/// It's harmless since each guard moves along with the table it protects.
#[test]
fn swapped_locks_keep_their_guards() {
    let _test = enter_test();
    let a = SyncTable::new();
    let b = SyncTable::new();

    let mut lock_a = a.lock();
    let mut lock_b = b.lock();

    mem::swap(&mut lock_a, &mut lock_b);

    assert!(a.mutex().is_locked());
    assert!(b.mutex().is_locked());

    // `lock_a` now holds `b`'s guard and writes to `b`.
    lock_a.write().insert(1, 1, None);
    drop(lock_a);
    assert!(!b.mutex().is_locked());
    assert!(a.mutex().is_locked());

    lock_b.write().insert(2, 2, None);
    drop(lock_b);
    assert!(!a.mutex().is_locked());

    assert_eq!(b.lock().read().get(&1, None).map(|(_, v)| *v), Some(1));
    assert_eq!(a.lock().read().get(&2, None).map(|(_, v)| *v), Some(2));
    assert_eq!(a.lock().read().get(&1, None), None);
    assert_eq!(b.lock().read().get(&2, None), None);

    release();
}

#[test]
fn test_remove() {
    let _test = enter_test();
    let m = SyncTable::new();
    m.lock().write().insert(2, 7, None);
    m.lock().write().insert(5, 3, None);
    m.lock().write().remove(&2, None);
    m.lock().write().remove(&5, None);
    assert_eq!(m.lock().read().get(&2, None), None);
    assert_eq!(m.lock().read().get(&5, None), None);
    assert_eq!(m.lock().read().len(), 0);
    release();
}

#[test]
fn remove_drops_values_after_reclamation() {
    let _test = enter_test();

    #[derive(Clone)]
    struct DropCounter {
        // A heap allocation, so that a value dropped too early leaves the reference
        // `remove` hands back dangling rather than merely stale.
        name: String,
        drops: Arc<AtomicUsize>,
    }

    impl Drop for DropCounter {
        fn drop(&mut self) {
            self.drops.fetch_add(1, Ordering::SeqCst);
        }
    }

    let drops = Arc::new(AtomicUsize::new(0));
    let mut table = SyncTable::new();

    assert!(table.lock().write().insert(
        1usize,
        DropCounter {
            name: "one".to_owned(),
            drops: drops.clone(),
        },
        None
    ));

    {
        let mut locked = table.lock();
        let mut write = locked.write();
        let (key, value) = write.remove(&1usize, None).expect("the key was inserted");

        // `remove` only marks the bucket `DELETED`; the value must stay alive until the
        // table holding it is reclaimed, since the pair it returns points into that bucket.
        assert_eq!(
            drops.load(Ordering::SeqCst),
            0,
            "`remove` dropped the value while still returning a reference to it"
        );
        assert_eq!(*key, 1);
        assert_eq!(value.name, "one");
    }

    table
        .lock()
        .write()
        .replace(Vec::<(usize, DropCounter)>::new(), 0);
    for _ in 0..4 {
        release();
        crate::collect::collect();
    }

    table.write().prune();

    assert_eq!(drops.load(Ordering::SeqCst), 1);
}

#[test]
fn test_insert() {
    let _test = enter_test();
    let m = SyncTable::new();
    assert_eq!(m.lock().read().len(), 0);
    assert!(m.lock().write().insert(1, 2, None));
    assert_eq!(m.lock().read().len(), 1);
    assert!(m.lock().write().insert(2, 4, None));
    assert_eq!(m.lock().read().len(), 2);
    assert_eq!(*m.lock().read().get(&1, None).unwrap().1, 2);
    assert_eq!(*m.lock().read().get(&2, None).unwrap().1, 4);

    release();
}

#[test]
fn concurrent_get_and_insert() {
    let _test = enter_test();
    let table = SyncTable::new();
    let barrier = Barrier::new(2);

    thread::scope(|scope| {
        scope.spawn(|| {
            barrier.wait();

            for _ in 0..8 {
                pin(|pin| {
                    let _ = table.read(pin).get(&1, None).map(|(_, value)| *value);
                });
                thread::yield_now();
            }

            barrier.wait();

            pin(|pin| {
                assert_eq!(
                    table.read(pin).get(&1, None).map(|(_, value)| *value),
                    Some(2)
                );
            });

            release();
        });

        scope.spawn(|| {
            barrier.wait();
            assert!(table.lock().write().insert(1, 2, None));
            barrier.wait();
        });
    });

    release();
}

#[test]
fn concurrent_get_and_remove() {
    let _test = enter_test();
    let table = SyncTable::new();
    let barrier = Barrier::new(2);

    assert!(table.lock().write().insert(1, 2, None));

    thread::scope(|scope| {
        scope.spawn(|| {
            barrier.wait();

            for _ in 0..8 {
                pin(|pin| {
                    let _ = table.read(pin).get(&1, None).map(|(_, value)| *value);
                });
                thread::yield_now();
            }

            barrier.wait();

            pin(|pin| {
                assert!(table.read(pin).get(&1, None).is_none());
            });

            release();
        });

        scope.spawn(|| {
            barrier.wait();
            assert_eq!(
                table
                    .lock()
                    .write()
                    .remove(&1, None)
                    .map(|(_, value)| *value),
                Some(2)
            );
            barrier.wait();
        });
    });

    release();
}

#[test]
fn concurrent_insert_remove_and_get() {
    let _test = enter_test();
    let table = SyncTable::new();
    let barrier = Barrier::new(2);

    thread::scope(|scope| {
        scope.spawn(|| {
            barrier.wait();

            for _ in 0..8 {
                pin(|pin| {
                    let _ = table.read(pin).get(&1, None).map(|(_, value)| *value);
                    let _ = table.read(pin).get(&2, None).map(|(_, value)| *value);
                });
                thread::yield_now();
            }

            barrier.wait();

            pin(|pin| {
                assert!(table.read(pin).get(&1, None).is_none());
                assert_eq!(
                    table.read(pin).get(&2, None).map(|(_, value)| *value),
                    Some(4)
                );
            });

            release();
        });

        scope.spawn(|| {
            barrier.wait();
            assert!(table.lock().write().insert(1, 2, None));
            assert_eq!(
                table
                    .lock()
                    .write()
                    .remove(&1, None)
                    .map(|(_, value)| *value),
                Some(2)
            );
            assert!(table.lock().write().insert(2, 4, None));
            barrier.wait();
        });
    });

    release();
}

/// A pinned reader keeps the table it reads from alive, however often a writer replaces it.
///
/// The other concurrent tests never get past the static empty table, which `replace_table`
/// returns early for, so none of them ever retires anything.
#[test]
fn concurrent_read_across_a_table_retirement() {
    let _test = enter_test();

    #[derive(Clone)]
    struct Tracked {
        // A heap allocation, so reading a freed table is a use-after-free Miri can see.
        name: String,
        drops: Arc<AtomicUsize>,
    }

    impl Drop for Tracked {
        fn drop(&mut self) {
            self.drops.fetch_add(1, Ordering::SeqCst);
        }
    }

    // Exactly the capacity of the first allocation, so the writer below grows the table
    // the reader is pinned on straight away.
    const KEYS: usize = 14;
    const EXTRA: usize = 42;

    let drops = Arc::new(AtomicUsize::new(0));
    let value = |i: usize| Tracked {
        name: format!("v{i}"),
        drops: drops.clone(),
    };

    let table: SyncTable<usize, Tracked> = SyncTable::new();

    {
        let mut lock = table.lock();
        for i in 0..KEYS {
            assert!(lock.write().insert(i, value(i), None));
        }
    }

    let pinned = Barrier::new(2);
    let retired = Barrier::new(2);
    let checked = Barrier::new(2);

    let mut freed_while_pinned = 0;
    let mut retired_while_pinned = 0;

    thread::scope(|scope| {
        scope.spawn(|| {
            let observed = pin(|pin| {
                // References into the table as it is now, borrowed for as long as the pin.
                // The writer replaces that table below.
                let entries: Vec<_> = (0..KEYS)
                    .map(|i| table.read(pin).get(&i, None).unwrap())
                    .collect();

                pinned.wait();
                retired.wait();

                // The table these point into has been retired and the writer has tried to
                // free it since, so this reads what the reclamation has to keep alive.
                let observed: Vec<_> = entries
                    .into_iter()
                    .map(|(key, value)| (*key, value.name.clone()))
                    .collect();

                checked.wait();

                observed
            });

            release();

            // Assert once the writer is no longer waiting on a barrier for this thread.
            for (i, entry) in observed.into_iter().enumerate() {
                assert_eq!(entry, (i, format!("v{i}")));
            }
        });

        pinned.wait();

        {
            let mut lock = table.lock_no_prune();
            let mut write = lock.write();

            // Grow the table several times over, retiring the reader's table on the way.
            for i in KEYS..KEYS + EXTRA {
                assert!(write.insert(i, value(i), None));
            }

            // Give the collector every chance to hand the retired tables back.
            for _ in 0..4 {
                crate::collect::collect();
            }
            write.prune();

            freed_while_pinned = drops.load(Ordering::SeqCst);
            retired_while_pinned = write.table.retired.get().retired_iter().count();
        }

        retired.wait();
        checked.wait();
    });

    // Assert once the reader has been joined, so a failure cannot strand it on a barrier.
    assert!(
        retired_while_pinned > 0,
        "no table was retired, so nothing tested the pin"
    );
    assert_eq!(
        freed_while_pinned, 0,
        "a table was freed while a reader was pinned on it"
    );

    // With the reader unpinned and gone, the retired tables can go too.
    for _ in 0..4 {
        release();
        crate::collect::collect();
    }

    let mut lock = table.lock_no_prune();
    let mut write = lock.write();
    write.prune();

    assert_eq!(write.table.retired.get().retired_iter().count(), 0);
    assert!(drops.load(Ordering::SeqCst) > 0);

    // The elements the retired tables held were copies; the current table still has its own.
    for i in 0..KEYS + EXTRA {
        assert_eq!(
            write
                .read()
                .get(&i, None)
                .map(|(_, value)| value.name.clone()),
            Some(format!("v{i}"))
        );
    }
}

#[test]
fn test_iter() {
    let _test = enter_test();
    let m = SyncTable::new();
    assert!(m.lock().write().insert(1, 2, None));
    assert!(m.lock().write().insert(5, 3, None));
    assert!(m.lock().write().insert(2, 4, None));
    assert!(m.lock().write().insert(9, 4, None));

    pin(|pin| {
        let mut v: Vec<(i32, i32)> = m.read(pin).iter().map(|i| (*i.0, *i.1)).collect();
        v.sort_by_key(|k| k.0);

        assert_eq!(v, vec![(1, 2), (2, 4), (5, 3), (9, 4)]);
    });

    release();
}

#[test]
fn test_insert_conflicts() {
    let _test = enter_test();
    let m = SyncTable::new_with(RandomState::default(), 4);
    assert!(m.lock().write().insert(1, 2, None));
    assert!(m.lock().write().insert(5, 3, None));
    assert!(m.lock().write().insert(9, 4, None));
    assert_eq!(*m.lock().read().get(&9, None).unwrap().1, 4);
    assert_eq!(*m.lock().read().get(&5, None).unwrap().1, 3);
    assert_eq!(*m.lock().read().get(&1, None).unwrap().1, 2);

    release();
}

#[test]
fn test_expand() {
    let _test = enter_test();
    let m = SyncTable::new();

    assert_eq!(m.lock().read().len(), 0);

    // Take the bucket count after the first insert: a new table points at the static empty
    // one.
    m.lock().write().insert(0, 0, None);
    let old_raw_cap = unsafe { m.current().info().buckets() };

    let mut i = 1;
    while old_raw_cap == unsafe { m.current().info().buckets() } {
        m.lock().write().insert(i, i, None);
        i += 1;
    }

    assert!(unsafe { m.current().info().buckets() } > old_raw_cap);
    assert_eq!(m.lock().read().len(), i);

    // Everything the rehash moved must still be there.
    for key in 0..i {
        assert_eq!(
            m.lock().read().get(&key, None).map(|(_, value)| *value),
            Some(key)
        );
    }

    release();
}

#[test]
fn test_find() {
    let _test = enter_test();
    let m = SyncTable::new();
    assert!(m.lock().read().get(&1, None).is_none());
    m.lock().write().insert(1, 2, None);
    match m.lock().read().get(&1, None) {
        None => panic!(),
        Some(v) => assert_eq!(*v.1, 2),
    }

    release();
}

#[test]
fn test_capacity_not_less_than_len() {
    let _test = enter_test();
    let a: SyncTable<i32, i32> = SyncTable::new();
    let mut item = 0;

    for _ in 0..116 {
        a.lock().write().insert(item, 0, None);
        item += 1;
    }

    pin(|pin| {
        assert!(a.read(pin).capacity() > a.read(pin).len());

        let free = a.read(pin).capacity() - a.read(pin).len();
        for _ in 0..free {
            a.lock().write().insert(item, 0, None);
            item += 1;
        }

        assert_eq!(a.read(pin).len(), a.read(pin).capacity());

        // Insert at capacity should cause allocation.
        a.lock().write().insert(item, 0, None);
        assert!(a.read(pin).capacity() > a.read(pin).len());
    });

    release();
}

#[test]
fn rehash() {
    let _test = enter_test();
    let table = SyncTable::new();
    for i in 0..100 {
        table.lock().write().insert_new(i, (), None);
    }

    pin(|pin| {
        for i in 0..100 {
            assert_eq!(table.read(pin).get(&i, None).map(|b| *b.0), Some(i));
            assert!(table.read(pin).get(&(i + 100), None).is_none());
        }
    });

    release();
}

const INTERN_SIZE: u64 = if cfg!(miri) { 35 } else { 26334 };
const HIT_RATE: u64 = 84;

fn assert_equal(a: &mut SyncTable<u64, u64>, b: &HashMap<u64, u64>) {
    let mut ca: Vec<_> = b.iter().map(|v| (*v.0, *v.1)).collect();
    ca.sort();
    let mut cb: Vec<_> = a.write().read().iter().map(|v| (*v.0, *v.1)).collect();
    cb.sort();
    assert_eq!(ca, cb);
}

fn test_interning(intern: impl Fn(&SyncTable<u64, u64>, u64, u64, Pin<'_>) -> bool) {
    let mut control = HashMap::new();
    let mut test = SyncTable::new();

    for i in 0..INTERN_SIZE {
        let mut s = DefaultHasher::new();
        s.write_u64(i);
        let s = s.finish();
        if s % 100 > (100 - HIT_RATE) {
            test.lock().write().insert(i, i * 2, None);
            control.insert(i, i * 2);
        }
    }

    assert_equal(&mut test, &control);

    pin(|pin| {
        for i in 0..INTERN_SIZE {
            assert_eq!(
                intern(&test, i, i * 2, pin),
                control.insert(i, i * 2).is_some()
            )
        }
    });

    assert_equal(&mut test, &control);

    release();
}

#[test]
fn intern_potential() {
    let _test = enter_test();
    fn intern(table: &SyncTable<u64, u64>, k: u64, v: u64, pin: Pin<'_>) -> bool {
        let hash = table.hash_key(&k);
        let p = match table.read(pin).get_potential(&k, Some(hash)) {
            Ok(_) => return true,
            Err(p) => p,
        };

        let mut lock = table.lock();
        let mut write = lock.write();
        match p.get(write.read(), &k, Some(hash)) {
            Some(v) => {
                let _ = v.1;
                true
            }
            None => {
                p.insert_new(&mut write, k, v, Some(hash));
                false
            }
        }
    }

    test_interning(intern);
}

#[test]
fn intern_get_insert() {
    let _test = enter_test();
    fn intern(table: &SyncTable<u64, u64>, k: u64, v: u64, pin: Pin<'_>) -> bool {
        let hash = table.hash_key(&k);
        if table.read(pin).get(&k, Some(hash)).is_some() {
            return true;
        }

        let mut lock = table.lock();
        let mut write = lock.write();
        match write.read().get(&k, Some(hash)) {
            Some(_) => true,
            None => {
                write.insert_new(k, v, Some(hash));
                false
            }
        }
    }

    test_interning(intern);
}

/// Removed elements leave tombstones which consume `growth_left`. Reclaiming them must not
/// require a bigger table, otherwise insert/remove churn grows the table without bound.
#[test]
fn insert_remove_churn_does_not_grow_the_table() {
    let _test = enter_test();
    let m = SyncTable::new();

    assert!(m.lock().write().insert(0u64, 0u64, None));
    assert!(m.lock().write().remove(&0u64, None).is_some());

    let buckets = unsafe { m.current().info().buckets() };

    for i in 1..2000u64 {
        assert!(m.lock().write().insert(i, i, None));
        assert!(m.lock().write().remove(&i, None).is_some());
    }

    assert_eq!(m.lock().read().len(), 0);
    assert_eq!(unsafe { m.current().info().buckets() }, buckets);

    release();
}

/// A table which is mostly tombstones is rehashed into a smaller one, so churn on a table
/// which once was large does not keep its memory around forever.
#[test]
fn insert_remove_churn_shrinks_a_mostly_empty_table() {
    let _test = enter_test();
    let m = SyncTable::new();

    for i in 0..2000u64 {
        assert!(m.lock().write().insert(i, i, None));
    }

    let grown = unsafe { m.current().info().buckets() };

    for i in 0..1990u64 {
        assert!(m.lock().write().remove(&i, None).is_some());
    }

    // The removals only leave tombstones behind, so the table is still fully grown.
    assert_eq!(unsafe { m.current().info().buckets() }, grown);

    // Churn until the tombstones exhaust `growth_left` and force a rehash.
    for i in 2000..4000u64 {
        assert!(m.lock().write().insert(i, i, None));
        assert!(m.lock().write().remove(&i, None).is_some());
    }

    let shrunk = unsafe { m.current().info().buckets() };
    assert!(
        shrunk < grown,
        "{shrunk} buckets is not smaller than {grown}"
    );

    let lock = m.lock();
    let read = lock.read();
    assert_eq!(read.len(), 10);
    for i in 1990..2000u64 {
        assert_eq!(read.get(&i, None), Some((&i, &i)));
    }

    release();
}

#[test]
fn replace_sizes_by_the_actual_iterator_length() {
    let _test = enter_test();

    let mut m = SyncTable::new();

    // `filter` only bounds the length from above, so the allocation must be sized by the
    // number of elements actually yielded.
    m.write()
        .replace((0..1000i32).filter(|x| *x < 3).map(|x| (x, x)), 0);

    let write = m.write();
    let read = write.read();
    assert_eq!(read.len(), 3);
    assert!(read.capacity() < 1000);
}

/// A hash builder whose clone deliberately hashes differently from the original.
struct ShiftingHashBuilder(u64);

impl Clone for ShiftingHashBuilder {
    fn clone(&self) -> Self {
        ShiftingHashBuilder(self.0 + 1)
    }
}

struct ShiftingHasher(u64);

impl Hasher for ShiftingHasher {
    fn finish(&self) -> u64 {
        self.0
    }

    fn write(&mut self, _: &[u8]) {
        unimplemented!("only `u64` keys are supported")
    }

    fn write_u64(&mut self, value: u64) {
        self.0 = self.0.wrapping_add(value);
    }
}

impl std::hash::BuildHasher for ShiftingHashBuilder {
    type Hasher = ShiftingHasher;

    fn build_hasher(&self) -> ShiftingHasher {
        ShiftingHasher(self.0.wrapping_mul(0x9E37_79B9_7F4A_7C15))
    }
}

#[derive(Clone, Default)]
struct IdentityHashBuilder;

struct IdentityHasher(u64);

impl Hasher for IdentityHasher {
    fn finish(&self) -> u64 {
        self.0
    }

    fn write(&mut self, _: &[u8]) {
        unimplemented!("only `u64` keys are supported")
    }

    fn write_u64(&mut self, value: u64) {
        self.0 = value;
    }
}

impl std::hash::BuildHasher for IdentityHashBuilder {
    type Hasher = IdentityHasher;

    fn build_hasher(&self) -> IdentityHasher {
        IdentityHasher(0)
    }
}

/// `remove` leaves a `DELETED` tombstone behind and lookups stop only on `EMPTY`, so a key
/// whose probe sequence starts on a tombstone must still be found.
#[test]
fn lookup_probes_past_a_tombstone() {
    let _test = enter_test();

    // Hashes are the keys themselves. Every key is a multiple of the bucket count, so they
    // all start their probe sequence at bucket 0, and their top bits are all zero, so they
    // share an `h2` byte too. They fill consecutive buckets from there.
    const STRIDE: u64 = 1024;
    const KEYS: u64 = 32;

    let m: SyncTable<u64, u64, IdentityHashBuilder> =
        SyncTable::new_with(IdentityHashBuilder, KEYS as usize);

    for i in 0..KEYS {
        assert!(m.lock().write().insert(i * STRIDE, i * 10, None));
    }

    // Tombstone the first bucket of the probe sequence all of them share. The keys past the
    // first group now sit behind a full group which starts on that tombstone.
    assert_eq!(
        m.lock().write().remove(&0, None).map(|(key, _)| *key),
        Some(0)
    );

    for i in 1..KEYS {
        assert_eq!(
            m.lock().read().get(&(i * STRIDE), None).map(|(_, v)| *v),
            Some(i * 10),
            "the lookup for key {} did not probe past the tombstone",
            i * STRIDE
        );
    }

    // Tombstones are never reused, so this takes a bucket past all of the above and has to
    // be found through the tombstone it left behind.
    assert!(m.lock().write().insert(0, 1, None));
    assert_eq!(m.lock().read().get(&0, None).map(|(_, v)| *v), Some(1));

    // A missing key sharing the same probe sequence must still stop, at the first empty
    // bucket after all of them.
    assert_eq!(m.lock().read().get(&(KEYS * STRIDE), None), None);
}

#[test]
#[cfg(debug_assertions)]
#[should_panic(expected = "hash does not match the key")]
fn insert_with_a_mismatched_hash_is_rejected() {
    let _test = enter_test();

    let m = SyncTable::new();

    // A hash that is not `hash_key(&1)` would place the element outside its own probe
    // sequence, losing it.
    let wrong = m.hash_key(&1u64) ^ (1 << 63);

    m.lock().write().insert(1u64, 2u64, Some(wrong));
}

#[test]
#[cfg(debug_assertions)]
#[should_panic(expected = "bucket count must be a power of two")]
fn allocate_rejects_a_bucket_count_below_the_group_width() {
    // A single bucket leaves a `bucket_mask` of 0, which is how the static
    // `EMPTY_TABLE` is recognized, so such a table could never be freed.
    TableRef::<(u64, u64)>::allocate(1);
}

#[test]
#[cfg(debug_assertions)]
#[should_panic(expected = "bucket count must be a power of two")]
fn allocate_rejects_a_non_power_of_two_bucket_count() {
    TableRef::<(u64, u64)>::allocate(24);
}
