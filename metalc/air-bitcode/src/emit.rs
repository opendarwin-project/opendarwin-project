//! Emit typed-pointer Metal AIR bitcode from an [`AirModule`].

use std::collections::HashMap;

use crate::bitstream::BitstreamWriter;
use crate::codes::{
    bin_op, block, cast_op, cst, func, ident, linkage, md, module as modc, ty, vst,
};
use crate::module::*;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum TyKey {
    Void,
    Float,
    Int(u32),
    Metadata,
    Label,
    Ptr { pointee: Box<TyKey>, addrspace: u32 },
    Func { ret: Box<TyKey>, params: Vec<TyKey> },
}

fn air_ty(t: &AirType) -> TyKey {
    match t {
        AirType::Void => TyKey::Void,
        AirType::Float => TyKey::Float,
        AirType::Int(w) => TyKey::Int(*w),
        AirType::Ptr { pointee, addrspace } => TyKey::Ptr {
            pointee: Box::new(air_ty(pointee)),
            addrspace: *addrspace,
        },
    }
}

struct TypeTable {
    list: Vec<TyKey>,
}

impl TypeTable {
    fn new() -> Self {
        Self { list: Vec::new() }
    }

    fn intern(&mut self, key: TyKey) -> u64 {
        if let Some(i) = self.list.iter().position(|t| t == &key) {
            return i as u64;
        }
        match &key {
            TyKey::Ptr { pointee, .. } => {
                let p = (**pointee).clone();
                self.intern(p);
            }
            TyKey::Func { ret, params } => {
                let r = (**ret).clone();
                self.intern(r);
                for p in params.clone() {
                    self.intern(p);
                }
            }
            _ => {}
        }
        if let Some(i) = self.list.iter().position(|t| t == &key) {
            return i as u64;
        }
        self.list.push(key);
        (self.list.len() - 1) as u64
    }

    fn id_of(&self, key: &TyKey) -> u64 {
        self.list.iter().position(|t| t == key).unwrap() as u64
    }
}

fn encode_signed(v: i64) -> u64 {
    if v >= 0 {
        (v as u64) << 1
    } else {
        ((-v) as u64) << 1 | 1
    }
}

fn align_encoding(align: u32) -> u64 {
    u64::from(align.trailing_zeros()) + 1
}

