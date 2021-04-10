use crate::qsbr;
use crossbeam_epoch::Guard;
use std::sync::atomic::{AtomicBool, Ordering};

use super::Pin;

static DUMMY: AtomicBool = AtomicBool::new(false);

#[inline(never)]
#[no_mangle]
unsafe fn dummy() {
    if DUMMY.load(Ordering::Acquire) {
        panic!("whoops")
    }
}

#[no_mangle]
unsafe fn pin_test() {
    qsbr::pin(|_| dummy());
}

#[no_mangle]
unsafe fn pin_guard(pin: &Pin) -> &Guard {
    pin.guard()
}

#[no_mangle]
unsafe fn collect_test() {
    qsbr::collect();
}

#[no_mangle]
unsafe fn release_test() {
    qsbr::release();
}
