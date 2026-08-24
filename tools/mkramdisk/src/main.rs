//! Compresses a file with `zrip` into an embeddable ramdisk blob.
//!
//! Used to build `src/kernel/ramdisk.fat32.zst`, embedded via
//! `include_bytes!` and decompressed at boot (see `kernel::ramdisk`).

use std::env;
use std::fs;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    let [_, input, output] = args.as_slice() else {
        eprintln!("usage: mkramdisk <input> <output.zst>");
        return ExitCode::from(2);
    };

    let data = match fs::read(input) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("mkramdisk: reading {input}: {e}");
            return ExitCode::FAILURE;
        }
    };

    let compressed = match zrip::compress(&data, 4) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("mkramdisk: compression failed: {e}");
            return ExitCode::FAILURE;
        }
    };

    if let Err(e) = fs::write(output, &compressed) {
        eprintln!("mkramdisk: writing {output}: {e}");
        return ExitCode::FAILURE;
    }

    eprintln!(
        "mkramdisk: {} bytes -> {} bytes compressed -> {output}",
        data.len(),
        compressed.len()
    );
    ExitCode::SUCCESS
}
