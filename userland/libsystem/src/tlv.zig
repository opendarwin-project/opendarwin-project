//! Thread-local storage (TLV) bootstrap: __tlv_bootstrap.

const common = @import("common.zig");
const C = common;

const TlvDescriptor = extern struct {
    thunk: usize,
    key: usize,
    offset: usize,
};

const MAX_TLV_RECORDS = 16;
const MAX_TLV_THREADS = 64;
const TLV_BLOCK_SIZE = 1024 * 1024;

const TlvRecord = struct {
    template_base: usize = 0,
    storage: [MAX_TLV_THREADS]?[*]u8 = [_]?[*]u8{null} ** MAX_TLV_THREADS,
};

var tlv_records: [MAX_TLV_RECORDS]TlvRecord = [_]TlvRecord{.{}} ** MAX_TLV_RECORDS;
var tlv_record_count: usize = 0;

fn currentTlvThreadIndex() usize {
    const tid = C.darwinSyscall3(C.SYS_thread_selfid, 0, 0, 0);
    if (tid == 0) return 0;
    return @min(tid - 1, MAX_TLV_THREADS - 1);
}

fn findOrCreateTlvRecord(template_base: usize) *TlvRecord {
    var i: usize = 0;
    while (i < tlv_record_count) : (i += 1) {
        if (tlv_records[i].template_base == template_base) return &tlv_records[i];
    }
    if (tlv_record_count >= MAX_TLV_RECORDS) return &tlv_records[MAX_TLV_RECORDS - 1];
    const rec = &tlv_records[tlv_record_count];
    rec.* = .{ .template_base = template_base };
    tlv_record_count += 1;
    return rec;
}

fn tlvStorageFor(record: *TlvRecord) ?[*]u8 {
    const idx = currentTlvThreadIndex();
    if (record.storage[idx]) |storage| return storage;
    const mapped = @import("mach.zig").mmap(null, TLV_BLOCK_SIZE, C.VM_PROT_READ_WRITE, C.MAP_PRIVATE_ANON, -1, 0);
    if (mapped == null or @intFromPtr(mapped.?) == C.usize_max) {
        C.reportStub("tlv mmap failed");
        return null;
    }
    const storage: [*]u8 = @ptrCast(mapped.?);
    record.storage[idx] = storage;
    return storage;
}

fn isTlvRecordKey(key: usize) bool {
    const start = @intFromPtr(&tlv_records);
    const end = start + @sizeOf(@TypeOf(tlv_records));
    return key >= start and key < end and ((key - start) % @sizeOf(TlvRecord)) == 0;
}

pub fn tlvBootstrapImpl(desc: *TlvDescriptor) callconv(.c) ?*anyopaque {
    if (desc.key == 0 or !isTlvRecordKey(desc.key)) {
        const this_addr = @intFromPtr(desc);
        const thunk = desc.thunk;
        var start = this_addr;
        while (start >= 24) {
            const prev: *const TlvDescriptor = @ptrFromInt(start - 24);
            if (prev.thunk != thunk or prev.offset >= @as(*const TlvDescriptor, @ptrFromInt(start)).offset) break;
            start -= 24;
        }
        var end = start;
        var last_offset: usize = 0;
        while (true) {
            const cur: *const TlvDescriptor = @ptrFromInt(end);
            if (cur.thunk != thunk or cur.offset < last_offset) break;
            last_offset = cur.offset;
            end += 24;
            if (end - start > 4096) break;
        }
        desc.key = @intFromPtr(findOrCreateTlvRecord(end));
    }
    const record: *TlvRecord = @ptrFromInt(desc.key);
    const storage = tlvStorageFor(record) orelse return null;
    return @ptrFromInt(@intFromPtr(storage) + desc.offset);
}

/// Darwin's TLV thunk ABI requires a naked trampoline that spills every
/// register the Darwin TLV contract requires before delegating to the Zig impl.
pub export fn __tlv_bootstrap() callconv(.naked) void {
    asm volatile (
        \\stp x29, x30, [sp, #-16]!
        \\mov x29, sp
        \\stp x1, x2, [sp, #-16]!
        \\stp x3, x4, [sp, #-16]!
        \\stp x5, x6, [sp, #-16]!
        \\stp x7, x8, [sp, #-16]!
        \\stp x9, x10, [sp, #-16]!
        \\stp x11, x12, [sp, #-16]!
        \\stp x13, x14, [sp, #-16]!
        \\stp x15, x16, [sp, #-16]!
        \\stp x17, x18, [sp, #-16]!
        \\stp x19, x20, [sp, #-16]!
        \\stp x21, x22, [sp, #-16]!
        \\stp x23, x24, [sp, #-16]!
        \\stp x25, x26, [sp, #-16]!
        \\stp x27, x28, [sp, #-16]!
        \\stp q0, q1, [sp, #-32]!
        \\stp q2, q3, [sp, #-32]!
        \\stp q4, q5, [sp, #-32]!
        \\stp q6, q7, [sp, #-32]!
        \\stp q8, q9, [sp, #-32]!
        \\stp q10, q11, [sp, #-32]!
        \\stp q12, q13, [sp, #-32]!
        \\stp q14, q15, [sp, #-32]!
        \\stp q16, q17, [sp, #-32]!
        \\stp q18, q19, [sp, #-32]!
        \\stp q20, q21, [sp, #-32]!
        \\stp q22, q23, [sp, #-32]!
        \\stp q24, q25, [sp, #-32]!
        \\stp q26, q27, [sp, #-32]!
        \\stp q28, q29, [sp, #-32]!
        \\stp q30, q31, [sp, #-32]!
        \\bl %[impl]
        \\ldp q30, q31, [sp], #32
        \\ldp q28, q29, [sp], #32
        \\ldp q26, q27, [sp], #32
        \\ldp q24, q25, [sp], #32
        \\ldp q22, q23, [sp], #32
        \\ldp q20, q21, [sp], #32
        \\ldp q18, q19, [sp], #32
        \\ldp q16, q17, [sp], #32
        \\ldp q14, q15, [sp], #32
        \\ldp q12, q13, [sp], #32
        \\ldp q10, q11, [sp], #32
        \\ldp q8, q9, [sp], #32
        \\ldp q6, q7, [sp], #32
        \\ldp q4, q5, [sp], #32
        \\ldp q2, q3, [sp], #32
        \\ldp q0, q1, [sp], #32
        \\ldp x27, x28, [sp], #16
        \\ldp x25, x26, [sp], #16
        \\ldp x23, x24, [sp], #16
        \\ldp x21, x22, [sp], #16
        \\ldp x19, x20, [sp], #16
        \\ldp x17, x18, [sp], #16
        \\ldp x15, x16, [sp], #16
        \\ldp x13, x14, [sp], #16
        \\ldp x11, x12, [sp], #16
        \\ldp x9, x10, [sp], #16
        \\ldp x7, x8, [sp], #16
        \\ldp x5, x6, [sp], #16
        \\ldp x3, x4, [sp], #16
        \\ldp x1, x2, [sp], #16
        \\ldp x29, x30, [sp], #16
        \\ret
        :
        : [impl] "X" (&tlvBootstrapImpl),
    );
}

pub export fn sys_icache_invalidate(_: ?*anyopaque, _: usize) void {
    C.reportStub("sys_icache_invalidate");
}

comptime {
    @export(&__tlv_bootstrap, .{ .name = "_tlv_bootstrap", .linkage = .strong });
}