/// Emit raw LLVM/AIR bitcode (`BC\xc0\xde` …) for `module`.
pub fn emit_bitcode(module: &AirModule) -> Vec<u8> {
    assert!(!module.functions.is_empty(), "module has no functions");

    let mut w = BitstreamWriter::new();
    w.emit(b'B' as u32, 8);
    w.emit(b'C' as u32, 8);
    w.emit(0xc0, 8);
    w.emit(0xde, 8);

    w.enter_subblock(block::IDENTIFICATION, 5);
    w.emit_string_record(ident::STRING, "MetalIR");
    w.emit_record(ident::EPOCH, &[0]);
    w.exit_block();

    let mut types = TypeTable::new();
    let float_ty = types.intern(TyKey::Float);
    let i32_ty = types.intern(TyKey::Int(32));
    let i64_ty = types.intern(TyKey::Int(64));
    let _void_ty = types.intern(TyKey::Void);
    let _meta_ty = types.intern(TyKey::Metadata);
    let _label_ty = types.intern(TyKey::Label);

    let mut fty_keys = Vec::new();
    for f in &module.functions {
        let params: Vec<TyKey> = f.args.iter().map(|a| air_ty(&a.ty)).collect();
        let ret = air_ty(&f.return_ty);
        let fty = TyKey::Func {
            ret: Box::new(ret),
            params,
        };
        types.intern(fty.clone());
        types.intern(TyKey::Ptr {
            pointee: Box::new(fty.clone()),
            addrspace: 0,
        });
        fty_keys.push(fty);
        for inst in &f.body {
            if let Inst::Gep { elem_ty, .. } = inst {
                types.intern(TyKey::Ptr {
                    pointee: Box::new(air_ty(elem_ty)),
                    addrspace: 1,
                });
            }
            if let Inst::Load { ty: t, .. } = inst {
                types.intern(air_ty(t));
            }
        }
    }

    // Module i32 constants for metadata.
    let mut mod_i32s: Vec<i32> = Vec::new();
    let mut intern_i32 = |v: i32| {
        if !mod_i32s.contains(&v) {
            mod_i32s.push(v);
        }
    };
    for v in [
        0,
        1,
        2,
        4,
        7,
        8,
        16,
        27,
        31,
        128,
        module.air_version.0 as i32,
        module.air_version.1 as i32,
        module.air_version.2 as i32,
        module.language_version.1 as i32,
        module.language_version.2 as i32,
        module.language_version.3 as i32,
    ] {
        intern_i32(v);
    }
    for f in &module.functions {
        for (i, a) in f.args.iter().enumerate() {
            intern_i32(i as i32);
            if let ArgKind::Buffer { location, .. } = a.kind {
                intern_i32(location as i32);
            }
        }
    }

    w.enter_subblock(block::MODULE, 4);
    w.emit_record(modc::VERSION, &[1]);

    // Types
    w.enter_subblock(block::TYPE, 4);
    w.emit_record(ty::NUMENTRY, &[types.list.len() as u64]);
    for t in types.list.clone() {
        match t {
            TyKey::Void => w.emit_record(ty::VOID, &[]),
            TyKey::Float => w.emit_record(ty::FLOAT, &[]),
            TyKey::Int(bits) => w.emit_record(ty::INTEGER, &[bits as u64]),
            TyKey::Metadata => w.emit_record(ty::METADATA, &[]),
            TyKey::Label => w.emit_record(ty::LABEL, &[]),
            TyKey::Ptr { pointee, addrspace } => {
                w.emit_record(ty::POINTER, &[types.id_of(&pointee), addrspace as u64]);
            }
            TyKey::Func { ret, params } => {
                let mut ops = vec![0u64, types.id_of(&ret)];
                for p in &params {
                    ops.push(types.id_of(p));
                }
                w.emit_record(ty::FUNCTION, &ops);
            }
        }
    }
    w.exit_block();

    w.emit_string_record(modc::TRIPLE, &module.triple);
    w.emit_string_record(modc::DATALAYOUT, &module.datalayout);
    if !module.source_filename.is_empty() {
        w.emit_string_record(modc::SOURCE_FILENAME, &module.source_filename);
    }

    for fty in &fty_keys {
        let fty_id = types.id_of(fty);
        let mut ops = vec![fty_id, 0, 0, linkage::EXTERNAL, 0, 0];
        ops.extend(std::iter::repeat_n(0u64, 10));
        ops.push(0);
        w.emit_record(modc::FUNCTION, &ops);
    }

    // Module constants
    w.enter_subblock(block::CONSTANTS, 5);
    w.emit_record(cst::SETTYPE, &[i32_ty]);
    for v in &mod_i32s {
        w.emit_record(cst::INTEGER, &[encode_signed(i64::from(*v))]);
    }
    w.exit_block();

    // Metadata kinds
    w.enter_subblock(block::METADATA_KIND, 3);
    for (i, name) in [
        "dbg",
        "tbaa",
        "prof",
        "fpmath",
        "range",
        "tbaa.struct",
        "invariant.load",
        "alias.scope",
        "noalias",
        "nontemporal",
        "llvm.mem.parallel_loop_access",
        "nonnull",
        "dereferenceable",
        "dereferenceable_or_null",
        "make.implicit",
        "unpredictable",
        "invariant.group",
        "align",
        "llvm.loop",
        "type",
        "section_prefix",
        "absolute_symbol",
        "associated",
        "callees",
        "irr_loop",
        "llvm.access.group",
        "callback",
        "llvm.preserve.access.index",
        "vcall_visibility",
        "noundef",
        "annotation",
        "heapallocsite",
        "air.function_groups",
    ]
    .iter()
    .enumerate()
    {
        let mut ops = vec![i as u64];
        ops.extend(name.bytes().map(|b| b as u64));
        w.emit_record(md::KIND, &ops);
    }
    w.exit_block();

    emit_metadata_block(&mut w, module, &types, &mod_i32s, &fty_keys[0]);

    w.enter_subblock(block::OPERAND_BUNDLE_TAGS, 3);
    for tag in [
        "deopt",
        "funclet",
        "gc-transition",
        "cfguardtarget",
        "preallocated",
        "gc-live",
        "clang.arc.attachedcall",
        "ptrauth",
    ] {
        w.emit_string_record(1, tag);
    }
    w.exit_block();

    w.enter_subblock(block::SYNC_SCOPE_NAMES, 2);
    w.emit_string_record(1, "singlethread");
    w.exit_block();

    for f in &module.functions {
        emit_function(&mut w, f, &types, mod_i32s.len(), float_ty, i32_ty, i64_ty);
    }

    w.enter_subblock(block::VALUE_SYMTAB, 4);
    for (i, f) in module.functions.iter().enumerate() {
        let mut ops = vec![i as u64];
        ops.extend(f.name.bytes().map(|b| b as u64));
        w.emit_record(vst::ENTRY, &ops);
    }
    w.exit_block();

    w.exit_block();
    w.into_bytes()
}

