//! Memory copy utilities between kernel and user address spaces.

pub fn copy_in<T: Copy>(user_addr: usize) -> Option<T> {
    if user_addr == 0 || user_addr % core::mem::align_of::<T>() != 0 {
        return None;
    }
    unsafe {
        let ptr = user_addr as *const T;
        Some(core::ptr::read(ptr))
    }
}

pub fn copy_out<T: Copy>(user_addr: usize, val: &T) -> bool {
    if user_addr == 0 || user_addr % core::mem::align_of::<T>() != 0 {
        return false;
    }
    unsafe {
        let ptr = user_addr as *mut T;
        core::ptr::write(ptr, *val);
        true
    }
}

pub fn copy_bytes_in(dst: &mut [u8], user_addr: usize) -> bool {
    if user_addr == 0 && !dst.is_empty() {
        return false;
    }
    unsafe {
        let src = user_addr as *const u8;
        core::ptr::copy_nonoverlapping(src, dst.as_mut_ptr(), dst.len());
        true
    }
}

pub fn copy_bytes_out(user_addr: usize, src: &[u8]) -> bool {
    if user_addr == 0 && !src.is_empty() {
        return false;
    }
    unsafe {
        let dst = user_addr as *mut u8;
        core::ptr::copy_nonoverlapping(src.as_ptr(), dst, src.len());
        true
    }
}

pub fn copyin_path<'a, const N: usize>(user_addr: usize, buf: &'a mut [u8; N]) -> Option<&'a str> {
    if user_addr == 0 {
        return None;
    }
    let mut n = 0;
    while n < N {
        let mut byte = [0u8; 1];
        if !copy_bytes_in(&mut byte, user_addr + n) {
            return None;
        }
        if byte[0] == 0 {
            break;
        }
        buf[n] = byte[0];
        n += 1;
    }
    if n == N {
        return None;
    }
    core::str::from_utf8(&buf[..n]).ok()
}
