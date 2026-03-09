#![cfg(test)]

use crate::collect;
use std::sync::Arc;
use std::sync::Barrier;
use std::sync::LazyLock;
use std::sync::Mutex;
use std::sync::MutexGuard;
use std::sync::atomic::{AtomicUsize, Ordering};
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
    TestGuard { _lock: lock }
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
#[should_panic(expected = "Cannot call `collect` while pinned")]
fn collect_panics_while_pinned_without_events() {
    let _test = enter_test();

    collect::pin(|_| collect::collect());
}

#[test]
fn nested_pin_restores_outer_pinned_state() {
    let _test = enter_test();

    let result = std::panic::catch_unwind(|| {
        collect::pin(|_| {
            collect::pin(|_| ());
            collect::collect();
        });
    });

    assert!(result.is_err());
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
