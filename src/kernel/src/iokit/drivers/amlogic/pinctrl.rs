//! Minimal `periphs_pinctrl` GPIO driver on Amlogic Meson G12A.
//!
//! Ported from `drivers/pinctrl/meson/pinctrl-meson-g12a.c`.

use super::regs::modify32;

const GPIO_REGION: usize = 0x40;
const MUX_REGION: usize = 0x2c0;

struct Pin {
    dir_word: usize,
    out_word: usize,
    bit: u32,
    mux_word: usize,
    mux_shift: u32,
}

const GPIOZ_5: Pin = Pin {
    dir_word: 12,
    out_word: 13,
    bit: 5,
    mux_word: 6,
    mux_shift: 20,
};

const GPIOH_4: Pin = Pin {
    dir_word: 9,
    out_word: 10,
    bit: 4,
    mux_word: 0xb,
    mux_shift: 16,
};

pub struct Pinctrl {
    base: usize,
}

impl Pinctrl {
    pub const unsafe fn new(base: usize) -> Self {
        Self { base }
    }

    fn as_gpio_output(&self, pin: &Pin, high: bool) {
        let mux_addr = self.base + MUX_REGION + pin.mux_word * 4;
        let dir_addr = self.base + GPIO_REGION + pin.dir_word * 4;
        let out_addr = self.base + GPIO_REGION + pin.out_word * 4;
        unsafe {
            modify32(mux_addr, 0xf << pin.mux_shift, 0);
            modify32(dir_addr, 1 << pin.bit, 0);
            modify32(out_addr, 1 << pin.bit, if high { 1 << pin.bit } else { 0 });
        }
    }

    fn set_output(&self, pin: &Pin, high: bool) {
        let out_addr = self.base + GPIO_REGION + pin.out_word * 4;
        unsafe { modify32(out_addr, 1 << pin.bit, if high { 1 << pin.bit } else { 0 }) };
    }

    pub fn panel_reset_init(&self, high: bool) {
        self.as_gpio_output(&GPIOZ_5, high);
    }

    pub fn panel_reset_set(&self, high: bool) {
        self.set_output(&GPIOZ_5, high);
    }

    pub fn backlight_enable_init(&self) {
        self.as_gpio_output(&GPIOH_4, false);
    }

    pub fn backlight_enable_set(&self, high: bool) {
        self.set_output(&GPIOH_4, high);
    }
}
