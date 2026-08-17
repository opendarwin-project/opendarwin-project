//! Passes over dialect-metal modules (MVP: identity / verify hook).

use pliron::{builtin::ops::ModuleOp, context::Context, result::Result};

/// Run cheap legalization hooks. MVP is a no-op that returns the module unchanged.
pub fn run_passes(_ctx: &mut Context, module: ModuleOp) -> Result<ModuleOp> {
    Ok(module)
}
