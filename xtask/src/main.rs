//! OpenDarwin build driver (`cargo xtask ...`).
//!
//! entry point and get the right flags automatically. External commands inherit
//! stdout/stderr. Clippy stays human-readable by default; pass
//! `--message-format json` to get its newline-delimited JSON passthrough
//! (pipe to jq etc.).
//!
//! Usage:
//!   cargo xtask test [nextest args]        # nextest --workspace, excluding kernel (falls back to cargo test)
//!   cargo xtask clippy [clippy args]       # clippy --workspace --all-targets, excluding kernel
//!                                        #   (+ --message-format json for JSON)
//!   cargo xtask check [cargo check args]   # check --workspace (host/darwin targets) + kernel (aarch64-unknown-none)
//!   cargo xtask framework                  # nu tools/build_iokit_framework.nu

use std::path::PathBuf;
use std::process::{Command, Stdio};

/// The `kernel` crate is `no_std`/`no_main`, freestanding aarch64: it cannot
/// build, test, or lint under the host/darwin targets the rest of the
/// workspace uses. Every workspace-wide cargo invocation excludes it via
/// `--exclude kernel`, and `cmd_check`/`cmd_kernel_check` build it separately
/// with its own target + `-Zbuild-std`.
const KERNEL_PACKAGE: &str = "kernel";
const KERNEL_TARGET: &str = "aarch64-unknown-none";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("usage: cargo xtask <test|clippy|check|kernel-check|kernel-clippy|framework> [args...]");
        std::process::exit(2);
    }
    let cmd = args[0].as_str();
    let rest = &args[1..];
    match cmd {
        "test" => cmd_test(rest),
        "clippy" => cmd_clippy(rest),
        "check" => cmd_check(rest),
        "kernel-check" => cmd_kernel_check(rest),
        "kernel-clippy" => cmd_kernel_clippy(rest),
        "framework" => cmd_framework(rest),
        other => {
            eprintln!("unknown subcommand: {other}");
            std::process::exit(2);
        }
    }
}

/// Repository root: the xtask crate sits at `$repo/xtask`, so its parent is the
/// workspace root.
fn repo_root() -> PathBuf {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .parent()
        .expect("xtask manifest has no parent dir")
        .to_path_buf()
}

fn has_nextest() -> bool {
    Command::new("cargo")
        .args(["nextest", "--version"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Run cargo from the workspace root and propagate its exit status.
fn run(args: &[String]) -> ! {
    println!("==> cargo {}", args.join(" "));
    let status = Command::new("cargo")
        .current_dir(repo_root())
        .args(args)
        .status()
        .expect("failed to spawn cargo");
    std::process::exit(status.code().unwrap_or(1));
}

/// Run cargo from the workspace root, propagate failure, but let the caller
/// keep going afterward (used to chain a host-target step before a
/// kernel-target step in `cmd_check`).
fn run_and_continue(args: &[String]) -> i32 {
    println!("==> cargo {}", args.join(" "));
    let status = Command::new("cargo")
        .current_dir(repo_root())
        .args(args)
        .status()
        .expect("failed to spawn cargo");
    status.code().unwrap_or(1)
}

fn cmd_test(extra: &[String]) -> ! {
    // nextest accepts `-p/--package` for filtering, but that conflicts with
    // `--workspace`; only add `--workspace --exclude kernel` when no package
    // filter is given (kernel is no_std/freestanding and can't run tests).
    let has_pkg = extra.iter().any(|a| a == "-p" || a == "--package");
    if has_nextest() {
        let mut args = vec!["nextest".to_string(), "run".to_string()];
        if !has_pkg {
            args.push("--workspace".to_string());
            args.push("--exclude".to_string());
            args.push(KERNEL_PACKAGE.to_string());
        }
        args.extend_from_slice(extra);
        run(&args);
    } else {
        eprintln!("cargo-nextest not found; falling back to `cargo test`");
        let mut args = vec!["test".to_string()];
        if !has_pkg {
            args.push("--workspace".to_string());
            args.push("--exclude".to_string());
            args.push(KERNEL_PACKAGE.to_string());
        }
        args.extend_from_slice(extra);
        run(&args);
    }
}

fn cmd_clippy(extra: &[String]) -> ! {
    // Human-readable output by default. JSON is opt-in: pass
    // `--message-format json` (forwarded verbatim) when you want clippy's
    // newline-delimited JSON for jq/review tools.
    let mut args = vec![
        "clippy".to_string(),
        "--workspace".to_string(),
        "--exclude".to_string(),
        KERNEL_PACKAGE.to_string(),
        "--all-targets".to_string(),
    ];
    args.extend_from_slice(extra);
    run(&args);
}

fn cmd_check(extra: &[String]) -> ! {
    // Two passes: the ordinary workspace (host/darwin targets, kernel
    // excluded), then the kernel crate alone against its own freestanding
    // aarch64 target. Both must pass; run the kernel pass second so its
    // failure (if any) is the last, most visible thing printed.
    let mut host_args = vec![
        "check".to_string(),
        "--workspace".to_string(),
        "--exclude".to_string(),
        KERNEL_PACKAGE.to_string(),
    ];
    host_args.extend_from_slice(extra);
    let host_code = run_and_continue(&host_args);

    let kernel_code = run_and_continue(&kernel_check_args(extra));

    std::process::exit(if host_code != 0 { host_code } else { kernel_code });
}

/// `-Zbuild-std=core,alloc` is required because `aarch64-unknown-none` has no
/// prebuilt std/core in the default rustup distribution; the kernel is
/// `#![no_std]` freestanding and only needs `core`/`alloc`.
fn kernel_check_args(extra: &[String]) -> Vec<String> {
    let mut args = vec![
        "check".to_string(),
        "-p".to_string(),
        KERNEL_PACKAGE.to_string(),
        "-Zbuild-std=core,alloc".to_string(),
        "--target".to_string(),
        KERNEL_TARGET.to_string(),
    ];
    args.extend_from_slice(extra);
    args
}

fn cmd_kernel_check(extra: &[String]) -> ! {
    run(&kernel_check_args(extra));
}

fn cmd_kernel_clippy(extra: &[String]) -> ! {
    let mut args = vec![
        "clippy".to_string(),
        "-p".to_string(),
        KERNEL_PACKAGE.to_string(),
        "-Zbuild-std=core,alloc".to_string(),
        "--target".to_string(),
        KERNEL_TARGET.to_string(),
        "--all-targets".to_string(),
    ];
    args.extend_from_slice(extra);
    run(&args);
}

fn cmd_framework(_extra: &[String]) -> ! {
    let root = repo_root();
    let script = root.join("tools/build_frameworks.sh");
    println!("==> brush {}", script.display());
    let status = Command::new("brush")
        .current_dir(&root)
        .arg(&script)
        .status()
        .expect("failed to spawn nu (is nushell installed?)");
    std::process::exit(status.code().unwrap_or(1));
}
