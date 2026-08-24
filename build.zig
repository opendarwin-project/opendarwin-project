const std = @import("std");

fn addKernel(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    rootfs_path: ?[]const u8,
    /// When set, qemu waits for this step before booting (smoke rootfs rebuild).
    rootfs_depend: ?*std.Build.Step,
) void {
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
        // Pin GICv2: our intc driver (conduit gicv2) speaks the GICv2 MMIO
        // CPU-interface. QEMU can otherwise default to GICv3 (whose CPU
        // interface is system-register based) depending on accelerator/CPU,
        // which our MMIO driver can't drive - leaving all interrupts
        // (including the timer) undelivered under HVF.
        // HVF only supports GICv3; TCG supports either. GICv3 works under
        // both, so pin it: the kernel's intc layer auto-selects the v2 or
        // v3 driver from devicetree, and only GICv3 delivers interrupts
        // (incl. the periodic timer) under Apple's hypervisor.
        "virt,gic-version=3",
        // "max" rather than "cortex-a72": real cortex-a72 has no PAC
        // (FEAT_PAuth), and the kernel's PAC groundwork (arch/aarch64/pac.zig)
        // needs a CPU model that implements it to actually exercise.
        "-cpu",
        // "max",
        "host",
        "-accel",
        "hvf",
        "-smp",
        "4",
        "-serial",
        "stdio",
        "-monitor",
        "unix:/tmp/opendarwin-qemu-mon.sock,server,nowait",
        "-device",
        "virtio-gpu-device",
        "-device",
        "virtio-tablet-device",
        "-device",
        "virtio-keyboard-device",
        "-kernel",
    });
    qemu_cmd.addFileArg(kernel_bin.getOutput());
    // conduit's virtio-mmio drivers speak the modern (v2) protocol; QEMU
    // virt's transports default to legacy (v1) otherwise.
    qemu_cmd.addArgs(&.{
        "-global",
        "virtio-mmio.force-legacy=false",
    });

    // -Drootfs=<path> attaches a raw disk image as a virtio-mmio block
    // device (see drivers/virtio_blk.zig / devicetree.zig for the kernel
    // side). Passing -Dmain=<name> without -Drootfs implies the smoke
    // image at zig-out/zig-smoke-rootfs.img (rebuilt first).
    if (rootfs_path) |path| {
        if (rootfs_depend) |dep| qemu_cmd.step.dependOn(dep);
        qemu_cmd.addArgs(&.{
            "-drive",
            b.fmt("file={s},if=none,format=raw,id=rootfs", .{path}),
            "-device",
            "virtio-blk-device,drive=rootfs",
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
    // Real dylib goes in the guest rootfs for runtime. Link consumers against
    // Zig's vendored libSystem.tbd (resolveLibSystem), not this artifact —
    // linkLibrary() would emit a second LC_LOAD_DYLIB with the same install name.
    libsystem.install_name = "/usr/lib/libSystem.B.dylib";
    libsystem.linker_allow_shlib_undefined = true;
    libsystem.dead_strip_dylibs = true;

    const install = b.addInstallArtifact(libsystem, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
        .dest_sub_path = "libSystem.B.dylib",
    });
    b.getInstallStep().dependOn(&install.step);

    const step = b.step("libsystem", "Build the minimal FOSS libSystem.B.dylib for aarch64-macos");
    step.dependOn(&install.step);
    return libsystem;
}

/// One guest userland program: built for aarch64-macos against our own
/// libSystem (and optionally SkyLight / IOKit), installed into zig-out/userland, and
/// selectable as the rootfs MAIN via `-Dmain=<name>`.
const UserlandProgram = struct {
    name: []const u8,
    source: []const u8,
    description: []const u8,
    /// Guest path inside the FAT rootfs.
    guest_path: []const u8,
    needs_skylight: bool = false,
    needs_iokit: bool = false,
};

const BuiltUserland = struct {
    meta: UserlandProgram,
    exe: *std.Build.Step.Compile,
};

const userland_programs = [_]UserlandProgram{
    .{
        .name = "zig-smoke",
        .source = "src/userland/threads.zig",
        .description = "a tiny aarch64-macos Zig executable linked to minimal libSystem",
        .guest_path = "bin/zig-smoke",
    },
    .{
        .name = "fb-smoke",
        .source = "src/userland/fb_smoke.zig",
        .description = "guest IOKit framebuffer present smoke",
        .guest_path = "bin/fb-smoke",
        .needs_iokit = true,
    },
    .{
        .name = "window-smoke",
        .source = "src/userland/window_smoke.zig",
        .description = "guest SkyLight/CGS window composite smoke",
        .guest_path = "bin/window-smoke",
        .needs_skylight = true,
    },
};

fn addUserlandProgram(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    program: UserlandProgram,
    skylight: *std.Build.Step.Compile,
    iokit: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const guest_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .abi = .none,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path(program.source),
        .target = guest_target,
        .optimize = optimize,
        .link_libc = false,
    });

    const exe = b.addExecutable(.{
        .name = program.name,
        .root_module = mod,
    });
    // libSystem comes from Zig's vendored TBD at link time (one LC_LOAD_DYLIB).
    // FOSS dylibs (IOKit, SkyLight, libSystem) load from the rootfs at runtime.
    if (program.needs_iokit) mod.linkLibrary(iokit);
    if (program.needs_skylight) mod.linkLibrary(skylight);

    const install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "userland" } },
    });
    b.getInstallStep().dependOn(&install.step);

    const step = b.step(program.name, b.fmt("Build {s}", .{program.description}));
    step.dependOn(&install.step);
    return exe;
}

