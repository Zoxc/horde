#![cfg(code)]

use super::{SyncPushVec, Write};

#[unsafe(no_mangle)]
unsafe fn get(a: &SyncPushVec<usize>) -> Option<usize> {
    unsafe { a.unsafe_write() }
        .read()
        .as_slice()
        .get(2)
        .cloned()
}

#[unsafe(no_mangle)]
unsafe fn push(a: &SyncPushVec<usize>) {
    unsafe { a.unsafe_write() }.push(4000);
}

#[unsafe(no_mangle)]
unsafe fn push2(a: &mut Write<'_, usize>) {
    a.push(4000);
}
