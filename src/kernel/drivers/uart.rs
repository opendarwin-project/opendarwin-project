//! Universal early UART console driver supporting ARM PL011 and Amlogic Meson AO UART.

use core::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use spin::Mutex;

pub const BOOTSTRAP_BASE: u64 = 0x0900_0000;

#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UartKind {
    Pl011 = 0,
    MesonAo = 1,
}

// PL011 registers
const PL011_DR: usize = 0x00;
const PL011_FR: usize = 0x18;
const PL011_FR_TXFF: u32 = 1 << 5;

// Meson UART registers
const MESON_WFIFO: usize = 0x00;
const MESON_STATUS: usize = 0x0c;
const MESON_STATUS_TX_FULL: u32 = 1 << 21;

static UART_LOCK: Mutex<()> = Mutex::new(());
static UART_BASE: AtomicU64 = AtomicU64::new(BOOTSTRAP_BASE);
static UART_KIND: AtomicU32 = AtomicU32::new(UartKind::Pl011 as u32);

pub fn init(base: u64) {
    let _guard = UART_LOCK.lock();
    UART_BASE.store(base, Ordering::Release);
    if base >= 0xff80_0000 {
        UART_KIND.store(UartKind::MesonAo as u32, Ordering::Release);
    } else {
        UART_KIND.store(UartKind::Pl011 as u32, Ordering::Release);
    }
}

pub fn set_kind(kind: UartKind) {
    UART_KIND.store(kind as u32, Ordering::Release);
}

pub fn putc(c: u8) {
    let base = UART_BASE.load(Ordering::Acquire);
    let kind = if UART_KIND.load(Ordering::Acquire) == UartKind::MesonAo as u32 {
        UartKind::MesonAo
    } else {
        UartKind::Pl011
    };

    unsafe {
        match kind {
            UartKind::Pl011 => {
                let fr = (base + PL011_FR as u64) as *const u32;
                let dr = (base + PL011_DR as u64) as *mut u32;

                while (core::ptr::read_volatile(fr) & PL011_FR_TXFF) != 0 {
                    core::hint::spin_loop();
                }
                core::ptr::write_volatile(dr, c as u32);
            }
            UartKind::MesonAo => {
                let status = (base + MESON_STATUS as u64) as *const u32;
                let wfifo = (base + MESON_WFIFO as u64) as *mut u32;

                while (core::ptr::read_volatile(status) & MESON_STATUS_TX_FULL) != 0 {
                    core::hint::spin_loop();
                }
                core::ptr::write_volatile(wfifo, c as u32);
            }
        }
    }
}

pub fn print(s: &str) {
    let _guard = UART_LOCK.lock();
    for byte in s.bytes() {
        if byte == b'\n' {
            putc(b'\r');
        }
        putc(byte);
    }
    // Also mirror to display console if active
    if crate::drivers::display::is_active() {
        crate::drivers::display::print(s);
    }
}

pub fn print_bytes(bytes: &[u8]) {
    let _guard = UART_LOCK.lock();
    for &byte in bytes {
        if byte == b'\n' {
            putc(b'\r');
        }
        putc(byte);
    }
}

pub fn print_hex(value: u64) {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut buf = [b'0'; 18];
    buf[0] = b'0';
    buf[1] = b'x';
    for i in 0..16 {
        let shift = (15 - i) * 4;
        let digit = ((value >> shift) & 0xf) as usize;
        buf[2 + i] = DIGITS[digit];
    }
    let _guard = UART_LOCK.lock();
    for &b in &buf {
        putc(b);
    }
    if crate::drivers::display::is_active() {
        if let Ok(s) = core::str::from_utf8(&buf) {
            crate::drivers::display::print(s);
        }
    }
}

pub fn print_dec(mut value: u64) {
    if value == 0 {
        print("0");
        return;
    }
    let mut buf = [b'0'; 20];
    let mut i = buf.len();
    while value > 0 {
        i -= 1;
        buf[i] = b'0' + (value % 10) as u8;
        value /= 10;
    }
    let _guard = UART_LOCK.lock();
    for &b in &buf[i..] {
        putc(b);
    }
    if crate::drivers::display::is_active() {
        if let Ok(s) = core::str::from_utf8(&buf[i..]) {
            crate::drivers::display::print(s);
        }
    }
}
