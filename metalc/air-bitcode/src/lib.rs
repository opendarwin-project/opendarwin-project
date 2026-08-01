//! AIR module model, textual LLVM IR emission, and metallib packaging.
//!
//! Bitcode assembly for the MVP uses the host `metal-as` tool to produce the
//! typed-pointer AIR bitcode Apple's loader expects. The MTLB container is
//! always written by the pure-Rust [`metallib`] crate. A pure-Rust bitstream
//! writer can replace `metal-as` later without changing the [`AirModule`] API.

mod assemble;
mod module;
mod write_ll;

pub use assemble::{AssembleError, assemble_bitcode, emit_metallib};
pub use module::*;
pub use write_ll::write_llvm_ir;

/// Build the MVP `add_one` compute kernel as an [`AirModule`].
pub fn add_one_module() -> AirModule {
    let float_ptr = AirType::Ptr {
        pointee: Box::new(AirType::Float),
        addrspace: 1,
    };

    let mut m = AirModule::new(
        "air64_v29-apple-macosx27.0.0",
        "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32",
    );
    m.source_filename = "add_one.metal".into();
    m.air_version = (2, 9, 0);
    m.language_version = ("Metal".into(), 4, 1, 0);

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
