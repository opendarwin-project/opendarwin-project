pub fn copyIn(comptime T: type, user_addr: u64) ?T {
    if (user_addr == 0 or user_addr % @alignOf(T) != 0) return null;
    return @as(*const T, @ptrFromInt(user_addr)).*;
}

pub fn copyOut(comptime T: type, user_addr: u64, value: T) bool {
    if (user_addr == 0 or user_addr % @alignOf(T) != 0) return false;
    @as(*T, @ptrFromInt(user_addr)).* = value;
    return true;
}

pub fn copyBytesIn(dst: []u8, user_addr: u64) bool {
    if (user_addr == 0 and dst.len != 0) return false;
    @memcpy(dst, @as([*]const u8, @ptrFromInt(user_addr))[0..dst.len]);
    return true;
}

pub fn copyBytesOut(user_addr: u64, src: []const u8) bool {
    if (user_addr == 0 and src.len != 0) return false;
    @memcpy(@as([*]u8, @ptrFromInt(user_addr))[0..src.len], src);
    return true;
}
