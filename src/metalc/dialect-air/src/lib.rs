//! AIR-facing helpers shared by lowering (version triples, address spaces).

use air_bitcode::{AirModule, AirTarget};

/// Default AIR / language versions for the resolved target (env / host / golden).
pub fn default_air_module() -> AirModule {
    AirModule::for_target(AirTarget::resolve())
}

pub const ADDRSPACE_DEVICE: u32 = 1;
pub const ADDRSPACE_CONSTANT: u32 = 2;
pub const ADDRSPACE_THREADGROUP: u32 = 3;
