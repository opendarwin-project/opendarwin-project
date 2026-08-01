//! High-level Metal compute dialect built on pliron.

use awint::bw;
use pliron::{
    builtin::{
        attributes::IntegerAttr,
        op_interfaces::{
            NOpdsInterface, NResultsInterface, OneOpdInterface, OneResultInterface,
            SingleBlockRegionInterface,
        },
        ops::{FuncOp, ModuleOp},
        types::{FunctionType, IntegerType, Signedness},
    },
    context::Context,
    derive::pliron_op,
    irbuild::{
        inserter::{IRInserter, Inserter},
        listener::DummyListener,
    },
    op::Op,
    operation::Operation,
    result::Result,
    r#type::TypeHandle,
    utils::apint::APInt,
    value::Value,
};

type OpInserter = IRInserter<DummyListener>;

#[pliron_op(
    name = "metal.constant_f32",
    format = "attr($bits, $IntegerAttr) ` : ` type($0)",
    interfaces = [NOpdsInterface<0>, OneResultInterface],
    attributes = (bits: IntegerAttr),
    verifier = "succ",
)]
pub struct ConstantF32Op;

impl ConstantF32Op {
    pub fn new(ctx: &mut Context, value: f32) -> Self {
        let i32_ty = IntegerType::get(ctx, 32, Signedness::Signless);
        let bits = value.to_bits();
        let attr = IntegerAttr::new(i32_ty, APInt::from_u64(u64::from(bits), bw(32)));
        let op = Operation::new(
            ctx,
            Self::get_concrete_op_info(),
            vec![i32_ty.into()],
            vec![],
            vec![],
            0,
        );
        let op = ConstantF32Op { op };
        op.set_attr_bits(ctx, attr);
        op
    }
}

#[pliron_op(
    name = "metal.fadd",
    format = "$0 `, ` $1 ` : ` type($0)",
    interfaces = [NOpdsInterface<2>, OneResultInterface],
    verifier = "succ",
)]
pub struct FAddOp;

impl FAddOp {
    pub fn new(ctx: &mut Context, lhs: Value, rhs: Value, ty: TypeHandle) -> Self {
        FAddOp {
            op: Operation::new(
                ctx,
                Self::get_concrete_op_info(),
                vec![ty],
                vec![lhs, rhs],
                vec![],
                0,
            ),
        }
    }
}

#[pliron_op(
    name = "metal.fsub",
    format = "$0 `, ` $1 ` : ` type($0)",
    interfaces = [NOpdsInterface<2>, OneResultInterface],
    verifier = "succ",
)]
pub struct FSubOp;

impl FSubOp {
    pub fn new(ctx: &mut Context, lhs: Value, rhs: Value, ty: TypeHandle) -> Self {
        FSubOp {
            op: Operation::new(
                ctx,
                Self::get_concrete_op_info(),
                vec![ty],
                vec![lhs, rhs],
                vec![],
                0,
            ),
        }
    }
}

#[pliron_op(
    name = "metal.fmul",
    format = "$0 `, ` $1 ` : ` type($0)",
    interfaces = [NOpdsInterface<2>, OneResultInterface],
    verifier = "succ",
)]
pub struct FMulOp;

impl FMulOp {
    pub fn new(ctx: &mut Context, lhs: Value, rhs: Value, ty: TypeHandle) -> Self {
        FMulOp {
            op: Operation::new(
                ctx,
                Self::get_concrete_op_info(),
                vec![ty],
                vec![lhs, rhs],
                vec![],
                0,
            ),
        }
    }
}

#[pliron_op(
    name = "metal.load",
    format = "$0 ` : ` type($0)",
    interfaces = [OneOpdInterface, OneResultInterface],
    verifier = "succ",
)]
pub struct LoadOp;

impl LoadOp {
    pub fn new(ctx: &mut Context, ptr: Value, result_ty: TypeHandle) -> Self {
        LoadOp {
            op: Operation::new(
                ctx,
                Self::get_concrete_op_info(),
                vec![result_ty],
                vec![ptr],
                vec![],
                0,
            ),
        }
    }
}

#[pliron_op(
    name = "metal.store",
    format = "$0 `, ` $1",
    interfaces = [NOpdsInterface<2>, NResultsInterface<0>],
    verifier = "succ",
)]
pub struct StoreOp;

impl StoreOp {
    pub fn new(ctx: &mut Context, value: Value, ptr: Value) -> Self {
        StoreOp {
            op: Operation::new(
                ctx,
                Self::get_concrete_op_info(),
                vec![],
                vec![value, ptr],
                vec![],
                0,
            ),
        }
    }
}

#[pliron_op(
    name = "metal.gep",
    format = "$0 `[` $1 `]` ` : ` type($0)",
    interfaces = [NOpdsInterface<2>, OneResultInterface],
    verifier = "succ",
)]
pub struct GepOp;

