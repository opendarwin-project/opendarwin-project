const std = @import("std");

/// IOKit.framework replacement: Darwin IOKitLib (src/iokit.zig), built as an
/// aarch64-macos dynamic library named "IOKit". malloc/free resolve through
/// libSystem at runtime. Installed by this package so the root build can
/// place it in the guest rootfs as
/// `/System/Library/Frameworks/IOKit.framework/IOKit`.
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const iokit_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .abi = .none,
    });

    const libsystem_dep = b.dependency("libsystem", .{ .optimize = optimize });
    const libsystem = libsystem_dep.artifact("System");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/iokit.zig"),
        .target = iokit_target,
        .optimize = optimize,
        .link_libc = false,
    });
    // mach_msg / mach_host_self / mach_reply_port are real libSystem symbols;
    // link against it instead of duplicating the raw trap asm here.
    mod.linkLibrary(libsystem);

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "IOKit",
        .root_module = mod,
    });
    lib.install_name = "/System/Library/Frameworks/IOKit.framework/IOKit";
    lib.linker_allow_shlib_undefined = true;
    lib.dead_strip_dylibs = true;

    b.installArtifact(lib);
}
