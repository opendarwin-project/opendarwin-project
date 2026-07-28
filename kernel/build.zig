const std = @import("std");

/// The OpenDarwin kernel: a freestanding aarch64 executable ("opendarwin-kernel"),
/// installed by this package so the root build can objcopy it to a raw binary
/// and boot it in QEMU (see the root build.zig's `qemu` step).
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // The target is always aarch64-freestanding, regardless of any `-Dtarget=`
    // passed to this package (there is only ever one kernel target).
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a72 },
    });

    const conduit_dep = b.dependency("conduit", .{
        .target = kernel_target,
        .optimize = optimize,
    });

    const dtree_dep = b.dependency("dtree", .{
        .target = kernel_target,
        .optimize = optimize,
    });

    const xml_dep = b.dependency("xml", .{
        .target = kernel_target,
        .optimize = optimize,
    });

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/kmain.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "conduit", .module = conduit_dep.module("conduit") },
            .{ .name = "dtree", .module = dtree_dep.module("dtree") },
            .{ .name = "xml", .module = xml_dep.module("xml") },
        },
    });
    kernel_mod.addIncludePath(b.path("src/arch/aarch64"));
    kernel_mod.addAssemblyFile(b.path("src/boot/start.S"));
    kernel_mod.addAssemblyFile(b.path("src/arch/aarch64/vectors.S"));
    kernel_mod.addAssemblyFile(b.path("src/arch/aarch64/task_entry.S"));

    const kernel_exe = b.addExecutable(.{
        .name = "opendarwin-kernel",
        .root_module = kernel_mod,
    });
    kernel_exe.setLinkerScript(b.path("src/boot/linker.ld"));
    kernel_exe.entry = .{ .symbol_name = "_start" };

    b.installArtifact(kernel_exe);
}
