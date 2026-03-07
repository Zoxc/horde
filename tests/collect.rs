use horde::collect;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::sync::Barrier;
use std::sync::LazyLock;
use std::sync::Mutex;
use std::sync::MutexGuard;
use std::thread;

static TEST_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

fn test_lock() -> MutexGuard<'static, ()> {
    TEST_LOCK.lock().unwrap_or_else(|error| error.into_inner())
}

struct TestGuard {
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

fn enter_test() -> TestGuard {
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
    assert_eq!(*free.lock().unwrap(), true);

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
    assert_eq!(*free.lock().unwrap(), true);
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
