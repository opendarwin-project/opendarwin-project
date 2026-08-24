//! IORegistryEntry — named node with parent/child links and a property bag.
//! Children and properties are intrusive lists (XNU: OSOrderedSet / OSDictionary).

const slab = @import("../mm/slab.zig");

pub const Property = struct {
    next: ?*Property = null,
    key: []const u8 = &.{},
    kind: enum { u64, str } = .u64,
    u64_value: u64 = 0,
    str_value: []const u8 = &.{},
};

pub const ChildLink = struct {
    next: ?*ChildLink = null,
    entry: *IORegistryEntry,
};

pub const IORegistryEntry = struct {
    name: []const u8 = &.{},
    location: []const u8 = &.{},
    parent: ?*IORegistryEntry = null,
    child_head: ?*ChildLink = null,
    child_tail: ?*ChildLink = null,
    property_head: ?*Property = null,

    pub fn init(self: *IORegistryEntry, name: []const u8, location: []const u8) void {
        self.* = .{};
        self.setName(name);
        self.setLocation(location);
    }

    pub fn setName(self: *IORegistryEntry, name: []const u8) void {
        self.name = dupSlice(name);
    }

    pub fn getName(self: *const IORegistryEntry) []const u8 {
        return self.name;
    }

    pub fn setLocation(self: *IORegistryEntry, location: []const u8) void {
        self.location = dupSlice(location);
    }

    pub fn getLocation(self: *const IORegistryEntry) []const u8 {
        return self.location;
    }

    pub fn childCount(self: *const IORegistryEntry) usize {
        var n: usize = 0;
        var link = self.child_head;
        while (link) |l| : (link = l.next) n += 1;
        return n;
    }

    pub fn childAt(self: *const IORegistryEntry, index: usize) ?*IORegistryEntry {
        var i: usize = 0;
        var link = self.child_head;
        while (link) |l| : (link = l.next) {
            if (i == index) return l.entry;
            i += 1;
        }
        return null;
    }

    pub fn attachChild(self: *IORegistryEntry, child: *IORegistryEntry) bool {
        const link = slab.allocObj(ChildLink);
        link.* = .{ .entry = child };
        if (self.child_tail) |tail| {
            tail.next = link;
            self.child_tail = link;
        } else {
            self.child_head = link;
            self.child_tail = link;
        }
        child.parent = self;
        return true;
    }

    pub fn detachChild(self: *IORegistryEntry, child: *IORegistryEntry) void {
        var prev: ?*ChildLink = null;
        var link = self.child_head;
        while (link) |l| {
            if (l.entry == child) {
                if (prev) |p| {
                    p.next = l.next;
                } else {
                    self.child_head = l.next;
                }
                if (self.child_tail == l) self.child_tail = prev;
                child.parent = null;
                slab.free(@ptrCast(l));
                return;
            }
            prev = l;
            link = l.next;
        }
    }

    pub fn setPropertyU64(self: *IORegistryEntry, key: []const u8, value: u64) bool {
        if (self.findProperty(key)) |prop| {
            prop.kind = .u64;
            prop.u64_value = value;
            prop.str_value = &.{};
            return true;
        }
        const prop = slab.allocObj(Property);
        prop.* = .{
            .next = self.property_head,
            .key = dupSlice(key),
            .kind = .u64,
            .u64_value = value,
        };
        self.property_head = prop;
        return true;
    }

    pub fn setPropertyStr(self: *IORegistryEntry, key: []const u8, value: []const u8) bool {
        if (self.findProperty(key)) |prop| {
            prop.kind = .str;
            prop.str_value = dupSlice(value);
            return true;
        }
        const prop = slab.allocObj(Property);
        prop.* = .{
            .next = self.property_head,
            .key = dupSlice(key),
            .kind = .str,
            .str_value = dupSlice(value),
        };
        self.property_head = prop;
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
        return prop.str_value;
    }

    fn findProperty(self: *IORegistryEntry, key: []const u8) ?*Property {
        var prop = self.property_head;
        while (prop) |p| : (prop = p.next) {
            if (eql(p.key, key)) return p;
        }
        return null;
    }

    fn findPropertyConst(self: *const IORegistryEntry, key: []const u8) ?*const Property {
        var prop = self.property_head;
        while (prop) |p| : (prop = p.next) {
            if (eql(p.key, key)) return p;
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

fn dupSlice(s: []const u8) []const u8 {
    if (s.len == 0) return &.{};
    const buf: [*]u8 = @ptrCast(slab.alloc(s.len));
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}