fn mod_const_id(mod_i32s: &[i32], v: i32) -> u64 {
    1 + mod_i32s.iter().position(|x| *x == v).unwrap() as u64
}

fn emit_metadata_block(
    w: &mut BitstreamWriter,
    module: &AirModule,
    types: &TypeTable,
    mod_i32s: &[i32],
    fty: &TyKey,
) {
    let f = &module.functions[0];
    let mut strings: Vec<String> = Vec::new();
    let mut intern_s = |s: &str| -> usize {
        if let Some(i) = strings.iter().position(|x| x == s) {
            return i;
        }
        strings.push(s.to_string());
        strings.len() - 1
    };

    for s in [
        "SDK Version",
        "wchar_size",
        "frame-pointer",
        "air.max_device_buffers",
        "air.max_constant_buffers",
        "air.max_threadgroup_buffers",
        "air.max_textures",
        "air.max_read_write_textures",
        "air.max_samplers",
        "air.buffer",
        "air.location_index",
        "air.read",
        "air.read_write",
        "air.write",
        "air.address_space",
        "air.arg_type_size",
        "air.arg_type_align_size",
        "air.arg_type_name",
        "air.arg_name",
        "float",
        "uint",
        "air.thread_position_in_grid",
        "air.compile.denorms_disable",
        "air.compile.fast_math_enable",
        "air.compile.framebuffer_fetch_enable",
        "metalc (OpenMetal AIR compiler)",
        "Metal",
    ] {
        let _ = intern_s(s);
    }
    let _ = intern_s(&module.source_filename);
    for a in &f.args {
        let _ = intern_s(&a.name);
    }

    // Values: [0]=function, then i32 constants in mod_i32s order
    let fptr = TyKey::Ptr {
        pointee: Box::new(fty.clone()),
        addrspace: 0,
    };
    let fptr_ty = types.id_of(&fptr);
    let i32_ty = types.id_of(&TyKey::Int(32));
    let mut values: Vec<(u64, u64)> = vec![(fptr_ty, 0)];
    let mut i32_val_slot: HashMap<i32, usize> = HashMap::new();
    for &v in mod_i32s {
        i32_val_slot.insert(v, values.len());
        values.push((i32_ty, mod_const_id(mod_i32s, v)));
    }

    #[derive(Clone)]
    enum Op {
        S(String),
        I32(i32),
        Fn,
        N(usize),
    }
    let mut nodes: Vec<Vec<Op>> = Vec::new();
    let push_flag = |nodes: &mut Vec<Vec<Op>>, k: i32, name: &str, v: i32| {
        nodes.push(vec![Op::I32(k), Op::S(name.into()), Op::I32(v)]);
    };

    nodes.push(vec![
        Op::I32(2),
        Op::S("SDK Version".into()),
        Op::I32(27),
        Op::I32(0),
    ]);
    push_flag(&mut nodes, 1, "wchar_size", 4);
    push_flag(&mut nodes, 7, "frame-pointer", 2);
    push_flag(&mut nodes, 7, "air.max_device_buffers", 31);
    push_flag(&mut nodes, 7, "air.max_constant_buffers", 31);
    push_flag(&mut nodes, 7, "air.max_threadgroup_buffers", 31);
    push_flag(&mut nodes, 7, "air.max_textures", 128);
    push_flag(&mut nodes, 7, "air.max_read_write_textures", 8);
    push_flag(&mut nodes, 7, "air.max_samplers", 16);

    let kernel_i = nodes.len();
    nodes.push(vec![]);
    let empty_i = nodes.len();
    nodes.push(vec![]);
    let list_i = nodes.len();
    nodes.push(vec![]);

    let mut arg_is = Vec::new();
    for (i, a) in f.args.iter().enumerate() {
        arg_is.push(nodes.len());
        match &a.kind {
            ArgKind::Buffer { location, access } => {
                let access_s = match access {
                    BufferAccess::Read => "air.read",
                    BufferAccess::Write => "air.write",
                    BufferAccess::ReadWrite => "air.read_write",
                };
                nodes.push(vec![
                    Op::I32(i as i32),
                    Op::S("air.buffer".into()),
                    Op::S("air.location_index".into()),
                    Op::I32(*location as i32),
                    Op::I32(1),
                    Op::S(access_s.into()),
                    Op::S("air.address_space".into()),
                    Op::I32(1),
                    Op::S("air.arg_type_size".into()),
                    Op::I32(4),
                    Op::S("air.arg_type_align_size".into()),
                    Op::I32(4),
                    Op::S("air.arg_type_name".into()),
                    Op::S("float".into()),
                    Op::S("air.arg_name".into()),
                    Op::S(a.name.clone()),
                ]);
            }
            ArgKind::ThreadPositionInGrid => {
                nodes.push(vec![
                    Op::I32(i as i32),
                    Op::S("air.thread_position_in_grid".into()),
                    Op::S("air.arg_type_name".into()),
                    Op::S("uint".into()),
                    Op::S("air.arg_name".into()),
                    Op::S(a.name.clone()),
                ]);
            }
        }
    }
    nodes[list_i] = arg_is.iter().map(|i| Op::N(*i)).collect();
    nodes[kernel_i] = vec![Op::Fn, Op::N(empty_i), Op::N(list_i)];

    let c0 = nodes.len();
    nodes.push(vec![Op::S("air.compile.denorms_disable".into())]);
    let c1 = nodes.len();
    nodes.push(vec![Op::S("air.compile.fast_math_enable".into())]);
    let c2 = nodes.len();
    nodes.push(vec![Op::S("air.compile.framebuffer_fetch_enable".into())]);
    let ident_i = nodes.len();
    nodes.push(vec![Op::S("metalc (OpenMetal AIR compiler)".into())]);
    let ver_i = nodes.len();
    nodes.push(vec![
        Op::I32(module.air_version.0 as i32),
        Op::I32(module.air_version.1 as i32),
        Op::I32(module.air_version.2 as i32),
    ]);
    let lang_i = nodes.len();
    nodes.push(vec![
        Op::S("Metal".into()),
        Op::I32(module.language_version.1 as i32),
        Op::I32(module.language_version.2 as i32),
        Op::I32(module.language_version.3 as i32),
    ]);
    let src_i = nodes.len();
    nodes.push(vec![Op::S(module.source_filename.clone())]);

    let s_base = strings.len();
    let v_base = s_base + values.len();

    let op_id = |op: &Op| -> u64 {
        match op {
            Op::S(s) => 1 + strings.iter().position(|x| x == s).unwrap() as u64,
            Op::I32(v) => 1 + s_base as u64 + i32_val_slot[v] as u64,
            Op::Fn => 1 + s_base as u64, // values[0]
            Op::N(i) => 1 + v_base as u64 + *i as u64,
        }
    };

    w.enter_subblock(block::METADATA, 4);
    for s in &strings {
        w.emit_string_record(md::STRING_OLD, s);
    }
    for (t, v) in &values {
        w.emit_record(md::VALUE, &[*t, *v]);
    }
    for node in &nodes {
        let ops: Vec<u64> = node.iter().map(op_id).collect();
        w.emit_record(md::NODE, &ops);
    }

    let named = |w: &mut BitstreamWriter, name: &str, kids: &[usize]| {
        w.emit_string_record(md::NAME, name);
        // NAMED_NODE uses 0-based indices into the concatenated MD pool
        // (strings | values | nodes), matching MetadataWriter.cpp.
        let ops: Vec<u64> = kids.iter().map(|i| (v_base + *i) as u64).collect();
        w.emit_record(md::NAMED_NODE, &ops);
    };
    named(w, "llvm.module.flags", &[0, 1, 2, 3, 4, 5, 6, 7, 8]);
    named(w, "air.kernel", &[kernel_i]);
    named(w, "air.compile_options", &[c0, c1, c2]);
    named(w, "llvm.ident", &[ident_i]);
    named(w, "air.version", &[ver_i]);
    named(w, "air.language_version", &[lang_i]);
    named(w, "air.source_file_name", &[src_i]);
    w.exit_block();
}

