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

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel/kmain.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "conduit", .module = conduit_dep.module("conduit") },
            .{ .name = "dtree", .module = dtree_dep.module("dtree") },
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

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Declared per project requirements but not yet integrated: prism is a
    // hosted userspace graphics stack (DRM/GBM/Wayland-oriented), not
    // something the freestanding kernel links against. Real usage starts at
    // a later "WindowServer-equivalent" milestone.
    _ = b.dependency("prism", .{ .target = target, .optimize = optimize });

    const rootfs_path = b.option([]const u8, "rootfs", "Path to a raw disk image to attach as virtio-blk when running `zig build qemu`");
    addKernel(b, optimize, rootfs_path);
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("opendarwin", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "opendarwin",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "opendarwin" is the name you will use in your source code to
                // import this module (e.g. `@import("opendarwin")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "opendarwin", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
