#![cfg(test)]

use crate::collect::enter_test;
use crate::collect::release;
use crate::sync_push_vec::SyncPushVec;

#[test]
#[should_panic(expected = "capacity overflow")]
fn test_with_capacity_panics_on_layout_alignment_overflow() {
    SyncPushVec::<u8>::with_capacity(usize::MAX);
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
    m.lock().push(2);
    assert_eq!(m.lock().read().len(), 1);
    m.lock().push(5);
    assert_eq!(m.lock().read().len(), 2);
    assert_eq!(m.lock().read().as_slice()[0], 2);
    assert_eq!(m.lock().read().as_slice()[1], 5);

    release();
}

#[test]
fn test_replace() {
    let _test = enter_test();
    let m = SyncPushVec::new();
    m.lock().push(2);
    m.lock().push(5);
    assert_eq!(m.lock().read().as_slice(), [2, 5]);
    m.lock().replace(vec![3], 0);
    assert_eq!(m.lock().read().as_slice(), [3]);
    m.lock().replace(vec![], 0);
    assert_eq!(m.lock().read().as_slice(), []);
    release();
}

#[test]
fn test_replace_empty_preserves_requested_capacity() {
    let _test = enter_test();
    let m = SyncPushVec::new();
    m.lock().replace(Vec::<i32>::new(), 8);
    assert_eq!(m.lock().read().as_slice(), []);
    assert_eq!(m.lock().read().capacity(), 8);
    release();
}

#[test]
fn test_expand() {
    let _test = enter_test();
    let m = SyncPushVec::new();

    assert_eq!(m.lock().read().len(), 0);

    let mut i = 0;
    let old_raw_cap = m.lock().read().capacity();
    while old_raw_cap == m.lock().read().capacity() {
        m.lock().push(i);
        i += 1;
    }

    assert_eq!(m.lock().read().len(), i);

    release();
}
