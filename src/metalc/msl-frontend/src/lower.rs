//! Lower a parsed MSL AST into a dialect-metal [`ModuleOp`].
//!
//! MVP: recognize `add_one` (`+ 1.0`) and `scale` (`* 2.0`) buffer kernels.

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
    lower_kernel(ctx, &unit.kernels[0], source, filename)
}

fn lower_kernel(
    ctx: &mut Context,
    kernel: &Kernel,
    source: &str,
    filename: &str,
) -> Result<ModuleOp, Diagnostic> {
    expect_buffer_pair(kernel, source, filename)?;

    if kernel.body.len() != 1 {
        return Err(Diagnostic::new(
            "MVP kernels expect a single assignment statement",
            kernel.span.clone(),
            source,
            filename,
        ));
    }

    let Stmt::AssignIndex {
        base, index, value, ..
    } = &kernel.body[0];
    if base.node != "out" {
        return Err(Diagnostic::new(
            "expected store to `out[...]`",
            base.span.clone(),
            source,
            filename,
        ));
    }
    expect_ident(index, "tid", source, filename)?;

    let (op, imm) = match value {
        Expr::Binary {
            op: BinOp::Add,
            lhs,
            rhs,
            ..
        } => {
            expect_index(lhs, "in", "tid", source, filename)?;
            expect_float(rhs, 1.0, source, filename)?;
            (BinOp::Add, 1.0)
        }
        Expr::Binary {
            op: BinOp::Mul,
            lhs,
            rhs,
            ..
        } => {
            expect_index(lhs, "in", "tid", source, filename)?;
            expect_float(rhs, 2.0, source, filename)?;
            (BinOp::Mul, 2.0)
        }
        other => {
            return Err(Diagnostic::new(
                "expected `in[tid] + 1.0` or `in[tid] * 2.0`",
                expr_span(other),
                source,
                filename,
            ));
        }
    };

    match (kernel.name.node.as_str(), op, imm) {
        ("add_one", BinOp::Add, _) => dialect_metal::build_add_one_module(ctx),
        ("scale", BinOp::Mul, _) => dialect_metal::build_scale_module(ctx),
        (name, _, _) => {
            return Err(Diagnostic::new(
                format!("unsupported kernel `{name}` (MVP: add_one with +1.0, or scale with *2.0)"),
                kernel.name.span.clone(),
                source,
                filename,
            ));
        }
    }
    .map_err(|e| {
        Diagnostic::new(
            format!("failed to build dialect-metal module: {e}"),
            kernel.span.clone(),
            source,
            filename,
        )
    })
}

fn expect_buffer_pair(kernel: &Kernel, source: &str, filename: &str) -> Result<(), Diagnostic> {
    if kernel.params.len() != 3 {
        return Err(Diagnostic::new(
            "expected three parameters: const float* in, float* out, uint tid",
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
    Ok(())
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

fn expect_float(e: &Expr, want: f32, source: &str, filename: &str) -> Result<(), Diagnostic> {
    match e {
        Expr::FloatLit { value, .. } if (*value - want).abs() < f32::EPSILON => Ok(()),
        other => Err(Diagnostic::new(
            format!("expected floating literal `{want:.1}`"),
            expr_span(other),
            source,
            filename,
        )),
    }
}
