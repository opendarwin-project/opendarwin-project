const std = @import("std");

fn addKernel(b: *std.Build, optimize: std.builtin.OptimizeMode, rootfs_path: ?[]const u8) void {
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
        .root_source_file = b.path("src/kernel/kmain.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "conduit", .module = conduit_dep.module("conduit") },
            .{ .name = "dtree", .module = dtree_dep.module("dtree") },
            .{ .name = "xml", .module = xml_dep.module("xml") },
        },
    });
    kernel_mod.addIncludePath(b.path("src/kernel/arch/aarch64"));
    kernel_mod.addAssemblyFile(b.path("src/kernel/boot/start.S"));
    kernel_mod.addAssemblyFile(b.path("src/kernel/arch/aarch64/vectors.S"));
    kernel_mod.addAssemblyFile(b.path("src/kernel/arch/aarch64/task_entry.S"));

    const kernel_exe = b.addExecutable(.{
        .name = "opendarwin-kernel",
        .root_module = kernel_mod,
    });
    kernel_exe.setLinkerScript(b.path("src/kernel/boot/linker.ld"));
    kernel_exe.entry = .{ .symbol_name = "_start" };

    b.installArtifact(kernel_exe);

    // QEMU's arm_setup_direct_kernel_boot() (hw/arm/boot.c) hardcodes
    // "ELF images are not [Linux]" - it only inspects a loaded image for the
    // arm64 Image boot header (ARM64_MAGIC_OFFSET check in
    // load_aarch64_image()) when ELF loading *fails*, i.e. only for a raw
    // binary. Since start.S embeds that header (see its module comment), the
    // kernel must be booted as a raw binary - not the ELF - for QEMU to take
    // the is_linux path and hand x0 = DTB pointer to real_start. Feeding it
    // the ELF instead silently leaves x0 as whatever QEMU last left there
    // (observed to be 0), and devicetree.zig's discovery permanently no-ops.
    const kernel_bin = b.addObjCopy(kernel_exe.getEmittedBin(), .{ .format = .bin });

    const qemu_step = b.step("qemu", "Boot the kernel in qemu-system-aarch64 -M virt");
    const qemu_cmd = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-M",
        "virt",
        // "max" rather than "cortex-a72": real cortex-a72 has no PAC
        // (FEAT_PAuth), and the kernel's PAC groundwork (arch/aarch64/pac.zig)
        // needs a CPU model that implements it to actually exercise.
        "-cpu",
        "max",
        "-smp",
        "4",
        "-nographic",
        "-kernel",
    });
    qemu_cmd.addFileArg(kernel_bin.getOutput());

    // -Drootfs=<path> attaches a raw disk image as a virtio-mmio block
    // device (see drivers/virtio_blk.zig / devicetree.zig for the kernel
    // side). Not wired in by default since the image is host-prepared
    // (tools/make_rootfs.sh) and embeds host-specific content.
    if (rootfs_path) |path| {
        qemu_cmd.addArgs(&.{
            "-drive",
            b.fmt("file={s},if=none,format=raw,id=rootfs", .{path}),
            "-device",
            "virtio-blk-device,drive=rootfs",
            // conduit's virtio_blk driver only speaks the modern (v2)
            // virtio-mmio protocol; QEMU virt's transports default to
            // legacy (v1) otherwise.
            "-global",
            "virtio-mmio.force-legacy=false",
        });
    }

    qemu_step.dependOn(&qemu_cmd.step);
}

// Host-side tool (native target, not the freestanding kernel one): prepares
// a FAT rootfs image from a real macOS dyld shared cache - see
// tools/prepare_shared_cache.zig's module doc comment. Reuses
// src/kernel/loader/{shared_cache,rootfs_manifest}.zig directly (both are
// plain byte-parsing code with no freestanding-only dependencies), imported
// as named modules since Zig 0.16 disallows a module's relative imports
// climbing outside its own root directory.
fn addPrepareSharedCacheTool(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const shared_cache_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel/loader/shared_cache.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const rootfs_manifest_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel/loader/rootfs_manifest.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });

    const tool_mod = b.createModule(.{
        .root_source_file = b.path("tools/prepare_shared_cache.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "shared_cache", .module = shared_cache_mod },
            .{ .name = "rootfs_manifest", .module = rootfs_manifest_mod },
        },
    });

    const tool_exe = b.addExecutable(.{
        .name = "prepare_shared_cache",
        .root_module = tool_mod,
    });
    b.installArtifact(tool_exe);

    const run_step = b.step("prepare-shared-cache", "Build tools/prepare_shared_cache (run it directly to prepare a rootfs image)");
    run_step.dependOn(&b.addInstallArtifact(tool_exe, .{}).step);
}

