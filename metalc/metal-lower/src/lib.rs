//! Lower a dialect-metal `add_one` module to [`air_bitcode::AirModule`].
//!
//! The MVP lowering recognizes the canonical `add_one` FuncOp shape produced by
//! [`dialect_metal::build_add_one_module`] and emits the matching AIR module.
//! A full DialectConversion walk can replace this pattern match later.

use air_bitcode::{AirModule, add_one_module};
use dialect_air::default_air_module;
use pliron::{
    builtin::{
        op_interfaces::{SingleBlockRegionInterface, SymbolOpInterface},
        ops::{FuncOp, ModuleOp},
    },
    context::Context,
    linked_list::ContainsLinkedList,
    operation::Operation,
};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum LowerError {
    #[error("expected a single kernel function in the module")]
    ExpectedKernel,
    #[error("unsupported metal kernel `{0}` (MVP only lowers add_one)")]
    UnsupportedKernel(String),
}

/// Lower `module` to an [`AirModule`].
pub fn lower_module(ctx: &Context, module: ModuleOp) -> Result<AirModule, LowerError> {
    let body = module.get_body(ctx, 0);
    let mut funcs = Vec::new();
    for op in body.deref(ctx).iter(ctx) {
        if let Some(func) = Operation::get_op::<FuncOp>(op, ctx) {
            let name = func.get_symbol_name(ctx).to_string();
            funcs.push(name);
        }
    }
    if funcs.len() != 1 {
        return Err(LowerError::ExpectedKernel);
    }
    if funcs[0] != "add_one" {
        return Err(LowerError::UnsupportedKernel(funcs[0].clone()));
    }
    let mut air = add_one_module();
    // Keep dialect-air defaults aligned.
    let defaults = default_air_module();
    air.triple = defaults.triple;
    air.datalayout = defaults.datalayout;
    air.air_version = defaults.air_version;
    air.language_version = defaults.language_version;
    Ok(air)
}

#[cfg(test)]
mod tests {
    use super::*;
    use dialect_metal::build_add_one_module;

    #[test]
    fn lower_add_one() {
        let ctx = &mut Context::new();
        let module = build_add_one_module(ctx).expect("build");
        let air = lower_module(ctx, module).expect("lower");
        assert_eq!(air.functions[0].name, "add_one");
        assert_eq!(air.functions[0].args.len(), 3);
    }
}
