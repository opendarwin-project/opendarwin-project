const std = @import("std");

/// Guest userland smoke programs, built for aarch64-macos against the
/// vendored libSystem.tbd (and optionally IOKit / SkyLight). The root build
/// fetches these by name (see the root build.zig's `userland_programs`
/// table) to assemble the guest rootfs and choose `-Dmain=<name>`.
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const guest_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .abi = .none,
    });

    const iokit_dep = b.dependency("iokit", .{ .optimize = optimize });
    const iokit = iokit_dep.artifact("IOKit");
    const skylight_dep = b.dependency("skylight", .{ .optimize = optimize });
    const skylight = skylight_dep.artifact("SkyLight");

    addProgram(b, guest_target, optimize, "zig-smoke", "programs/thread_smoke.zig", null);
    addProgram(b, guest_target, optimize, "fb-smoke", "programs/fb_smoke.zig", iokit);
    addProgram(b, guest_target, optimize, "window-smoke", "programs/window_smoke.zig", skylight);
    addOksh(b, guest_target, optimize);
}

fn addProgram(
    b: *std.Build,
    guest_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    source: []const u8,
    /// libSystem comes from Zig's vendored TBD at link time (one LC_LOAD_DYLIB).
    /// FOSS dylibs (IOKit, SkyLight, libSystem) load from the rootfs at runtime.
    needs: ?*std.Build.Step.Compile,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path(source),
        .target = guest_target,
        .optimize = optimize,
        .link_libc = false,
    });
    if (needs) |dep| mod.linkLibrary(dep);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = mod,
    });
    b.installArtifact(exe);
}

/// Portable OpenBSD ksh (https://github.com/ibara/oksh), cross-built for the
/// guest triple.  Links against Zig's vendored libSystem.tbd like the Zig
/// smoke programs; the rootfs supplies our FOSS libSystem.B.dylib at runtime.
fn addOksh(
    b: *std.Build,
    guest_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const upstream = b.dependency("oksh", .{});
    const oksh_sources = [_][]const u8{
        "alloc.c",       "asprintf.c",    "c_ksh.c",       "c_sh.c",
        "c_test.c",      "c_ulimit.c",    "confstr.c",     "edit.c",
        "emacs.c",       "eval.c",        "exec.c",        "expr.c",
        "history.c",     "io.c",          "issetugid.c",   "jobs.c",
        "lex.c",         "mail.c",        "main.c",        "misc.c",
        "path.c",        "reallocarray.c", "shf.c",        "siglist.c",
        "signame.c",     "strlcat.c",     "strlcpy.c",     "strtonum.c",
        "syn.c",         "table.c",       "trap.c",        "tree.c",
        "tty.c",         "unvis.c",       "var.c",         "version.c",
        "vi.c",          "vis.c",
    };

    const mod = b.createModule(.{
        .target = guest_target,
        .optimize = optimize,
        .link_libc = false,
    });
    mod.addIncludePath(upstream.path("."));
    mod.addIncludePath(b.path("programs/oksh"));

    const flags = &.{
        "-std=c99",
        "-DEMACS",
        "-DSMALL",
        "-DNO_CURSES",
        "-include",
        b.pathFromRoot("programs/oksh/pconfig.h"),
        "-fno-sanitize=undefined",
        "-U_FORTIFY_SOURCE",
        "-D_FORTIFY_SOURCE=0",
        "-Wno-everything",
    };

    for (oksh_sources) |src| {
        mod.addCSourceFile(.{
            .file = upstream.path(src),
            .flags = flags,
        });
    }

    const exe = b.addExecutable(.{
        .name = "oksh",
        .root_module = mod,
    });
    b.installArtifact(exe);
}
