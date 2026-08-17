//! Saved register frame pushed by vector table's SAVE_CONTEXT macro.
//! Field order/types must match that macro's stack offsets exactly.
//!
//! Layout:
//!   0x000..0x0f7  x0..x30          (248 bytes)
//!   0x0f8..0x11f  sp_el0..far_el1  (40 bytes; ends at 288)
//!   0x120..0x31f  q0..q31          (512 bytes)
//! Total 800 bytes.

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Frame {
    pub x: [u64; 31],
    pub sp_el0: u64,
    pub elr_el1: u64,
    pub spsr_el1: u64,
    pub esr_el1: u64,
    pub far_el1: u64,
    pub q: [u128; 32],
}

impl Default for Frame {
    fn default() -> Self {
        Self {
            x: [0; 31],
            sp_el0: 0,
            elr_el1: 0,
            spsr_el1: 0,
            esr_el1: 0,
            far_el1: 0,
            q: [0; 32],
        }
    }
}

impl Frame {
    #[inline(always)]
    pub fn arg(&self, index: usize) -> usize {
        self.x[index] as usize
    }

    #[inline(always)]
    pub fn arg_u64(&self, index: usize) -> u64 {
        self.x[index]
    }

    #[inline(always)]
    pub fn arg_u32(&self, index: usize) -> u32 {
        self.x[index] as u32
    }

    #[inline(always)]
    pub fn arg_i32(&self, index: usize) -> i32 {
        self.x[index] as i32
    }

    #[inline(always)]
    pub fn arg_i64(&self, index: usize) -> i64 {
        self.x[index] as i64
    }

    #[inline(always)]
    pub fn set_return_usize(&mut self, val: usize) {
        self.x[0] = val as u64;
    }

    #[inline(always)]
    pub fn set_return_u64(&mut self, val: u64) {
        self.x[0] = val;
    }

    #[inline(always)]
    pub fn set_return_u32(&mut self, val: u32) {
        self.x[0] = val as u64;
    }

    #[inline(always)]
    pub fn set_return_i64(&mut self, val: i64) {
        self.x[0] = val as u64;
    }
}

const _: () = {
    assert!(core::mem::offset_of!(Frame, sp_el0) == 248);
    assert!(core::mem::offset_of!(Frame, q) == 288);
    assert!(core::mem::size_of::<Frame>() == 800);
};
