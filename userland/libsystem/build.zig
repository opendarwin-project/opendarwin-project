const std = @import("std");

/// The minimal FOSS libSystem replacement: an aarch64-macos dynamic library
/// named "System", installed by this package so the root build can place it
/// in the guest rootfs as `/usr/lib/libSystem.B.dylib`.
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const libsystem_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .abi = .none,
    });

    const dyld_dep = b.dependency("dyld", .{ .optimize = optimize });
    const dyld = dyld_dep.artifact("dyld");

    const libsystem_mod = b.createModule(.{
        .root_source_file = b.path("src/libsystem.zig"),
        .target = libsystem_target,
        .optimize = optimize,
        .link_libc = false,
    });
    // Force a dependent LC_LOAD_DYLIB on libdyld, mirroring Apple's
    // libSystem -> libdyld.dylib layering, so the kernel's transitive dylib
    // loader picks it up alongside libSystem for every consumer.
    libsystem_mod.linkLibrary(dyld);
    libsystem_mod.addAssemblyFile(b.path("src/setjmp.S"));

    const libsystem = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "System",
        .root_module = libsystem_mod,
    });
    // Real dylib goes in the guest rootfs for runtime. Link consumers against
    // Zig's vendored libSystem.tbd (resolveLibSystem), not this artifact —
    // linkLibrary() would emit a second LC_LOAD_DYLIB with the same install name.
    libsystem.install_name = "/usr/lib/libSystem.B.dylib";
    libsystem.linker_allow_shlib_undefined = true;
    libsystem.dead_strip_dylibs = true;

    b.installArtifact(libsystem);
}
