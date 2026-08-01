//! AIR-facing helpers shared by lowering (version triples, address spaces).

use air_bitcode::AirModule;

/// Default AIR / language versions matching current Xcode Metal 4.1 goldens.
pub fn default_air_module() -> AirModule {
    let mut m = AirModule::new(
        "air64_v29-apple-macosx27.0.0",
        "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32",
    );
    m.air_version = (2, 9, 0);
    m.language_version = ("Metal".into(), 4, 1, 0);
    m
}

pub const ADDRSPACE_DEVICE: u32 = 1;
pub const ADDRSPACE_CONSTANT: u32 = 2;
pub const ADDRSPACE_THREADGROUP: u32 = 3;
