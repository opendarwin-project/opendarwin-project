#![no_std]
#![no_main]

// All kernel entry assembly, kmain, allocator, and panic handler are in the kernel lib crate.
use kernel as _;
