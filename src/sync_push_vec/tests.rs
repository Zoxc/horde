#![cfg(test)]

use super::TableRef;
use crate::collect::enter_test;
use crate::sync_push_vec::SyncPushVec;
use crate::util::leak_as_miri_root;
use std::mem;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

#[test]
#[should_panic(expected = "capacity overflow")]
fn test_with_capacity_panics_on_layout_alignment_overflow() {
    SyncPushVec::<u8>::with_capacity(usize::MAX);
}

#[test]
fn test_layout_rejects_capacities_above_isize_max_bytes() {
    let capacity = (isize::MAX as usize / mem::size_of::<u16>()) + 1;

    assert!(TableRef::<u16>::layout(capacity).is_none());
}

#[test]
fn test_push_appends_in_order() {
    let _test = enter_test();
    let mut m = SyncPushVec::new();
    m.write().push(1);
    m.write().push(2);
    assert_eq!(m.write().read().as_slice().to_vec(), vec![1, 2]);
}

#[test]
fn test_high_align() {
    let _test = enter_test();
    #[repr(align(128))]
    #[allow(dead_code)]
    #[derive(Clone)]
    struct A(u8);
    let mut m = SyncPushVec::<A>::new();
    for _a in m.write().read().as_slice() {}
    m.write().push(A(1));
    for _a in m.write().read().as_slice() {}
}

#[test]
fn test_low_align() {
    let _test = enter_test();
    let mut m = SyncPushVec::<u8>::with_capacity(1);
    m.write().push(1);
}

#[test]
fn test_low_align_iteration_with_padding_before_info() {
    let _test = enter_test();
    let mut m = SyncPushVec::<u8>::with_capacity(3);
    m.write().push(1);
    m.write().push(2);
    m.write().push(3);

    assert_eq!(m.write().read().as_slice(), [1, 2, 3]);
}

#[test]
fn test_low_align_replace_and_expand_keep_values() {
    let _test = enter_test();
    let mut m = SyncPushVec::<u8>::with_capacity(3);
    m.write().replace(vec![1, 2, 3], 3);
    assert_eq!(m.write().read().as_slice(), [1, 2, 3]);

    m.write().push(4);
    assert_eq!(m.write().read().as_slice(), [1, 2, 3, 4]);
}

#[test]
fn test_insert() {
    let _test = enter_test();
    let m = SyncPushVec::new();
    assert_eq!(m.lock().read().len(), 0);
    m.lock().write().push(2);
    assert_eq!(m.lock().read().len(), 1);
    m.lock().write().push(5);
    assert_eq!(m.lock().read().len(), 2);
    assert_eq!(m.lock().read().as_slice()[0], 2);
    assert_eq!(m.lock().read().as_slice()[1], 5);
}

#[test]
fn swapped_locks_keep_their_guards() {
    let _test = enter_test();
    let a = SyncPushVec::new();
    let b = SyncPushVec::new();

    let mut lock_a = a.lock();
    let mut lock_b = b.lock();

    // Swapping whole `LockedWrite`s is harmless since each guard moves along with the
    // vector it protects.
    mem::swap(&mut lock_a, &mut lock_b);

    assert!(a.mutex().is_locked());
    assert!(b.mutex().is_locked());

    // `lock_a` now holds `b`'s guard and writes to `b`.
    lock_a.write().push(1);
    drop(lock_a);
    assert!(!b.mutex().is_locked());
    assert!(a.mutex().is_locked());

    lock_b.write().push(2);
    drop(lock_b);
    assert!(!a.mutex().is_locked());

    assert_eq!(b.lock().read().as_slice(), [1]);
    assert_eq!(a.lock().read().as_slice(), [2]);
}

