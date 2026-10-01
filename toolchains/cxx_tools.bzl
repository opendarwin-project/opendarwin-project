load(
    "@prelude//cxx:cxx_toolchain_types.bzl",
    "BinaryUtilitiesInfo",
    "CCompilerInfo",
    "CxxCompilerInfo",
    "CxxInternalTools",
    "CxxPlatformInfo",
    "CxxToolchainInfo",
    "DepTrackingMode",
    "LinkerInfo",
    "LinkerType",
    "PicBehavior",
    "RuntimeDependencyHandling",
    "ShlibInterfacesMode",
)
load("@prelude//cxx:headers.bzl", "HeaderMode")
load("@prelude//decls:common.bzl", "buck")
load("@prelude//linking:link_info.bzl", "LinkOrdering", "LinkStyle")
load("@prelude//linking:lto.bzl", "LtoMode")
load("@prelude//os_lookup:defs.bzl", "OsLookup")

def _run_info(args):
    return None if args == None else RunInfo(args = [args])

def _opendarwin_cxx_toolchain_impl(ctx):
    os = ctx.attrs._target_os_type[OsLookup].os.value
    arch_name = ctx.attrs._target_os_type[OsLookup].cpu
    target_name = os
    if arch_name:
        target_name += "-" + arch_name

    linker_type = LinkerType(ctx.attrs.linker_type)
    link_style = LinkStyle(ctx.attrs.link_style)

    return [
        DefaultInfo(),
        CxxToolchainInfo(
            internal_tools = ctx.attrs.internal_tools[CxxInternalTools],
            linker_info = LinkerInfo(
                linker = _run_info(ctx.attrs.linker),
                linker_flags = ctx.attrs.link_flags,
                post_linker_flags = ctx.attrs.post_link_flags,
                archiver = _run_info(ctx.attrs.archiver),
                archiver_type = ctx.attrs.archiver_type,
                archiver_supports_argfiles = (linker_type != LinkerType("darwin")),
                generate_linker_maps = False,
                lto_mode = LtoMode("none"),
                type = linker_type,
                link_binaries_locally = True,
                link_libraries_locally = True,
                archive_objects_locally = True,
                use_archiver_flags = True,
                static_dep_runtime_ld_flags = [],
                static_pic_dep_runtime_ld_flags = [],
                shared_dep_runtime_ld_flags = [],
                independent_shlib_interface_linker_flags = [],
                shlib_interfaces = ShlibInterfacesMode("disabled"),
                link_style = link_style,
                link_weight = 1,
                binary_extension = "",
                object_file_extension = "o",
                shared_library_name_default_prefix = "lib",
                shared_library_name_format = "{}.dylib" if linker_type == LinkerType("darwin") else "{}.so",
                shared_library_versioned_name_format = "{}.dylib" if linker_type == LinkerType("darwin") else "{}.so.{}",
                static_library_extension = "a",
                force_full_hybrid_if_capable = False,
                is_pdb_generated = False,
                link_ordering = ctx.attrs.link_ordering,
            ),
            bolt_enabled = False,
            binary_utilities_info = BinaryUtilitiesInfo(
                nm = RunInfo(args = ["nm"]),
                objcopy = RunInfo(args = ["objcopy"]),
                objdump = RunInfo(args = ["objdump"]),
                ranlib = RunInfo(args = ["ranlib"]),
                strip = RunInfo(args = ["strip"]),
                dwp = None,
                bolt_msdk = None,
            ),
            cxx_compiler_info = CxxCompilerInfo(
                compiler = _run_info(ctx.attrs.cxx_compiler),
                preprocessor_flags = [],
                compiler_flags = ctx.attrs.cxx_flags,
                compiler_type = ctx.attrs.compiler_type,
                supports_two_phase_compilation = False,
                supports_content_based_paths = False,
            ),
            c_compiler_info = CCompilerInfo(
                compiler = _run_info(ctx.attrs.compiler),
                preprocessor_flags = [],
                compiler_flags = ctx.attrs.c_flags,
                compiler_type = ctx.attrs.compiler_type,
                supports_content_based_paths = False,
            ),
            as_compiler_info = CCompilerInfo(
                compiler = _run_info(ctx.attrs.compiler),
                compiler_type = ctx.attrs.compiler_type,
                supports_content_based_paths = False,
            ),
            asm_compiler_info = CCompilerInfo(
                compiler = _run_info(ctx.attrs.compiler),
                compiler_type = ctx.attrs.compiler_type,
            ),
            cvtres_compiler_info = None,
            rc_compiler_info = None,
            header_mode = HeaderMode("symlink_tree_only"),
            cpp_dep_tracking_mode = DepTrackingMode("makefile"),
            pic_behavior = PicBehavior("always_enabled" if linker_type == LinkerType("darwin") else "supported"),
            llvm_link = RunInfo(args = ["llvm-link"]),
            use_dep_files = True,
            runtime_dependency_handling = RuntimeDependencyHandling("no_symlink"),
        ),
        CxxPlatformInfo(name = target_name),
    ]

opendarwin_cxx_toolchain = rule(
    impl = _opendarwin_cxx_toolchain_impl,
    attrs = {
        "archiver": attrs.string(default = "llvm-ar"),
        "archiver_type": attrs.string(default = "gnu"),
        "c_flags": attrs.list(attrs.arg(), default = []),
        "compiler": attrs.string(default = "clang"),
        "compiler_type": attrs.string(default = "clang"),
        "cxx_compiler": attrs.string(default = "clang++"),
        "cxx_flags": attrs.list(attrs.arg(), default = []),
        "internal_tools": attrs.default_only(attrs.exec_dep(providers = [CxxInternalTools], default = "prelude//cxx/tools:internal_tools")),
        "link_flags": attrs.list(attrs.arg(), default = []),
        "link_ordering": attrs.option(attrs.enum(LinkOrdering.values()), default = None),
        "link_style": attrs.string(default = "shared"),
        "linker": attrs.string(default = "clang"),
        "linker_type": attrs.string(default = "gnu"),
        "post_link_flags": attrs.list(attrs.arg(), default = []),
        "_target_os_type": buck.target_os_type_arg(),
    },
    is_toolchain_rule = True,
)
