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
