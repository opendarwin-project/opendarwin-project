//! Compresses a file with `lz4rip` (matching `kernel::mm::compress`'s
//! decoder) into an embeddable ramdisk blob: an 8-byte little-endian
//! original-length header followed by the compressed payload.
//!
//! Used to build `src/kernel/src/ramdisk.fat32.lz4`, embedded via
//! `include_bytes!` and decompressed at boot (see `kernel::ramdisk`).

use std::env;
use std::fs;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    let [_, input, output] = args.as_slice() else {
        eprintln!("usage: mkramdisk <input> <output.lz4>");
        return ExitCode::from(2);
    };

    let data = match fs::read(input) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("mkramdisk: reading {input}: {e}");
            return ExitCode::FAILURE;
        }
    };

    let compressed = lz4rip::compress(&data);

    let mut out = Vec::with_capacity(8 + compressed.len());
    out.extend_from_slice(&(data.len() as u64).to_le_bytes());
    out.extend_from_slice(&compressed);

    if let Err(e) = fs::write(output, &out) {
        eprintln!("mkramdisk: writing {output}: {e}");
        return ExitCode::FAILURE;
    }

    eprintln!(
        "mkramdisk: {} bytes -> {} bytes compressed (+8 byte header) -> {output}",
        data.len(),
        compressed.len()
    );
    ExitCode::SUCCESS
}
