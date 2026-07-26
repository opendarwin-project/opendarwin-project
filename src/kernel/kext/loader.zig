const std = @import("std");
const api = @import("api.zig");
const plist = @import("plist.zig");
const registry = @import("registry.zig");
const macho = @import("../loader/macho.zig");
const mmu = @import("../mm/mmu.zig");
const fat = @import("../fs/fat.zig");
const uart = @import("../drivers/uart.zig");

var kext_scratch: [256 * 1024]u8 align(16) = undefined;
var plist_scratch: [64 * 1024]u8 align(16) = undefined;
var xml_scratch: [32 * 1024]u8 align(16) = undefined;
var path_scratch: [160]u8 = undefined;

fn kernelResolver(ctx: ?*anyopaque, ordinal: u8, name: []const u8) ?u64 {
    _ = ctx;
    _ = ordinal;
    if (strEql(name, "_kext_kernel_api")) return @intFromPtr(&registry.kernel_api);
    if (strEql(name, "_kext_log")) return @intFromPtr(&registry.log);
    if (strEql(name, "_kext_register_driver")) return @intFromPtr(&registry.registerDriver);
    return null;
}

fn strEql(a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

pub fn loadImage(name: []const u8, image: []const u8) bool {
    var regions: [8]mmu.Region = undefined;
    var regions_used: usize = 0;
    const result = macho.loadWithOptions(image, &regions, &regions_used, .{
        .resolver = kernelResolver,
        .resolver_ctx = null,
        .user_accessible = false,
    }) catch |err| {
        uart.print("opendarwin: kext load failed: ");
        uart.print(name);
        uart.print(": ");
        uart.print(@errorName(err));
        uart.print("\n");
        return false;
    };

    for (regions[0..regions_used]) |region| {
        mmu.mapExtra(region.pa, region.len, region.prot);
        mmu.inheritExtraInTaskTables(region.pa, region.len, region.prot);
    }

    const entry: api.KextEntry = @ptrFromInt(result.entry);
    const rc = entry(&registry.kernel_api);
    if (rc != api.KEXT_SUCCESS) {
        uart.print("opendarwin: kext entry failed: ");
        uart.print(name);
        uart.print("\n");
        return false;
    }

    uart.print("opendarwin: kext loaded: ");
    uart.print(name);
    uart.print("\n");
    return true;
}

pub fn loadFromFat(name: []const u8) bool {
    const n = fat.readFile(name, &kext_scratch) orelse return false;
    return loadImage(name, kext_scratch[0..n]);
}

pub fn loadBundleFromFat(bundle_name: []const u8) bool {
    const info_path = std.fmt.bufPrint(&path_scratch, "{s}/Contents/Info.plist", .{bundle_name}) catch return false;
    const info_len = fat.readFile(info_path, &plist_scratch) orelse return false;
    const info = plist.parseInfoPlist(plist_scratch[0..info_len], &xml_scratch) catch |err| {
        uart.print("opendarwin: kext plist failed: ");
        uart.print(bundle_name);
        uart.print(": ");
        uart.print(@errorName(err));
        uart.print("\n");
        return false;
    };

    uart.print("opendarwin: kext bundle: ");
    uart.print(info.bundle_identifier);
    uart.print(" executable ");
    uart.print(info.executable);
    uart.print("\n");

    const exe_path = std.fmt.bufPrint(&path_scratch, "{s}/Contents/MacOS/{s}", .{ bundle_name, info.executable }) catch return false;
    const exe_len = fat.readFile(exe_path, &kext_scratch) orelse {
        uart.print("opendarwin: kext executable missing: ");
        uart.print(exe_path);
        uart.print("\n");
        return false;
    };
    return loadImage(info.bundle_identifier, kext_scratch[0..exe_len]);
}
