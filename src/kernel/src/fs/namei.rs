//! BSD-style pathname lookup (`namei`).

use crate::fs::vfs::{self, Vnode};
use crate::syscall::usercopy;

pub const MAX_PATH: usize = 1024;

pub fn lookup(path: &str) -> Option<*mut Vnode> {
    let root = vfs::root_vnode()?;
    lookupat(root, path)
}

pub fn lookupat(dvp: *mut Vnode, path: &str) -> Option<*mut Vnode> {
    if path.is_empty() {
        vfs::vref(dvp);
        return Some(dvp);
    }

    let mut start = dvp;
    let mut rest = path;

    if path.starts_with('/') || path.starts_with('\\') {
        start = vfs::root_vnode()?;
        rest = trim_left_sep(path);
    }

    vfs::vref(start);
    let mut cur = start;

    for segment in rest.split(|c| c == '/' || c == '\\') {
        if segment.is_empty() || segment == "." {
            continue;
        }

        let mut next = None;
        let err = vfs::vop_lookup(cur, segment, &mut next);
        vfs::vrele(cur);
        if err != 0 || next.is_none() {
            return None;
        }
        cur = next.unwrap();
    }

    Some(cur)
}

fn trim_left_sep(path: &str) -> &str {
    path.trim_start_matches(|c| c == '/' || c == '\\')
}

pub fn copyin_path<'a>(user_addr: u64, buf: &'a mut [u8; MAX_PATH]) -> Option<&'a str> {
    if user_addr == 0 {
        return None;
    }
    let mut n = 0;
    while n < MAX_PATH {
        let mut byte = [0u8; 1];
        if !usercopy::copy_bytes_in(&mut byte, user_addr + n as u64) {
            return None;
        }
        if byte[0] == 0 {
            break;
        }
        buf[n] = byte[0];
        n += 1;
    }
    if n == MAX_PATH {
        return None;
    }
    core::str::from_utf8(&buf[..n]).ok()
}
