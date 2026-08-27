//! This crate contains [SyncTable] and [SyncPushVec] which offer lock-free reads and use
//! quiescent state based reclamation for which an API is available in the [collect] module.

#![cfg_attr(
    feature = "nightly",
    feature(cfg_sanitize, dropck_eyepatch, extend_one, likely_unlikely)
)]
#![allow(clippy::len_without_is_empty, clippy::type_complexity)]

pub mod collect;
mod raw;
mod scopeguard;
mod util;

pub mod sync_push_vec;
pub mod sync_table;

pub use sync_push_vec::SyncPushVec;
pub use sync_table::SyncTable;
