//! Pack an [`AirModule`] into a `.metallib` (pure-Rust bitcode + MTLB).

use std::path::Path;

use metallib::{EntryType, MetallibEntry, MetallibOptions, write_metallib};
use thiserror::Error;

use crate::emit::emit_bitcode;
use crate::module::AirModule;

#[derive(Debug, Error)]
pub enum AssembleError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("no kernels in module")]
    NoKernels,
    #[error("bitcode emit failed: {0}")]
    Emit(String),
}

/// Emit a `.metallib` using the pure-Rust AIR bitcode writer + MTLB packer.
///
/// `work_dir` is accepted for API stability with the former metal-as path; it
/// is unused by the pure emitter.
pub fn emit_metallib(module: &AirModule, _work_dir: &Path) -> Result<Vec<u8>, AssembleError> {
    if module.functions.is_empty() {
        return Err(AssembleError::NoKernels);
    }
    let bitcode = emit_bitcode(module);
    if bitcode.len() < 4 || &bitcode[0..2] != b"BC" {
        return Err(AssembleError::Emit("missing BC magic".into()));
    }
    let opts = MetallibOptions {
        os_major: module.macos_version.0 as u16,
        os_minor: module.macos_version.1 as u16,
        os_patch: module.macos_version.2 as u16,
        air_major: module.air_version.0 as u16,
        air_minor: module.air_version.1 as u16,
        metal_major: module.language_version.1 as u16,
        metal_minor: module.language_version.2 as u16,
        ..MetallibOptions::default()
    };
    let entries: Vec<MetallibEntry> = module
        .functions
        .iter()
        .map(|f| MetallibEntry {
            name: f.name.clone(),
            entry_type: EntryType::Kernel,
        })
        .collect();
    Ok(write_metallib(&bitcode, &entries, &opts))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::add_one_module;
    use metallib::parse_metallib;

    #[test]
    fn emit_bitcode_has_bc_magic() {
        let bc = crate::emit_bitcode(&crate::add_one_module());
        assert!(bc.len() > 64);
        assert_eq!(&bc[0..4], &[b'B', b'C', 0xc0, 0xde]);
    }

    #[test]
    fn emit_add_one_metallib_parses() {
        let dir = std::env::temp_dir().join("metalc-air-bitcode-pure");
        let bytes = emit_metallib(&add_one_module(), &dir).expect("emit");
        let parsed = parse_metallib(&bytes).expect("parse");
        assert_eq!(parsed.entries[0].name, "add_one");
        assert_eq!(parsed.entries[0].entry_type, 2);
        let bc = metallib::unwrap_bitcode(&parsed.wrapped_bitcode).unwrap();
        assert_eq!(&bc[0..2], b"BC");
    }
}