fn emit_function(
    w: &mut BitstreamWriter,
    f: &AirFunction,
    types: &TypeTable,
    mod_const_count: usize,
    float_ty: u64,
    i32_ty: u64,
    i64_ty: u64,
) {
    w.enter_subblock(block::FUNCTION, 5);
    w.emit_record(func::DECLAREBLOCKS, &[1]);

    let mut f32s: Vec<f32> = Vec::new();
    let mut note_f32 = |v: f32| {
        if !f32s.iter().any(|x| *x == v) {
            f32s.push(v);
        }
    };
    let walk = |val: &Val, note_f32: &mut dyn FnMut(f32)| {
        if let Val::F32(v) = val {
            note_f32(*v);
        }
    };
    for inst in &f.body {
        match inst {
            Inst::Zext { src, .. } => walk(src, &mut note_f32),
            Inst::Gep { ptr, index, .. } => {
                walk(ptr, &mut note_f32);
                walk(index, &mut note_f32);
            }
            Inst::Load { ptr, .. } => walk(ptr, &mut note_f32),
            Inst::Store { value, ptr, .. } => {
                walk(value, &mut note_f32);
                walk(ptr, &mut note_f32);
            }
            Inst::Fadd { lhs, rhs, .. }
            | Inst::Fsub { lhs, rhs, .. }
            | Inst::Fmul { lhs, rhs, .. } => {
                walk(lhs, &mut note_f32);
                walk(rhs, &mut note_f32);
            }
            Inst::RetVoid => {}
        }
    }

    if !f32s.is_empty() {
        w.enter_subblock(block::CONSTANTS, 5);
        w.emit_record(cst::SETTYPE, &[float_ty]);
        for v in &f32s {
            w.emit_record(cst::FLOAT, &[u64::from(v.to_bits())]);
        }
        w.exit_block();
    }

    let arg0 = 1 + mod_const_count;
    let fc0 = arg0 + f.args.len();
    let mut locals: HashMap<String, u64> = HashMap::new();
    let mut cur = (fc0 + f32s.len()) as u64;

    let abs_val = |val: &Val, locals: &HashMap<String, u64>| -> u64 {
        match val {
            Val::Arg(i) => (arg0 + *i) as u64,
            Val::Local(n) => locals[n],
            Val::F32(v) => {
                let i = f32s.iter().position(|x| x == v).unwrap();
                (fc0 + i) as u64
            }
            Val::I32(_) | Val::I64(_) => panic!("unexpected int immediate"),
        }
    };

    for inst in &f.body {
        let rel = |abs: u64| cur - abs;
        match inst {
            Inst::Zext { dest, src, to_bits } => {
                let dest_ty = if *to_bits == 64 { i64_ty } else { i32_ty };
                w.emit_record(
                    func::INST_CAST,
                    &[rel(abs_val(src, &locals)), dest_ty, cast_op::ZEXT],
                );
                locals.insert(dest.clone(), cur);
                cur += 1;
            }
            Inst::Gep {
                dest,
                elem_ty,
                ptr,
                index,
            } => {
                let src_ty = types.id_of(&air_ty(elem_ty));
                w.emit_record(
                    func::INST_GEP,
                    &[
                        1,
                        src_ty,
                        rel(abs_val(ptr, &locals)),
                        rel(abs_val(index, &locals)),
                    ],
                );
                locals.insert(dest.clone(), cur);
                cur += 1;
            }
            Inst::Load {
                dest,
                ty: load_ty,
                ptr,
                align,
            } => {
                let lty = types.id_of(&air_ty(load_ty));
                w.emit_record(
                    func::INST_LOAD,
                    &[rel(abs_val(ptr, &locals)), lty, align_encoding(*align), 0],
                );
                locals.insert(dest.clone(), cur);
                cur += 1;
            }
            Inst::Fadd { dest, lhs, rhs } => {
                w.emit_record(
                    func::INST_BINOP,
                    &[
                        rel(abs_val(lhs, &locals)),
                        rel(abs_val(rhs, &locals)),
                        bin_op::ADD,
                        0,
                    ],
                );
                locals.insert(dest.clone(), cur);
                cur += 1;
            }
            Inst::Fsub { dest, lhs, rhs } => {
                w.emit_record(
                    func::INST_BINOP,
                    &[
                        rel(abs_val(lhs, &locals)),
                        rel(abs_val(rhs, &locals)),
                        bin_op::SUB,
                        0,
                    ],
                );
                locals.insert(dest.clone(), cur);
                cur += 1;
            }
            Inst::Fmul { dest, lhs, rhs } => {
                w.emit_record(
                    func::INST_BINOP,
                    &[
                        rel(abs_val(lhs, &locals)),
                        rel(abs_val(rhs, &locals)),
                        bin_op::MUL,
                        0,
                    ],
                );
                locals.insert(dest.clone(), cur);
                cur += 1;
            }
            Inst::Store {
                value, ptr, align, ..
            } => {
                w.emit_record(
                    func::INST_STORE,
                    &[
                        rel(abs_val(ptr, &locals)),
                        rel(abs_val(value, &locals)),
                        align_encoding(*align),
                        0,
                    ],
                );
            }
            Inst::RetVoid => {
                w.emit_record(func::INST_RET, &[]);
            }
        }
    }

    w.exit_block();
}
