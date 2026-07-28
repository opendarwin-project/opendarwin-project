const std = @import("std");

/// libdyld: the dyld introspection API (_dyld_image_count, dlopen/dlsym,
/// etc.) that real macOS ships as /usr/lib/system/libdyld.dylib and
/// reexports from libSystem. Built as its own dylib named "dyld".
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const dyld_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .abi = .none,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/dyld.zig"),
        .target = dyld_target,
        .optimize = optimize,
        .link_libc = false,
    });

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "dyld",
        .root_module = mod,
    });
    lib.install_name = "/usr/lib/system/libdyld.dylib";
    lib.linker_allow_shlib_undefined = true;
    lib.dead_strip_dylibs = true;

    b.installArtifact(lib);
}
