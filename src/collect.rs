//! An API for quiescent state based reclamation.
//!
//! Threads that read shared lock-free data call [pin] to mark the duration of the critical
//! section. Destruction of removed data is postponed with [defer_unchecked] and later driven by
//! [collect], which advances the global quiescent-state cycle.
//!
//! Threads which call [pin] will participate in global memory reclamation and should
//! regularly call [collect] to allow memory reclamation to progress.
//! When threads are unable to do so, for example due to sleeping, they should call [release] so
//! they no longer delay reclamation.
//!
//! Participating threads are also released when they exit, by a thread local destructor.
//! Threads which exit skipping those destructors must call [release] first, otherwise
//! reclamation for the whole process will stall. Releasing do not run any callbacks
//! so it could be useful to call [collect] after joining that last thread that use the collector,
//! or have a [release] and [collect] pair prior to its exit, to ensure all callbacks run.

use crate::{
    scopeguard::guard,
    util::{cold_path, unlikely},
};
use parking_lot::Mutex;
use std::{
    cell::Cell,
    collections::HashMap,
    collections::HashSet,
    marker::PhantomData,
    mem,
    panic::{self, AssertUnwindSafe},
    process,
    sync::LazyLock,
    sync::atomic::{AtomicBool, AtomicUsize, Ordering},
    thread::{self, ThreadId},
};

mod code;
mod tests;
#[cfg(test)]
pub(crate) use tests::enter_test;

/// Monotonic event counter used to notify threads that reclamation state changed.
static EVENTS: AtomicUsize = AtomicUsize::new(0);

/// Represents a proof that no callback deferred at or after the start of `'a` will run during
/// `'a`.
#[derive(Clone, Copy)]
pub struct Pin<'a> {
    // `Pin` is `Send` and `Sync` as having a single thread pinning is sufficient.
    _private: PhantomData<&'a ()>,
}

/// Schedules a closure to run after all threads leave their current pinned regions.
///
/// The closure will be called by the [collect] method.
///
/// This deferred callback must not call [pin] or [collect].
/// It may call [defer] which is useful for inner destructors.
///
/// Deferred callbacks run in a later collection cycle on whichever thread performs that collection.
/// They are typically used to destroy or free data that was removed from a lock-free structure.
pub fn defer(f: impl FnOnce() + Send + 'static) {
    let f = Box::new(f);
    COLLECTOR.lock().defer(f);
}

/// Schedules `ready` to be set to `true` after all threads leave their current pinned regions.
///
/// [cancel_by_ids] can be used to prevent writes for matching pointers.
///
/// # Safety
///
/// The caller must ensure `ready` remains valid until it is set to `true` by the collector or the
/// store is cancelled using [cancel_by_ids].
///
/// A pointer must not be scheduled again until a previous registration of it has been observed
/// to be written as `true` by the collector or cancelled.
pub(crate) unsafe fn defer_by_id(ready: *const AtomicBool) {
    COLLECTOR.lock().defer_by_id(ready);
}

/// Prevents execution of any deferred stores registered by [defer_by_id] with matching pointers.
pub(crate) fn cancel_by_ids(ids: impl IntoIterator<Item = *const AtomicBool>) {
    let ids: HashSet<_> = ids.into_iter().collect();
    if ids.is_empty() {
        return;
    }

    COLLECTOR.lock().cancel_by_ids(&ids);
}

/// Schedules a closure to run after all threads leave their current pinned regions.
///
/// The closure will be called by the [collect] method.
///
/// This deferred callback must not call [pin] or [collect].
/// It may call [defer] which is useful for inner destructors.
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
            thread_id: Cell::new(None),
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
    /// The thread's id, lazily initialized by [Data::thread_id].
    thread_id: Cell<Option<ThreadId>>,
}

impl Data {
    /// Returns the id used to key the thread in [Collector::threads].
    #[inline]
    fn thread_id(&self) -> ThreadId {
        match self.thread_id.get() {
            Some(thread_id) => thread_id,
            None => cold_path(|| {
                DATA.with(|data| {
                    let thread_id = thread::current().id();
                    data.thread_id.set(Some(thread_id));
                    thread_id
                })
            }),
        }
    }
}

/// Returns `true` once the loader has started shutting the process down on Windows
#[cfg(windows)]
fn process_is_exiting() -> bool {
    #[link(name = "ntdll")]
    unsafe extern "system" {
        /// Returns a non-zero value while the loader is shutting the process down.
        /// This does not include unloading DLLs.
        /// See <https://learn.microsoft.com/en-us/windows/win32/devnotes/rtldllshutdowninprogress>.
        fn RtlDllShutdownInProgress() -> u8;
    }
    unsafe { RtlDllShutdownInProgress() != 0 }
}

#[cfg(not(windows))]
fn process_is_exiting() -> bool {
    false
}

/// Releases the current thread from the collector when the thread exits.
struct ExitGuard;

impl Drop for ExitGuard {
    fn drop(&mut self) {
        // On Windows this destructor also runs during process exit with all other threads killed.
        // We could deadlock if we tried to get the `COLLECTOR` lock,
        // so instead we just skip calling `release.
        if process_is_exiting() {
            return;
        }

        release();
    }
}