#[test]
fn test_replace() {
    let _test = enter_test();
    let m = SyncPushVec::new();
    m.lock().write().push(2);
    m.lock().write().push(5);
    assert_eq!(m.lock().read().as_slice(), [2, 5]);
    m.lock().write().replace(vec![3], 0);
    assert_eq!(m.lock().read().as_slice(), [3]);
    m.lock().write().replace(vec![], 0);
    assert_eq!(m.lock().read().as_slice(), []);
}

#[test]
fn test_replace_empty_preserves_requested_capacity() {
    let _test = enter_test();
    let m = SyncPushVec::new();
    m.lock().write().replace(Vec::<i32>::new(), 8);
    assert_eq!(m.lock().read().as_slice(), []);
    assert_eq!(m.lock().read().capacity(), 8);
}

#[test]
fn replace_then_forget_leaks_retired_elements() {
    let _test = enter_test();

    #[derive(Clone)]
    struct DropCounter(Arc<AtomicUsize>);

    impl Drop for DropCounter {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    let drops = Arc::new(AtomicUsize::new(0));
    let vector = SyncPushVec::with_capacity(1);

    vector.lock().write().push(DropCounter(drops.clone()));
    vector.lock().write().replace(Vec::<DropCounter>::new(), 0);

    leak_as_miri_root(vector);

    crate::collect::collect();

    assert_eq!(drops.load(Ordering::SeqCst), 0);
}

#[test]
fn test_expand() {
    let _test = enter_test();
    let m = SyncPushVec::new();

    assert_eq!(m.lock().read().len(), 0);

    // Take the capacity after the first push: a new vector has no allocation at all.
    m.lock().write().push(0);
    let old_raw_cap = m.lock().read().capacity();

    let mut i = 1;
    while old_raw_cap == m.lock().read().capacity() {
        m.lock().write().push(i);
        i += 1;
    }

    assert!(m.lock().read().capacity() > old_raw_cap);
    assert_eq!(m.lock().read().len(), i);

    // Everything the copy into the bigger table moved must still be there, in order.
    assert_eq!(m.lock().read().as_slice(), (0..i).collect::<Vec<_>>());
}

#[test]
fn zst_repro_expand_overflow() {
    let _test = enter_test();

    let mut v = crate::sync_push_vec::SyncPushVec::<()>::with_capacity(usize::MAX - 1);
    let mut w = v.write();
    w.reserve(usize::MAX);
    assert_eq!(w.read().as_slice().len(), 0);
    w.push(());
    assert_eq!(w.read().as_slice().len(), 1);
}

#[test]
fn replace_sizes_by_the_actual_iterator_length() {
    let _test = enter_test();

    let mut m = SyncPushVec::new();

    // `filter` only bounds the length from above, so the allocation must be sized by the
    // number of elements actually yielded.
    m.write().replace((0..1000u32).filter(|x| *x < 3), 0);

    let write = m.write();
    let read = write.read();
    assert_eq!(read.as_slice(), &[0, 1, 2]);
    assert_eq!(read.len(), 3);
    assert_eq!(read.capacity(), 3);
}

#[test]
fn dropping_the_vector_drops_every_element_exactly_once() {
    let _test = enter_test();

    static CONSTRUCTED: AtomicUsize = AtomicUsize::new(0);
    static DROPPED: AtomicUsize = AtomicUsize::new(0);

    // A heap allocation, so a missing drop leaks and a second one is a double free Miri sees.
    struct Tracked(String);

    impl Tracked {
        fn new(i: usize) -> Self {
            CONSTRUCTED.fetch_add(1, Ordering::SeqCst);
            Tracked(format!("v{i}"))
        }
    }

    impl Clone for Tracked {
        fn clone(&self) -> Self {
            CONSTRUCTED.fetch_add(1, Ordering::SeqCst);
            Tracked(self.0.clone())
        }
    }

    impl Drop for Tracked {
        fn drop(&mut self) {
            DROPPED.fetch_add(1, Ordering::SeqCst);
        }
    }

    const PUSHES: usize = 40;

    let mut vector = SyncPushVec::new();
    {
        let mut write = vector.write();
        for i in 0..PUSHES {
            write.push(Tracked::new(i));
        }
    }

    let constructed = CONSTRUCTED.load(Ordering::SeqCst);

    // The vector expanded on the way, so the tables it retired hold clones of their own.
    assert!(
        constructed > PUSHES,
        "the vector never expanded, so no retired table held an element"
    );
    assert_eq!(
        DROPPED.load(Ordering::SeqCst),
        0,
        "an element was dropped while the vector still owned it"
    );

    // The elements the current table holds are still the ones that were pushed.
    assert_eq!(
        vector
            .as_mut_slice()
            .iter()
            .map(|value| value.0.clone())
            .collect::<Vec<_>>(),
        (0..PUSHES).map(|i| format!("v{i}")).collect::<Vec<_>>()
    );

    drop(vector);

    assert_eq!(DROPPED.load(Ordering::SeqCst), constructed);
}

#[test]
fn push_returns_the_index_of_the_new_element() {
    let _test = enter_test();

    let mut m = SyncPushVec::new();
    let mut write = m.write();

    // Enough pushes that the vector expands several times on the way.
    for i in 0..40u32 {
        let (value, index) = write.push(i);
        assert_eq!(*value, i);
        assert_eq!(index, i as usize);
    }

    let read = write.read();
    for i in 0..40u32 {
        assert_eq!(read.as_slice()[i as usize], i);
    }
}

#[test]
fn unsafe_write_and_lock_from_guard_give_a_working_handle() {
    let _test = enter_test();

    let m = SyncPushVec::new();

    // SAFETY: this thread holds the only handle to `m`, so no other `Write` exists.
    unsafe { m.unsafe_write() }.push(1);

    let mut lock = m.lock_from_guard(m.mutex().lock());
    lock.write().push(2);
    assert_eq!(lock.read().as_slice(), [1, 2]);

    // The guard is held for as long as the handle is.
    assert!(m.mutex().is_locked());
    drop(lock);
    assert!(!m.mutex().is_locked());
}

/// The mismatch check is the only thing keeping a `LockedWrite` from being built over a guard
/// for a different vector's mutex, which would leave both unprotected.
#[test]
#[should_panic(expected = "left == right")]
fn lock_from_guard_rejects_another_vectors_guard() {
    let _test = enter_test();

    let a = SyncPushVec::<u32>::new();
    let b = SyncPushVec::<u32>::new();

    let _lock = a.lock_from_guard(b.mutex().lock());
}

#[test]
fn from_iter_and_extend_take_every_element() {
    let _test = enter_test();

    let mut m: SyncPushVec<u32> = (0..8).collect();
    assert_eq!(m.write().read().as_slice(), (0..8).collect::<Vec<_>>());

    // An iterator whose `size_hint` only bounds the length from above, so `reserve` alone
    // does not make room for all of it.
    m.write().extend((8..1000u32).filter(|i| *i < 24));
    assert_eq!(m.write().read().as_slice(), (0..24).collect::<Vec<_>>());
}

#[test]
fn reserve_grows_the_allocation_once() {
    let _test = enter_test();

    let mut m = SyncPushVec::<u32>::new();
    m.write().push(1);

    let before = m.write().read().capacity();
    m.write().reserve(100);

    let grown = m.write().read().capacity();
    assert!(grown > before);
    assert!(grown >= 101);

    // The room is already there, so this must not reallocate.
    m.write().reserve(1);
    assert_eq!(m.write().read().capacity(), grown);

    assert_eq!(m.write().read().as_slice(), [1]);
}

#[test]
#[should_panic(expected = "capacity overflow")]
fn reserve_rejects_a_request_which_overflows() {
    let _test = enter_test();

    let mut m = SyncPushVec::<u32>::new();
    m.write().push(1);
    m.write().reserve(usize::MAX);
}
