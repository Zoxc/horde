#![cfg(code)]

use crate::collect;

#[inline(never)]
#[unsafe(no_mangle)]
unsafe fn dummy() {
    if unsafe { *(5345 as *const bool) } {
        panic!("whoops")
    }
}

#[unsafe(no_mangle)]
unsafe fn pin_test() {
    collect::pin(|_| unsafe { dummy() });
}

#[unsafe(no_mangle)]
unsafe fn collect_test() {
    collect::collect();
}

#[unsafe(no_mangle)]
unsafe fn release_test() {
    collect::release();
}
