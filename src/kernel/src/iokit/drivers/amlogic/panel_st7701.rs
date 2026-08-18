//! Sitronix ST7701 panel driver for Amlogic Superbird.
//!
//! Ported from `drivers/gpu/drm/panel/panel-sitronix-st7701.c` and
//! `patches/0005-st7701-panel.patch`.

use super::dsi::Dsi;
use super::pinctrl::Pinctrl;
use super::regs::mdelay;

const MIPI_DCS_SOFT_RESET: u8 = 0x01;
const MIPI_DCS_EXIT_SLEEP_MODE: u8 = 0x11;
const MIPI_DCS_SET_DISPLAY_ON: u8 = 0x29;
const MIPI_DCS_SET_TEAR_ON: u8 = 0x35;

const SLEEP_DELAY_MS: u64 = 120;

fn switch_bank(dsi: &Dsi, cmd2: bool, bkx: u8) {
    let val = if cmd2 { 0x10 | bkx } else { 0x00 };
    dsi.dcs_write(0xff, &[0x77, 0x01, 0x00, 0x00, val]);
}

fn cfield_prep(mask: u8, val: u8) -> u8 {
    (val << mask.trailing_zeros()) & mask
}

fn pv_gamma() -> [u8; 16] {
    [
        cfield_prep(0xc0, 0) | cfield_prep(0x0f, 0xa),
        cfield_prep(0xc0, 0) | cfield_prep(0x3f, 0x10),
        cfield_prep(0xc0, 2) | cfield_prep(0x3f, 0x16),
        cfield_prep(0x1f, 0xe),
        cfield_prep(0xc0, 0) | cfield_prep(0x1f, 0x11),
        cfield_prep(0x0f, 0x6),
        cfield_prep(0x3f, 0x6),
        cfield_prep(0x0f, 0xa),
        cfield_prep(0x0f, 0x8),
        cfield_prep(0x3f, 0x24),
        cfield_prep(0x0f, 0x7),
        cfield_prep(0xc0, 1) | cfield_prep(0x1f, 0x13),
        cfield_prep(0x1f, 0x11),
        cfield_prep(0xc0, 1) | cfield_prep(0x3f, 0x28),
        cfield_prep(0xc0, 2) | cfield_prep(0x3f, 0x2d),
        cfield_prep(0xc0, 3) | cfield_prep(0x1f, 0x11),
    ]
}

fn nv_gamma() -> [u8; 16] {
    [
        cfield_prep(0xc0, 0) | cfield_prep(0x0f, 0x6),
        cfield_prep(0xc0, 2) | cfield_prep(0x3f, 0xd),
        cfield_prep(0xc0, 3) | cfield_prep(0x3f, 0x13),
        cfield_prep(0x1f, 0x9),
        cfield_prep(0xc0, 0) | cfield_prep(0x1f, 0xd),
        cfield_prep(0x0f, 0x4),
        cfield_prep(0x3f, 0x4),
        cfield_prep(0x0f, 0x7),
        cfield_prep(0x0f, 0x7),
        cfield_prep(0x3f, 0x23),
        cfield_prep(0x0f, 0x5),
        cfield_prep(0xc0, 0) | cfield_prep(0x1f, 0x15),
        cfield_prep(0x1f, 0x14),
        cfield_prep(0xc0, 2) | cfield_prep(0x3f, 0x27),
        cfield_prep(0xc0, 2) | cfield_prep(0x3f, 0x2c),
        cfield_prep(0xc0, 1) | cfield_prep(0x1f, 0xf),
    ]
}

