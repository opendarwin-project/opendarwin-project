//! Structured AIR module (subset sufficient for MVP compute kernels).

use crate::target::{AIR_DATALAYOUT, AirTarget};

#[derive(Debug, Clone, PartialEq)]
pub enum AirType {
    Void,
    Float,
    Int(u32),
    Ptr {
        pointee: Box<AirType>,
        addrspace: u32,
    },
}

impl AirType {
    pub fn llvm_str(&self) -> String {
        match self {
            AirType::Void => "void".into(),
            AirType::Float => "float".into(),
            AirType::Int(w) => format!("i{w}"),
            AirType::Ptr { pointee, addrspace } => {
                if *addrspace == 0 {
                    format!("{}*", pointee.llvm_str())
                } else {
                    format!("{} addrspace({addrspace})*", pointee.llvm_str())
                }
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BufferAccess {
    Read,
    ReadWrite,
    Write,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ArgKind {
    Buffer { location: u32, access: BufferAccess },
    ThreadPositionInGrid,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AirArg {
    pub name: String,
    pub ty: AirType,
    pub kind: ArgKind,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Val {
    Arg(usize),
    Local(String),
    F32(f32),
    I32(i32),
    I64(i64),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Inst {
    Zext {
        dest: String,
        src: Val,
        to_bits: u32,
    },
    Gep {
        dest: String,
        elem_ty: AirType,
        ptr: Val,
        index: Val,
    },
    Load {
        dest: String,
        ty: AirType,
        ptr: Val,
        align: u32,
    },
    Store {
        ty: AirType,
        value: Val,
        ptr: Val,
        align: u32,
    },
    Fadd {
        dest: String,
        lhs: Val,
        rhs: Val,
    },
    Fsub {
        dest: String,
        lhs: Val,
        rhs: Val,
    },
    Fmul {
        dest: String,
        lhs: Val,
        rhs: Val,
    },
    RetVoid,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AirFunction {
    pub name: String,
    pub return_ty: AirType,
    pub args: Vec<AirArg>,
    pub body: Vec<Inst>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AirModule {
    pub triple: String,
    pub datalayout: String,
    pub source_filename: String,
    /// macOS version embedded in SDK Version metadata and the MTLB header.
    pub macos_version: (u32, u32, u32),
    pub air_version: (u32, u32, u32),
    pub language_version: (String, u32, u32, u32),
    pub functions: Vec<AirFunction>,
}

impl AirModule {
    pub fn new(triple: impl Into<String>, datalayout: impl Into<String>) -> Self {
        let target = AirTarget::resolve();
        Self {
            triple: triple.into(),
            datalayout: datalayout.into(),
            source_filename: "metalc.metal".into(),
            macos_version: target.macos_version(),
            air_version: target.air_version(),
            language_version: ("Metal".into(), 4, 1, 0),
            functions: Vec::new(),
        }
    }

    /// Build an empty module for the resolved (or given) [`AirTarget`].
    pub fn for_target(target: AirTarget) -> Self {
        Self {
            triple: target.triple(),
            datalayout: AIR_DATALAYOUT.into(),
            source_filename: "metalc.metal".into(),
            macos_version: target.macos_version(),
            air_version: target.air_version(),
            language_version: ("Metal".into(), 4, 1, 0),
            functions: Vec::new(),
        }
    }

    pub fn kernel_names(&self) -> Vec<&str> {
        self.functions.iter().map(|f| f.name.as_str()).collect()
    }
}
