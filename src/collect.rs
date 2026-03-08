//! An API for quiescent state based reclamation.
//!
//! Threads that read shared lock-free data call [pin] to mark the duration of the critical
//! section. Destruction of removed data is postponed with [defer_unchecked] and later driven by
//! [collect], which advances the global quiescent-state cycle.
//!
//! Long-lived threads that stop interacting with lock-free structures should call [release] so
//! they no longer delay reclamation.

use crate::{scopeguard::guard, util::cold_path};
use parking_lot::Mutex;
use std::{
    cell::Cell,
    collections::HashMap,
    hint::unlikely,
    marker::PhantomData,
    mem,
    panic::{self, AssertUnwindSafe},
    sync::LazyLock,
    sync::atomic::{AtomicUsize, Ordering},
    thread::{self, ThreadId},
};

mod code;

/// Monotonic event counter used to notify threads that reclamation state changed.
static EVENTS: AtomicUsize = AtomicUsize::new(0);

/// Represents a proof that no deferred callbacks will run for the lifetime `'a`.
///
/// A `Pin` is handed to the closure passed to [pin] and can be used to access data structures in
/// a lock-free manner while the current thread remains pinned.
#[derive(Clone, Copy)]
pub struct Pin<'a> {
    _private: PhantomData<&'a ()>,
}

/// Schedules a closure to run after all threads leave their current pinned regions.
///
/// The closure will be called by the [collect] method.
///
/// This deferred callback must not call [pin] or [collect].
///
/// Deferred callbacks run in a later collection cycle on whichever thread performs that collection.
/// They are typically used to destroy or free data that was removed from a lock-free structure.
///
/// # Safety
/// This method is unsafe since the closure is not required to be `'static`.
/// It's up to the caller to ensure the closure does not access freed memory.
/// A `move` closure is recommended to avoid accidental references to stack variables.
pub unsafe fn defer_unchecked<F>(f: F)
where
    F: FnOnce(),
    F: Send,
{
    unsafe {
        let f: Box<dyn FnOnce() + Send> = Box::new(f);
        let f: Box<dyn FnOnce() + Send + 'static> = mem::transmute(f);

        COLLECTOR.lock().defer(f);
    }
}