// (fb-smoke / window-smoke / zig-smoke all come from userland_programs above.)

// IOKit.framework replacement: Darwin IOKitLib (src/iokit/*.zig).  Built as its
// own dylib with Apple's install name; malloc/free resolve through libSystem at
// runtime.
fn addIOKit(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const iokit_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .abi = .none,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/iokit/iokit.zig"),
        .target = iokit_target,
        .optimize = optimize,
        .link_libc = false,
    });

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "IOKit",
        .root_module = mod,
    });
    lib.install_name = "/System/Library/Frameworks/IOKit.framework/IOKit";
    lib.linker_allow_shlib_undefined = true;
    lib.dead_strip_dylibs = true;

    const install = b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
        .dest_sub_path = "IOKit",
    });
    b.getInstallStep().dependOn(&install.step);

    const step = b.step("iokit", "Build the FOSS IOKit.framework for aarch64-macos");
    step.dependOn(&install.step);
    return lib;
}

// SkyLight.framework replacement: the CGS* window-server API implemented on
// top of our IOKit framebuffer (src/skylight/*.zig).  Built as its own dylib
// with Apple's install name so std.DynLib consumers (Prism's
// platform/darwin.zig) find it at the usual path inside the guest rootfs.
fn addSkyLight(b: *std.Build, optimize: std.builtin.OptimizeMode, iokit: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const skylight_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .abi = .none,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/skylight/skylight.zig"),
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

    const install = b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
        .dest_sub_path = "SkyLight",
    });
    b.getInstallStep().dependOn(&install.step);

    const step = b.step("skylight", "Build the FOSS SkyLight/CGS window server for aarch64-macos");
    step.dependOn(&install.step);
    return lib;
}

// CoreFoundation: upstream swift-corelibs-foundation C sources (fetched via
// build.zig.zon, unmodified) compiled for the guest against our own libSystem.
//
// Configuration is DEPLOYMENT_TARGET_LINUX ("no Apple userland": no ObjC, no
// Swift runtime, no ICU) on an aarch64-macos triple, reconciled by the force-
// included src/corefoundation/cf_prefix.h and the shim headers next to it.
// This is the tier that CFDictionary needs - enough to replace the ad-hoc
// IOKit matching-dictionary code with real CFDictionaryRef/CFStringRef/
// CFNumberRef objects.  Higher tiers (CFDate, CFURL, CFPropertyList,
// CFRunLoop) are deliberately left out; see docs/corefoundation.md.
const corefoundation_sources = [_][]const u8{
    "Base.subproj/CFBase.c",
    "Base.subproj/CFRuntime.c",
    "Base.subproj/CFPlatform.c",
    "Base.subproj/CFSortFunctions.c",
    "Base.subproj/CFFileUtilities.c",
    "Base.subproj/CFUtilities.c",
    "Collections.subproj/CFArray.c",
    "Collections.subproj/CFBag.c",
    "Collections.subproj/CFBasicHash.c",
    "Collections.subproj/CFData.c",
    "Collections.subproj/CFDictionary.c",
    "Collections.subproj/CFSet.c",
    "Collections.subproj/CFStorage.c",
    "String.subproj/CFString.c",
    "String.subproj/CFStringScanner.c",
    "String.subproj/CFStringEncodings.c",
    "String.subproj/CFBurstTrie.c",
    "String.subproj/CFCharacterSet.c",
    "StringEncodings.subproj/CFStringEncodingConverter.c",
    "StringEncodings.subproj/CFStringEncodingDatabase.c",
    "StringEncodings.subproj/CFBuiltinConverters.c",
    "StringEncodings.subproj/CFPlatformConverters.c",
    "StringEncodings.subproj/CFUniChar.c",
    "StringEncodings.subproj/CFUnicodeDecomposition.c",
    "StringEncodings.subproj/CFUnicodePrecomposition.c",
    "NumberDate.subproj/CFNumber.c",
    "NumberDate.subproj/CFDate.c",
    "Error.subproj/CFError.c",
    "URL.subproj/CFURL.c",
    "URL.subproj/CFURLAccess.c",
    "Parsing.subproj/CFBinaryPList.c",
    "Parsing.subproj/CFPropertyList.c",
    "Parsing.subproj/CFOldStylePList.c",
};

