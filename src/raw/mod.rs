cfg_select! {
    // Use the SSE2 implementation if possible: it allows us to scan 16 buckets
    // at once instead of 8. We don't bother with AVX since it would require
    // runtime dispatch and wouldn't gain us much anyways: the probability of
    // finding a match drops off drastically after the first few buckets.
    //
    // I attempted an implementation on ARM using NEON instructions, but it
    // turns out that most NEON instructions have multi-cycle latency, which in
    // the end outweighs any gains over the generic implementation.
    all(
        target_feature = "sse2",
        any(target_arch = "x86", target_arch = "x86_64")
    ) => {
        pub mod sse2;
        pub use sse2 as imp;
    }
    _ => {
        #[path = "generic.rs"]
        pub mod generic;
        pub use generic as imp;
    }
}

pub mod bitmask;

/// Control byte value for an empty bucket.
pub(crate) const EMPTY: u8 = 0b1111_1111;

/// Control byte value for a deleted bucket.
pub(crate) const DELETED: u8 = 0b1000_0000;

const _: () = assert!(core::mem::align_of::<imp::Group>() == imp::Group::WIDTH);
