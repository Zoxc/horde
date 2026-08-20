#![cfg(test)]

use crate::collect;
use crate::sync_table::SyncTable;
use std::sync::Arc;
use std::sync::Barrier;
use std::sync::LazyLock;
use std::sync::Mutex;
use std::sync::MutexGuard;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::thread;

static TEST_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

fn test_lock() -> MutexGuard<'static, ()> {
    TEST_LOCK.lock().unwrap_or_else(|error| error.into_inner())
}

pub(crate) struct TestGuard {
    _lock: MutexGuard<'static, ()>,
}

impl Drop for TestGuard {
    fn drop(&mut self) {
        collect::release();
        for _ in 0..4 {
            collect::collect();
        }
    }
}

pub(crate) fn enter_test() -> TestGuard {
    let lock = test_lock();
    collect::release();
    for _ in 0..4 {
        collect::collect();
    }
    assert_collector_is_idle();
    TestGuard { _lock: lock }
}

/// Panics if a thread is still registered with the collector.
///
/// `release` and `collect` only act on the calling thread, so the cleanup above cannot remove a
/// thread another test left behind. Such a thread stays `Busy` forever, no epoch can complete,
/// and every test that reclaims memory afterwards silently fails. Check for that here so the
/// blame lands next to the test that leaked instead of spreading over the rest of the suite.
fn assert_collector_is_idle() {
    let collector = collect::COLLECTOR.lock();
    assert!(
        collector.threads.is_empty(),
        "a previous test left {} thread(s) registered with the collector, {} of them busy",
        collector.threads.len(),
        collector.busy_count,
    );
}

// Check that running `collect` with only a single thread active will collect garbage.
#[test]
fn free_single_thread() {
    let _test = enter_test();

    // Test unregistered free
    let free = Arc::new(Mutex::new(false));
    let free2 = free.clone();
    unsafe {
        collect::defer_unchecked(move || {
            *free2.lock().unwrap() = true;
        });
    }
    collect::collect();
    assert!(*free.lock().unwrap());

    // Test registered free
    collect::pin(|_| ());
    let free = Arc::new(Mutex::new(false));
    let free2 = free.clone();
    unsafe {
        collect::defer_unchecked(move || {
            *free2.lock().unwrap() = true;
        });
    }
    collect::collect();
    assert!(*free.lock().unwrap());
}

#[test]
fn collects_after_registered_thread_exits() {
    let _test = enter_test();

    let free = Arc::new(AtomicUsize::new(0));

    thread::spawn(|| {
        collect::pin(|_| ());
    })
    .join()
    .unwrap();

    let free2 = free.clone();
    unsafe {
        collect::defer_unchecked(move || {
            free2.fetch_add(1, Ordering::SeqCst);
        });
    }

    collect::collect();
    assert_eq!(free.load(Ordering::SeqCst), 1);
}

#[test]
fn collects_after_busy_thread_releases() {
    let _test = enter_test();

    let free = Arc::new(AtomicUsize::new(0));

    collect::pin(|_| ());

    let free2 = free.clone();
    unsafe {
        collect::defer_unchecked(move || {
            free2.fetch_add(1, Ordering::SeqCst);
        });
    }

    collect::release();
    collect::collect();
    assert_eq!(free.load(Ordering::SeqCst), 1);
}

#[test]
fn collects_after_last_quiet_thread_releases() {
    let _test = enter_test();

    let ready = Arc::new(Barrier::new(3));
    let quiet_done = Arc::new(Barrier::new(3));
    let release_busy = Arc::new(Barrier::new(2));
    let release_quiet = Arc::new(Barrier::new(2));

    let quiet = {
        let ready = ready.clone();
        let quiet_done = quiet_done.clone();
        let release_quiet = release_quiet.clone();

        thread::spawn(move || {
            collect::pin(|_| ());
            ready.wait();
            collect::collect();
            quiet_done.wait();
            release_quiet.wait();
            collect::release();
        })
    };

    let busy = {
        let ready = ready.clone();
        let quiet_done = quiet_done.clone();
        let release_busy = release_busy.clone();

        thread::spawn(move || {
            collect::pin(|_| ());
            ready.wait();
            quiet_done.wait();
            release_busy.wait();
            collect::release();
        })
    };

    ready.wait();
    quiet_done.wait();

    let free = Arc::new(AtomicUsize::new(0));
    let free2 = free.clone();
    unsafe {
        collect::defer_unchecked(move || {
            free2.fetch_add(1, Ordering::SeqCst);
        });
    }

    collect::collect();
    assert_eq!(free.load(Ordering::SeqCst), 0);

    release_busy.wait();
    busy.join().unwrap();

    collect::collect();
    assert_eq!(free.load(Ordering::SeqCst), 0);

    release_quiet.wait();
    quiet.join().unwrap();

    collect::collect();

    assert_eq!(free.load(Ordering::SeqCst), 1);
}

