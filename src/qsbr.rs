use crate::scopeguard::guard;
use crossbeam_epoch::Guard;
use std::{
    cell::UnsafeCell,
    intrinsics::unlikely,
    sync::atomic::{compiler_fence, Ordering},
};

mod code;

pub struct Pin {
    _private: (),
}

impl Pin {
    pub fn guard(&self) -> &Guard {
        let data = hide(data());

        unsafe {
            if unlikely((*data).guard.is_none()) {
                (*data).get_guard();
            }

            (*data).guard.as_ref().unwrap_unchecked()
        }
    }
}

#[thread_local]
static DATA: UnsafeCell<Data> = UnsafeCell::new(Data {
    pinned: false,
    guard: None,
});

struct Data {
    pinned: bool,
    guard: Option<Guard>,
}

#[inline(never)]
#[cold]
fn panic_pinned() {
    panic!("The current thread was pinned");
}

impl Data {
    #[inline]
    fn assert_unpinned(&self) {
        if self.pinned {
            panic_pinned()
        }
    }

    #[inline(never)]
    #[cold]
    fn get_guard(&mut self) {
        self.guard = Some(crossbeam_epoch::pin());
    }
}

cfg_if! {
    if #[cfg(all(
        any(target_arch = "x86", target_arch = "x86_64"),
        not(miri)
    ))] {
        #[inline]
        fn hide(mut data: *mut Data) -> *mut Data {
            // Hide the `data` value from LLVM to prevent it from generating multiple TLS accesses
            unsafe {
                asm!("/* {} */", inout(reg) data);
            }

            data
        }
    } else {
        #[inline]
        fn hide(data: *mut Data) -> *mut Data {
            data
        }
    }
}

// Never inline due to thread_local bugs
#[inline(never)]
fn data() -> *mut Data {
    DATA.get()
}

#[inline]
pub fn pin<R>(f: impl FnOnce(&Pin) -> R) -> R {
    let data = unsafe { &mut *(hide(data())) };
    let old_pinned = data.pinned;
    data.pinned = true;
    guard(old_pinned, |pin| data.pinned = *pin);
    f(&Pin { _private: () })
}

pub fn release() {
    let data = unsafe { &mut *(hide(data())) };
    data.assert_unpinned();
    data.guard = None;
}

pub fn collect() {
    let data = unsafe { &mut *(hide(data())) };

    // This fence prevents the `data` access from being moved below into the
    // basic block below. That would cause LLVM to create a second TLS lookup since
    // it does one per basic block.
    compiler_fence(Ordering::SeqCst);

    data.assert_unpinned();
    data.guard.as_mut().map(|guard| guard.repin());
}
