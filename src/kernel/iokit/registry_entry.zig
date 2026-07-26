//! IORegistryEntry — named node with parent/child links and a property bag.

const types = @import("types.zig");

pub const Property = struct {
    key: [types.MAX_PROPERTY_KEY_LEN]u8 = undefined,
    key_len: usize = 0,
    kind: enum { u64, str } = .u64,
    u64_value: u64 = 0,
    str_value: [types.MAX_NAME_LEN]u8 = undefined,
    str_len: usize = 0,
};

pub const IORegistryEntry = struct {
    name: [types.MAX_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    location: [types.MAX_NAME_LEN]u8 = undefined,
    location_len: usize = 0,
    parent: ?*IORegistryEntry = null,
    children: [types.MAX_CHILDREN]?*IORegistryEntry = .{null} ** types.MAX_CHILDREN,
    child_count: usize = 0,
    properties: [types.MAX_PROPERTIES]Property = [_]Property{.{}} ** types.MAX_PROPERTIES,
    property_count: usize = 0,

    pub fn init(self: *IORegistryEntry, name: []const u8, location: []const u8) void {
        self.* = .{};
        self.setName(name);
        self.setLocation(location);
    }

    pub fn setName(self: *IORegistryEntry, name: []const u8) void {
        const n = @min(name.len, types.MAX_NAME_LEN);
        @memcpy(self.name[0..n], name[0..n]);
        self.name_len = n;
    }

    pub fn getName(self: *const IORegistryEntry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setLocation(self: *IORegistryEntry, location: []const u8) void {
        const n = @min(location.len, types.MAX_NAME_LEN);
        @memcpy(self.location[0..n], location[0..n]);
        self.location_len = n;
    }

    pub fn getLocation(self: *const IORegistryEntry) []const u8 {
        return self.location[0..self.location_len];
    }

    pub fn attachChild(self: *IORegistryEntry, child: *IORegistryEntry) bool {
        if (self.child_count >= types.MAX_CHILDREN) return false;
        self.children[self.child_count] = child;
        self.child_count += 1;
        child.parent = self;
        return true;
    }

    pub fn detachChild(self: *IORegistryEntry, child: *IORegistryEntry) void {
        var i: usize = 0;
        while (i < self.child_count) : (i += 1) {
            if (self.children[i] == child) {
                child.parent = null;
                var j = i;
                while (j + 1 < self.child_count) : (j += 1) {
                    self.children[j] = self.children[j + 1];
                }
                self.child_count -= 1;
                self.children[self.child_count] = null;
                return;
            }
        }
    }

    pub fn setPropertyU64(self: *IORegistryEntry, key: []const u8, value: u64) bool {
        if (self.findProperty(key)) |prop| {
            prop.kind = .u64;
            prop.u64_value = value;
            prop.str_len = 0;
            return true;
        }
        if (self.property_count >= types.MAX_PROPERTIES) return false;
        const prop = &self.properties[self.property_count];
        const kn = @min(key.len, types.MAX_PROPERTY_KEY_LEN);
        @memcpy(prop.key[0..kn], key[0..kn]);
        prop.key_len = kn;
        prop.kind = .u64;
        prop.u64_value = value;
        prop.str_len = 0;
        self.property_count += 1;
        return true;
    }

    pub fn setPropertyStr(self: *IORegistryEntry, key: []const u8, value: []const u8) bool {
        if (self.findProperty(key)) |prop| {
            prop.kind = .str;
            const vn = @min(value.len, types.MAX_NAME_LEN);
            @memcpy(prop.str_value[0..vn], value[0..vn]);
            prop.str_len = vn;
            return true;
        }
        if (self.property_count >= types.MAX_PROPERTIES) return false;
        const prop = &self.properties[self.property_count];
        const kn = @min(key.len, types.MAX_PROPERTY_KEY_LEN);
        @memcpy(prop.key[0..kn], key[0..kn]);
        prop.key_len = kn;
        prop.kind = .str;
        const vn = @min(value.len, types.MAX_NAME_LEN);
        @memcpy(prop.str_value[0..vn], value[0..vn]);
        prop.str_len = vn;
        self.property_count += 1;
        return true;
    }

    pub fn getPropertyU64(self: *const IORegistryEntry, key: []const u8) ?u64 {
        const prop = self.findPropertyConst(key) orelse return null;
        if (prop.kind != .u64) return null;
        return prop.u64_value;
    }

    pub fn getPropertyStr(self: *const IORegistryEntry, key: []const u8) ?[]const u8 {
        const prop = self.findPropertyConst(key) orelse return null;
        if (prop.kind != .str) return null;
        return prop.str_value[0..prop.str_len];
    }

    fn findProperty(self: *IORegistryEntry, key: []const u8) ?*Property {
        for (self.properties[0..self.property_count]) |*prop| {
            if (eql(prop.key[0..prop.key_len], key)) return prop;
        }
        return null;
    }

    fn findPropertyConst(self: *const IORegistryEntry, key: []const u8) ?*const Property {
        for (self.properties[0..self.property_count]) |*prop| {
            if (eql(prop.key[0..prop.key_len], key)) return prop;
        }
        return null;
    }

    fn eql(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            if (ca != cb) return false;
        }
        return true;
    }
};