cfg_select! {
    all(any(target_arch = "x86", target_arch = "x86_64"), not(miri)) => {
        #[inline]
        #[allow(clippy::pointers_in_nomem_asm_block)]
        fn hide(data: &Data) -> &Data {
            let mut data = data as *const Data;
            use std::arch::asm;
            // Hide the `data` value from LLVM to prevent it from generating multiple TLS accesses
            unsafe {
                asm!("/* {} */", inout(reg) data, options(pure, nomem, nostack, preserves_flags));

                &*data
            }
        }
    }
    _ => {
        #[inline]
        fn hide(data: &Data) -> &Data {
            data
        }
    }
}

/// Call a closure with a reference to the current thread's collector state.
///
/// This hides the TLS access behind `hide` internally.
#[inline(always)]
fn data<R>(f: impl FnOnce(&Data) -> R) -> R {
    DATA.with(|data| f(hide(data)))
}

/// Marks the current thread as pinned and returns a proof of that to the closure.
///
/// This adds the current thread to the set of threads that needs to regularly call [collect]
/// before memory can be freed. [release] can be called if a thread no longer needs
/// access to lock-free data structures for an extended period of time.
///
/// Nested calls to [pin] are allowed.
///
/// This will panic if called from a deferred callback. It will also panic if called in
/// thread local destructors registered before the first [pin] call, which will in turn abort the process.
#[inline]
pub fn pin<R>(f: impl FnOnce(Pin<'_>) -> R) -> R {
    data(|data| {
        let state = data.state.get();
        let old_state = if unlikely(!matches!(state, State::Registered | State::Pinned)) {
            pin_cold();
            // `data.state` will always be `Registered` after `pin_cold`.
            // This avoids a load from `data.state`.
            State::Registered
        } else {
            state
        };
        data.state.set(State::Pinned);
        let _guard = guard(old_state, |state| data.state.set(*state));
        f(Pin {
            _private: PhantomData,
        })
    })
}

#[inline(never)]
#[cold]
fn pin_cold() {
    data(|data| match data.state.get() {
        State::Unregistered => {
            if EXIT_GUARD.try_with(|_| ()).is_err() {
                cold_path(|| {
                    panic!(
                        "Cannot call `pin` in thread local destructors after the thread exit guard"
                    )
                })
            }

            if COLLECTOR.lock().register(data.thread_id()) {
                // The collector has pending callbacks.
                // Set `seen_events` to ensure the next `collect` call triggers.
                data.seen_events
                    .set(EVENTS.load(Ordering::Relaxed).wrapping_sub(1));
            }

            data.state.set(State::Registered);
        }
        State::Registered | State::Pinned => unreachable!(),
        State::Collecting => cold_path(|| panic!("Deferred callbacks cannot call `pin`")),
    })
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
    data(|data| match data.state.get() {
        State::Unregistered => (),
        State::Registered => {
            data.state.set(State::Unregistered);
            COLLECTOR.lock().unregister(data.thread_id());
        }
        State::Pinned => cold_path(|| panic!("Cannot call `release` while pinned")),
        State::Collecting => cold_path(|| panic!("Deferred callbacks cannot call `release`")),
    })
}

/// Signals a quiescent state where garbage may be collected.
///
/// This may collect garbage using the callbacks registered with [defer] and [defer_unchecked].
///
/// This may panic if called while the current thread is pinned or during a deferred callback.
pub fn collect() {
    data(|data| {
        if cfg!(debug_assertions) {
            // We check this only with `debug_assertions` to improve performance.
            // A proper check is done in `collect_cold` if there's new events.
            assert_collect_state(data);
        }

        // `EVENTS` can wrap around causing us to miss an event.
        // That is unlikely and will just delay reclamation until another event is triggered.
        let new = EVENTS.load(Ordering::Acquire);
        if unlikely(new != data.seen_events.get()) {
            collect_cold();
        }
    })
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
    data(|data| {
        assert_collect_state(data);

        // Update seen events after `assert_collect_state` in case it panics.
        // This allows future `collect` to continue if we resume execution after the panic.
        data.seen_events.set(EVENTS.load(Ordering::Relaxed));

        let old_state = data.state.get();
        let _guard = guard(old_state, |state| data.state.set(*state));
        data.state.set(State::Collecting);

        let callbacks = {
            let mut collector = COLLECTOR.lock();

            // Check if we could block any deferred methods
            let mut callbacks = if let State::Registered = old_state {
                collector.quiet(data.thread_id())
            } else {
                collector.collect_unregistered()
            };

            // Mark bools as ready inside the collector lock to prevent races with `cancel_by_ids`
            callbacks.mark_ready();

            callbacks
        };

        let mut panic = None;

        for callback in callbacks.deferred {
            if let Err(payload) = panic::catch_unwind(AssertUnwindSafe(|| {
                callback();
            })) {
                if panic.is_none() {
                    panic = Some(payload);
                } else {
                    let abort = guard((), |_| {
                        eprintln!("fatal: a panic payload's destructor panicked inside `collect`");
                        process::abort()
                    });
                    drop(payload);
                    mem::forget(abort);
                }
            }
        }

        if let Some(payload) = panic {
            panic::resume_unwind(payload)
        }
    })
}

static COLLECTOR: LazyLock<Mutex<Collector>> = LazyLock::new(|| Mutex::new(Collector::new()));

#[derive(Default)]
struct Callbacks {
    deferred: Vec<Box<dyn FnOnce() + Send>>,
    defer_by_id: Vec<*const AtomicBool>,
}

// SAFETY: The `*const AtomicBool` pointers are only ever stored to, and it is the
// `defer_by_id` caller's obligation to keep them valid until then, on any thread.
unsafe impl Send for Callbacks {}

impl Callbacks {
    fn push(&mut self, callback: Box<dyn FnOnce() + Send>) {
        self.deferred.push(callback);
    }

    fn push_id(&mut self, ready: *const AtomicBool) {
        debug_assert!(!self.defer_by_id.contains(&ready));
        self.defer_by_id.push(ready);
    }

    fn extend(&mut self, other: Self) {
        self.deferred.extend(other.deferred);
        self.defer_by_id.extend(other.defer_by_id);
    }

    fn mark_ready(&mut self) {
        for ready in self.defer_by_id.drain(..) {
            // SAFETY: It's up to the caller of `defer_by_id` to ensure this
            // pointer stays valid.
            unsafe {
                (*ready).store(true, Ordering::Release);
            }
        }
    }

    fn is_empty(&self) -> bool {
        self.deferred.is_empty() && self.defer_by_id.is_empty()
    }

    fn cancel_by_ids(&mut self, ids: &HashSet<*const AtomicBool>) {
        self.defer_by_id.retain(|ready| !ids.contains(ready));
    }
}

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
            pending: Callbacks::default(),
            busy_count: 0,
            threads: HashMap::new(),
            current_deferred: Callbacks::default(),
            previous_deferred: Callbacks::default(),
        }
    }

    /// Registers the current thread as a busy participant in the current epoch.
    ///
    /// Returns `true` if the collector holds callbacks.
    #[must_use]
    fn register(&mut self, thread_id: ThreadId) -> bool {
        self.busy_count += 1;
        assert!(self.threads.insert(thread_id, ThreadState::Busy).is_none());

        !(self.pending.is_empty()
            && self.previous_deferred.is_empty()
            && self.current_deferred.is_empty())
    }

    fn unregister(&mut self, thread_id: ThreadId) {
        let state = self.threads.remove(&thread_id).unwrap();
        if state == ThreadState::Busy {
            self.busy_count -= 1;

            if self.busy_count == 0 {
                self.complete_epoch(true);
            }
        } else if self.threads.is_empty() {
            self.complete_epoch(true);
        }
    }

    fn collect_unregistered(&mut self) -> Callbacks {
        debug_assert!(!self.threads.contains_key(&data(|data| data.thread_id())));

        let mut callbacks = mem::take(&mut self.pending);

        if self.threads.is_empty() {
            callbacks.extend(mem::take(&mut self.previous_deferred));
            callbacks.extend(mem::take(&mut self.current_deferred));
        }

        callbacks
    }

    fn quiet(&mut self, thread_id: ThreadId) -> Callbacks {
        let state = self.threads.get_mut(&thread_id).unwrap();

        let mut callbacks = mem::take(&mut self.pending);

        if *state != ThreadState::Busy {
            return callbacks;
        }

        self.busy_count -= 1;
        *state = ThreadState::Quiet;

        if self.busy_count == 0 {
            // We pass `false` as we'll immediately take pending callbacks, so we don't need to signal them.
            self.complete_epoch(false);
            callbacks.extend(mem::take(&mut self.pending));

            if !self.previous_deferred.is_empty() {
                // We immediately call `quiet` so we will be up to date with the new epoch
                DATA.with(|data| data.seen_events.set(EVENTS.load(Ordering::Relaxed)));

                // Mark ourselves as quiet again
                callbacks.extend(self.quiet(thread_id));
            }
        }

        callbacks
    }

    fn defer(&mut self, callback: Box<dyn FnOnce() + Send>) {
        self.current_deferred.push(callback);
        EVENTS.fetch_add(1, Ordering::Release);
    }

    fn defer_by_id(&mut self, ready: *const AtomicBool) {
        debug_assert!(!self.pending.defer_by_id.contains(&ready));
        debug_assert!(!self.previous_deferred.defer_by_id.contains(&ready));

        self.current_deferred.push_id(ready);
        EVENTS.fetch_add(1, Ordering::Release);
    }

    fn cancel_by_ids(&mut self, ids: &HashSet<*const AtomicBool>) {
        self.pending.cancel_by_ids(ids);
        self.current_deferred.cancel_by_ids(ids);
        self.previous_deferred.cancel_by_ids(ids);
    }

    fn complete_epoch(&mut self, signal_pending: bool) {
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

        if (signal_pending && !self.pending.is_empty()) || !self.previous_deferred.is_empty() {
            // Signal all threads to check in
            EVENTS.fetch_add(1, Ordering::Release);
        }
    }
}
