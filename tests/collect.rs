use horde::collect;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::sync::Mutex;
use std::thread;

// Check that running `collect` with only a single thread active will collect garbage.
#[test]
fn free_single_thread() {
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
