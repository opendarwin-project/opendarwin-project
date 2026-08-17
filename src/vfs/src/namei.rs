//! BSD-style pathname lookup (`namei`).

use crate::vfs::{self, Vnode};

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
