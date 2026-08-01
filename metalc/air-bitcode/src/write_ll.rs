//! Emit textual LLVM IR in AIR dialect (typed pointers + air.* metadata).

use crate::module::*;

fn val_str(v: &Val, f: &AirFunction) -> String {
    match v {
        Val::Arg(i) => format!("%{}", f.args[*i].name),
        Val::Local(n) => format!("%{n}"),
        Val::F32(x) => {
            // LLVM prints floats in scientific hex-ish; decimal is accepted by metal-as.
            if *x == 1.0 {
                "1.000000e+00".into()
            } else {
                format!("{x:?}")
            }
        }
        Val::I32(x) => format!("{x}"),
        Val::I64(x) => format!("{x}"),
    }
}

/// Write an AIR-shaped LLVM IR module as text.
pub fn write_llvm_ir(module: &AirModule) -> String {
    let mut out = String::new();
    out.push_str(&format!("; ModuleID = '{}'\n", module.source_filename));
    out.push_str(&format!(
        "source_filename = \"{}\"\n",
        module.source_filename
    ));
    out.push_str(&format!("target datalayout = \"{}\"\n", module.datalayout));
    out.push_str(&format!("target triple = \"{}\"\n\n", module.triple));

    for (fi, f) in module.functions.iter().enumerate() {
        let params: Vec<String> = f
            .args
            .iter()
            .map(|a| {
                let attr = match &a.kind {
                    ArgKind::Buffer { access, .. } => match access {
                        BufferAccess::Read => " nocapture noundef readonly \"air-buffer-no-alias\"",
                        BufferAccess::Write => {
                            " nocapture noundef writeonly \"air-buffer-no-alias\""
                        }
                        // Match Apple MSL: writeonly attr + air.read_write metadata.
                        BufferAccess::ReadWrite => {
                            " nocapture noundef writeonly \"air-buffer-no-alias\""
                        }
                    },
                    ArgKind::ThreadPositionInGrid => " noundef",
                };
                format!("{}{} %{}", a.ty.llvm_str(), attr, a.name)
            })
            .collect();
        out.push_str(&format!(
            "define {} @{}({}) local_unnamed_addr #0 {{\n",
            f.return_ty.llvm_str(),
            f.name,
            params.join(", ")
        ));

        for inst in &f.body {
            match inst {
                Inst::Zext { dest, src, to_bits } => {
                    let src_ty = match src {
                        Val::Arg(i) => f.args[*i].ty.llvm_str(),
                        _ => "i32".into(),
                    };
                    out.push_str(&format!(
                        "  %{dest} = zext {src_ty} {} to i{to_bits}\n",
                        val_str(src, f)
                    ));
                }
                Inst::Gep {
                    dest,
                    elem_ty,
                    ptr,
                    index,
                } => {
                    let ptr_ty = match ptr {
                        Val::Arg(i) => f.args[*i].ty.llvm_str(),
                        Val::Local(_) => {
                            // Reconstruct pointer type from elem + addrspace 1 for MVP.
                            format!("{} addrspace(1)*", elem_ty.llvm_str())
                        }
                        _ => elem_ty.llvm_str(),
                    };
                    out.push_str(&format!(
                        "  %{dest} = getelementptr inbounds {}, {ptr_ty} {}, i64 {}\n",
                        elem_ty.llvm_str(),
                        val_str(ptr, f),
                        val_str(index, f)
                    ));
                }
                Inst::Load {
                    dest,
                    ty,
                    ptr,
                    align,
                } => {
                    let ptr_ty = format!("{} addrspace(1)*", ty.llvm_str());
                    out.push_str(&format!(
                        "  %{dest} = load {}, {ptr_ty} {}, align {align}\n",
                        ty.llvm_str(),
                        val_str(ptr, f)
                    ));
                }
                Inst::Store {
                    ty,
                    value,
                    ptr,
                    align,
                } => {
                    let ptr_ty = format!("{} addrspace(1)*", ty.llvm_str());
                    out.push_str(&format!(
                        "  store {} {}, {ptr_ty} {}, align {align}\n",
                        ty.llvm_str(),
                        val_str(value, f),
                        val_str(ptr, f)
                    ));
                }
                Inst::Fadd { dest, lhs, rhs } => {
                    out.push_str(&format!(
                        "  %{dest} = fadd fast float {}, {}\n",
                        val_str(lhs, f),
                        val_str(rhs, f)
                    ));
                }
                Inst::Fsub { dest, lhs, rhs } => {
                    out.push_str(&format!(
                        "  %{dest} = fsub fast float {}, {}\n",
                        val_str(lhs, f),
                        val_str(rhs, f)
                    ));
                }
                Inst::Fmul { dest, lhs, rhs } => {
                    out.push_str(&format!(
                        "  %{dest} = fmul fast float {}, {}\n",
                        val_str(lhs, f),
                        val_str(rhs, f)
                    ));
                }
                Inst::RetVoid => out.push_str("  ret void\n"),
            }
        }
        out.push_str("}\n\n");

        // Attributes + metadata (once, after first function — emit at end).
        let _ = fi;
    }

    out.push_str("attributes #0 = { nounwind \"frame-pointer\"=\"all\" \"no-builtins\" \"unsafe-fp-math\"=\"true\" }\n\n");

    // Named metadata
    out.push_str("!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}\n");
    if !module.functions.is_empty() {
        out.push_str("!air.kernel = !{!9}\n");
    }
    out.push_str("!air.compile_options = !{!15, !16, !17}\n");
    out.push_str("!llvm.ident = !{!18}\n");
    out.push_str("!air.version = !{!19}\n");
    out.push_str("!air.language_version = !{!20}\n");
    out.push_str("!air.source_file_name = !{!21}\n\n");

    out.push_str("!0 = !{i32 2, !\"SDK Version\", [2 x i32] [i32 27, i32 0]}\n");
    out.push_str("!1 = !{i32 1, !\"wchar_size\", i32 4}\n");
    out.push_str("!2 = !{i32 7, !\"frame-pointer\", i32 2}\n");
    out.push_str("!3 = !{i32 7, !\"air.max_device_buffers\", i32 31}\n");
    out.push_str("!4 = !{i32 7, !\"air.max_constant_buffers\", i32 31}\n");
    out.push_str("!5 = !{i32 7, !\"air.max_threadgroup_buffers\", i32 31}\n");
    out.push_str("!6 = !{i32 7, !\"air.max_textures\", i32 128}\n");
    out.push_str("!7 = !{i32 7, !\"air.max_read_write_textures\", i32 8}\n");
    out.push_str("!8 = !{i32 7, !\"air.max_samplers\", i32 16}\n");

    if let Some(f) = module.functions.first() {
        let arg_tys: Vec<String> = f.args.iter().map(|a| a.ty.llvm_str()).collect();
        out.push_str(&format!(
            "!9 = !{{void ({})* @{}, !10, !11}}\n",
            arg_tys.join(", "),
            f.name
        ));
        out.push_str("!10 = !{}\n");
        out.push_str("!11 = !{!12, !13, !14}\n");

        for (i, a) in f.args.iter().enumerate() {
            let md_id = 12 + i;
            match &a.kind {
                ArgKind::Buffer { location, access } => {
                    let access_s = match access {
                        BufferAccess::Read => "air.read",
                        BufferAccess::Write => "air.write",
                        BufferAccess::ReadWrite => "air.read_write",
                    };
                    let (tsz, talign, tname) = match &a.ty {
                        AirType::Ptr { pointee, .. } => match **pointee {
                            AirType::Float => (4, 4, "float"),
                            AirType::Int(32) => (4, 4, "int"),
                            _ => (4, 4, "float"),
                        },
                        _ => (4, 4, "float"),
                    };
                    out.push_str(&format!(
                        "!{md_id} = !{{i32 {i}, !\"air.buffer\", !\"air.location_index\", i32 {location}, i32 1, !\"{access_s}\", !\"air.address_space\", i32 1, !\"air.arg_type_size\", i32 {tsz}, !\"air.arg_type_align_size\", i32 {talign}, !\"air.arg_type_name\", !\"{tname}\", !\"air.arg_name\", !\"{}\"}}\n",
                        a.name
                    ));
                }
                ArgKind::ThreadPositionInGrid => {
                    out.push_str(&format!(
                        "!{md_id} = !{{i32 {i}, !\"air.thread_position_in_grid\", !\"air.arg_type_name\", !\"uint\", !\"air.arg_name\", !\"{}\"}}\n",
                        a.name
                    ));
                }
            }
        }
    }

    out.push_str("!15 = !{!\"air.compile.denorms_disable\"}\n");
    out.push_str("!16 = !{!\"air.compile.fast_math_enable\"}\n");
    out.push_str("!17 = !{!\"air.compile.framebuffer_fetch_enable\"}\n");
    out.push_str("!18 = !{!\"metalc (OpenMetal AIR compiler)\"}\n");
    let (amaj, amin, apat) = module.air_version;
    out.push_str(&format!("!19 = !{{i32 {amaj}, i32 {amin}, i32 {apat}}}\n"));
    let (lang, lmaj, lmin, lpat) = &module.language_version;
    out.push_str(&format!(
        "!20 = !{{!\"{lang}\", i32 {lmaj}, i32 {lmin}, i32 {lpat}}}\n"
    ));
    out.push_str(&format!("!21 = !{{!\"{}\"}}\n", module.source_filename));

    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::add_one_module;

    #[test]
    fn add_one_ll_contains_kernel_metadata() {
        let ll = write_llvm_ir(&add_one_module());
        assert!(ll.contains("define void @add_one("));
        assert!(ll.contains("!air.kernel"));
        assert!(ll.contains("air.thread_position_in_grid"));
        assert!(ll.contains("target triple = \"air64_v29-apple-macosx27.0.0\""));
    }
}
