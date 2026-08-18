//! Amlogic Meson G12A display pipeline drivers and IOFramebuffer implementation.

pub mod dphy;
pub mod dsi;
pub mod framebuffer;
pub mod hhi;
pub mod panel_st7701;
pub mod pinctrl;
pub mod pwm;
pub mod pwrc;
pub mod regs;
pub mod reset;
pub mod venc;
pub mod vpu;

pub use framebuffer::register as register_amlogic_fb;
