//! Tiny AST for the MSL compute subset metalc accepts today.

use std::ops::Range;

pub type Span = Range<usize>;

#[derive(Debug, Clone, PartialEq)]
pub struct Spanned<T> {
    pub node: T,
    pub span: Span,
}

impl<T> Spanned<T> {
    pub fn new(node: T, span: Span) -> Self {
        Self { node, span }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct TranslationUnit {
    pub kernels: Vec<Kernel>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Kernel {
    pub name: Spanned<String>,
    pub params: Vec<Param>,
    pub body: Vec<Stmt>,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Param {
    Buffer {
        name: Spanned<String>,
        elem_ty: Type,
        is_const: bool,
        location: u32,
        span: Span,
    },
    ThreadPositionInGrid {
        name: Spanned<String>,
        span: Span,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Type {
    Float,
    Uint,
    Void,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Stmt {
    /// `lhs[index] = rhs;`
    AssignIndex {
        base: Spanned<String>,
        index: Expr,
        value: Expr,
        span: Span,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Ident(Spanned<String>),
    Index {
        base: Spanned<String>,
        index: Box<Expr>,
        span: Span,
    },
    FloatLit {
        value: f32,
        span: Span,
    },
    Binary {
        op: BinOp,
        lhs: Box<Expr>,
        rhs: Box<Expr>,
        span: Span,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
}
