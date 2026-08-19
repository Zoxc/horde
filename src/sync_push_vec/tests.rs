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
fn test_iter() {
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
