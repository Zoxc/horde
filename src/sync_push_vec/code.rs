use super::SyncPushVec;

#[no_mangle]
unsafe fn get(a: &SyncPushVec<usize>) -> Option<usize> {
    a.unsafe_write().read().get(2).cloned()
}

#[no_mangle]
unsafe fn push(a: &SyncPushVec<usize>) {
    a.unsafe_write().push(4000);
}
