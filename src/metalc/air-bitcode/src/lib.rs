//! AIR module model, textual LLVM IR emission, and metallib packaging.
//!
//! Typed-pointer AIR bitcode is emitted by a pure-Rust bitstream writer
//! ([`emit_bitcode`]). The MTLB container is written by [`metallib`].

mod assemble;
mod bitstream;
mod codes;
mod emit;
mod module;
mod target;
mod write_ll;

pub use assemble::{AssembleError, emit_metallib};
pub use emit::emit_bitcode;
pub use module::*;
pub use target::{AIR_DATALAYOUT, AirTarget};
pub use write_ll::write_llvm_ir;

/// Build the MVP `add_one` compute kernel as an [`AirModule`].
pub fn add_one_module() -> AirModule {
    let float_ptr = AirType::Ptr {
        pointee: Box::new(AirType::Float),
        addrspace: 1,
    };

    let mut m = AirModule::for_target(AirTarget::resolve());
    m.source_filename = "add_one.metal".into();

    m.functions.push(AirFunction {
        name: "add_one".into(),
        return_ty: AirType::Void,
        args: vec![
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
        ],
        body: vec![
            Inst::Zext {
                dest: "tid64".into(),
                src: Val::Arg(2),
                to_bits: 64,
            },
            Inst::Gep {
                dest: "in_ptr".into(),
                elem_ty: AirType::Float,
                ptr: Val::Arg(0),
                index: Val::Local("tid64".into()),
            },
            Inst::Load {
                dest: "v".into(),
                ty: AirType::Float,
                ptr: Val::Local("in_ptr".into()),
                align: 4,
            },
            Inst::Fadd {
                dest: "sum".into(),
                lhs: Val::Local("v".into()),
                rhs: Val::F32(1.0),
            },
            Inst::Gep {
                dest: "out_ptr".into(),
                elem_ty: AirType::Float,
                ptr: Val::Arg(1),
                index: Val::Local("tid64".into()),
            },
            Inst::Store {
                ty: AirType::Float,
                value: Val::Local("sum".into()),
                ptr: Val::Local("out_ptr".into()),
                align: 4,
            },
            Inst::RetVoid,
        ],
    });
    m
}
