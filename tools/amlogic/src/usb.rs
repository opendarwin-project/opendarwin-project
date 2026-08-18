//! Pure-Rust Linux usbfs communication layer for Amlogic USB boot.
//!
//! Directly interacts with the Linux USB device filesystem (`/dev/bus/usb/...`)
//! via `ioctl` (no external C library or async runtime dependencies).

use std::fs::{File, OpenOptions};
use std::os::raw::{c_int, c_ulong};
use std::os::unix::fs::FileTypeExt;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

unsafe extern "C" {
    fn ioctl(fd: c_int, request: c_ulong, ...) -> c_int;
}

const USBDEVFS_CONTROL: c_ulong = 0xc018_5500;
const USBDEVFS_BULK: c_ulong = 0xc018_5502;
const USBDEVFS_CLAIMINTERFACE: c_ulong = 0x8004_550f;
const USBDEVFS_RELEASEINTERFACE: c_ulong = 0x8004_5510;
const USBDEVFS_RESET: c_ulong = 0x0000_5514;
#[repr(C)]
struct UsbDevFsCtrlTransfer {
    b_request_type: u8,
    b_request: u8,
    w_value: u16,
    w_index: u16,
    w_length: u16,
    timeout: u32,
    data: *mut u8,
}

#[repr(C)]
struct UsbDevFsBulkTransfer {
    ep: u32,
    len: u32,
    timeout: u32,
    _pad: u32,
    data: *mut u8,
}

pub struct UsbDevice {
    file: File,
    interface: u32,
    pub out_ep: u8,
    pub in_ep: u8,
    pub path: PathBuf,
}

impl Drop for UsbDevice {
    fn drop(&mut self) {
        unsafe {
            ioctl(
                self.file.as_raw_fd(),
                USBDEVFS_RELEASEINTERFACE,
                &self.interface,
            );
        }
    }
}

