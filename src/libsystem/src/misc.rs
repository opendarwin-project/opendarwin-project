//! Miscellaneous exports: environ, getenv, setenv, unsetenv, uuid_generate,
//! localeconv, setlocale, atexit, atfork, __cxa_atexit, pow, fmod, modf, etc.

use core::ffi::{c_char, c_int, c_void};

use crate::common;

// ── environment ────────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub static mut environ: *const c_char = c"".as_ptr();

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getenv(_name: *const c_char) -> *const c_char {
    core::ptr::null()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn setenv(
    _name: *const c_char,
    _value: *const c_char,
    _overwrite: c_int,
) -> c_int {
    common::stubErr("setenv")
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn unsetenv(_name: *const c_char) -> c_int {
    common::stubErr("unsetenv")
}

// ── locale ─────────────────────────────────────────────────────────────

#[repr(C)]
#[derive(Copy, Clone)]
pub struct Lconv {
    pub decimal_point: *const c_char,
    pub thousands_sep: *const c_char,
    pub grouping: *const c_char,
    pub int_curr_symbol: *const c_char,
    pub currency_symbol: *const c_char,
    pub mon_decimal_point: *const c_char,
    pub mon_thousands_sep: *const c_char,
    pub mon_grouping: *const c_char,
    pub positive_sign: *const c_char,
    pub negative_sign: *const c_char,
    pub int_frac_digits: i8,
    pub frac_digits: i8,
    pub p_cs_precedes: i8,
    pub p_sep_by_space: i8,
    pub n_cs_precedes: i8,
    pub n_sep_by_space: i8,
    pub p_sign_posn: i8,
    pub n_sign_posn: i8,
}

static mut DEFAULT_LCONV: Lconv = Lconv {
    decimal_point: c".".as_ptr(),
    thousands_sep: c"".as_ptr(),
    grouping: c"".as_ptr(),
    int_curr_symbol: c"".as_ptr(),
    currency_symbol: c"".as_ptr(),
    mon_decimal_point: c"".as_ptr(),
    mon_thousands_sep: c"".as_ptr(),
    mon_grouping: c"".as_ptr(),
    positive_sign: c"".as_ptr(),
    negative_sign: c"".as_ptr(),
    int_frac_digits: 2,
    frac_digits: 2,
    p_cs_precedes: 1,
    p_sep_by_space: 0,
    n_cs_precedes: 1,
    n_sep_by_space: 0,
    p_sign_posn: 1,
    n_sign_posn: 1,
};

#[unsafe(no_mangle)]
pub unsafe extern "C" fn localeconv() -> *mut Lconv {
    &raw mut DEFAULT_LCONV
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn setlocale(_category: c_int, _locale: *const c_char) -> *const c_char {
    c"C".as_ptr()
}

// ── atexit / __cxa_atexit ─────────────────────────────────────────────

const MAX_ATEXIT: usize = 32;
static mut ATEXIT_FNS: [Option<unsafe extern "C" fn()>; MAX_ATEXIT] = [None; MAX_ATEXIT];
static mut ATEXIT_COUNT: usize = 0;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn atexit(fn_ptr: Option<unsafe extern "C" fn()>) -> c_int {
    if ATEXIT_COUNT >= MAX_ATEXIT {
        return -1;
    }
    ATEXIT_FNS[ATEXIT_COUNT] = fn_ptr;
    ATEXIT_COUNT += 1;
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __cxa_atexit(
    _func: Option<unsafe extern "C" fn(*mut c_void)>,
    _arg: *mut c_void,
    _dso_handle: *mut c_void,
) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __cxa_finalize(_dso_handle: *mut c_void) {}

// QoS class constants (Darwin).
pub const QOS_CLASS_DEFAULT: c_int = 0x15;
pub const QOS_CLASS_UNSPECIFIED: c_int = 0x00;

#[unsafe(no_mangle)]
pub extern "C" fn qos_class_self() -> c_int {
    QOS_CLASS_DEFAULT
}

// passwd stubs — enough for CFUtilities getpwuid paths.
#[repr(C)]
#[derive(Copy, Clone)]
pub struct Passwd {
    pub pw_name: *const c_char,
    pub pw_passwd: *const c_char,
    pub pw_uid: u32,
    pub pw_gid: u32,
    pub pw_change: *const c_char,
    pub pw_class: *const c_char,
    pub pw_gecos: *const c_char,
    pub pw_dir: *const c_char,
    pub pw_shell: *const c_char,
}

static mut ROOT_PASSWD: Passwd = Passwd {
    pw_name: c"root".as_ptr(),
    pw_passwd: c"*".as_ptr(),
    pw_uid: 0,
    pw_gid: 0,
    pw_change: c"".as_ptr(),
    pw_class: c"".as_ptr(),
    pw_gecos: c"root".as_ptr(),
    pw_dir: c"/var/root".as_ptr(),
    pw_shell: c"/bin/sh".as_ptr(),
};

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getpwuid(uid: u32) -> *mut Passwd {
    if uid != 0 {
        return core::ptr::null_mut();
    }
    &raw mut ROOT_PASSWD
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getpwnam(name: *const c_char) -> *mut Passwd {
    if name.is_null() {
        return core::ptr::null_mut();
    }
    if *name != b'r' as c_char
        || *name.add(1) != b'o' as c_char
        || *name.add(2) != b'o' as c_char
        || *name.add(3) != b't' as c_char
        || *name.add(4) != 0
    {
        return core::ptr::null_mut();
    }
    &raw mut ROOT_PASSWD
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn getpwuid_r(
    uid: u32,
    pwd: *mut Passwd,
    _buf: *mut u8,
    _buflen: usize,
    result: *mut *mut Passwd,
) -> c_int {
    if uid != 0 {
        if !result.is_null() {
            *result = core::ptr::null_mut();
        }
        return common::EINVAL;
    }
    if !pwd.is_null() {
        *pwd = ROOT_PASSWD;
    }
    if !result.is_null() {
        *result = pwd;
    }
    0
}

// ── math stubs (CF uses these) ─────────────────────────────────────────

#[unsafe(no_mangle)]
pub extern "C" fn pow(x: f64, y: f64) -> f64 {
    if y == 0.0 {
        return 1.0;
    }
    if x == 0.0 {
        return 0.0;
    }
    let floor_y = floor(y);
    if y == floor_y && y > 0.0 && y < 64.0 {
        let mut result = 1.0;
        let mut exp = y as i64;
        let mut base = x;
        while exp > 0 {
            if exp & 1 == 1 {
                result *= base;
            }
            base *= base;
            exp >>= 1;
        }
        return result;
    }
    1.0
}

#[unsafe(no_mangle)]
pub extern "C" fn powf(x: f32, y: f32) -> f32 {
    pow(x as f64, y as f64) as f32
}

#[unsafe(no_mangle)]
pub extern "C" fn fmod(x: f64, y: f64) -> f64 {
    if y == 0.0 {
        return 0.0;
    }
    x - trunc(x / y) * y
}

#[unsafe(no_mangle)]
pub extern "C" fn fmodf(x: f32, y: f32) -> f32 {
    fmod(x as f64, y as f64) as f32
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn modf(x: f64, iptr: *mut f64) -> f64 {
    let i = trunc(x);
    if !iptr.is_null() {
        *iptr = i;
    }
    x - i
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn modff(x: f32, iptr: *mut f32) -> f32 {
    let i = truncf(x);
    if !iptr.is_null() {
        *iptr = i;
    }
    x - i
}

#[unsafe(no_mangle)]
pub extern "C" fn sqrt(x: f64) -> f64 {
    if x <= 0.0 {
        return 0.0;
    }
    let mut guess = x / 2.0;
    if guess == 0.0 {
        return 0.0;
    }
    for _ in 0..50 {
        guess = (guess + x / guess) / 2.0;
    }
    guess
}

#[unsafe(no_mangle)]
pub extern "C" fn sqrtf(x: f32) -> f32 {
    sqrt(x as f64) as f32
}

#[unsafe(no_mangle)]
pub extern "C" fn fabs(x: f64) -> f64 {
    if x < 0.0 { -x } else { x }
}

#[unsafe(no_mangle)]
pub extern "C" fn fabsf(x: f32) -> f32 {
    if x < 0.0 { -x } else { x }
}

#[unsafe(no_mangle)]
pub extern "C" fn ceil(x: f64) -> f64 {
    let i = x as i64;
    if x > i as f64 {
        (i + 1) as f64
    } else {
        i as f64
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ceilf(x: f32) -> f32 {
    ceil(x as f64) as f32
}

#[unsafe(no_mangle)]
pub extern "C" fn floor(x: f64) -> f64 {
    let i = x as i64;
    if x < i as f64 {
        (i - 1) as f64
    } else {
        i as f64
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn floorf(x: f32) -> f32 {
    floor(x as f64) as f32
}

#[unsafe(no_mangle)]
pub extern "C" fn round(x: f64) -> f64 {
    if x >= 0.0 {
        floor(x + 0.5)
    } else {
        ceil(x - 0.5)
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roundf(x: f32) -> f32 {
    round(x as f64) as f32
}

#[unsafe(no_mangle)]
pub extern "C" fn trunc(x: f64) -> f64 {
    (x as i64) as f64
}

#[unsafe(no_mangle)]
pub extern "C" fn truncf(x: f32) -> f32 {
    (x as i32) as f32
}

#[unsafe(no_mangle)]
pub extern "C" fn copysign(x: f64, y: f64) -> f64 {
    let x_abs = fabs(x);
    if y.is_sign_negative() { -x_abs } else { x_abs }
}

#[unsafe(no_mangle)]
pub extern "C" fn copysignf(x: f32, y: f32) -> f32 {
    let x_abs = fabsf(x);
    if y.is_sign_negative() { -x_abs } else { x_abs }
}

#[unsafe(no_mangle)]
pub extern "C" fn ldexp(x: f64, exp: c_int) -> f64 {
    let mut result = x;
    let mut e = exp;
    if e < 0 {
        while e < 0 {
            result /= 2.0;
            e += 1;
        }
    } else {
        while e > 0 {
            result *= 2.0;
            e -= 1;
        }
    }
    result
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn frexp(x: f64, exp: *mut c_int) -> f64 {
    let mut e: c_int = 0;
    let mut val = x;
    while fabs(val) >= 2.0 {
        val /= 2.0;
        e += 1;
    }
    while fabs(val) < 1.0 && val != 0.0 {
        val *= 2.0;
        e -= 1;
    }
    if !exp.is_null() {
        *exp = e;
    }
    val
}

// ── uuid stubs ─────────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn uuid_generate(out: *mut u8) {
    if !out.is_null() {
        core::ptr::write_bytes(out, 0, 16);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn uuid_generate_random(out: *mut u8) {
    uuid_generate(out);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn uuid_clear(uu: *mut u8) {
    if !uu.is_null() {
        core::ptr::write_bytes(uu, 0, 16);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn uuid_is_null(uu: *const [u8; 16]) -> bool {
    if !uu.is_null() {
        for b in &*uu {
            if *b != 0 {
                return false;
            }
        }
    }
    true
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn uuid_compare(a: *const [u8; 16], b: *const [u8; 16]) -> c_int {
    if a.is_null() || b.is_null() {
        return 0;
    }
    let aa = &*a;
    let bb = &*b;
    for i in 0..16 {
        if aa[i] < bb[i] {
            return -1;
        }
        if aa[i] > bb[i] {
            return 1;
        }
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn uuid_copy(dst: *mut u8, src: *const [u8; 16]) {
    if !dst.is_null() && !src.is_null() {
        core::ptr::copy_nonoverlapping(src as *const u8, dst, 16);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn uuid_to_string(_uu: *const [u8; 16], out: *mut *const c_char) {
    if !out.is_null() {
        *out = c"00000000-0000-0000-0000-000000000000".as_ptr();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn uuid_string_to_uuid(_str: *const c_char, uu: *mut u8) {
    if !uu.is_null() {
        core::ptr::write_bytes(uu, 0, 16);
    }
}
