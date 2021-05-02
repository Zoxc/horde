use horde::collect;
use std::sync::Arc;
use std::sync::Mutex;

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