fn init_sequence(dsi: &Dsi) {
    dsi.dcs_write(MIPI_DCS_SOFT_RESET, &[0x00]);
    mdelay(5);

    dsi.dcs_write(MIPI_DCS_EXIT_SLEEP_MODE, &[0x00]);
    mdelay(SLEEP_DELAY_MS);

    switch_bank(dsi, true, 0);
    dsi.dcs_write(0xb0, &pv_gamma());
    dsi.dcs_write(0xb1, &nv_gamma());

    dsi.dcs_write(0xc0, &[0x63, 0x00]);
    dsi.dcs_write(0xc1, &[0x06, 0x14]);
    dsi.dcs_write(0xc2, &[0x31, 0x07]);

    switch_bank(dsi, true, 1);
    dsi.dcs_write(0xb0, &[93]);
    dsi.dcs_write(0xb1, &[69]);
    dsi.dcs_write(0xb2, &[0x02]);
    dsi.dcs_write(0xb3, &[0x80]);
    dsi.dcs_write(0xb5, &[0x45]);
    dsi.dcs_write(0xb7, &[0x85]);
    dsi.dcs_write(0xb8, &[0x21]);
    dsi.dcs_write(0xc1, &[0x78]);
    dsi.dcs_write(0xc2, &[0x78]);
    dsi.dcs_write(0xd0, &[0x88]);
}

fn gip_sequence(dsi: &Dsi) {
    switch_bank(dsi, true, 3);
    dsi.dcs_write(0xef, &[0x08]);

    switch_bank(dsi, true, 0);
    dsi.dcs_write(0xcc, &[0x10]);

    switch_bank(dsi, true, 1);
    dsi.dcs_write(0xb9, &[0x10, 0x1f]);
    dsi.dcs_write(0xbb, &[0x03]);
    dsi.dcs_write(0xbc, &[0x3e]);

    dsi.dcs_write(0xe0, &[0x00, 0x00, 0x02]);
    dsi.dcs_write(
        0xe1,
        &[
            0x04, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x20, 0x20,
        ],
    );
    dsi.dcs_write(
        0xe2,
        &[
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ],
    );
    dsi.dcs_write(0xe3, &[0x00, 0x00, 0x33, 0x00]);
    dsi.dcs_write(0xe4, &[0x22, 0x00]);
    dsi.dcs_write(
        0xe5,
        &[
            0x04, 0x34, 0x9a, 0xa0, 0x06, 0x34, 0x9a, 0xa0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00,
        ],
    );
    dsi.dcs_write(0xe6, &[0x00, 0x00, 0x33, 0x00]);
    dsi.dcs_write(0xe7, &[0x22, 0x00]);
    dsi.dcs_write(
        0xe8,
        &[
            0x05, 0x34, 0x9a, 0xa0, 0x07, 0x34, 0x9a, 0xa0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00,
        ],
    );
    dsi.dcs_write(0xeb, &[0x02, 0x00, 0x40, 0x40, 0x00, 0x00, 0x00]);
    dsi.dcs_write(0xec, &[0x00, 0x00]);
    dsi.dcs_write(
        0xed,
        &[
            0xfa, 0x45, 0x0b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xb0,
            0x54, 0xaf,
        ],
    );
    dsi.dcs_write(0xef, &[0x08, 0x08, 0x08, 0x45, 0x3f, 0x54]);

    switch_bank(dsi, true, 3);
    dsi.dcs_write(0xe8, &[0x00, 0x0e]);

    switch_bank(dsi, false, 0);
    dsi.dcs_write(MIPI_DCS_EXIT_SLEEP_MODE, &[0x00]);
    mdelay(SLEEP_DELAY_MS);

    switch_bank(dsi, true, 3);
    dsi.dcs_write(0xe8, &[0x00, 0x0c]);
    mdelay(2);
    dsi.dcs_write(0xe8, &[0x00, 0x00]);

    switch_bank(dsi, false, 0);
    dsi.dcs_write(MIPI_DCS_SET_TEAR_ON, &[0x00]);
    mdelay(15);
}

pub fn prepare(dsi: &Dsi, pinctrl: &Pinctrl) {
    pinctrl.panel_reset_init(false);
    mdelay(20);
    pinctrl.panel_reset_set(true);
    mdelay(150);

    init_sequence(dsi);
    gip_sequence(dsi);
    switch_bank(dsi, false, 0);
}

pub fn enable(dsi: &Dsi) {
    dsi.dcs_write(MIPI_DCS_SET_DISPLAY_ON, &[0x00]);
}
