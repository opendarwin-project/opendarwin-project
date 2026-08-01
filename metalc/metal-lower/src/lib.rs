//! Lower dialect-metal kernels to [`air_bitcode::AirModule`] by walking ops.
//!
//! Recognizes the metal.* op vocabulary (constants, zext/gep/load/store,
//! fadd/fsub/fmul, return) and emits matching AIR. Kernel argument kinds use a
//! simple MVP convention: `ptr, ptr, i32` → buffers 0/1 + thread id.

use std::collections::HashMap;

use air_bitcode::{AirArg, AirFunction, AirModule, AirType, ArgKind, BufferAccess, Inst, Val};
use dialect_air::{ADDRSPACE_DEVICE, default_air_module};
use dialect_metal::{
    ConstantF32Op, FAddOp, FMulOp, FSubOp, GepOp, LoadOp, ReturnOp, StoreOp, ZextOp,
};
use pliron::{
    builtin::{
        op_interfaces::{
            OneOpdInterface, OneResultInterface, SingleBlockRegionInterface, SymbolOpInterface,
        },
        ops::{FuncOp, ModuleOp},
    },
    context::{Context, Ptr},
    linked_list::ContainsLinkedList,
    op::Op,
    operation::Operation,
    utils::apint::APInt,
    value::Value,
};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum LowerError {
    #[error("expected a single kernel function in the module")]
    ExpectedKernel,
    #[error("unsupported metal op `{0}`")]
    UnsupportedOp(String),
    #[error("kernel `{0}` has unsupported signature (want device ptr, device ptr, i32 tid)")]
    UnsupportedSignature(String),
    #[error("missing attribute on metal.constant_f32")]
    MissingConstant,
}

/// Lower `module` to an [`AirModule`].
pub fn lower_module(ctx: &Context, module: ModuleOp) -> Result<AirModule, LowerError> {
    let body = module.get_body(ctx, 0);
    let mut funcs = Vec::new();
    for op in body.deref(ctx).iter(ctx) {
        if let Some(func) = Operation::get_op::<FuncOp>(op, ctx) {
            funcs.push(func);
        }
    }
    if funcs.len() != 1 {
        return Err(LowerError::ExpectedKernel);
    }
    let air_fn = lower_func(ctx, funcs[0])?;
    let mut air = default_air_module();
    air.source_filename = format!("{}.metal", air_fn.name);
    air.functions.push(air_fn);
    Ok(air)
}

fn lower_func(ctx: &Context, func: FuncOp) -> Result<AirFunction, LowerError> {
    let name = func.get_symbol_name(ctx).to_string();
    let entry = func.get_entry_block(ctx);
    let block = entry.deref(ctx);
    let num_args = block.get_num_arguments();
    if num_args != 3 {
        return Err(LowerError::UnsupportedSignature(name));
    }

    // MVP signature convention matching the current dialect builders / MSL frontend.
    let float_ptr = AirType::Ptr {
        pointee: Box::new(AirType::Float),
        addrspace: ADDRSPACE_DEVICE,
    };
    let args = vec![
        AirArg {
            name: "in".into(),
            ty: float_ptr.clone(),
            kind: ArgKind::Buffer {
                location: 0,
                access: BufferAccess::Read,
            },
        },
        AirArg {
            name: "out".into(),
            ty: float_ptr,
            kind: ArgKind::Buffer {
                location: 1,
                access: BufferAccess::ReadWrite,
            },
        },
        AirArg {
            name: "tid".into(),
            ty: AirType::Int(32),
            kind: ArgKind::ThreadPositionInGrid,
        },
    ];

    let mut val_map: HashMap<Value, Val> = HashMap::new();
    for i in 0..num_args {
        val_map.insert(block.get_argument(i), Val::Arg(i));
    }

    let mut body = Vec::new();
    let mut tmp = 0u32;
    let mut fresh = || {
        let n = format!("t{tmp}");
        tmp += 1;
        n
    };

    for op_ptr in block.iter(ctx) {
        lower_op(ctx, op_ptr, &mut val_map, &mut body, &mut fresh)?;
    }

    Ok(AirFunction {
        name,
        return_ty: AirType::Void,
        args,
        body,
    })
}

fn map_val(ctx: &Context, v: Value, val_map: &HashMap<Value, Val>) -> Result<Val, LowerError> {
    if let Some(val) = val_map.get(&v) {
        return Ok(val.clone());
    }
    // Constants may be referenced before we stored them if folding; treat as error.
    let _ = ctx;
    Err(LowerError::UnsupportedOp("unmapped value".into()))
}

