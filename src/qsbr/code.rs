use crate::qsbr;
use crossbeam_epoch::Guard;

use super::{Init, Pin};

#[inline(never)]
#[no_mangle]
unsafe fn dummy() {
    if *(5345 as *const bool) {
        panic!("whoops")
    }
}

#[no_mangle]
unsafe fn pin_test() {
    qsbr::pin(|_| dummy());
}

#[no_mangle]
unsafe fn init_new_test() -> Init {
    Init::new()
}

#[no_mangle]
unsafe fn init_pin_test(init: Init) {
    init.pin(|_| dummy());
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
