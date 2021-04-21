use crate::{scopeguard::guard, util::cold_path};
use crossbeam_epoch::Guard;
use std::{
    cell::UnsafeCell,
    intrinsics::unlikely,
    sync::atomic::{AtomicU64, Ordering},
};

mod code;

// TODO: Make the &'a Pin into a ZST Pin<'a>.
// TODO: Use a reference count of pins and a PinRef ZST with a destructor that drops the reference
// so a closure with the `pin` function isn't required.

/// Proof that the guard is initialized on this thread.
#[derive(Clone, Copy)]
pub struct Init {
    _private: (),
}

impl !Send for Init {}

impl Init {
    pub fn new() -> Self {
        pin(|_| ());
        Init { _private: () }
    }

    #[inline]
    pub fn pin<R>(&self, f: impl FnOnce(&Pin) -> R) -> R {
        let data = unsafe { &mut *(hide(data())) };
        let old_pinned = data.pinned;
        data.pinned = true;
        guard(old_pinned, |pin| data.pinned = *pin);
        f(&Pin { _private: () })
    }
}

static DEFERRED: AtomicU64 = AtomicU64::new(0);

pub struct Pin {
    _private: (),
}

impl Pin {
    fn guard(&self) -> &Guard {
        let data = data();

        unsafe { (*data).guard.as_ref().unwrap() }
    }

    // FIXME: Prevent pin calls inside the callback?
    pub unsafe fn defer_unchecked<F, R>(&self, f: F)
    where
        F: FnOnce() -> R,
        F: Send,
    {
        DEFERRED
            .fetch_update(Ordering::Acquire, Ordering::Relaxed, |current| {
                Some(current.checked_add(1).unwrap())
            })
            .ok();

        self.guard().defer_unchecked(f)
    }
}

#[thread_local]
static DATA: UnsafeCell<Data> = UnsafeCell::new(Data {
    pinned: false,
    guard: None,
    seen_deferred: 0,
});

struct Data {
    pinned: bool,
    guard: Option<Guard>,
    seen_deferred: u64,
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
                asm!("/* {} */", inout(reg) data, options(pure, nomem, nostack, preserves_flags));
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

// Never inline due to thread_local bugs
#[inline(never)]
fn data_init() -> *mut Data {
    let data = hide(DATA.get());

    {
        let data = unsafe { &mut *data };
        if unlikely(data.guard.is_none()) {
            data.get_guard();
        }
    }

    data
}

#[inline]
pub fn pin<R>(f: impl FnOnce(&Pin) -> R) -> R {
    let data = unsafe { &mut *(hide(data_init())) };
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
    data.assert_unpinned();
    let new = DEFERRED.load(Ordering::Acquire);
    if unlikely(new != data.seen_deferred) {
        data.seen_deferred = new;
        cold_path(|| {
            data.guard = None;
            data.guard = Some(crossbeam_epoch::pin());
        });
    }
}
