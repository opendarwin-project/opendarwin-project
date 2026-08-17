//! MSL subset frontend for metalc.
//!
//! Parses a tiny compute-oriented Metal Shading Language subset and renders
//! failures with [`annotate-snippets`](https://docs.rs/annotate-snippets).
//! The recognized `add_one` kernel lowers into dialect-metal.

mod ast;
mod diagnostic;
mod lower;
mod parse;

pub use ast::{BinOp, Expr, Kernel, Param, Spanned, Stmt, TranslationUnit, Type};
pub use diagnostic::Diagnostic;
pub use lower::lower_unit;

use pliron::{builtin::ops::ModuleOp, context::Context};

/// Parse `source` into an AST.
pub fn parse_msl(source: &str, filename: &str) -> Result<TranslationUnit, Diagnostic> {
    parse::parse_ast(source, filename)
}

/// Parse and lower MSL source to a dialect-metal [`ModuleOp`].
pub fn compile_msl(
    ctx: &mut Context,
    source: &str,
    filename: &str,
) -> Result<ModuleOp, Diagnostic> {
    let unit = parse_msl(source, filename)?;
    lower_unit(ctx, &unit, source, filename)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ADD_ONE: &str = r#"#include <metal_stdlib>
using namespace metal;

kernel void add_one(device const float* in [[buffer(0)]],
                    device float* out [[buffer(1)]],
                    uint tid [[thread_position_in_grid]]) {
  out[tid] = in[tid] + 1.0f;
}
"#;

    #[test]
    fn parse_add_one_golden() {
        let unit = parse_msl(ADD_ONE, "add_one.metal").expect("parse");
        assert_eq!(unit.kernels.len(), 1);
        assert_eq!(unit.kernels[0].name.node, "add_one");
        assert_eq!(unit.kernels[0].params.len(), 3);
        assert_eq!(unit.kernels[0].body.len(), 1);
    }

    #[test]
    fn parse_testdata_file() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../testdata/add_one.metal");
        let source = std::fs::read_to_string(path).expect("read testdata");
        let unit = parse_msl(&source, "add_one.metal").expect("parse");
        assert_eq!(unit.kernels[0].name.node, "add_one");
    }

    #[test]
    fn compile_add_one_to_dialect() {
        let ctx = &mut Context::new();
        let module = compile_msl(ctx, ADD_ONE, "add_one.metal").expect("compile");
        let dump = dialect_metal::dump_module(ctx, module);
        assert!(
            dump.contains("add_one") || dump.contains("metal."),
            "{dump}"
        );
    }

    #[test]
    fn parse_error_is_annotated() {
        let err = parse_msl("kernel void oops( {", "bad.metal").expect_err("should fail");
        let rendered = err.to_string();
        assert!(rendered.contains("error:"), "{rendered}");
        assert!(rendered.contains("bad.metal"), "{rendered}");
    }

    #[test]
    fn semantic_error_wrong_rhs() {
        let src = r#"
kernel void add_one(device const float* in [[buffer(0)]],
                    device float* out [[buffer(1)]],
                    uint tid [[thread_position_in_grid]]) {
  out[tid] = in[tid] + 2.0f;
}
"#;
        let ctx = &mut Context::new();
        let Err(err) = compile_msl(ctx, src, "bad.metal") else {
            panic!("expected semantic error");
        };
        let rendered = err.to_string();
        assert!(rendered.contains("1.0"), "{rendered}");
        assert!(rendered.contains("bad.metal"), "{rendered}");
    }
}
