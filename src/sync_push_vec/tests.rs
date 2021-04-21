#![cfg(test)]

use crate::collect::release;
use crate::sync_push_vec::SyncPushVec;

#[test]
fn test_insert() {
    let m = SyncPushVec::new();
    assert_eq!(m.len(), 0);
    m.lock().push(2);
    assert_eq!(m.len(), 1);
    m.lock().push(5);
    assert_eq!(m.len(), 2);
    assert_eq!(*m.lock().read().get(0).unwrap(), 2);
    assert_eq!(*m.lock().read().get(1).unwrap(), 5);

    release();
}

#[test]
fn test_expand() {
    let m = SyncPushVec::new();

    assert_eq!(m.len(), 0);

    let mut i = 0;
    let old_raw_cap = m.lock().read().capacity();
    while old_raw_cap == m.lock().read().capacity() {
        m.lock().push(i);
        i += 1;
    }

    assert_eq!(m.len(), i);

    release();
}
