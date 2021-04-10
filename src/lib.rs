#![feature(
    alloc_layout_extra,
    option_result_unwrap_unchecked,
    asm,
    test,
    core_intrinsics,
    dropck_eyepatch,
    min_specialization,
    extend_one,
    allocator_api,
    slice_ptr_get,
    nonnull_slice_from_raw_parts,
    maybe_uninit_array_assume_init
)]

extern crate alloc;

#[macro_use]
mod macros;

mod raw;
mod scopeguard;
mod util;

pub mod sync_insert_table;