impl GepOp {
    pub fn new(ctx: &mut Context, ptr: Value, index: Value, result_ty: TypeHandle) -> Self {
        GepOp {
            op: Operation::new(
                ctx,
                Self::get_concrete_op_info(),
                vec![result_ty],
                vec![ptr, index],
                vec![],
                0,
            ),
        }
    }
}

#[pliron_op(
    name = "metal.zext",
    format = "$0 ` : ` type($0)",
    interfaces = [OneOpdInterface, OneResultInterface],
    verifier = "succ",
)]
pub struct ZextOp;

impl ZextOp {
    pub fn new(ctx: &mut Context, src: Value, result_ty: TypeHandle) -> Self {
        ZextOp {
            op: Operation::new(
                ctx,
                Self::get_concrete_op_info(),
                vec![result_ty],
                vec![src],
                vec![],
                0,
            ),
        }
    }
}

#[pliron_op(
    name = "metal.return",
    format,
    interfaces = [NOpdsInterface<0>, NResultsInterface<0>],
    verifier = "succ",
)]
pub struct ReturnOp;

impl ReturnOp {
    pub fn new(ctx: &mut Context) -> Self {
        ReturnOp {
            op: Operation::new(ctx, Self::get_concrete_op_info(), vec![], vec![], vec![], 0),
        }
    }
}

/// Build the MVP `add_one` kernel as a pliron [`ModuleOp`].
pub fn build_add_one_module(ctx: &mut Context) -> Result<ModuleOp> {
    build_binary_kernel(ctx, "add_one", BinKind::Add, 1.0)
}

/// Build a `scale` kernel: `out[tid] = in[tid] * 2.0`.
pub fn build_scale_module(ctx: &mut Context) -> Result<ModuleOp> {
    build_binary_kernel(ctx, "scale", BinKind::Mul, 2.0)
}

enum BinKind {
    Add,
    Mul,
}

fn build_binary_kernel(ctx: &mut Context, name: &str, kind: BinKind, imm: f32) -> Result<ModuleOp> {
    let i32_ty = IntegerType::get(ctx, 32, Signedness::Signless);
    let i64_ty = IntegerType::get(ctx, 64, Signedness::Signless);
    let ptr_ty = i64_ty;

    let func_ty = FunctionType::get(
        ctx,
        vec![ptr_ty.into(), ptr_ty.into(), i32_ty.into()],
        vec![],
    );
    let module_name = format!("{name}_mod");
    let module = ModuleOp::new(ctx, module_name.as_str().try_into().expect("id"));
    let func = FuncOp::new(ctx, name.try_into().expect("id"), func_ty);
    module.append_operation(ctx, func.get_operation(), 0);

    let entry = func.get_entry_block(ctx);
    let mut ins = OpInserter::new_at_block_end(entry);

    let (in_ptr, out_ptr, tid) = {
        let block = entry.deref(ctx);
        (
            block.get_argument(0),
            block.get_argument(1),
            block.get_argument(2),
        )
    };

    let tid64 = ZextOp::new(ctx, tid, i64_ty.into());
    ins.append_op(ctx, &tid64);
    let tid64_v = tid64.get_result(ctx);

    let in_gep = GepOp::new(ctx, in_ptr, tid64_v, ptr_ty.into());
    ins.append_op(ctx, &in_gep);
    let in_elem = in_gep.get_result(ctx);

    let loaded = LoadOp::new(ctx, in_elem, i32_ty.into());
    ins.append_op(ctx, &loaded);
    let v = loaded.get_result(ctx);

    let imm_op = ConstantF32Op::new(ctx, imm);
    ins.append_op(ctx, &imm_op);
    let imm_v = imm_op.get_result(ctx);

    let result = match kind {
        BinKind::Add => {
            let sum = FAddOp::new(ctx, v, imm_v, i32_ty.into());
            ins.append_op(ctx, &sum);
            sum.get_result(ctx)
        }
        BinKind::Mul => {
            let prod = FMulOp::new(ctx, v, imm_v, i32_ty.into());
            ins.append_op(ctx, &prod);
            prod.get_result(ctx)
        }
    };

    let out_gep = GepOp::new(ctx, out_ptr, tid64_v, ptr_ty.into());
    ins.append_op(ctx, &out_gep);
    let out_elem = out_gep.get_result(ctx);

    let st = StoreOp::new(ctx, result, out_elem);
    ins.append_op(ctx, &st);

    let ret = ReturnOp::new(ctx);
    ins.append_op(ctx, &ret);

    Ok(module)
}

/// Dump a module via pliron's printer.
pub fn dump_module(ctx: &Context, module: ModuleOp) -> String {
    use pliron::printable::Printable;
    module.disp(ctx).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_and_dump_add_one() {
        let ctx = &mut Context::new();
        let module = build_add_one_module(ctx).expect("build");
        let s = dump_module(ctx, module);
        assert!(s.contains("add_one") || s.contains("metal."), "{s}");
    }
}