impl UsbDevice {
    /// Discovers and opens a USB device matching the given Vendor ID and Product ID.
    pub fn open(vid: u16, pid: u16, timeout: Duration) -> Result<Self, anyhow::Error> {
        let start = Instant::now();
        loop {
            if let Some(path) = find_usb_device(vid, pid)? {
                match OpenOptions::new().read(true).write(true).open(&path) {
                    Ok(file) => {
                        let intf = 0u32;
                        let rc = unsafe { ioctl(file.as_raw_fd(), USBDEVFS_CLAIMINTERFACE, &intf) };
                        if rc < 0 {
                            let err = std::io::Error::last_os_error();
                            // If busy or permission denied, retry or report
                            if start.elapsed() >= timeout {
                                anyhow::bail!(
                                    "Failed to claim USB interface 0 on {}: {}",
                                    path.display(),
                                    err
                                );
                            }
                        } else {
                            let mut dev_inst = Self {
                                file,
                                interface: intf,
                                out_ep: 0x01,
                                in_ep: 0x81,
                                path,
                            };
                            if let Some((out_ep, in_ep)) = dev_inst.probe_endpoints_ctrl() {
                                dev_inst.out_ep = out_ep;
                                dev_inst.in_ep = in_ep;
                            }
                            return Ok(dev_inst);
                        }
                    }
                    Err(e) => {
                        if start.elapsed() >= timeout {
                            anyhow::bail!("Failed to open {}: {}", path.display(), e);
                        }
                    }
                }
            }

            if start.elapsed() >= timeout {
                anyhow::bail!(
                    "Timed out waiting for Amlogic USB device (VID: {:04x}, PID: {:04x})",
                    vid,
                    pid
                );
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    /// Performs a USB control transfer.
    pub fn control_transfer(
        &self,
        request_type: u8,
        request: u8,
        value: u16,
        index: u16,
        data: &mut [u8],
        timeout_ms: u32,
    ) -> Result<usize, std::io::Error> {
        let mut ctrl = UsbDevFsCtrlTransfer {
            b_request_type: request_type,
            b_request: request,
            w_value: value,
            w_index: index,
            w_length: data.len() as u16,
            timeout: timeout_ms,
            data: data.as_mut_ptr(),
        };

        let rc = unsafe { ioctl(self.file.as_raw_fd(), USBDEVFS_CONTROL, &mut ctrl) };

        if rc >= 0 {
            Ok(rc as usize)
        } else {
            Err(std::io::Error::last_os_error())
        }
    }

    /// Performs a USB bulk write to the given endpoint.
    pub fn bulk_write(
        &self,
        ep: u8,
        data: &[u8],
        timeout_ms: u32,
    ) -> Result<usize, std::io::Error> {
        let mut bulk = UsbDevFsBulkTransfer {
            ep: ep as u32,
            len: data.len() as u32,
            timeout: timeout_ms,
            _pad: 0,
            data: data.as_ptr() as *mut u8,
        };

        let rc = unsafe { ioctl(self.file.as_raw_fd(), USBDEVFS_BULK, &mut bulk) };

        if rc >= 0 {
            Ok(rc as usize)
        } else {
            Err(std::io::Error::last_os_error())
        }
    }

    /// Performs a USB bulk read from the given endpoint.
    pub fn bulk_read(
        &self,
        ep: u8,
        buf: &mut [u8],
        timeout_ms: u32,
    ) -> Result<usize, std::io::Error> {
        let mut bulk = UsbDevFsBulkTransfer {
            ep: (ep | 0x80) as u32,
            len: buf.len() as u32,
            timeout: timeout_ms,
            _pad: 0,
            data: buf.as_mut_ptr(),
        };

        let rc = unsafe { ioctl(self.file.as_raw_fd(), USBDEVFS_BULK, &mut bulk) };

        if rc >= 0 {
            Ok(rc as usize)
        } else {
            Err(std::io::Error::last_os_error())
        }
    }

    /// Performs a USB port reset.
    pub fn reset(&self) -> Result<(), std::io::Error> {
        let rc = unsafe { ioctl(self.file.as_raw_fd(), USBDEVFS_RESET, 0) };
        if rc >= 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error())
        }
    }

    /// Probes configuration descriptor via standard GET_DESCRIPTOR control transfer.
    pub fn probe_endpoints_ctrl(&self) -> Option<(u8, u8)> {
        let mut buf = [0u8; 256];
        if let Ok(n) = self.control_transfer(0x80, 0x06, (2 << 8) | 0, 0, &mut buf, 1000) {
            let mut out_ep = None;
            let mut in_ep = None;
            let mut idx = 0;
            while idx + 2 <= n {
                let len = buf[idx] as usize;
                if len == 0 || idx + len > n {
                    break;
                }
                let desc_type = buf[idx + 1];
                if desc_type == 0x05 && len >= 7 {
                    let ep_addr = buf[idx + 2];
                    let ep_attr = buf[idx + 3];
                    if (ep_attr & 0x03) == 0x02 {
                        if (ep_addr & 0x80) != 0 {
                            in_ep = Some(ep_addr & 0x7f);
                        } else {
                            out_ep = Some(ep_addr & 0x7f);
                        }
                    }
                }
                idx += len;
            }
            if let (Some(o), Some(i)) = (out_ep, in_ep) {
                return Some((o, i));
            }
        }
        None
    }
}

/// Scans `/sys/bus/usb/devices` for a device matching `vid` and `pid`.
fn find_usb_device(vid: u16, pid: u16) -> Result<Option<PathBuf>, std::io::Error> {
    let sysfs = Path::new("/sys/bus/usb/devices");
    if sysfs.exists() {
        for entry in std::fs::read_dir(sysfs)? {
            let entry = entry?;
            let path = entry.path();
            let vid_path = path.join("idVendor");
            let pid_path = path.join("idProduct");
            let bus_path = path.join("busnum");
            let dev_path = path.join("devnum");

            if vid_path.exists() && pid_path.exists() && bus_path.exists() && dev_path.exists() {
                let vid_raw = std::fs::read_to_string(vid_path)?;
                let pid_raw = std::fs::read_to_string(pid_path)?;
                let dev_vid = vid_raw.trim().trim_start_matches("0x");
                let dev_pid = pid_raw.trim().trim_start_matches("0x");
                if let (Ok(v), Ok(p)) = (
                    u16::from_str_radix(dev_vid, 16),
                    u16::from_str_radix(dev_pid, 16),
                ) {
                    if v == vid && p == pid {
                        let busnum: u32 = std::fs::read_to_string(bus_path)?
                            .trim()
                            .parse()
                            .unwrap_or(1);
                        let devnum: u32 = std::fs::read_to_string(dev_path)?
                            .trim()
                            .parse()
                            .unwrap_or(1);
                        let devnode =
                            PathBuf::from(format!("/dev/bus/usb/{:03}/{:03}", busnum, devnum));
                        if devnode.exists() {
                            return Ok(Some(devnode));
                        }
                    }
                }
            }
        }
    }
    Ok(None)
}
