//! metalc — OpenMetal AIR compiler CLI (IR-first MVP).

use std::path::PathBuf;

use anyhow::{Context as AnyhowContext, Result};
use clap::{Parser, Subcommand};
use pliron::context::Context;

#[derive(Parser, Debug)]
#[command(name = "metalc", about = "OpenMetal AIR compiler (IR-first MVP)")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Build the built-in add_one metal dialect module and print pliron IR.
    Dump,
    /// Emit LLVM AIR textual IR for add_one.
    EmitLl {
        #[arg(short, long)]
        output: PathBuf,
    },
    /// Emit a .metallib for add_one (pure-Rust AIR bitcode + MTLB packer).
    EmitMetallib {
        #[arg(short, long)]
        output: PathBuf,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Dump => {
            let ctx = &mut Context::new();
            let module = dialect_metal::build_add_one_module(ctx)?;
            let _ = metal_transforms::run_passes(ctx, module)?;
            println!("{}", dialect_metal::dump_module(ctx, module));
        }
        Cmd::EmitLl { output } => {
            let ctx = &mut Context::new();
            let module = dialect_metal::build_add_one_module(ctx)?;
            let module = metal_transforms::run_passes(ctx, module)?;
            let air = metal_lower::lower_module(ctx, module).context("lower")?;
            let ll = air_bitcode::write_llvm_ir(&air);
            std::fs::write(&output, ll).with_context(|| format!("write {}", output.display()))?;
            eprintln!("wrote {}", output.display());
        }
        Cmd::EmitMetallib { output } => {
            let ctx = &mut Context::new();
            let module = dialect_metal::build_add_one_module(ctx)?;
            let module = metal_transforms::run_passes(ctx, module)?;
            let air = metal_lower::lower_module(ctx, module).context("lower")?;
            let work = output
                .parent()
                .map(|p| p.join(".metalc-work"))
                .unwrap_or_else(|| PathBuf::from(".metalc-work"));
            let bytes = air_bitcode::emit_metallib(&air, &work).context("emit metallib")?;
            std::fs::write(&output, bytes)
                .with_context(|| format!("write {}", output.display()))?;
            eprintln!("wrote {}", output.display());
        }
    }
    Ok(())
}
