//! Terminal control: tcgetattr/tcsetattr, job-control tty pgrp, ttyname.

const common = @import("common.zig");
const C = common;

pub const NCCS: usize = 20;

pub const Termios = extern struct {
    c_iflag: u32 = 0,
    c_oflag: u32 = 0,
    c_cflag: u32 = 0,
    c_lflag: u32 = 0,
    c_cc: [NCCS]u8 = .{0} ** NCCS,
    c_ispeed: u32 = 9600,
    c_ospeed: u32 = 9600,
};

const ICRNL: u32 = 0x00000100;
const IXON: u32 = 0x00000200;
const OPOST: u32 = 0x00000001;
const ONLCR: u32 = 0x00000002;
const CREAD: u32 = 0x00000800;
const CS8: u32 = 0x00000300;
const ICANON: u32 = 0x00000100;
const ECHO: u32 = 0x00000008;
const ISIG: u32 = 0x00000001;

const TIOCGETA: usize = 0x402c7413;
const TIOCSETA: usize = 0x802c7414;
const TIOCSETAW: usize = 0x802c7415;
const TIOCSETAF: usize = 0x802c7416;
const TIOCGPGRP: usize = 0x40047477;
const TIOCSPGRP: usize = 0x80047476;

var tty_pgrp: c_int = 1;
var tty_attrs: [3]Termios = .{.{}, .{}, .{}};

fn defaultTermios() Termios {
    var t: Termios = .{};
    t.c_iflag = ICRNL | IXON;
    t.c_oflag = OPOST | ONLCR;
    t.c_cflag = CREAD | CS8;
    t.c_lflag = ICANON | ECHO | ISIG;
    t.c_cc[0] = 4; // VEOF ^D
    t.c_cc[1] = 10; // VEOL ^J
    t.c_cc[3] = 8; // VINTR ^H
    t.c_cc[4] = 21; // VKILL ^U
    t.c_cc[5] = 4; // VEOF alt
    t.c_cc[6] = 23; // VQUIT ^S
    t.c_cc[7] = 19; // VSUSP ^Y
    t.c_cc[8] = 0; // VSTART
    t.c_cc[9] = 0; // VSTOP
    t.c_cc[10] = 0; // VSUSP
    t.c_cc[11] = 0; // VEOL2
    t.c_cc[12] = 0; // VSWTCH
    t.c_cc[13] = 0; // VDSUSP
    t.c_cc[14] = 0; // VREPRINT
    t.c_cc[15] = 0; // VDISCARD
    t.c_cc[16] = 0; // VWERASE
    t.c_cc[17] = 0; // VLNEXT
    t.c_cc[18] = 0; // VEOL2
    t.c_cc[19] = 0; // spare
    t.c_ispeed = 9600;
    t.c_ospeed = 9600;
    return t;
}

fn ttyIndex(fd: c_int) ?usize {
    if (fd < 0 or fd > 2) return null;
    return @intCast(fd);
}

fn ttyAttrs(fd: c_int) ?*Termios {
    const idx = ttyIndex(fd) orelse return null;
    if (tty_attrs[idx].c_cflag == 0) tty_attrs[idx] = defaultTermios();
    return &tty_attrs[idx];
}

pub fn ioctl_tty(fd: c_int, request: usize, arg: usize) c_int {
    const idx = ttyIndex(fd) orelse return C.ENOSYS;
    switch (request) {
        TIOCGETA => {
            const out = @as(*Termios, @ptrFromInt(arg));
            out.* = ttyAttrs(fd).?.*;
            return 0;
        },
        TIOCSETA, TIOCSETAW, TIOCSETAF => {
            const inp = @as(*const Termios, @ptrFromInt(arg));
            tty_attrs[idx] = inp.*;
            return 0;
        },
        TIOCGPGRP => {
            @as(*c_int, @ptrFromInt(arg)).* = tty_pgrp;
            return 0;
        },
        TIOCSPGRP => {
            tty_pgrp = @as(*const c_int, @ptrFromInt(arg)).*;
            return 0;
        },
        else => return C.ENOSYS,
    }
}

pub export fn tcgetattr(fd: c_int, termios_p: ?*Termios) c_int {
    const out = termios_p orelse {
        common.errno = C.EINVAL;
        return -1;
    };
    const attrs = ttyAttrs(fd) orelse {
        common.errno = C.ENOTTY;
        return -1;
    };
    out.* = attrs.*;
    return 0;
}

pub export fn tcsetattr(fd: c_int, _: c_int, termios_p: ?*const Termios) c_int {
    const inp = termios_p orelse {
        common.errno = C.EINVAL;
        return -1;
    };
    const idx = ttyIndex(fd) orelse {
        common.errno = C.ENOTTY;
        return -1;
    };
    tty_attrs[idx] = inp.*;
    return 0;
}

pub export fn tcgetpgrp(fd: c_int) c_int {
    if (ttyIndex(fd) == null) {
        common.errno = C.ENOTTY;
        return -1;
    }
    return tty_pgrp;
}

pub export fn tcsetpgrp(fd: c_int, pgrp: c_int) c_int {
    if (ttyIndex(fd) == null) {
        common.errno = C.ENOTTY;
        return -1;
    }
    tty_pgrp = pgrp;
    return 0;
}

var ttyname_buf: [32]u8 = b: {
    var buf: [32]u8 = .{0} ** 32;
  const name = "/dev/tty";
    @memcpy(buf[0..name.len], name);
    break :b buf;
};

pub export fn ttyname(fd: c_int) ?[*:0]u8 {
    if (ttyIndex(fd) == null) {
        common.errno = C.ENOTTY;
        return null;
    }
    return @ptrCast(&ttyname_buf);
}

pub export fn ttyname_r(fd: c_int, buf: [*]u8, len: usize) c_int {
    const name = ttyname(fd) orelse return -1;
    const n = C.cstrLen(name);
    if (len <= n) {
        common.errno = C.ERANGE;
        return -1;
    }
    @memcpy(buf[0..n], name[0..n]);
    buf[n] = 0;
    return 0;
}