thread_local! {
    static DATA: Data = const {
        Data {
            state: Cell::new(State::Unregistered),
            seen_events: Cell::new(0),
        }
    };
    static EXIT_GUARD: ExitGuard = const { ExitGuard };
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum State {
    // Valid states to immediately pin in.
    // This is placed on top so `pin` can check these states with a single comparison.
    /// Registered with the collector and allowed to enter a pinned region immediately.
    Registered,
    /// Currently inside a pinned region.
    Pinned,

    // Not valid states to immediately pin in
    /// Not currently known to the collector.
    Unregistered,
    /// Running deferred callbacks as part of a collection pass.
    Collecting,
}

/// Per-thread state tracked in thread-local storage.
struct Data {
    /// Current collector state for the thread.
    state: Cell<State>,
    /// Last observed value of [EVENTS].
    seen_events: Cell<usize>,
}

/// Releases the current thread from the collector when the thread exits.
struct ExitGuard;

impl Drop for ExitGuard {
    fn drop(&mut self) {
        release();
    }
}

cfg_if! {
    if #[cfg(all(
        any(target_arch = "x86", target_arch = "x86_64"),
        not(miri)
    ))] {
        #[inline]
        #[allow(clippy::pointers_in_nomem_asm_block)]
        fn hide(mut data: *const Data) -> *const Data {
            use std::arch::asm;
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

/// Returns the address of the current thread's collector state.
fn data() -> *const Data {
    DATA.with(|data| data as *const Data)
}

/// Marks the current thread as pinned and returns a proof of that to the closure.
///
/// This adds the current thread to the set of threads that needs to regularly call [collect]
/// before memory can be freed. [release] can be called if a thread no longer needs
/// access to lock-free data structures for an extended period of time.
///
/// Nested calls to [pin] are allowed.
///
/// This will panic if called from a deferred callback.
#[inline]
pub fn pin<R>(f: impl FnOnce(Pin<'_>) -> R) -> R {
    let data = unsafe { &*(hide(data())) };

    if unlikely(!matches!(
        data.state.get(),
        State::Registered | State::Pinned
    )) {
        pin_cold();
    }

    let old_state = data.state.get();
    data.state.set(State::Pinned);
    let _guard = guard(old_state, |state| data.state.set(*state));
    f(Pin {
        _private: PhantomData,
    })
}

#[inline(never)]
#[cold]
fn pin_cold() {
    let data = unsafe { &*(hide(data())) };

    match data.state.get() {
        State::Unregistered => {
            EXIT_GUARD.with(|_| ());
            COLLECTOR.lock().register();
            data.state.set(State::Registered);
        }
        State::Registered | State::Pinned => unreachable!(),
        State::Collecting => cold_path(|| panic!("Deferred callbacks cannot call `pin`")),
    }
}

/// Removes the current thread from the threads allowed to access lock-free data structures.
///
/// This allows memory to be freed without waiting for [collect] calls from the current thread.
/// [pin] can be called after to continue accessing lock-free data structures.
///
/// This will not free any garbage so [collect] should be called before the last thread
/// terminates to avoid memory leaks.
///
/// Calling this function when the thread is already unregistered is a no-op.
///
/// This will panic if called while the current thread is pinned or during a deferred callback.
pub fn release() {
    let data = unsafe { &*(hide(data())) };

    match data.state.get() {
        State::Unregistered => (),
        State::Registered => {
            data.state.set(State::Unregistered);
            COLLECTOR.lock().unregister();
        }
        State::Pinned => cold_path(|| panic!("Cannot call `release` while pinned")),
        State::Collecting => cold_path(|| panic!("Deferred callbacks cannot call `release`")),
    }
}

/// Signals a quiescent state where garbage may be collected.
///
/// This may collect garbage using the callbacks registered in [Pin::defer_unchecked](struct.Pin.html#method.defer_unchecked).
///
/// This may panic if called while a thread is pinned or if called from a deferred callback.
pub fn collect() {
    let data = unsafe { &*(hide(data())) };

    if cfg!(debug_assertions) {
        assert_collect_state(data);
    }

    let new = EVENTS.load(Ordering::Acquire);
    if unlikely(new != data.seen_events.get()) {
        data.seen_events.set(new);
        collect_cold();
    }
}

fn assert_collect_state(data: &Data) {
    match data.state.get() {
        State::Registered | State::Unregistered => (),
        State::Pinned => panic!("Cannot call `collect` while pinned"),
        State::Collecting => panic!("Deferred callbacks cannot call `collect`"),
    }
}

#[inline(never)]
#[cold]
fn collect_cold() {
    let data = unsafe { &*(hide(data())) };
    assert_collect_state(data);

    let old_state = data.state.get();
    let _guard = guard(old_state, |state| data.state.set(*state));
    data.state.set(State::Collecting);

    let callbacks = {
        let mut collector = COLLECTOR.lock();

        // Check if we could block any deferred methods
        if let State::Registered = old_state {
            collector.quiet()
        } else {
            collector.collect_unregistered()
        }
    };

    let mut panic = None;

    for callback in callbacks {
        if let Err(payload) = panic::catch_unwind(AssertUnwindSafe(|| {
            callback();
        })) {
            panic = Some(payload);
        }
    }

    if let Some(payload) = panic {
        panic::resume_unwind(payload)
    }
}

static COLLECTOR: LazyLock<Mutex<Collector>> = LazyLock::new(|| Mutex::new(Collector::new()));

type Callbacks = Vec<Box<dyn FnOnce() + Send>>;

#[derive(Clone, Copy, PartialEq, Eq)]
enum ThreadState {
    /// The thread reported a quiescent state for the current epoch.
    Quiet,
    /// The thread still needs to report a quiescent state for the current epoch.
    Busy,
}

/// Global collector state shared by all participating threads.
struct Collector {
    /// Callbacks that are ready to run on the next collection attempt.
    pending: Callbacks,
    /// Number of registered threads still marked as [ThreadState::Busy].
    busy_count: usize,
    /// Per-thread participation state for the current epoch.
    threads: HashMap<ThreadId, ThreadState>,
    /// Callbacks deferred during the current epoch.
    current_deferred: Callbacks,
    /// Callbacks that became eligible once the current epoch completes.
    previous_deferred: Callbacks,
}

impl Collector {
    fn new() -> Self {
        Self {
            pending: Vec::new(),
            busy_count: 0,
            threads: HashMap::new(),
            current_deferred: Vec::new(),
            previous_deferred: Vec::new(),
        }
    }

    fn register(&mut self) {
        self.busy_count += 1;
        assert!(
            self.threads
                .insert(thread::current().id(), ThreadState::Busy)
                .is_none()
        );
    }

    fn unregister(&mut self) {
        let state = self.threads.remove(&thread::current().id()).unwrap();
        if state == ThreadState::Busy {
            self.busy_count -= 1;

            if self.busy_count == 0 {
                self.complete_epoch();
            }
        } else if self.threads.is_empty() {
            self.complete_epoch();
        }
    }

    fn collect_unregistered(&mut self) -> Callbacks {
        debug_assert!(!self.threads.contains_key(&thread::current().id()));

        let mut callbacks = mem::take(&mut self.pending);

        if self.threads.is_empty() {
            callbacks.extend(mem::take(&mut self.previous_deferred));
            callbacks.extend(mem::take(&mut self.current_deferred));
        }

        callbacks
    }

    fn quiet(&mut self) -> Callbacks {
        let state = self.threads.get_mut(&thread::current().id()).unwrap();

        let mut callbacks = mem::take(&mut self.pending);

        if *state != ThreadState::Busy {
            return callbacks;
        }

        self.busy_count -= 1;
        *state = ThreadState::Quiet;

        if self.busy_count == 0 {
            self.complete_epoch();
            callbacks.extend(mem::take(&mut self.pending));

            if !self.previous_deferred.is_empty() {
                // We immediately call `quiet` so we will be up to date with the new epoch
                DATA.with(|data| data.seen_events.set(EVENTS.load(Ordering::Relaxed)));

                // Mark ourselves as quiet again
                callbacks.extend(self.quiet());
            }
        }

        callbacks
    }

    fn defer(&mut self, callback: Box<dyn FnOnce() + Send>) {
        self.current_deferred.push(callback);
        EVENTS.fetch_add(1, Ordering::Release);
    }

    fn complete_epoch(&mut self) {
        self.pending.extend(mem::take(&mut self.previous_deferred));

        if self.threads.is_empty() {
            self.pending.extend(mem::take(&mut self.current_deferred));
            if !self.pending.is_empty() {
                // Signal future threads to check in
                EVENTS.fetch_add(1, Ordering::Release);
            }
            return;
        }

        self.busy_count = self.threads.len();
        self.threads.values_mut().for_each(|value| {
            *value = ThreadState::Busy;
        });
        self.previous_deferred = mem::take(&mut self.current_deferred);

        if !self.previous_deferred.is_empty() {
            // Signal all threads to check in
            EVENTS.fetch_add(1, Ordering::Release);
        }
    }
}
