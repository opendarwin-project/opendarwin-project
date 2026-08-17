//! PL011 UART driver for early bootstrap console and diagnostic output.

use core::sync::atomic::{AtomicU64, Ordering};
use spin::Mutex;

pub const BOOTSTRAP_BASE: u64 = 0x0900_0000;

const UART_DR: usize = 0x00;
const UART_FR: usize = 0x18;
const UART_FR_TXFF: u32 = 1 << 5;

static UART_LOCK: Mutex<()> = Mutex::new(());
static UART_BASE: AtomicU64 = AtomicU64::new(BOOTSTRAP_BASE);

pub fn init(base: u64) {
    let _guard = UART_LOCK.lock();
    UART_BASE.store(base, Ordering::Release);
}

pub fn putc(c: u8) {
    let base = UART_BASE.load(Ordering::Acquire);
    unsafe {
        let fr = (base + UART_FR as u64) as *const u32;
        let dr = (base + UART_DR as u64) as *mut u32;

        while (core::ptr::read_volatile(fr) & UART_FR_TXFF) != 0 {
            core::hint::spin_loop();
        }
        core::ptr::write_volatile(dr, c as u32);
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
}