#[test]
#[cfg(debug_assertions)]
#[should_panic(expected = "Cannot call `collect` while pinned")]
fn collect_panics_while_pinned_without_events() {
    let _test = enter_test();

    collect::pin(|_| collect::collect());
}

#[test]
#[cfg(debug_assertions)]
#[should_panic(expected = "Cannot call `collect` while pinned")]
fn nested_pin_restores_outer_pinned_state() {
    let _test = enter_test();

    collect::pin(|_| {
        collect::pin(|_| ());
        collect::collect();
    });
}

#[test]
fn invalid_collect_does_not_consume_pending_event() {
    let _test = enter_test();

    let calls = Arc::new(AtomicUsize::new(0));
    let calls2 = calls.clone();

    unsafe {
        collect::defer_unchecked(move || {
            calls2.fetch_add(1, Ordering::SeqCst);
        });
    }

    let result = std::panic::catch_unwind(|| {
        collect::pin(|_| collect::collect());
    });
    assert!(result.is_err());
    assert_eq!(calls.load(Ordering::SeqCst), 0);

    collect::collect();
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[test]
#[should_panic(expected = "Deferred callbacks cannot call `pin`")]
fn callback_cannot_pin() {
    let _test = enter_test();

    unsafe {
        collect::defer_unchecked(|| {
            collect::pin(|_| ());
        });
    }

    collect::collect();
}

#[test]
fn callback_panic_does_not_drop_remaining_callbacks() {
    let _test = enter_test();

    let calls = Arc::new(AtomicUsize::new(0));

    unsafe {
        collect::defer_unchecked(|| panic!("boom"));
    }

    let calls2 = calls.clone();
    unsafe {
        collect::defer_unchecked(move || {
            calls2.fetch_add(1, Ordering::SeqCst);
        });
    }

    let result = std::panic::catch_unwind(collect::collect);
    assert!(result.is_err());
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[test]
#[cfg(debug_assertions)]
#[should_panic(expected = "Deferred callbacks cannot call `collect`")]
fn callback_cannot_collect() {
    let _test = enter_test();

    unsafe {
        collect::defer_unchecked(|| {
            collect::collect();
        });
    }

    collect::collect();
}

#[test]
fn concurrent_collect_stress() {
    let _test = enter_test();

    const THREADS: usize = 6;
    const ITERS: usize = 200;

    let barrier = Arc::new(Barrier::new(THREADS));
    let executed = Arc::new(AtomicUsize::new(0));

    let mut handles = Vec::new();
    for _ in 0..THREADS {
        let barrier = barrier.clone();
        let executed = executed.clone();
        handles.push(thread::spawn(move || {
            barrier.wait();

            for _ in 0..ITERS {
                collect::pin(|_| ());

                let executed = executed.clone();
                unsafe {
                    collect::defer_unchecked(move || {
                        executed.fetch_add(1, Ordering::SeqCst);
                    });
                }

                collect::collect();
                collect::release();
                collect::collect();
            }

            collect::collect();
        }));
    }

    for handle in handles {
        handle.join().unwrap();
    }

    for _ in 0..THREADS {
        collect::collect();
    }

    assert_eq!(executed.load(Ordering::SeqCst), THREADS * ITERS);
}

#[test]
fn collect_after_epoch_completion_without_new_defers_runs_pending_callbacks() {
    let _test = enter_test();

    let ready = Arc::new(Barrier::new(2));
    let release_thread = Arc::new(Barrier::new(2));

    let handle = {
        let ready = ready.clone();
        let release_thread = release_thread.clone();
        thread::spawn(move || {
            collect::pin(|_| ());
            ready.wait();
            release_thread.wait();
            collect::release();
        })
    };

    collect::pin(|_| ());
    ready.wait();
    collect::collect();

    let calls = Arc::new(AtomicUsize::new(0));
    let calls2 = calls.clone();
    unsafe {
        collect::defer_unchecked(move || {
            calls2.fetch_add(1, Ordering::SeqCst);
        });
    }

    collect::collect();
    assert_eq!(calls.load(Ordering::SeqCst), 0);

    release_thread.wait();
    handle.join().unwrap();

    collect::collect();
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[test]
fn cancel_by_id_prevents_matching_callbacks() {
    let _test = enter_test();

    // `defer_by_id` takes a raw pointer which has to stay valid until the collector stores
    // through it or the registration is cancelled. A stack local only satisfies that on the
    // happy path: an assertion failure below pops the frame with the registration outstanding,
    // and the store then lands on dead storage. `static`s are valid for the whole program.
    static FIRST: AtomicBool = AtomicBool::new(false);
    static SECOND: AtomicBool = AtomicBool::new(false);

    // SAFETY: both flags outlive the collector, and each is registered once.
    unsafe {
        collect::defer_by_id(&FIRST);
        collect::defer_by_id(&SECOND);
    }

    collect::cancel_by_ids([&FIRST as *const AtomicBool]);
    collect::collect();

    assert!(!FIRST.load(Ordering::SeqCst));
    assert!(SECOND.load(Ordering::SeqCst));
}

#[test]
fn cancel_by_id_removes_pending_callbacks() {
    let _test = enter_test();

    let ready = Arc::new(Barrier::new(2));
    let release_thread = Arc::new(Barrier::new(2));

    let handle = {
        let ready = ready.clone();
        let release_thread = release_thread.clone();
        thread::spawn(move || {
            collect::pin(|_| ());
            ready.wait();
            release_thread.wait();
            collect::release();
        })
    };

    collect::pin(|_| ());
    ready.wait();
    collect::collect();

    // A `static` rather than a local: the registration below outlives this frame whenever an
    // assertion fails or the helper's `join` panics, and the collector stores through it later.
    static READY_FLAG: AtomicBool = AtomicBool::new(false);

    // SAFETY: the flag outlives the collector, and it is registered once.
    unsafe {
        collect::defer_by_id(&READY_FLAG);
    }

    collect::collect();
    assert!(!READY_FLAG.load(Ordering::SeqCst));

    release_thread.wait();
    handle.join().unwrap();

    collect::cancel_by_ids([&READY_FLAG as *const AtomicBool]);
    collect::collect();
    assert!(!READY_FLAG.load(Ordering::SeqCst));
}

/// A thread that registers while its `seen_events` already matches `EVENTS` must still be able
/// to report a quiescent state, otherwise `busy_count` never reaches 0 again.
#[test]
fn register_does_not_stall_reclamation() {
    let _test = enter_test();

    let free = Arc::new(AtomicUsize::new(0));

    // The main thread becomes a registered, busy participant.
    collect::pin(|_| ());

    // Register a callback, bumping `EVENTS`.
    let free2 = free.clone();
    unsafe {
        collect::defer_unchecked(move || {
            free2.fetch_add(1, Ordering::SeqCst);
        });
    }

    let deferred = Arc::new(Barrier::new(2));
    let registered = Arc::new(Barrier::new(2));
    let main_quiet = Arc::new(Barrier::new(2));
    let worker_quiet = Arc::new(Barrier::new(2));
    let checked = Arc::new(Barrier::new(2));

    let worker = {
        let deferred = deferred.clone();
        let registered = registered.clone();
        let main_quiet = main_quiet.clone();
        let worker_quiet = worker_quiet.clone();
        let checked = checked.clone();

        thread::spawn(move || {
            deferred.wait();

            // Sync `seen_events` with `EVENTS` while still unregistered.
            collect::collect();

            // Register with `seen_events == EVENTS`.
            collect::pin(|_| ());
            registered.wait();

            main_quiet.wait();
            collect::collect();
            worker_quiet.wait();

            // Stay registered until the main thread has checked the result, so the release
            // below cannot be what completes the epoch.
            checked.wait();
            collect::release();
        })
    };

    deferred.wait();
    registered.wait();

    collect::collect();
    main_quiet.wait();

    worker_quiet.wait();
    collect::collect();

    assert_eq!(free.load(Ordering::SeqCst), 1);

    checked.wait();
    worker.join().unwrap();
}

/// A thread that registers while the collector is empty is not nudged, so it must still be
/// woken by the `EVENTS` bump of a later `defer` from another thread.
#[test]
fn register_into_empty_collector_still_collects_later() {
    let _test = enter_test();

    let free = Arc::new(AtomicUsize::new(0));

    // The main thread becomes a registered, busy participant while nothing is deferred.
    collect::pin(|_| ());

    let registered = Arc::new(Barrier::new(2));
    let deferred = Arc::new(Barrier::new(2));
    let main_quiet = Arc::new(Barrier::new(2));
    let worker_quiet = Arc::new(Barrier::new(2));
    let checked = Arc::new(Barrier::new(2));

    let worker = {
        let free = free.clone();
        let registered = registered.clone();
        let deferred = deferred.clone();
        let main_quiet = main_quiet.clone();
        let worker_quiet = worker_quiet.clone();
        let checked = checked.clone();

        thread::spawn(move || {
            // Sync `seen_events` with `EVENTS` while still unregistered.
            collect::collect();

            // Register with `seen_events == EVENTS` and an empty collector.
            collect::pin(|_| ());
            registered.wait();

            // The callback is deferred after this thread registered.
            deferred.wait();

            // Report a quiescent state only after the main thread did, so this thread is the
            // one completing the epoch.
            main_quiet.wait();
            collect::collect();
            worker_quiet.wait();

            // Stay registered until the main thread has checked the result, so the release
            // below cannot be what completes the epoch.
            checked.wait();
            drop(free);
            collect::release();
        })
    };

    registered.wait();

    let free2 = free.clone();
    unsafe {
        collect::defer_unchecked(move || {
            free2.fetch_add(1, Ordering::SeqCst);
        });
    }
    deferred.wait();

    collect::collect();
    main_quiet.wait();

    worker_quiet.wait();
    collect::collect();

    assert_eq!(free.load(Ordering::SeqCst), 1);

    checked.wait();
    worker.join().unwrap();
}

#[test]
fn defer_runs_a_static_callback() {
    let _test = enter_test();

    let calls = Arc::new(AtomicUsize::new(0));

    let calls2 = calls.clone();
    collect::defer(move || {
        calls2.fetch_add(1, Ordering::SeqCst);
    });

    assert_eq!(calls.load(Ordering::SeqCst), 0);

    collect::collect();

    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[test]
#[should_panic(expected = "Cannot call `release` while pinned")]
fn release_cannot_be_called_while_pinned() {
    let _test = enter_test();

    collect::pin(|_| collect::release());
}

#[test]
#[should_panic(expected = "Deferred callbacks cannot call `release`")]
fn callback_cannot_release() {
    let _test = enter_test();

    // SAFETY: the callback borrows nothing.
    unsafe {
        collect::defer_unchecked(collect::release);
    }

    collect::collect();
}

#[test]
fn the_first_panic_payload_is_the_one_re_raised() {
    let _test = enter_test();

    let calls = Arc::new(AtomicUsize::new(0));

    // SAFETY: neither callback borrows anything.
    unsafe {
        collect::defer_unchecked(|| panic!("first"));
        collect::defer_unchecked(|| panic!("second"));
    }

    let calls2 = calls.clone();
    // SAFETY: the callback owns its capture.
    unsafe {
        collect::defer_unchecked(move || {
            calls2.fetch_add(1, Ordering::SeqCst);
        });
    }

    let payload = std::panic::catch_unwind(collect::collect).expect_err("did not panic");

    assert_eq!(payload.downcast_ref::<&str>().copied(), Some("first"));
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[test]
fn pin_after_the_exit_guard_is_rejected() {
    let _test = enter_test();

    static OUTCOME: Mutex<Option<String>> = Mutex::new(None);

    struct PinOnExit;

    impl Drop for PinOnExit {
        fn drop(&mut self) {
            // Nothing may escape a thread local destructor: an unwind out of one aborts the
            // process, so the outcome is reported back rather than asserted on here.
            let outcome = match std::panic::catch_unwind(|| collect::pin(|_| ())) {
                Ok(()) => "`pin` did not panic".to_owned(),
                Err(payload) => payload.downcast_ref::<&str>().map_or_else(
                    || "a payload which is not a `&str`".to_owned(),
                    |message| (*message).to_owned(),
                ),
            };

            *OUTCOME.lock().unwrap_or_else(|error| error.into_inner()) = Some(outcome);
        }
    }

    thread_local! {
        static PIN_ON_EXIT: PinOnExit = const { PinOnExit };
    }

    thread::spawn(|| {
        // Registered before the collector's exit guard, so this destructor runs after it.
        PIN_ON_EXIT.with(|_| ());

        collect::pin(|_| ());
        collect::release();
    })
    .join()
    .unwrap();

    assert_eq!(
        OUTCOME
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .as_deref(),
        Some("Cannot call `pin` in thread local destructors after the thread exit guard")
    );
}

/// Callbacks run with the collector lock released, which is what makes them free to call
/// `defer`, `defer_by_id` and `cancel_by_ids` again. `SyncTable`'s drop glue relies on that:
/// it calls `cancel_by_ids` to unregister its retired tables, and the collector's mutex is not
/// reentrant, so running callbacks under the lock would deadlock a container dropped from one.
#[test]
fn a_callback_may_call_back_into_the_collector() {
    let _test = enter_test();

    let table: SyncTable<u64, u64> = SyncTable::new();
    for i in 0..64 {
        assert!(table.lock().write().insert(i, i, None));
    }

    let reentrant = Arc::new(AtomicUsize::new(0));
    let reentrant2 = reentrant.clone();

    collect::defer(move || {
        // Grow the table from inside the callback, so it retires tables which are registered
        // with the collector after this batch of callbacks was taken from it. Their ids are
        // therefore still live, and the drop below really does reach the collector lock rather
        // than bailing out of `cancel_by_ids` on an empty set.
        for i in 64..1024 {
            assert!(table.lock().write().insert(i, i, None));
        }

        // `drop` -> `drop_impl` -> `cancel_by_ids`.
        drop(table);

        // Deferring more work takes the same lock.
        let reentrant3 = reentrant2.clone();
        collect::defer(move || {
            reentrant3.fetch_add(1, Ordering::SeqCst);
        });
    });

    collect::collect();
    assert_eq!(reentrant.load(Ordering::SeqCst), 0);

    collect::collect();
    assert_eq!(reentrant.load(Ordering::SeqCst), 1);
}

/// `defer` from inside a callback takes the collector lock again, and the callback it registers
/// must run in a later cycle rather than in the batch that is already running.
#[test]
fn a_callback_may_defer() {
    let _test = enter_test();

    let ran = Arc::new(AtomicUsize::new(0));
    let ran2 = ran.clone();

    collect::defer(move || {
        collect::defer(move || {
            ran2.fetch_add(1, Ordering::SeqCst);
        });
    });

    // The inner callback is deferred while this collection is running, so it is only eligible
    // for the next one.
    collect::collect();
    assert_eq!(ran.load(Ordering::SeqCst), 0);

    collect::collect();
    assert_eq!(ran.load(Ordering::SeqCst), 1);
}

/// `defer_by_id` from inside a callback takes the collector lock again, and the id it registers
/// is marked ready by a later collection.
#[test]
fn a_callback_may_defer_by_id() {
    let _test = enter_test();

    // The flag is heap allocated and kept alive by `ready` for the whole test, so the pointer
    // registered inside the callback stays valid until it is stored to below.
    let ready = Arc::new(AtomicBool::new(false));
    let ready2 = ready.clone();

    collect::defer(move || {
        // SAFETY: `ready` keeps the flag alive past the store, and it is registered once.
        unsafe {
            collect::defer_by_id(&*ready2 as *const AtomicBool);
        }
    });

    collect::collect();
    assert!(!ready.load(Ordering::SeqCst));

    collect::collect();
    assert!(ready.load(Ordering::SeqCst));
}

/// `cancel_by_ids` from inside a callback takes the collector lock again and cancels ids that
/// are still registered. This is what `SyncTable`'s drop glue does for its retired tables.
///
/// The ids are registered from inside the callback on purpose: ids that were part of the batch
/// being collected have already been marked ready under the lock before any callback runs, so
/// they can no longer be cancelled at all.
#[test]
fn a_callback_may_cancel_by_ids() {
    let _test = enter_test();

    let cancelled = Arc::new(AtomicBool::new(false));
    let kept = Arc::new(AtomicBool::new(false));
    let cancelled2 = cancelled.clone();
    let kept2 = kept.clone();

    collect::defer(move || {
        // SAFETY: both flags outlive the callback and the collection that stores to `kept`,
        // and each is registered once.
        unsafe {
            collect::defer_by_id(&*cancelled2 as *const AtomicBool);
            collect::defer_by_id(&*kept2 as *const AtomicBool);
        }

        collect::cancel_by_ids([&*cancelled2 as *const AtomicBool]);
    });

    collect::collect();
    collect::collect();

    assert!(!cancelled.load(Ordering::SeqCst));
    assert!(kept.load(Ordering::SeqCst));
}

/// A thread is released when it exits, and a release runs no callbacks. Garbage deferred before
/// the last participating thread exited therefore waits for a `collect` call from someone else,
/// even though no thread is left to delay it.
#[test]
fn garbage_from_an_exited_thread_waits_for_a_collect_call() {
    let _test = enter_test();

    let freed = Arc::new(AtomicUsize::new(0));
    let freed2 = freed.clone();

    thread::spawn(move || {
        collect::pin(|_| ());

        collect::defer(move || {
            freed2.fetch_add(1, Ordering::SeqCst);
        });
    })
    .join()
    .unwrap();

    // The collector has no registered threads left, but nothing ran the callback.
    assert_eq!(freed.load(Ordering::SeqCst), 0);

    collect::collect();
    assert_eq!(freed.load(Ordering::SeqCst), 1);
}
