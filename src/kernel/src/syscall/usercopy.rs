//! Memory copy utilities between kernel and user address spaces.

pub fn copy_in<T: Copy>(user_addr: u64) -> Option<T> {
    if user_addr == 0 || user_addr % (core::mem::align_of::<T>() as u64) != 0 {
        return None;
    }
    unsafe {
        let ptr = user_addr as *const T;
        Some(core::ptr::read(ptr))
    }
}

pub fn copy_out<T: Copy>(user_addr: u64, val: &T) -> bool {
    if user_addr == 0 || user_addr % (core::mem::align_of::<T>() as u64) != 0 {
        return false;
    }
    unsafe {
        let ptr = user_addr as *mut T;
        core::ptr::write(ptr, *val);
        true
    }
}

pub fn copy_bytes_in(dst: &mut [u8], user_addr: u64) -> bool {
    if user_addr == 0 && !dst.is_empty() {
        return false;
    }
    unsafe {
        let src = user_addr as *const u8;
        core::ptr::copy_nonoverlapping(src, dst.as_mut_ptr(), dst.len());
        true
    }
}

pub fn copy_bytes_out(user_addr: u64, src: &[u8]) -> bool {
    if user_addr == 0 && !src.is_empty() {
        return false;
    }
    unsafe {
        let dst = user_addr as *mut u8;
        core::ptr::copy_nonoverlapping(src.as_ptr(), dst, src.len());
        true
    }
}
