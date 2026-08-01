//! Assemble AIR LLVM IR to bitcode and pack a metallib.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use metallib::{EntryType, MetallibEntry, MetallibOptions, write_metallib};
use thiserror::Error;

use crate::module::AirModule;
use crate::write_ll::write_llvm_ir;

#[derive(Debug, Error)]
pub enum AssembleError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("metal-as failed: {0}")]
    MetalAs(String),
    #[error("xcrun/metal-as not found: {0}")]
    NotFound(String),
    #[error("no kernels in module")]
    NoKernels,
}

fn find_metal_as() -> Result<PathBuf, AssembleError> {
    if let Ok(p) = which("metal-as") {
        return Ok(p);
    }
    let out = Command::new("xcrun")
        .args(["--find", "metal-as"])
        .output()
        .map_err(|e| AssembleError::NotFound(e.to_string()))?;
    if !out.status.success() {
        return Err(AssembleError::NotFound(
            String::from_utf8_lossy(&out.stderr).into_owned(),
        ));
    }
    let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if path.is_empty() {
        return Err(AssembleError::NotFound(
            "empty xcrun --find metal-as".into(),
        ));
    }
    Ok(PathBuf::from(path))
}

fn which(bin: &str) -> Result<PathBuf, ()> {
    let out = Command::new("which").arg(bin).output().map_err(|_| ())?;
    if !out.status.success() {
        return Err(());
    }
    let p = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if p.is_empty() {
        Err(())
    } else {
        Ok(PathBuf::from(p))
    }
}

/// Assemble textual AIR LLVM IR into typed-pointer bitcode via host `metal-as`.
pub fn assemble_bitcode(llvm_ir: &str, work_dir: &Path) -> Result<Vec<u8>, AssembleError> {
    std::fs::create_dir_all(work_dir)?;
    let ll_path = work_dir.join("module.ll");
    let air_path = work_dir.join("module.air");
    {
        let mut f = std::fs::File::create(&ll_path)?;
        f.write_all(llvm_ir.as_bytes())?;
    }

    let metal_as = find_metal_as()?;
    let out = Command::new(&metal_as)
        .args([
            ll_path.as_os_str(),
            std::ffi::OsStr::new("-o"),
            air_path.as_os_str(),
        ])
        .output()?;
    if !out.status.success() {
        return Err(AssembleError::MetalAs(format!(
            "status={} stderr={} stdout={}",
            out.status,
            String::from_utf8_lossy(&out.stderr),
            String::from_utf8_lossy(&out.stdout)
        )));
    }
    read_air_bitcode(&air_path)
}

/// Read bitcode from a `metal-as` `.air` file (which is already wrapper-framed).
fn read_air_bitcode(air_path: &Path) -> Result<Vec<u8>, AssembleError> {
    let data = std::fs::read(air_path)?;
    // metal-as emits Apple's 0x0B17C0DE wrapper; metallib::write_metallib wraps again.
    if data.len() >= 4 {
        let magic = u32::from_le_bytes(data[0..4].try_into().unwrap());
        if magic == metallib::BITCODE_WRAPPER_MAGIC {
            return metallib::unwrap_bitcode(&data)
                .map_err(|e| AssembleError::MetalAs(e.to_string()));
        }
    }
    Ok(data)
}

/// Emit a `.metallib` for `module` using host `metal-as` + pure-Rust MTLB packing.
pub fn emit_metallib(module: &AirModule, work_dir: &Path) -> Result<Vec<u8>, AssembleError> {
    if module.functions.is_empty() {
        return Err(AssembleError::NoKernels);
    }
    let ll = write_llvm_ir(module);
    let bitcode = assemble_bitcode(&ll, work_dir)?;
    let opts = MetallibOptions {
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
    #[cfg(target_os = "macos")]
    fn emit_add_one_metallib_parses() {
        let dir = std::env::temp_dir().join("metalc-air-bitcode-test");
        let bytes = emit_metallib(&add_one_module(), &dir).expect("emit");
        let parsed = parse_metallib(&bytes).expect("parse");
        assert_eq!(parsed.entries[0].name, "add_one");
        assert_eq!(parsed.entries[0].entry_type, 2);
    }
}
