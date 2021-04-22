use crate::{scopeguard::guard, util::cold_path};
use parking_lot::Mutex;
use std::{
    cell::Cell,
    collections::HashMap,
    intrinsics::unlikely,
    lazy::SyncLazy,
    marker::PhantomData,
    mem,
    sync::atomic::{AtomicUsize, Ordering},
    thread::{self, ThreadId},
};

mod code;

// TODO: Use a reference count of pins and a PinRef ZST with a destructor that drops the reference
// so a closure with the `pin` function isn't required.

static DEFERRED: AtomicUsize = AtomicUsize::new(0);

#[derive(Clone, Copy)]
pub struct Pin<'a> {
    _private: PhantomData<&'a ()>,
}

impl Pin<'_> {
    // FIXME: Prevent pin calls inside the callback?
    pub unsafe fn defer_unchecked<F>(&self, f: F)
    where
        F: FnOnce(),
        F: Send,
    {
        let f: Box<dyn FnOnce() + Send> = Box::new(f);
        let f: Box<dyn FnOnce() + Send + 'static> = mem::transmute(f);

        COLLECTOR.lock().defer(f);

        DEFERRED.fetch_add(1, Ordering::Release);
    }
}

#[thread_local]
static DATA: Data = Data {
    pinned: Cell::new(false),
    registered: Cell::new(false),
    seen_deferred: Cell::new(0),
};

struct Data {
    pinned: Cell<bool>,
    registered: Cell<bool>,
    seen_deferred: Cell<usize>,
}

#[inline(never)]
#[cold]
fn panic_pinned() {
    panic!("The current thread was pinned");
}

impl Data {
    #[inline]
    fn assert_unpinned(&self) {
        if self.pinned.get() {
            panic_pinned()
        }
    }

    #[inline(never)]
    #[cold]
    fn register(&self) {
        COLLECTOR.lock().register();
        self.registered.set(true);
    }
}

cfg_if! {
    if #[cfg(all(
        any(target_arch = "x86", target_arch = "x86_64"),
        not(miri)
    ))] {
        #[inline]
        fn hide(mut data: *const Data) -> *const Data {
            // Hide the `data` value from LLVM to prevent it from generating multiple TLS accesses
            unsafe {
                asm!("/* {} */", inout(reg) data, options(pure, nomem, nostack, preserves_flags));
            }

            data
        }
    } else {
        #[inline]
        fn hide(data: *const Data) -> *const Data {
            data
        }
    }
}

// Never inline due to thread_local bugs
#[inline(never)]
fn data() -> *const Data {
    &DATA as *const Data
}

// Never inline due to thread_local bugs
#[inline(never)]
fn data_init() -> *const Data {
    let data = hide(&DATA as *const Data);

    {
        let data = unsafe { &*data };
        if unlikely(!data.registered.get()) {
            data.register();
        }
    }

    data
}

#[inline]
pub fn pin<R>(f: impl FnOnce(Pin<'_>) -> R) -> R {
    let data = unsafe { &*(hide(data_init())) };
    let old_pinned = data.pinned.get();
    data.pinned.set(true);
    guard(old_pinned, |pin| data.pinned.set(*pin));
    f(Pin {
        _private: PhantomData,
    })
}

pub fn release() {
    let data = unsafe { &*(hide(data())) };
    data.assert_unpinned();
    if data.registered.get() {
        data.registered.set(false);
        COLLECTOR.lock().unregister();
    }
}

pub fn collect() {
    let data = unsafe { &*(hide(data())) };
    data.assert_unpinned();
    let new = DEFERRED.load(Ordering::Acquire);
    if unlikely(new != data.seen_deferred.get()) {
        data.seen_deferred.set(new);
        cold_path(|| {
            let callbacks = COLLECTOR.lock().quiet();

            callbacks.map(|callbacks| callbacks.into_iter().for_each(|callback| callback()));
        });
    }
}

static COLLECTOR: SyncLazy<Mutex<Collector>> = SyncLazy::new(|| Mutex::new(Collector::new()));

type Callbacks = Vec<Box<dyn FnOnce() + Send>>;

struct Collector {
    pending: bool,
    busy_count: usize,
    threads: HashMap<ThreadId, bool>,
    current_deferred: Callbacks,
    previous_deferred: Callbacks,
}

impl Collector {
    fn new() -> Self {
        Self {
            pending: false,
            busy_count: 0,
            threads: HashMap::new(),
            current_deferred: Vec::new(),
            previous_deferred: Vec::new(),
        }
    }

    fn register(&mut self) {
        debug_assert!(!self.threads.contains_key(&thread::current().id()));

        self.busy_count += 1;
        self.threads.insert(thread::current().id(), false);
    }

    fn unregister(&mut self) {
        debug_assert!(self.threads.contains_key(&thread::current().id()));

        let thread = &thread::current().id();
        if *self.threads.get(&thread).unwrap() {
            self.busy_count -= 1;

            if self.busy_count == 0
                && (!self.previous_deferred.is_empty() || !self.current_deferred.is_empty())
            {
                // Don't collect garbage here, but let the other threads know that there's
                // garbage to be collected.
                self.pending = true;
                DEFERRED.fetch_add(1, Ordering::Release);
            }
        }

        self.threads.remove(&thread);
    }

    fn quiet(&mut self) -> Option<Callbacks> {
        let quiet = self.threads.get_mut(&thread::current().id()).unwrap();
        if !*quiet || self.pending {
            if !*quiet {
                self.busy_count -= 1;
                *quiet = true;
            }

            if self.busy_count == 0 {
                // All threads are quiet
                self.pending = false;

                self.busy_count = self.threads.len();
                self.threads.values_mut().for_each(|value| {
                    *value = false;
                });

                let callbacks = mem::take(&mut self.previous_deferred);
                self.previous_deferred = mem::take(&mut self.current_deferred);

                Some(callbacks)
            } else {
                None
            }
        } else {
            None
        }
    }

    fn defer(&mut self, callback: Box<dyn FnOnce() + Send>) {
        debug_assert!(self.threads.contains_key(&thread::current().id()));

        self.current_deferred.push(callback);
    }
}
