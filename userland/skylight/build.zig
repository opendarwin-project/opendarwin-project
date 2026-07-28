const std = @import("std");

/// SkyLight.framework replacement: the CGS* window-server API implemented on
/// top of the IOKit framebuffer (src/skylight.zig, src/compositor.zig).
/// Built as an aarch64-macos dynamic library named "SkyLight" with Apple's
/// install name so std.DynLib consumers (Prism's platform/darwin.zig) find
/// it at the usual path inside the guest rootfs.
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const skylight_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .abi = .none,
    });

    const iokit_dep = b.dependency("iokit", .{ .optimize = optimize });
    const iokit = iokit_dep.artifact("IOKit");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/skylight.zig"),
        .target = skylight_target,
        .optimize = optimize,
        .link_libc = false,
    });

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "SkyLight",
        .root_module = mod,
    });
    lib.install_name = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight";
    // TBD supplies System at link time; IOKit + real SkyLight dylibs are for the rootfs.
    mod.linkLibrary(iokit);
    lib.linker_allow_shlib_undefined = true;
    lib.dead_strip_dylibs = true;

    b.installArtifact(lib);

    // Host-side unit tests for the compositor core (pure pixel math, no Mach).
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/compositor.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const t = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run window compositor unit tests on the host");
    test_step.dependOn(&b.addRunArtifact(t).step);
}
