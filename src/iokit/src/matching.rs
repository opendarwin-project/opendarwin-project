//! `IOServiceMatching` — the matching dictionary handed to
//! `IOServiceGetMatchingService`.
//!
//! Darwin returns a `CFMutableDictionaryRef` here; OpenDarwin uses a tiny
//! fixed-shape dict (class name + length) that the kernel's mach server can
//! parse without a CF implementation. The dict is heap-allocated and consumed
//! (freed) by `IOServiceGetMatchingService`, mirroring Darwin's
//! consume-once semantics.

use alloc::boxed::Box;
use core::ffi::{CStr, c_char, c_void};
use core::ptr;

use crate::types::CLASS_NAME_MAX;

/// Heap-side matching dictionary returned by `IOServiceMatching`.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub(crate) struct MatchingDict {
    pub class_name: [u8; CLASS_NAME_MAX],
    pub class_len: u32,
}

impl Default for MatchingDict {
    fn default() -> Self {
        MatchingDict {
            class_name: [0; CLASS_NAME_MAX],
            class_len: 0,
        }
    }
}

/// Wire body for `MSG_GET_MATCHING_SERVICE` (class_len first, then name).
#[repr(C)]
pub(crate) struct MatchingBody {
    pub class_len: u32,
    pub class_name: [u8; CLASS_NAME_MAX],
}

impl Default for MatchingBody {
    fn default() -> Self {
        MatchingBody {
            class_len: 0,
            class_name: [0; CLASS_NAME_MAX],
        }
    }
}

/// Build a matching dictionary for `IOClass == name`.
///
/// Returns a heap pointer owned by the caller; hand it to
/// `IOServiceGetMatchingService` (which consumes it) or leak it like Darwin's
/// CF semantics allow.
#[unsafe(no_mangle)]
pub extern "C" fn IOServiceMatching(name: *const c_char) -> *mut c_void {
    if name.is_null() {
        return ptr::null_mut();
    }
    // `CStr::from_ptr` is only sound for NUL-terminated strings, which the
    // IOKitLib contract guarantees.
    let name = unsafe { CStr::from_ptr(name) };
    let bytes = name.to_bytes();
    let n = bytes.len().min(CLASS_NAME_MAX);

    let mut dict = Box::new(MatchingDict::default());
    dict.class_len = n as u32;
    dict.class_name[..n].copy_from_slice(&bytes[..n]);
    Box::into_raw(dict) as *mut c_void
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dict_layout() {
        assert_eq!(core::mem::size_of::<MatchingDict>(), 68);
        assert_eq!(core::mem::size_of::<MatchingBody>(), 68);
    }

    #[test]
    fn matching_encodes_name() {
        // c"..." is a C string literal (no_std/core), no alloc or std needed.
        let dict = IOServiceMatching(c"IOFramebuffer".as_ptr());
        assert!(!dict.is_null());

        let d = unsafe { &*(dict as *const MatchingDict) };
        assert_eq!(d.class_len, 13);
        assert_eq!(&d.class_name[..13], b"IOFramebuffer");
        assert_eq!(d.class_name[13], 0);
    }

    #[test]
    fn matching_truncates_overlong_names() {
        // 200-char name, NUL-terminated (index 200), exceeding CLASS_NAME_MAX.
        let mut name = [b'x'; 201];
        name[200] = 0;
        let dict = IOServiceMatching(name.as_ptr().cast::<c_char>());
        assert!(!dict.is_null());

        let d = unsafe { &*(dict as *const MatchingDict) };
        assert_eq!(d.class_len as usize, CLASS_NAME_MAX);
    }

    #[test]
    fn matching_null_name_is_null() {
        assert!(IOServiceMatching(ptr::null()).is_null());
    }
}
