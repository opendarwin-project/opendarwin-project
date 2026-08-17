//! String and memory functions: strlen, strcmp, strncmp, strchr, strrchr,
//! strdup, strndup, strlcpy, strlcat, memcpy, memmove, memset, memcmp,
//! memchr, memrchr.

use core::ffi::{c_char, c_int, c_long, c_ulong, c_void};

use crate::common;

// ── memcpy / memmove / memset (needed by allocator and others) ─────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn memcpy(dst: *mut c_void, src: *const c_void, len: usize) -> *mut c_void {
    if dst.is_null() {
        return core::ptr::null_mut();
    }
    if src.is_null() {
        return dst;
    }
    let out = dst as *mut u8;
    let input = src as *const u8;
    for i in 0..len {
        core::ptr::write_volatile(out.add(i), core::ptr::read_volatile(input.add(i)));
    }
    dst
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn memmove(dst: *mut c_void, src: *const c_void, len: usize) -> *mut c_void {
    if dst.is_null() {
        return core::ptr::null_mut();
    }
    if src.is_null() {
        return dst;
    }
    let out = dst as *mut u8;
    let input = src as *const u8;
    if (out as usize) <= (input as usize) {
        for i in 0..len {
            core::ptr::write_volatile(out.add(i), core::ptr::read_volatile(input.add(i)));
        }
    } else {
        let mut i = len;
        while i != 0 {
            i -= 1;
            core::ptr::write_volatile(out.add(i), core::ptr::read_volatile(input.add(i)));
        }
    }
    dst
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn memset(dst: *mut c_void, value: c_int, len: usize) -> *mut c_void {
    if dst.is_null() {
        return core::ptr::null_mut();
    }
    let out = dst as *mut u8;
    let byte = value as u8;
    for i in 0..len {
        core::ptr::write_volatile(out.add(i), byte);
    }
    dst
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn memcmp(s1: *const c_void, s2: *const c_void, n: usize) -> c_int {
    if s1.is_null() || s2.is_null() {
        return 0;
    }
    let p1 = s1 as *const u8;
    let p2 = s2 as *const u8;
    for i in 0..n {
        let b1 = *p1.add(i);
        let b2 = *p2.add(i);
        if b1 != b2 {
            return if b1 < b2 { -1 } else { 1 };
        }
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn memchr(s: *const c_void, c: c_int, n: usize) -> *mut c_void {
    if s.is_null() {
        return core::ptr::null_mut();
    }
    let bytes = s as *const u8;
    let target = c as u8;
    for i in 0..n {
        if *bytes.add(i) == target {
            return bytes.add(i) as *mut c_void;
        }
    }
    core::ptr::null_mut()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn memrchr(s: *const c_void, c: c_int, n: usize) -> *mut c_void {
    if s.is_null() {
        return core::ptr::null_mut();
    }
    let bytes = s as *const u8;
    let target = c as u8;
    let mut i = n;
    while i > 0 {
        i -= 1;
        if *bytes.add(i) == target {
            return bytes.add(i) as *mut c_void;
        }
    }
    core::ptr::null_mut()
}

// ── strlen ─────────────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strlen(s: *const c_char) -> usize {
    common::cstrLen(s)
}

// ── strcmp family ──────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strcmp(s1: *const c_char, s2: *const c_char) -> c_int {
    let mut i = 0;
    loop {
        let c1 = *s1.add(i) as u8;
        let c2 = *s2.add(i) as u8;
        if c1 != c2 {
            return if c1 < c2 { -1 } else { 1 };
        }
        if c1 == 0 {
            return 0;
        }
        i += 1;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strncmp(s1: *const c_char, s2: *const c_char, n: usize) -> c_int {
    for i in 0..n {
        let c1 = *s1.add(i) as u8;
        let c2 = *s2.add(i) as u8;
        if c1 != c2 {
            return if c1 < c2 { -1 } else { 1 };
        }
        if c1 == 0 {
            return 0;
        }
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strcasecmp(s1: *const c_char, s2: *const c_char) -> c_int {
    let mut i = 0;
    loop {
        let c1 = (*s1.add(i) as u8).to_ascii_lowercase();
        let c2 = (*s2.add(i) as u8).to_ascii_lowercase();
        if c1 != c2 {
            return if c1 < c2 { -1 } else { 1 };
        }
        if c1 == 0 {
            return 0;
        }
        i += 1;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strncasecmp(s1: *const c_char, s2: *const c_char, n: usize) -> c_int {
    for i in 0..n {
        let c1 = (*s1.add(i) as u8).to_ascii_lowercase();
        let c2 = (*s2.add(i) as u8).to_ascii_lowercase();
        if c1 != c2 {
            return if c1 < c2 { -1 } else { 1 };
        }
        if c1 == 0 {
            return 0;
        }
    }
    0
}

// ── strchr / strrchr / strstr ──────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strchr(s: *const c_char, c: c_int) -> *mut c_char {
    let target = c as u8 as c_char;
    let mut i = 0;
    loop {
        let ch = *s.add(i);
        if ch == target {
            return s.add(i) as *mut c_char;
        }
        if ch == 0 {
            return core::ptr::null_mut();
        }
        i += 1;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strrchr(s: *const c_char, c: c_int) -> *mut c_char {
    let mut last = core::ptr::null_mut();
    let target = c as u8 as c_char;
    let mut i = 0;
    loop {
        let ch = *s.add(i);
        if ch == target {
            last = s.add(i) as *mut c_char;
        }
        if ch == 0 {
            return last;
        }
        i += 1;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strstr(haystack: *const c_char, needle: *const c_char) -> *mut c_char {
    let needle_len = common::cstrLen(needle);
    if needle_len == 0 {
        return haystack as *mut c_char;
    }
    let mut i = 0;
    while *haystack.add(i) != 0 {
        let mut j = 0;
        while j < needle_len && *haystack.add(i + j) == *needle.add(j) {
            j += 1;
        }
        if j == needle_len {
            return haystack.add(i) as *mut c_char;
        }
        i += 1;
    }
    core::ptr::null_mut()
}

// ── strdup / strndup ──────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strdup(s: *const c_char) -> *mut c_char {
    let len = common::cstrLen(s);
    let dst = crate::malloc::malloc(len + 1);
    if dst.is_null() {
        return core::ptr::null_mut();
    }
    memcpy(dst, s as *const c_void, len + 1);
    dst as *mut c_char
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strndup(s: *const c_char, n: usize) -> *mut c_char {
    let mut len = 0;
    while len < n && *s.add(len) != 0 {
        len += 1;
    }
    let dst = crate::malloc::malloc(len + 1);
    if dst.is_null() {
        return core::ptr::null_mut();
    }
    memcpy(dst, s as *const c_void, len);
    *(dst as *mut u8).add(len) = 0;
    dst as *mut c_char
}

// ── strlcpy / strlcat ─────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strlcpy(dst: *mut c_char, src: *const c_char, dstsize: usize) -> usize {
    if dstsize == 0 {
        return common::cstrLen(src);
    }
    let mut i = 0;
    while i + 1 < dstsize {
        let c = *src.add(i);
        if c == 0 {
            break;
        }
        *dst.add(i) = c;
        i += 1;
    }
    *dst.add(i) = 0;
    i + common::cstrLen(src.add(i))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strlcat(dst: *mut c_char, src: *const c_char, dstsize: usize) -> usize {
    let dst_len = common::cstrLen(dst);
    if dst_len >= dstsize {
        return dst_len + common::cstrLen(src);
    }
    dst_len + strlcpy(dst.add(dst_len), src, dstsize - dst_len)
}

// ── strtol / strtoul / strtoll / strtoull ─────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strtol(s: *const c_char, endp: *mut *const c_char, base: c_int) -> c_long {
    strtoll_internal(s, endp, base) as c_long
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strtoul(
    s: *const c_char,
    endp: *mut *const c_char,
    base: c_int,
) -> c_ulong {
    strtoull_internal(s, endp, base) as c_ulong
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strtoll(s: *const c_char, endp: *mut *const c_char, base: c_int) -> i64 {
    strtoll_internal(s, endp, base)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strtoull(s: *const c_char, endp: *mut *const c_char, base: c_int) -> u64 {
    strtoull_internal(s, endp, base)
}

unsafe fn strtoll_internal(s: *const c_char, endp: *mut *const c_char, base: c_int) -> i64 {
    // Skip leading whitespace
    let mut p = s;
    while (*p as u8).is_ascii_whitespace() {
        p = p.add(1);
    }

    // Handle sign
    let mut negative = false;
    if *p as u8 == b'+' {
        p = p.add(1);
    } else if *p as u8 == b'-' {
        negative = true;
        p = p.add(1);
    }

    // Handle base prefix
    let mut actual_base = base as u8;
    if base == 0 {
        if *p as u8 == b'0' {
            let next = *p.add(1) as u8;
            if next == b'x' || next == b'X' {
                actual_base = 16;
                p = p.add(2);
            } else {
                actual_base = 8;
                p = p.add(1);
            }
        } else {
            actual_base = 10;
        }
    } else if base == 16 && *p as u8 == b'0' {
        let next = *p.add(1) as u8;
        if next == b'x' || next == b'X' {
            p = p.add(2);
        }
    }

    // Parse digits
    let mut result: u64 = 0;
    loop {
        let c = *p as u8;
        let digit = if (b'0'..=b'9').contains(&c) {
            c - b'0'
        } else if (b'a'..=b'z').contains(&c) {
            c - b'a' + 10
        } else if (b'A'..=b'Z').contains(&c) {
            c - b'A' + 10
        } else {
            255
        };
        if digit >= actual_base {
            break;
        }
        result = result
            .wrapping_mul(actual_base as u64)
            .wrapping_add(digit as u64);
        p = p.add(1);
    }

    if !endp.is_null() {
        *endp = p;
    }

    if negative {
        0u64.wrapping_sub(result) as i64
    } else {
        result as i64
    }
}

unsafe fn strtoull_internal(s: *const c_char, endp: *mut *const c_char, base: c_int) -> u64 {
    strtoll_internal(s, endp, base) as u64
}

// ── strtod (minimal) ──────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strtod(s: *const c_char, endp: *mut *const c_char) -> f64 {
    let mut p = s;
    while (*p as u8).is_ascii_whitespace() {
        p = p.add(1);
    }

    let mut negative = false;
    if *p as u8 == b'+' {
        p = p.add(1);
    } else if *p as u8 == b'-' {
        negative = true;
        p = p.add(1);
    }

    // Parse integer part
    let mut int_part: u64 = 0;
    while (*p as u8).is_ascii_digit() {
        int_part = int_part * 10 + (*p as u8 - b'0') as u64;
        p = p.add(1);
    }

    let mut result: f64 = int_part as f64;

    // Parse fractional part
    if *p as u8 == b'.' {
        p = p.add(1);
        let mut frac: f64 = 0.0;
        let mut place: f64 = 0.1;
        while (*p as u8).is_ascii_digit() {
            frac += (*p as u8 - b'0') as f64 * place;
            place *= 0.1;
            p = p.add(1);
        }
        result += frac;
    }

    // Parse exponent
    if *p as u8 == b'e' || *p as u8 == b'E' {
        p = p.add(1);
        let mut exp_neg = false;
        if *p as u8 == b'+' {
            p = p.add(1);
        } else if *p as u8 == b'-' {
            exp_neg = true;
            p = p.add(1);
        }
        let mut exp: i32 = 0;
        while (*p as u8).is_ascii_digit() {
            exp = exp * 10 + (*p as u8 - b'0') as i32;
            p = p.add(1);
        }
        if exp_neg {
            while exp > 0 {
                exp -= 1;
                result /= 10.0;
            }
        } else {
            while exp > 0 {
                exp -= 1;
                result *= 10.0;
            }
        }
    }

    if !endp.is_null() {
        *endp = p;
    }
    if negative { -result } else { result }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn atof(s: *const c_char) -> f64 {
    strtod(s, core::ptr::null_mut())
}

// ── qsort / bsearch ───────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn qsort(
    base: *mut c_void,
    nmemb: usize,
    size: usize,
    compar: Option<unsafe extern "C" fn(*const c_void, *const c_void) -> c_int>,
) {
    if base.is_null() || nmemb < 2 {
        return;
    }
    let compar = match compar {
        Some(f) => f,
        None => return,
    };

    // Insertion sort — good enough for the small arrays CF uses.
    let arr = base as *mut u8;
    for i in 1..nmemb {
        let key_off = i * size;
        let mut j = i;
        while j > 0 {
            let prev_off = (j - 1) * size;
            if compar(
                arr.add(prev_off) as *const c_void,
                arr.add(key_off) as *const c_void,
            ) <= 0
            {
                break;
            }
            // swap
            for k in 0..size {
                let tmp = *arr.add(prev_off + k);
                *arr.add(prev_off + k) = *arr.add(key_off + k);
                *arr.add(key_off + k) = tmp;
            }
            j -= 1;
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn bsearch(
    key: *const c_void,
    base: *const c_void,
    nmemb: usize,
    size: usize,
    compar: Option<unsafe extern "C" fn(*const c_void, *const c_void) -> c_int>,
) -> *mut c_void {
    if base.is_null() {
        return core::ptr::null_mut();
    }
    let compar = match compar {
        Some(f) => f,
        None => return core::ptr::null_mut(),
    };
    let arr = base as *const u8;
    let mut lo = 0;
    let mut hi = nmemb;
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        let mid_off = mid * size;
        let cmp = compar(key, arr.add(mid_off) as *const c_void);
        if cmp == 0 {
            return arr.add(mid_off) as *mut c_void;
        }
        if cmp < 0 {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    core::ptr::null_mut()
}

// ── abs / labs ─────────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub extern "C" fn abs(x: c_int) -> c_int {
    x.abs()
}

#[unsafe(no_mangle)]
pub extern "C" fn labs(x: c_long) -> c_long {
    x.abs()
}

#[unsafe(no_mangle)]
pub extern "C" fn flsl(x: c_long) -> c_int {
    if x == 0 {
        return 0;
    }
    let mut v = x.unsigned_abs();
    let mut bit = 0;
    while v > 1 {
        bit += 1;
        v >>= 1;
    }
    bit + 1
}

// ── strnlen / strtok / strerror ────────────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strnlen(s: *const c_char, maxlen: usize) -> usize {
    let mut i = 0;
    while i < maxlen && *s.add(i) != 0 {
        i += 1;
    }
    i
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strtok(_s: *mut c_char, _delim: *const c_char) -> *mut c_char {
    core::ptr::null_mut()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strerror(_errnum: c_int) -> *mut c_char {
    c"Unknown error: 0".as_ptr() as *mut c_char
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strncasecmp_l(
    s1: *const c_char,
    s2: *const c_char,
    n: usize,
    _loc: *mut c_void,
) -> c_int {
    strncasecmp(s1, s2, n)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strtol_l(
    s: *const c_char,
    endp: *mut *const c_char,
    base: c_int,
    _loc: *mut c_void,
) -> c_long {
    strtol(s, endp, base)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strtod_l(
    s: *const c_char,
    endp: *mut *const c_char,
    _loc: *mut c_void,
) -> f64 {
    strtod(s, endp)
}

#[unsafe(no_mangle)]
pub extern "C" fn isdigit(c: c_int) -> c_int {
    if (b'0'..=b'9').contains(&(c as u8)) {
        1
    } else {
        0
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn isspace(c: c_int) -> c_int {
    if (c as u8).is_ascii_whitespace() {
        1
    } else {
        0
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn isxdigit(c: c_int) -> c_int {
    let ch = c as u8;
    if (b'0'..=b'9').contains(&ch) || (b'a'..=b'f').contains(&ch) || (b'A'..=b'F').contains(&ch) {
        1
    } else {
        0
    }
}

// ── strncpy / fortified (_chk) variants ────────────────────────────────

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strncpy(dst: *mut c_char, src: *const c_char, n: usize) -> *mut c_char {
    let mut i = 0;
    while i < n {
        let c = *src.add(i);
        *dst.add(i) = c;
        if c == 0 {
            break;
        }
        i += 1;
    }
    while i < n {
        *dst.add(i) = 0;
        i += 1;
    }
    dst
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __memcpy_chk(
    dst: *mut c_void,
    src: *const c_void,
    len: usize,
    _dstlen: usize,
) -> *mut c_void {
    memcpy(dst, src, len)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __memmove_chk(
    dst: *mut c_void,
    src: *const c_void,
    len: usize,
    _dstlen: usize,
) -> *mut c_void {
    memmove(dst, src, len)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __memset_chk(
    dst: *mut c_void,
    value: c_int,
    len: usize,
    _dstlen: usize,
) -> *mut c_void {
    memset(dst, value, len)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __strlcat_chk(
    dst: *mut c_char,
    src: *const c_char,
    dstsize: usize,
    _dstlen: usize,
) -> usize {
    strlcat(dst, src, dstsize)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __strlcpy_chk(
    dst: *mut c_char,
    src: *const c_char,
    dstsize: usize,
    _dstlen: usize,
) -> usize {
    strlcpy(dst, src, dstsize)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn __strncpy_chk(
    dst: *mut c_char,
    src: *const c_char,
    n: usize,
    _dstlen: usize,
) -> *mut c_char {
    strncpy(dst, src, n)
}