fn addDarwinWindowSmoke(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const prism_dep = b.dependency("prism", .{
        .target = b.graph.host,
        .optimize = optimize,
        .drivers = "software",
    });
    const tool_mod = b.createModule(.{
        .root_source_file = b.path("tools/darwin_window_smoke.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "prism", .module = prism_dep.module("prism") }},
    });
    const tool_exe = b.addExecutable(.{
        .name = "darwin_window_smoke",
        .root_module = tool_mod,
    });
    b.installArtifact(tool_exe);

    const run = b.addRunArtifact(tool_exe);
    const run_step = b.step("run-darwin-window", "Open a macOS window using std.DynLib-loaded AppKit");
    run_step.dependOn(&run.step);
}

fn addMinimalLibSystem(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const libsystem_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .abi = .none,
    });

    const libsystem_mod = b.createModule(.{
        .root_source_file = b.path("src/libsystem/libsystem.zig"),
        .target = libsystem_target,
        .optimize = optimize,
        .link_libc = false,
    });

    const libsystem = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "System",
        .root_module = libsystem_mod,
    });
    libsystem.install_name = "/usr/lib/libSystem.B.dylib";

    const install = b.addInstallArtifact(libsystem, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
        .dest_sub_path = "libSystem.B.dylib",
    });
    b.getInstallStep().dependOn(&install.step);

    const step = b.step("libsystem", "Build the minimal FOSS libSystem.B.dylib for aarch64-macos");
    step.dependOn(&install.step);
    return libsystem;
}

fn addZigDarwinSmoke(b: *std.Build, optimize: std.builtin.OptimizeMode, libsystem: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const smoke_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .abi = .none,
    });

    const smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/userland/zig_smoke.zig"),
        .target = smoke_target,
        .optimize = optimize,
        .link_libc = false,
    });

    const smoke = b.addExecutable(.{
        .name = "zig-smoke",
        .root_module = smoke_mod,
    });
    smoke.entry = .{ .symbol_name = "_zig_smoke_entry" };
    smoke_mod.linkLibrary(libsystem);

    const install = b.addInstallArtifact(smoke, .{
        .dest_dir = .{ .override = .{ .custom = "userland" } },
    });
    b.getInstallStep().dependOn(&install.step);

    const step = b.step("zig-smoke", "Build a tiny aarch64-macos Zig executable linked to minimal libSystem");
    step.dependOn(&install.step);
    return smoke;
}

fn addZigSmokeRootfs(b: *std.Build) void {
    const make_img = b.addSystemCommand(&.{
        "python3",
        "tools/make_fat32.py",
        "zig-out/zig-smoke-rootfs.img",
        "--multi",
        "usr/lib/libSystem.B.dylib=zig-out/lib/libSystem.B.dylib",
        "bin/zig-smoke=zig-out/userland/zig-smoke",
        "MAIN=zig-out/userland/zig-smoke",
    });
    make_img.step.dependOn(b.getInstallStep());

    const step = b.step("zig-smoke-rootfs", "Build a FAT32 QEMU rootfs containing zig-smoke and minimal libSystem");
    step.dependOn(&make_img.step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

    _ = b.dependency("prism", .{ .target = target, .optimize = optimize });

    const rootfs_path = b.option([]const u8, "rootfs", "Path to a raw disk image to attach as virtio-blk when running `zig build qemu`");
    addKernel(b, optimize, rootfs_path);
    addPrepareSharedCacheTool(b, optimize);
    addDarwinWindowSmoke(b, optimize);
    const libsystem = addMinimalLibSystem(b, optimize);
    _ = addZigDarwinSmoke(b, optimize, libsystem);
    addZigSmokeRootfs(b);
}
