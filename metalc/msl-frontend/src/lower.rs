//! Lower a parsed MSL AST into a dialect-metal [`ModuleOp`].
//!
//! MVP: recognize the `add_one` kernel shape and emit the matching pliron module
//! via [`dialect_metal::build_add_one_module`]. Unsupported shapes get spanned
//! diagnostics.

use pliron::{builtin::ops::ModuleOp, context::Context};

use crate::ast::{BinOp, Expr, Kernel, Param, Stmt, TranslationUnit, Type};
use crate::diagnostic::Diagnostic;

/// Lower `unit` to a dialect-metal module.
pub fn lower_unit(
    ctx: &mut Context,
    unit: &TranslationUnit,
    source: &str,
    filename: &str,
) -> Result<ModuleOp, Diagnostic> {
    if unit.kernels.len() != 1 {
        let span = unit
            .kernels
            .first()
            .map(|k| k.span.clone())
            .unwrap_or(0..source.len().min(1));
        return Err(Diagnostic::new(
            "MSL MVP expects exactly one kernel",
            span,
            source,
            filename,
        ));
    }
    lower_add_one(ctx, &unit.kernels[0], source, filename)
}

fn lower_add_one(
    ctx: &mut Context,
    kernel: &Kernel,
    source: &str,
    filename: &str,
) -> Result<ModuleOp, Diagnostic> {
    if kernel.name.node != "add_one" {
        return Err(Diagnostic::new(
            format!(
                "unsupported kernel `{}` (MVP only lowers `add_one`)",
                kernel.name.node
            ),
            kernel.name.span.clone(),
            source,
            filename,
        ));
    }

    if kernel.params.len() != 3 {
        return Err(Diagnostic::new(
            "add_one expects three parameters: const float* in, float* out, uint tid",
            kernel.span.clone(),
            source,
            filename,
        ));
    }

    match &kernel.params[0] {
        Param::Buffer {
            name,
            elem_ty,
            is_const,
            location,
            ..
        } if name.node == "in" && *elem_ty == Type::Float && *is_const && *location == 0 => {}
        p => {
            return Err(Diagnostic::new(
                "expected `device const float* in [[buffer(0)]]`",
                param_span(p),
                source,
                filename,
            ));
        }
    }

    match &kernel.params[1] {
        Param::Buffer {
            name,
            elem_ty,
            is_const,
            location,
            ..
        } if name.node == "out" && *elem_ty == Type::Float && !*is_const && *location == 1 => {}
        p => {
            return Err(Diagnostic::new(
                "expected `device float* out [[buffer(1)]]`",
                param_span(p),
                source,
                filename,
            ));
        }
    }

    match &kernel.params[2] {
        Param::ThreadPositionInGrid { name, .. } if name.node == "tid" => {}
        p => {
            return Err(Diagnostic::new(
                "expected `uint tid [[thread_position_in_grid]]`",
                param_span(p),
                source,
                filename,
            ));
        }
    }

    if kernel.body.len() != 1 {
        return Err(Diagnostic::new(
            "add_one expects a single assignment statement",
            kernel.span.clone(),
            source,
            filename,
        ));
    }

    match &kernel.body[0] {
        Stmt::AssignIndex {
            base,
            index,
            value,
            span,
        } => {
            if base.node != "out" {
                return Err(Diagnostic::new(
                    "expected store to `out[...]`",
                    base.span.clone(),
                    source,
                    filename,
                ));
            }
            expect_ident(index, "tid", source, filename)?;
            match value {
                Expr::Binary {
                    op: BinOp::Add,
                    lhs,
                    rhs,
                    ..
                } => {
                    expect_index(lhs, "in", "tid", source, filename)?;
                    expect_float_one(rhs, source, filename)?;
                }
                other => {
                    return Err(Diagnostic::new(
                        "expected `in[tid] + 1.0`",
                        expr_span(other),
                        source,
                        filename,
                    ));
                }
            }
            let _ = span;
        }
    }

    dialect_metal::build_add_one_module(ctx).map_err(|e| {
        Diagnostic::new(
            format!("failed to build dialect-metal module: {e}"),
            kernel.span.clone(),
            source,
            filename,
        )
    })
}

fn param_span(p: &Param) -> std::ops::Range<usize> {
    match p {
        Param::Buffer { span, .. } => span.clone(),
        Param::ThreadPositionInGrid { span, .. } => span.clone(),
    }
}

fn expr_span(e: &Expr) -> std::ops::Range<usize> {
    match e {
        Expr::Ident(s) => s.span.clone(),
        Expr::Index { span, .. } => span.clone(),
        Expr::FloatLit { span, .. } => span.clone(),
        Expr::Binary { span, .. } => span.clone(),
    }
}

fn expect_ident(e: &Expr, name: &str, source: &str, filename: &str) -> Result<(), Diagnostic> {
    match e {
        Expr::Ident(s) if s.node == name => Ok(()),
        other => Err(Diagnostic::new(
            format!("expected `{name}`"),
            expr_span(other),
            source,
            filename,
        )),
    }
}

fn expect_index(
    e: &Expr,
    base: &str,
    index: &str,
    source: &str,
    filename: &str,
) -> Result<(), Diagnostic> {
    match e {
        Expr::Index {
            base: b, index: i, ..
        } if b.node == base => expect_ident(i, index, source, filename),
        other => Err(Diagnostic::new(
            format!("expected `{base}[{index}]`"),
            expr_span(other),
            source,
            filename,
        )),
    }
}

fn expect_float_one(e: &Expr, source: &str, filename: &str) -> Result<(), Diagnostic> {
    match e {
        Expr::FloatLit { value, .. } if (*value - 1.0).abs() < f32::EPSILON => Ok(()),
        other => Err(Diagnostic::new(
            "expected floating literal `1.0`",
            expr_span(other),
            source,
            filename,
        )),
    }
}
