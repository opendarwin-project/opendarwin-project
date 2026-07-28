//! libdyld: dyld introspection symbols reexported by libSystem on real
//! macOS (_dyld_image_count, _dyld_get_image_header, dlopen/dlsym, etc.).
//! Built as its own dylib, installed at /usr/lib/system/libdyld.dylib, and
//! force-linked into libSystem.B.dylib (see libsystem/build.zig) so any
//! consumer that loads libSystem also pulls this in, matching Apple's
//! layering without needing real dylib re-exports.

fn stubErr(comptime name: []const u8) c_int {
    _ = name;
    return -1;
}

fn reportStub(comptime name: []const u8) void {
    _ = name;
}

const MAIN_IMAGE_BASE: usize = 0x1_0000_0000;
const MAIN_IMAGE_LIMIT: usize = 0x2_0000_0000;

fn findMachHeader(addr: ?*const anyopaque) ?*anyopaque {
    _ = addr;
    return null;
}

// ── NSGetExecutablePath ────────────────────────────────────────────────

pub export fn _NSGetExecutablePath(_: [*]u8, _: *u32) c_int {
    return stubErr("_NSGetExecutablePath");
}

pub export fn _NSGetArgc() *c_int {
    // Return pointer to a static 1
    const argc: c_int = 1;
    return @ptrCast(@constCast(&argc));
}

pub export fn _NSGetArgv() *[*:0]const u8 {
    const argv: [*:0]const u8 = "zig-smoke";
    return @ptrCast(@constCast(&argv));
}

pub export fn _NSGetEnviron() *[*:0]const u8 {
    const env: [*:0]const u8 = "";
    return @ptrCast(@constCast(&env));
}

// ── availability ───────────────────────────────────────────────────────

pub export fn __availability_version_check(_: u32, _: ?*const anyopaque) c_int {
    reportStub("__availability_version_check");
    return 1;
}

// ── dyld image walking ─────────────────────────────────────────────────

pub export fn _dyld_image_count() u32 {
    return 1; // We have exactly one image (the main one).
}

pub export fn _dyld_get_image_header(index: u32) ?*const anyopaque {
    _ = index;
    return null;
}

pub export fn _dyld_get_image_name(index: u32) ?[*:0]const u8 {
    if (index == 0) return "/MAIN\x00";
    return null;
}

pub export fn _dyld_get_image_vmaddr_slide(index: u32) i64 {
    _ = index;
    return 0;
}

pub export fn __dyld_get_image_header_containing_address(addr: ?*const anyopaque) ?*anyopaque {
    return findMachHeader(addr);
}

pub export fn _dyld_get_image_header_containing_address(addr: ?*const anyopaque) ?*anyopaque {
    return findMachHeader(addr);
}

pub export fn _dyld_image_path_containing_address(addr: ?*const anyopaque) ?[*:0]const u8 {
    const p = @intFromPtr(addr orelse return null);
    if (p >= MAIN_IMAGE_BASE and p < MAIN_IMAGE_LIMIT) return "/MAIN\x00";
    return "/usr/lib/libSystem.B.dylib\x00";
}

pub export fn _dyld_get_image_uuid(index: u32, uuid_out: ?*[16]u8) c_int {
    _ = index;
    if (uuid_out) |out| @memset(out, 0);
    return 0;
}

pub export fn _dyld_get_sdk_version_info() [*:0]const u8 {
    return "15.0\x00";
}

pub export fn _dyld_get_active_platform() u32 {
    return 1; // PLATFORM_MACOS
}

pub export fn _dyld_program_sdk_at_least(_: u32, _: u32, _: u32) bool {
    return true;
}

// ── getsectbynamefromheader_64 ─────────────────────────────────────────

pub export fn getsectbynamefromheader_64(
    _: ?*const anyopaque,
    _: [*:0]const u8,
    _: [*:0]const u8,
) ?*anyopaque {
    return null;
}

pub export fn getsectdatafromheader_64(
    _: ?*const anyopaque,
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: ?*u64,
) ?*anyopaque {
    return null;
}

// ── dlopen / dlsym / dladdr ────────────────────────────────────────────

pub export fn dlopen(_: ?[*:0]const u8, _: c_int) ?*anyopaque {
    return null;
}

pub export fn dlsym(_: ?*anyopaque, _: [*:0]const u8) ?*anyopaque {
    return null;
}

pub export fn dlclose(_: ?*anyopaque) c_int {
    return 0;
}

pub export fn dladdr(addr: ?*const anyopaque, info: ?*anyopaque) c_int {
    _ = addr;
    _ = info;
    return 0;
}

pub export fn dlerror() ?[*:0]const u8 {
    return null;
}

// ── comptime aliases for Mach-O name mangling ──────────────────────────
comptime {
    @export(&__availability_version_check, .{ .name = "_availability_version_check", .linkage = .strong });
    @export(&_dyld_get_image_header_containing_address, .{ .name = "dyld_get_image_header_containing_address", .linkage = .strong });
    @export(&_dyld_image_path_containing_address, .{ .name = "dyld_image_path_containing_address", .linkage = .strong });
}
