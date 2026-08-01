//! LLVM 14 / Metal AIR bitcode numeric constants (subset).

pub mod block {
    pub const MODULE: u32 = 8;
    pub const CONSTANTS: u32 = 11;
    pub const FUNCTION: u32 = 12;
    pub const IDENTIFICATION: u32 = 13;
    pub const VALUE_SYMTAB: u32 = 14;
    pub const METADATA: u32 = 15;
    pub const TYPE: u32 = 17;
    pub const OPERAND_BUNDLE_TAGS: u32 = 21;
    pub const METADATA_KIND: u32 = 22;
    pub const SYNC_SCOPE_NAMES: u32 = 26;
}

pub mod ident {
    pub const STRING: u32 = 1;
    pub const EPOCH: u32 = 2;
}

pub mod module {
    pub const VERSION: u32 = 1;
    pub const TRIPLE: u32 = 2;
    pub const DATALAYOUT: u32 = 3;
    pub const FUNCTION: u32 = 8;
    pub const SOURCE_FILENAME: u32 = 16;
}

pub mod ty {
    pub const NUMENTRY: u32 = 1;
    pub const VOID: u32 = 2;
    pub const FLOAT: u32 = 3;
    pub const LABEL: u32 = 5;
    pub const INTEGER: u32 = 7;
    pub const POINTER: u32 = 8;
    pub const METADATA: u32 = 16;
    pub const FUNCTION: u32 = 21;
}

pub mod cst {
    pub const SETTYPE: u32 = 1;
    pub const INTEGER: u32 = 4;
    pub const FLOAT: u32 = 6;
}

pub mod func {
    pub const DECLAREBLOCKS: u32 = 1;
    pub const INST_BINOP: u32 = 2;
    pub const INST_CAST: u32 = 3;
    pub const INST_RET: u32 = 10;
    pub const INST_LOAD: u32 = 20;
    pub const INST_GEP: u32 = 43;
    pub const INST_STORE: u32 = 44;
}

pub mod md {
    pub const STRING_OLD: u32 = 1;
    pub const VALUE: u32 = 2;
    pub const NODE: u32 = 3;
    pub const NAME: u32 = 4;
    pub const KIND: u32 = 6;
    pub const NAMED_NODE: u32 = 10;
}

pub mod vst {
    pub const ENTRY: u32 = 1;
}

pub mod cast_op {
    pub const ZEXT: u64 = 1;
}

pub mod bin_op {
    pub const ADD: u64 = 0; // also FAdd
    pub const SUB: u64 = 1; // also FSub
    pub const MUL: u64 = 2; // also FMul
}

pub mod linkage {
    pub const EXTERNAL: u64 = 0;
}
