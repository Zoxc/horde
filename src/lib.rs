//! This crate contains [SyncInsertTable] and [SyncPushVec] which offers lock-free reads and uses
//! quiescent state based reclamation for which an API is available in the [collect] module.

#![feature(
    alloc_layout_extra,
    allocator_api,
    asm,
    core_intrinsics,
    dropck_eyepatch,
    llvm_asm,
    negative_impls,
    once_cell,
    option_result_unwrap_unchecked,
    thread_local
)]

#[macro_use]
mod macros;

pub mod collect;
mod raw;
mod scopeguard;
mod util;

pub mod sync_insert_table;
pub mod sync_push_vec;

pub use sync_insert_table::SyncInsertTable;
pub use sync_push_vec::SyncPushVec;
