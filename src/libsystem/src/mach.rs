//! Mach and VM primitives: mach_task_self, mach_host_self, mach_reply_port,
//! mach_msg2_trap, iokit_user_client_trap, mach_vm_map, mmap, munmap.

use core::ffi::{c_char, c_int, c_uint, c_void};

use crate::common;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mach_task_self() -> c_uint {
    common::machTrap0(common::MACH_task_self_trap) as c_uint
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mach_host_self() -> c_uint {
    common::machTrap0(common::MACH_host_self_trap) as c_uint
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn host_self_trap() -> c_uint {
    mach_host_self()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mach_reply_port() -> c_uint {
    common::machTrap0(common::MACH_mach_reply_port) as c_uint
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mach_msg2_trap(
    msg: *mut u8,
    option: u64,
    send_size_and_bits: u64,
    ports: u64,
    id_and_voucher: u64,
    desc_and_rcv_name: u64,
    priority_and_rcv_size: u64,
    timeout: u32,
) -> c_uint {
    common::machTrap8(
        common::MACH_mach_msg2_trap,
        msg as usize,
        option as usize,
        send_size_and_bits as usize,
        ports as usize,
        id_and_voucher as usize,
        desc_and_rcv_name as usize,
        priority_and_rcv_size as usize,
        timeout as usize,
    ) as c_uint
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iokit_user_client_trap(
    connect: c_uint,
    index: u32,
    p1: usize,
    p2: usize,
    p3: usize,
    p4: usize,
    p5: usize,
    p6: usize,
) -> c_int {
    common::machTrap8(
        common::MACH_iokit_user_client_trap,
        connect as usize,
        index as usize,
        p1,
        p2,
        p3,
        p4,
        p5,
        p6,
    ) as c_int
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn IOConnectTrap6(
    connect: c_uint,
    index: u32,
    p1: usize,
    p2: usize,
    p3: usize,
    p4: usize,
    p5: usize,
    p6: usize,
) -> c_int {
    iokit_user_client_trap(connect, index, p1, p2, p3, p4, p5, p6)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn IOConnectTrap0(connect: c_uint, index: u32) -> c_int {
    IOConnectTrap6(connect, index, 0, 0, 0, 0, 0, 0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn IOConnectTrap1(connect: c_uint, index: u32, p1: usize) -> c_int {
    IOConnectTrap6(connect, index, p1, 0, 0, 0, 0, 0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn IOConnectTrap2(
    connect: c_uint,
    index: u32,
    p1: usize,
    p2: usize,
) -> c_int {
    IOConnectTrap6(connect, index, p1, p2, 0, 0, 0, 0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn IOConnectTrap3(
    connect: c_uint,
    index: u32,
    p1: usize,
    p2: usize,
    p3: usize,
) -> c_int {
    IOConnectTrap6(connect, index, p1, p2, p3, 0, 0, 0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn IOConnectTrap4(
    connect: c_uint,
    index: u32,
    p1: usize,
    p2: usize,
    p3: usize,
    p4: usize,
) -> c_int {
    IOConnectTrap6(connect, index, p1, p2, p3, p4, 0, 0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn IOConnectTrap5(
    connect: c_uint,
    index: u32,
    p1: usize,
    p2: usize,
    p3: usize,
    p4: usize,
    p5: usize,
) -> c_int {
    IOConnectTrap6(connect, index, p1, p2, p3, p4, p5, 0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mach_vm_map(
    target: c_uint,
    address: *mut u64,
    size: u64,
    mask: u64,
    flags: c_int,
    _object: c_uint,
    _offset: u64,
    _copy: bool,
    cur_protection: c_int,
    _max_protection: c_int,
    _inheritance: c_int,
) -> c_int {
    common::machTrap6(
        common::MACH_mach_vm_map_trap,
        target as usize,
        address as usize,
        size as usize,
        mask as usize,
        flags as usize,
        cur_protection as usize,
    ) as c_int
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mmap(
    addr: *mut c_void,
    len: usize,
    prot: c_int,
    _flags: c_int,
    _fd: c_int,
    _offset: i64,
) -> *mut c_void {
    let mut mapped_addr: u64 = if !addr.is_null() { addr as u64 } else { 0 };
    let vm_flags: c_int = if mapped_addr == 0 { 1 } else { 0 }; // VM_FLAGS_ANYWHERE
    let kr = mach_vm_map(
        mach_task_self(),
        &mut mapped_addr,
        len as u64,
        0,
        vm_flags,
        0,
        0,
        false,
        prot,
        prot,
        0,
    );
    if kr != common::KERN_SUCCESS as c_int {
        common::errno = 12; // ENOMEM
        return common::usize_max as *mut c_void; // MAP_FAILED
    }
    mapped_addr as *mut c_void
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn munmap(_addr: *mut c_void, _len: usize) -> c_int {
    0
}

#[unsafe(no_mangle)]
pub static mut mach_task_self_: c_uint = 0; // Initialized lazily

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mach_error_string(_err: c_int) -> *const c_char {
    c"mach error".as_ptr()
}
