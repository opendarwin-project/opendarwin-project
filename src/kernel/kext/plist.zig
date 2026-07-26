const std = @import("std");
const xml = @import("xml");

pub const ParseError = error{ MalformedXml, MissingExecutable, MissingIdentifier, UnsupportedPackageType };

pub const Info = struct {
    bundle_identifier: []const u8 = "",
    executable: []const u8 = "",
    package_type: []const u8 = "",
    bundle_name: []const u8 = "",
};

const Key = enum { none, bundle_identifier, executable, package_type, bundle_name };
const TextMode = enum { none, key, string };

pub fn parseInfoPlist(bytes: []const u8, scratch: []u8) ParseError!Info {
    const plist_start = std.mem.indexOf(u8, bytes, "<plist") orelse return ParseError.MalformedXml;
    const doc = bytes[plist_start..];

    var fba = std.heap.FixedBufferAllocator.init(scratch);
    var static_reader: xml.Reader.Static = .init(fba.allocator(), doc, .{
        .namespace_aware = false,
        .updateLocation = null,
        .assume_valid_utf8 = true,
    });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var info = Info{};
    var dict_depth: usize = 0;
    var mode: TextMode = .none;
    var pending_key: Key = .none;

    while (true) {
        const node = reader.read() catch return ParseError.MalformedXml;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "dict")) {
                    dict_depth += 1;
                } else if (dict_depth == 1 and std.mem.eql(u8, name, "key")) {
                    mode = .key;
                } else if (dict_depth == 1 and std.mem.eql(u8, name, "string") and pending_key != .none) {
                    mode = .string;
                }
            },
            .text => {
                const text = reader.textRaw();
                switch (mode) {
                    .key => pending_key = keyFromName(text),
                    .string => {
                        switch (pending_key) {
                            .bundle_identifier => info.bundle_identifier = text,
                            .executable => info.executable = text,
                            .package_type => info.package_type = text,
                            .bundle_name => info.bundle_name = text,
                            .none => {},
                        }
                    },
                    .none => {},
                }
            },
            .element_end => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "key")) {
                    mode = .none;
                } else if (std.mem.eql(u8, name, "string")) {
                    mode = .none;
                    pending_key = .none;
                } else if (std.mem.eql(u8, name, "dict")) {
                    if (dict_depth > 0) dict_depth -= 1;
                }
            },
            else => {},
        }
    }

    if (!std.mem.eql(u8, info.package_type, "KEXT")) return ParseError.UnsupportedPackageType;
    if (info.bundle_identifier.len == 0) return ParseError.MissingIdentifier;
    if (info.executable.len == 0) return ParseError.MissingExecutable;
    return info;
}

fn keyFromName(name: []const u8) Key {
    if (std.mem.eql(u8, name, "CFBundleIdentifier")) return .bundle_identifier;
    if (std.mem.eql(u8, name, "CFBundleExecutable")) return .executable;
    if (std.mem.eql(u8, name, "CFBundlePackageType")) return .package_type;
    if (std.mem.eql(u8, name, "CFBundleName")) return .bundle_name;
    return .none;
}
