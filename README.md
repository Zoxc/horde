horde
=====

[![Crate](https://img.shields.io/crates/v/horde)](https://crates.io/crates/horde)
[![Documentation](https://docs.rs/horde/badge.svg)](https://docs.rs/horde)
[![License](https://img.shields.io/badge/license-MIT%2FApache--2.0-blue.svg)](https://github.com/Zoxc/horde)
[![Build Status](https://img.shields.io/github/workflow/status/Zoxc/horde/build?label=build)](https://github.com/Zoxc/horde/actions/workflows/build.yaml)
[![Git Documentation](https://img.shields.io/github/workflow/status/Zoxc/horde/docs?label=git%20docs)](https://zoxc.github.io/horde/horde/)

A crate that contains `SyncTable` and `SyncPushVec`, both which offers lock-free reads. `SyncPushVec` has limited deletion options. They use quiescent state based reclamation for which an API is also available. `SyncTable` is based on the [hashbrown](https://crates.io/crates/hashbrown) crate and has similar lookup performance.

## License

Licensed under either of

 * Apache License, Version 2.0
   ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
 * MIT license
   ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

## Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be
dual licensed as above, without any additional terms or conditions.