fn lower_op(
    ctx: &Context,
    op_ptr: Ptr<Operation>,
    val_map: &mut HashMap<Value, Val>,
    body: &mut Vec<Inst>,
    fresh: &mut dyn FnMut() -> String,
) -> Result<(), LowerError> {
    if let Some(c) = Operation::get_op::<ConstantF32Op>(op_ptr, ctx) {
        let attr = c.get_attr_bits(ctx).ok_or(LowerError::MissingConstant)?;
        let bits = u32::try_from(APInt::from(attr.clone()).to_u64())
            .map_err(|_| LowerError::MissingConstant)?;
        val_map.insert(c.get_result(ctx), Val::F32(f32::from_bits(bits)));
        return Ok(());
    }
    if let Some(z) = Operation::get_op::<ZextOp>(op_ptr, ctx) {
        let dest = fresh();
        let src = map_val(ctx, z.get_operand(ctx), val_map)?;
        val_map.insert(z.get_result(ctx), Val::Local(dest.clone()));
        body.push(Inst::Zext {
            dest,
            src,
            to_bits: 64,
        });
        return Ok(());
    }
    if let Some(g) = Operation::get_op::<GepOp>(op_ptr, ctx) {
        let dest = fresh();
        let op = g.get_operation().deref(ctx);
        let ptr = map_val(ctx, op.get_operand(0), val_map)?;
        let index = map_val(ctx, op.get_operand(1), val_map)?;
        val_map.insert(g.get_result(ctx), Val::Local(dest.clone()));
        body.push(Inst::Gep {
            dest,
            elem_ty: AirType::Float,
            ptr,
            index,
        });
        return Ok(());
    }
    if let Some(l) = Operation::get_op::<LoadOp>(op_ptr, ctx) {
        let dest = fresh();
        let ptr = map_val(ctx, l.get_operand(ctx), val_map)?;
        val_map.insert(l.get_result(ctx), Val::Local(dest.clone()));
        body.push(Inst::Load {
            dest,
            ty: AirType::Float,
            ptr,
            align: 4,
        });
        return Ok(());
    }
    if let Some(a) = Operation::get_op::<FAddOp>(op_ptr, ctx) {
        return lower_binop(
            ctx,
            a.get_operation(),
            a.get_result(ctx),
            val_map,
            body,
            fresh,
            Bin::Add,
        );
    }
    if let Some(a) = Operation::get_op::<FSubOp>(op_ptr, ctx) {
        return lower_binop(
            ctx,
            a.get_operation(),
            a.get_result(ctx),
            val_map,
            body,
            fresh,
            Bin::Sub,
        );
    }
    if let Some(a) = Operation::get_op::<FMulOp>(op_ptr, ctx) {
        return lower_binop(
            ctx,
            a.get_operation(),
            a.get_result(ctx),
            val_map,
            body,
            fresh,
            Bin::Mul,
        );
    }
    if let Some(s) = Operation::get_op::<StoreOp>(op_ptr, ctx) {
        let op = s.get_operation().deref(ctx);
        let value = map_val(ctx, op.get_operand(0), val_map)?;
        let ptr = map_val(ctx, op.get_operand(1), val_map)?;
        body.push(Inst::Store {
            ty: AirType::Float,
            value,
            ptr,
            align: 4,
        });
        return Ok(());
    }
    if Operation::get_op::<ReturnOp>(op_ptr, ctx).is_some() {
        body.push(Inst::RetVoid);
        return Ok(());
    }
    // Ignore nested FuncOp/Module scaffolding if any.
    if Operation::get_op::<FuncOp>(op_ptr, ctx).is_some() {
        return Ok(());
    }
    let opid = Operation::get_opid(op_ptr, ctx);
    Err(LowerError::UnsupportedOp(opid.to_string()))
}

enum Bin {
    Add,
    Sub,
    Mul,
}

fn lower_binop(
    ctx: &Context,
    op_ptr: Ptr<Operation>,
    result: Value,
    val_map: &mut HashMap<Value, Val>,
    body: &mut Vec<Inst>,
    fresh: &mut dyn FnMut() -> String,
    kind: Bin,
) -> Result<(), LowerError> {
    let dest = fresh();
    let op = op_ptr.deref(ctx);
    let lhs = map_val(ctx, op.get_operand(0), val_map)?;
    let rhs = map_val(ctx, op.get_operand(1), val_map)?;
    val_map.insert(result, Val::Local(dest.clone()));
    body.push(match kind {
        Bin::Add => Inst::Fadd { dest, lhs, rhs },
        Bin::Sub => Inst::Fsub { dest, lhs, rhs },
        Bin::Mul => Inst::Fmul { dest, lhs, rhs },
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use dialect_metal::{build_add_one_module, build_scale_module};

    #[test]
    fn lower_add_one_walk() {
        let ctx = &mut Context::new();
        let module = build_add_one_module(ctx).expect("build");
        let air = lower_module(ctx, module).expect("lower");
        assert_eq!(air.functions[0].name, "add_one");
        assert_eq!(air.functions[0].args.len(), 3);
        assert!(
            air.functions[0]
                .body
                .iter()
                .any(|i| matches!(i, Inst::Fadd { .. })),
            "{:?}",
            air.functions[0].body
        );
    }

    #[test]
    fn lower_scale_walk() {
        let ctx = &mut Context::new();
        let module = build_scale_module(ctx).expect("build");
        let air = lower_module(ctx, module).expect("lower");
        assert_eq!(air.functions[0].name, "scale");
        assert!(
            air.functions[0]
                .body
                .iter()
                .any(|i| matches!(i, Inst::Fmul { .. })),
            "{:?}",
            air.functions[0].body
        );
    }
}