const corefoundation_subprojs = [_][]const u8{
    "AppServices.subproj",     "Base.subproj",       "Collections.subproj", "Error.subproj",
    "Locale.subproj",          "NumberDate.subproj", "Parsing.subproj",     "PlugIn.subproj",
    "Preferences.subproj",     "RunLoop.subproj",    "Stream.subproj",      "String.subproj",
    "StringEncodings.subproj", "URL.subproj",
};

fn addCoreFoundation(b: *std.Build, optimize: std.builtin.OptimizeMode) ?*std.Build.Step.Compile {
    const upstream = b.lazyDependency("corefoundation", .{}) orelse return null;
    const cf_root = upstream.path("CoreFoundation");

    // CF includes its own headers as <CoreFoundation/CFFoo.h>, but upstream
    // keeps them scattered across the *.subproj directories.  Stage a flat
    // CoreFoundation/ include tree with a WriteFiles step.
    const headers = b.addWriteFiles();
    for (corefoundation_subprojs) |sub| {
        _ = headers.addCopyDirectory(
            upstream.path(b.fmt("CoreFoundation/{s}", .{sub})),
            "CoreFoundation",
            .{ .include_extensions = &.{".h"} },
        );
    }
    // swift-corelibs ships its own TargetConditionals.h (and umbrella header)
    // under Base.subproj/SwiftRuntime; CF includes them as <CoreFoundation/...>.
    _ = headers.addCopyDirectory(
        upstream.path("CoreFoundation/Base.subproj/SwiftRuntime"),
        "CoreFoundation",
        .{ .include_extensions = &.{".h"} },
    );

    const cf_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .abi = .none,
    });
    const mod = b.createModule(.{
        .target = cf_target,
        .optimize = optimize,
        .link_libc = false,
    });

    var flags = std.ArrayList([]const u8).empty;
    flags.appendSlice(b.allocator, &.{
        "-DCF_BUILDING_CF=1",
        "-DDEPLOYMENT_TARGET_LINUX=1",
        "-DDEPLOYMENT_ENABLE_LIBDISPATCH=1",
        // No linker-synthesised __UNICODE segment yet: CF loads its Unicode
        // tables from CharacterSets/ files instead of a Mach-O section.
        "-DUSE_MACHO_SEGMENT=0",
        "-w",
        "-std=gnu11",
        // Debug builds otherwise pull __ubsan_handle_* out of compiler-rt,
        // which the guest has no runtime for.
        "-fno-sanitize=undefined",
        "-include",
        b.pathFromRoot("src/corefoundation/cf_prefix.h"),
    }) catch @panic("OOM");

    mod.addIncludePath(b.path("src/corefoundation/shims"));
    mod.addIncludePath(headers.getDirectory());
    mod.addIncludePath(cf_root);
    for (corefoundation_subprojs) |sub| {
        mod.addIncludePath(upstream.path(b.fmt("CoreFoundation/{s}", .{sub})));
    }
    for (corefoundation_sources) |src| {
        mod.addCSourceFile(.{
            .file = upstream.path(b.fmt("CoreFoundation/{s}", .{src})),
            .flags = flags.items,
        });
    }
    mod.addCSourceFile(.{
        .file = b.path("src/corefoundation/cf_stubs.c"),
        .flags = flags.items,
    });

    const lib = b.addLibrary(.{
        .name = "CoreFoundationCore",
        .root_module = mod,
        .linkage = .static,
    });

    const install = b.addInstallArtifact(lib, .{});
    const step = b.step("corefoundation", "Build the CoreFoundation container tier (CFDictionary/CFString/CFNumber) for aarch64-macos");
    step.dependOn(&install.step);

    // Report what libSystem still owes CF: the remaining bring-up work is
    // exactly this list (see docs/corefoundation.md).
    const gap = b.addSystemCommand(&.{ "python3", "tools/symbol_gap.py", "--provider", "zig-out/lib/libSystem.B.dylib", "--exit-zero" });
    gap.addArtifactArg(lib);
    gap.stdio = .inherit;
    const gap_step = b.step("cf-gap", "List the libSystem symbols CoreFoundation still needs");
    gap_step.dependOn(&install.step);
    gap_step.dependOn(&gap.step);

    return lib;
}

