//! Pretty diagnostics via `annotate-snippets`.

use std::fmt;
use std::ops::Range;

use annotate_snippets::{AnnotationKind, Level, Renderer, Snippet};

/// A rendered compiler diagnostic with a source span.
#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub message: String,
    pub span: Range<usize>,
    pub input: String,
    pub filename: String,
}

impl Diagnostic {
    pub fn new(
        message: impl Into<String>,
        span: Range<usize>,
        input: impl Into<String>,
        filename: impl Into<String>,
    ) -> Self {
        let input = input.into();
        let mut span = span;
        if span.start > input.len() {
            span.start = input.len();
        }
        if span.end > input.len() {
            span.end = input.len();
        }
        if span.start == span.end && span.end < input.len() {
            span.end += input[span.end..]
                .chars()
                .next()
                .map(|c| c.len_utf8())
                .unwrap_or(0);
        }
        if span.start == span.end && !input.is_empty() {
            span.start = span.start.saturating_sub(1);
        }
        Self {
            message: message.into(),
            span,
            input,
            filename: filename.into(),
        }
    }

    pub fn render(&self) -> String {
        let report = &[Level::ERROR.primary_title(&self.message).element(
            Snippet::source(&self.input)
                .path(&self.filename)
                .fold(true)
                .annotation(AnnotationKind::Primary.span(self.span.clone())),
        )];
        Renderer::plain().render(report).to_string()
    }
}

impl fmt::Display for Diagnostic {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.render())
    }
}

impl std::error::Error for Diagnostic {}
