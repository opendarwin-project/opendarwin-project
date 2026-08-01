//! Hand-rolled lexer + recursive-descent parser for a tiny MSL subset.
//!
//! Kept intentionally small: enough to accept `testdata/add_one.metal` and
//! reject unsupported constructs with spanned diagnostics. A combinator crate
//! (winnow/chumsky) can replace this later if the grammar grows.

use crate::ast::{BinOp, Expr, Kernel, Param, Spanned, Stmt, TranslationUnit, Type};
use crate::diagnostic::Diagnostic;

struct Parser<'a> {
    source: &'a str,
    filename: &'a str,
    pos: usize,
}

impl<'a> Parser<'a> {
    fn new(source: &'a str, filename: &'a str) -> Self {
        Self {
            source,
            filename,
            pos: 0,
        }
    }

    fn err(&self, message: impl Into<String>, span: std::ops::Range<usize>) -> Diagnostic {
        Diagnostic::new(message, span, self.source, self.filename)
    }

    fn peek_char(&self) -> Option<char> {
        self.source[self.pos..].chars().next()
    }

    fn bump(&mut self) -> Option<char> {
        let c = self.peek_char()?;
        self.pos += c.len_utf8();
        Some(c)
    }

    fn skip_ws_and_comments(&mut self) {
        loop {
            while matches!(self.peek_char(), Some(c) if c.is_whitespace()) {
                self.bump();
            }
            if self.source[self.pos..].starts_with("//") {
                while matches!(self.peek_char(), Some(c) if c != '\n') {
                    self.bump();
                }
                continue;
            }
            break;
        }
    }

    fn at_end(&mut self) -> bool {
        self.skip_ws_and_comments();
        self.pos >= self.source.len()
    }

    fn starts_with(&mut self, s: &str) -> bool {
        self.skip_ws_and_comments();
        self.source[self.pos..].starts_with(s)
    }

    fn eat(&mut self, s: &str) -> Result<(), Diagnostic> {
        self.skip_ws_and_comments();
        if self.source[self.pos..].starts_with(s) {
            self.pos += s.len();
            Ok(())
        } else {
            let end = (self.pos + 1).min(self.source.len()).max(self.pos);
            Err(self.err(format!("expected `{s}`"), self.pos..end))
        }
    }

    fn try_eat(&mut self, s: &str) -> bool {
        self.skip_ws_and_comments();
        if self.source[self.pos..].starts_with(s) {
            self.pos += s.len();
            true
        } else {
            false
        }
    }

    fn is_ident_start(c: char) -> bool {
        c.is_ascii_alphabetic() || c == '_'
    }

    fn is_ident_continue(c: char) -> bool {
        c.is_ascii_alphanumeric() || c == '_'
    }

    fn is_keyword(s: &str) -> bool {
        matches!(
            s,
            "kernel"
                | "void"
                | "device"
                | "const"
                | "float"
                | "uint"
                | "using"
                | "namespace"
                | "metal"
                | "true"
                | "false"
                | "buffer"
        )
    }

    fn parse_ident(&mut self) -> Result<Spanned<String>, Diagnostic> {
        self.skip_ws_and_comments();
        let start = self.pos;
        let Some(first) = self.peek_char() else {
            return Err(self.err(
                "expected identifier",
                start..start.saturating_add(1).min(self.source.len().max(start)),
            ));
        };
        if !Self::is_ident_start(first) {
            return Err(self.err("expected identifier", start..(start + first.len_utf8())));
        }
        self.bump();
        while matches!(self.peek_char(), Some(c) if Self::is_ident_continue(c)) {
            self.bump();
        }
        let text = &self.source[start..self.pos];
        if Self::is_keyword(text) {
            return Err(self.err(
                format!("expected identifier, found keyword `{text}`"),
                start..self.pos,
            ));
        }
        Ok(Spanned::new(text.to_string(), start..self.pos))
    }