// Host-side unit tests for the compositor core (pure pixel math, no Mach).
fn addSkyLightTests(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/skylight/compositor.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const t = b.addTest(.{ .root_module = mod });
    const step = b.step("test-skylight", "Run window compositor unit tests on the host");
    step.dependOn(&b.addRunArtifact(t).step);
}

const rootfs_basename = "rootfs.img";

fn addRootfs(
    b: *std.Build,
    main_name: []const u8,
    programs: []const BuiltUserland,
    libsystem: *std.Build.Step.Compile,
    iokit: *std.Build.Step.Compile,
    skylight: *std.Build.Step.Compile,
) *std.Build.Step {
    // Wire real artifact LazyPaths into make_fat32 so -Dmain= changes the
    // Run step's input hash (hardcoded zig-out/... strings do not).
    const make_img = b.addSystemCommand(&.{ "python3", b.pathFromRoot("tools/make_fat32.py") });
    const image = make_img.addOutputFileArg(rootfs_basename);
    make_img.addArg("--multi");
    make_img.addArg(b.fmt("--main-name={s}", .{main_name}));
    make_img.addPrefixedFileArg("usr/lib/libSystem.B.dylib=", libsystem.getEmittedBin());
    make_img.addPrefixedFileArg(
        "System/Library/Frameworks/IOKit.framework/IOKit=",
        iokit.getEmittedBin(),
    );
    make_img.addPrefixedFileArg(
        "System/Library/PrivateFrameworks/SkyLight.framework/SkyLight=",
        skylight.getEmittedBin(),
    );

    var main_exe: ?*std.Build.Step.Compile = null;
    for (programs) |p| {
        make_img.addPrefixedFileArg(b.fmt("{s}=", .{p.meta.guest_path}), p.exe.getEmittedBin());
        if (std.mem.eql(u8, p.meta.name, main_name)) main_exe = p.exe;
    }
    const chosen = main_exe orelse {
        std.debug.print("unknown -Dmain={s}; known programs:", .{main_name});
        for (programs) |p| std.debug.print(" {s}", .{p.meta.name});
        std.debug.print("\n", .{});
        @panic("invalid -Dmain");
    };
    // Kernel autoruns this fixed guest name (see kmain.zig).
    make_img.addPrefixedFileArg("MAIN=", chosen.getEmittedBin());

    const install_img = b.addInstallFile(image, rootfs_basename);
    const step = b.step(
        "rootfs",
        b.fmt("Build a FAT32 QEMU rootfs with every userland program (MAIN = {s})", .{main_name}),
    );
    step.dependOn(&install_img.step);
    return step;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.dependency("prism", .{ .target = target, .optimize = optimize });

    const rootfs_opt = b.option([]const u8, "rootfs", "Path to a raw disk image to attach as virtio-blk when running `zig build qemu`");
    // null when unset — so `qemu -Dmain=fb-smoke` can imply the smoke rootfs.
    const main_opt = b.option([]const u8, "main", "Userland program to install as the rootfs MAIN (zig-smoke, fb-smoke, window-smoke)");
    const main_name = main_opt orelse "zig-smoke";

    addPrepareSharedCacheTool(b, optimize);
    addDarwinWindowSmoke(b, optimize);
    const libsystem = addMinimalLibSystem(b, optimize);
    const iokit = addIOKit(b, optimize);
    const skylight = addSkyLight(b, optimize, iokit);
    _ = addCoreFoundation(b, optimize);

    var programs: [userland_programs.len]BuiltUserland = undefined;
    for (userland_programs, 0..) |p, i| {
        programs[i] = .{ .meta = p, .exe = addUserlandProgram(b, optimize, p, skylight, iokit) };
    }
    addSkyLightTests(b, optimize);
    const rootfs_step = addRootfs(b, main_name, programs[0..], libsystem, iokit, skylight);

    const smoke_img_path = b.fmt("{s}/{s}", .{ b.install_path, rootfs_basename });
    const qemu_rootfs: ?[]const u8 = rootfs_opt orelse if (main_opt != null) smoke_img_path else null;
    const qemu_rootfs_dep: ?*std.Build.Step = blk: {
        const path = qemu_rootfs orelse break :blk null;
        if (std.mem.endsWith(u8, path, rootfs_basename) or main_opt != null)
            break :blk rootfs_step;
        break :blk null;
    };

    addKernel(b, optimize, qemu_rootfs, qemu_rootfs_dep);
}
