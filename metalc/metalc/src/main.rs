//! metalc — OpenMetal AIR compiler CLI.

use std::path::PathBuf;

use anyhow::{Context as AnyhowContext, Result, bail};
use clap::{Parser, Subcommand};
use pliron::context::Context;

#[derive(Parser, Debug)]
#[command(name = "metalc", about = "OpenMetal AIR compiler")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Build the built-in add_one metal dialect module and print pliron IR.
    Dump,
    /// Parse an MSL file and print the dialect-metal dump.
    Parse { input: PathBuf },
    /// Compile MSL (or the built-in add_one) to textual AIR LLVM IR.
    EmitLl {
        /// Optional `.metal` source. Defaults to the built-in add_one kernel.
        input: Option<PathBuf>,
        #[arg(short, long)]
        output: PathBuf,
    },
    /// Compile MSL (or the built-in add_one) to a `.metallib`.
    EmitMetallib {
        /// Optional `.metal` source. Defaults to the built-in add_one kernel.
        input: Option<PathBuf>,
        #[arg(short, long)]
        output: PathBuf,
    },
}

fn load_module(
    ctx: &mut Context,
    input: Option<&PathBuf>,
) -> Result<pliron::builtin::ops::ModuleOp> {
    match input {
        None => Ok(dialect_metal::build_add_one_module(ctx)?),
        Some(path) => {
            let source = std::fs::read_to_string(path)
                .with_context(|| format!("read {}", path.display()))?;
            let filename = path
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("input.metal");
            msl_frontend::compile_msl(ctx, &source, filename).map_err(|d| {
                eprintln!("{d}");
                anyhow::anyhow!("MSL compile failed")
            })
        }
    }
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
        Cmd::Parse { input } => {
            let ctx = &mut Context::new();
            let module = load_module(ctx, Some(&input))?;
            let module = metal_transforms::run_passes(ctx, module)?;
            println!("{}", dialect_metal::dump_module(ctx, module));
        }
        Cmd::EmitLl { input, output } => {
            let ctx = &mut Context::new();
            let module = load_module(ctx, input.as_ref())?;
            let module = metal_transforms::run_passes(ctx, module)?;
            let air = metal_lower::lower_module(ctx, module).context("lower")?;
            let ll = air_bitcode::write_llvm_ir(&air);
            std::fs::write(&output, ll).with_context(|| format!("write {}", output.display()))?;
            eprintln!("wrote {}", output.display());
        }
        Cmd::EmitMetallib { input, output } => {
            if let Some(path) = &input
                && path.extension().and_then(|e| e.to_str()) != Some("metal")
            {
                bail!("expected a .metal input, got {}", path.display());
            }
            let ctx = &mut Context::new();
            let module = load_module(ctx, input.as_ref())?;
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