    fn eat_kw(&mut self, word: &str) -> Result<(), Diagnostic> {
        self.skip_ws_and_comments();
        let start = self.pos;
        if !self.source[self.pos..].starts_with(word) {
            let end = (start + 1).min(self.source.len()).max(start);
            return Err(self.err(format!("expected `{word}`"), start..end));
        }
        let after = start + word.len();
        if let Some(c) = self.source[after..].chars().next()
            && Self::is_ident_continue(c)
        {
            let end = (start + 1).min(self.source.len()).max(start);
            return Err(self.err(format!("expected `{word}`"), start..end));
        }
        self.pos = after;
        Ok(())
    }

    fn try_eat_kw(&mut self, word: &str) -> bool {
        self.skip_ws_and_comments();
        let start = self.pos;
        if !self.source[self.pos..].starts_with(word) {
            return false;
        }
        let after = start + word.len();
        if let Some(c) = self.source[after..].chars().next()
            && Self::is_ident_continue(c)
        {
            return false;
        }
        self.pos = after;
        true
    }

    fn skip_preamble(&mut self) -> Result<(), Diagnostic> {
        self.skip_ws_and_comments();
        if self.try_eat("#include") {
            self.skip_ws_and_comments();
            if !(self.try_eat("<metal_stdlib>") || self.try_eat("\"metal_stdlib\"")) {
                let end = (self.pos + 1).min(self.source.len()).max(self.pos);
                return Err(self.err("expected <metal_stdlib>", self.pos..end));
            }
        }
        self.skip_ws_and_comments();
        if self.try_eat_kw("using") {
            self.eat_kw("namespace")?;
            self.eat_kw("metal")?;
            self.eat(";")?;
        }
        Ok(())
    }

    fn parse_buffer_attr(&mut self) -> Result<u32, Diagnostic> {
        self.eat("[[")?;
        self.eat_kw("buffer")?;
        self.eat("(")?;
        self.skip_ws_and_comments();
        let start = self.pos;
        while matches!(self.peek_char(), Some(c) if c.is_ascii_digit()) {
            self.bump();
        }
        if start == self.pos {
            return Err(self.err(
                "expected buffer index",
                start..(start + 1).min(self.source.len().max(start)),
            ));
        }
        let n: u32 = self.source[start..self.pos]
            .parse()
            .map_err(|_| self.err("invalid buffer index", start..self.pos))?;
        self.eat(")")?;
        self.eat("]]")?;
        Ok(n)
    }

    fn parse_thread_pos_attr(&mut self) -> Result<(), Diagnostic> {
        self.eat("[[")?;
        self.eat("thread_position_in_grid")?;
        self.eat("]]")?;
        Ok(())
    }

    fn parse_param(&mut self) -> Result<Param, Diagnostic> {
        self.skip_ws_and_comments();
        let start = self.pos;
        if self.try_eat_kw("device") {
            let is_const = self.try_eat_kw("const");
            self.eat_kw("float")?;
            self.eat("*")?;
            let name = self.parse_ident()?;
            let location = self.parse_buffer_attr()?;
            return Ok(Param::Buffer {
                name,
                elem_ty: Type::Float,
                is_const,
                location,
                span: start..self.pos,
            });
        }
        if self.try_eat_kw("uint") {
            let name = self.parse_ident()?;
            self.parse_thread_pos_attr()?;
            return Ok(Param::ThreadPositionInGrid {
                name,
                span: start..self.pos,
            });
        }
        let end = (start + 1).min(self.source.len()).max(start);
        Err(self.err("expected buffer or thread id parameter", start..end))
    }

    fn parse_float_lit(&mut self) -> Result<Expr, Diagnostic> {
        self.skip_ws_and_comments();
        let start = self.pos;
        let mut saw_digit = false;
        while matches!(self.peek_char(), Some(c) if c.is_ascii_digit()) {
            saw_digit = true;
            self.bump();
        }
        if self.peek_char() == Some('.') {
            self.bump();
            while matches!(self.peek_char(), Some(c) if c.is_ascii_digit()) {
                saw_digit = true;
                self.bump();
            }
        }
        if !saw_digit {
            let end = (start + 1).min(self.source.len()).max(start);
            return Err(self.err("expected float literal", start..end));
        }
        if self.peek_char() == Some('f') || self.peek_char() == Some('F') {
            self.bump();
        }
        let text = &self.source[start..self.pos];
        let trimmed = text.trim_end_matches(['f', 'F']);
        let value: f32 = trimmed
            .parse()
            .map_err(|_| self.err("invalid float literal", start..self.pos))?;
        Ok(Expr::FloatLit {
            value,
            span: start..self.pos,
        })
    }

    fn parse_primary(&mut self) -> Result<Expr, Diagnostic> {
        self.skip_ws_and_comments();
        if self.try_eat("(") {
            let e = self.parse_expr()?;
            self.eat(")")?;
            return Ok(e);
        }
        if matches!(self.peek_char(), Some(c) if c.is_ascii_digit() || c == '.') {
            return self.parse_float_lit();
        }
        let base = self.parse_ident()?;
        if self.try_eat("[") {
            let index = self.parse_expr()?;
            self.eat("]")?;
            let span = base.span.start..expr_span(&index).end;
            return Ok(Expr::Index {
                base,
                index: Box::new(index),
                span,
            });
        }
        Ok(Expr::Ident(base))
    }

    fn parse_expr(&mut self) -> Result<Expr, Diagnostic> {
        let mut lhs = self.parse_primary()?;
        while self.try_eat("+") {
            let rhs = self.parse_primary()?;
            let span = expr_span(&lhs).start..expr_span(&rhs).end;
            lhs = Expr::Binary {
                op: BinOp::Add,
                lhs: Box::new(lhs),
                rhs: Box::new(rhs),
                span,
            };
        }
        Ok(lhs)
    }

    fn parse_stmt(&mut self) -> Result<Stmt, Diagnostic> {
        self.skip_ws_and_comments();
        let start = self.pos;
        let base = self.parse_ident()?;
        self.eat("[")?;
        let index = self.parse_expr()?;
        self.eat("]")?;
        self.eat("=")?;
        let value = self.parse_expr()?;
        self.eat(";")?;
        Ok(Stmt::AssignIndex {
            base,
            index,
            value,
            span: start..self.pos,
        })
    }

    fn parse_kernel(&mut self) -> Result<Kernel, Diagnostic> {
        self.skip_ws_and_comments();
        let start = self.pos;
        self.eat_kw("kernel")?;
        self.eat_kw("void")?;
        let name = self.parse_ident()?;
        self.eat("(")?;
        let mut params = Vec::new();
        params.push(self.parse_param()?);
        while self.try_eat(",") {
            params.push(self.parse_param()?);
        }
        self.eat(")")?;
        self.eat("{")?;
        let mut body = Vec::new();
        while !self.starts_with("}") {
            if self.at_end() {
                return Err(self.err("unclosed kernel body", start..self.pos));
            }
            body.push(self.parse_stmt()?);
        }
        self.eat("}")?;
        Ok(Kernel {
            name,
            params,
            body,
            span: start..self.pos,
        })
    }

    fn parse_translation_unit(&mut self) -> Result<TranslationUnit, Diagnostic> {
        self.skip_preamble()?;
        let mut kernels = Vec::new();
        while !self.at_end() {
            kernels.push(self.parse_kernel()?);
        }
        if kernels.is_empty() {
            let end = self.source.len().max(1).min(self.source.len());
            return Err(self.err("expected at least one kernel", 0..end));
        }
        Ok(TranslationUnit { kernels })
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

/// Parse `source` into an AST.
pub fn parse_ast(source: &str, filename: &str) -> Result<TranslationUnit, Diagnostic> {
    Parser::new(source, filename).parse_translation_unit()
}
