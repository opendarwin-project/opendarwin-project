//! IOUserClient and PortObject dispatch matching Darwin IOKit/IOUserClient.h.

use crate::drivers::virtio_gpu;
use crate::iokit::framebuffer::IOFramebuffer;
use crate::iokit::service::IOService;
use crate::iokit::types::{
    IO_RETURN_BAD_ARGUMENT, IO_RETURN_NOT_READY, IO_RETURN_SUCCESS, IO_RETURN_UNSUPPORTED,
    IOReturn, MAX_CLIENTS,
};
use crate::ipc::IpcPort;
use crate::mm::slab;
use spin::Mutex;

#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum PortObjectTag {
    #[default]
    None = 0,
    Master = 1,
    Service = 2,
    Connect = 3,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct PortObject {
    pub tag: PortObjectTag,
    pub service: Option<*mut IOService>,
    pub connect: Option<*mut IOUserClient>,
}

pub struct IOUserClientVtable {
    pub external_method: fn(uc: *mut IOUserClient, selector: u32, args: *const u64) -> IOReturn,
    pub trap: fn(
        uc: *mut IOUserClient,
        index: u32,
        p1: u64,
        p2: u64,
        p3: u64,
        p4: u64,
        p5: u64,
        p6: u64,
    ) -> IOReturn,
}

pub struct IOUserClient {
    pub service: IOService,
    pub provider: *mut IOService,
    pub client_type: u32,
    pub vtable: Option<&'static IOUserClientVtable>,
}

impl Default for IOUserClient {
    fn default() -> Self {
        Self::new()
    }
}

impl IOUserClient {
    pub const fn new() -> Self {
        Self {
            service: IOService::new(),
            provider: core::ptr::null_mut(),
            client_type: 0,
            vtable: None,
        }
    }
}

struct ClientPoolState {
    master_object: PortObject,
    client_pool: [IOUserClient; MAX_CLIENTS],
    client_used: [bool; MAX_CLIENTS],
}

unsafe impl Send for PortObject {}
unsafe impl Sync for PortObject {}
unsafe impl Send for IOUserClient {}
unsafe impl Sync for IOUserClient {}
unsafe impl Send for ClientPoolState {}
unsafe impl Sync for ClientPoolState {}
static CLIENTS: Mutex<ClientPoolState> = Mutex::new(ClientPoolState {
    master_object: PortObject {
        tag: PortObjectTag::Master,
        service: None,
        connect: None,
    },
    client_pool: [const { IOUserClient::new() }; MAX_CLIENTS],
    client_used: [false; MAX_CLIENTS],
});

pub fn master_port_object() -> *mut u8 {
    let mut clients = CLIENTS.lock();
    &mut clients.master_object as *mut PortObject as *mut u8
}

pub fn bind_service_port(svc: *mut IOService, port: *mut IpcPort) -> *mut u8 {
    let po = slab::alloc_obj::<PortObject>();
    unsafe {
        *po = PortObject {
            tag: PortObjectTag::Service,
            service: Some(svc),
            connect: None,
        };
        (*port).ip_kobject = po as *mut u8;
        po as *mut u8
    }
}

pub fn bind_connect_port(uc: *mut IOUserClient, port: *mut IpcPort) {
    let po = slab::alloc_obj::<PortObject>();
    unsafe {
        *po = PortObject {
            tag: PortObjectTag::Connect,
            service: None,
            connect: Some(uc),
        };
        (*port).ip_kobject = po as *mut u8;
    }
}

pub fn as_port_object(kobj: *mut u8) -> Option<&'static mut PortObject> {
    if kobj.is_null() {
        None
    } else {
        unsafe { Some(&mut *(kobj as *mut PortObject)) }
    }
}

pub fn open(svc: *mut IOService) -> Option<*mut IOUserClient> {
    let mut clients = CLIENTS.lock();
    for (i, used) in clients.client_used.iter_mut().enumerate() {
        if !*used {
            *used = true;
            let client = &mut clients.client_pool[i] as *mut IOUserClient;
            unsafe {
                (*client).service.init("IOUserClient", "IOUserClient", "");
                (*client).provider = svc;
            }
            return Some(client);
        }
    }
    None
}

pub struct PhysicalRange {
    pub pa: u64,
    pub len: u64,
}

pub fn framebuffer_map_aperture(uc: *mut IOUserClient) -> Option<PhysicalRange> {
    unsafe {
        let prov = (*uc).provider;
        if prov.is_null() {
            return None;
        }
        let fb = IOFramebuffer::from_service(prov);
        let mut base = 0u64;
        let mut len = 0u64;
        if fb.get_aperture(&mut base, &mut len) != IO_RETURN_SUCCESS || len == 0 {
            return None;
        }
        Some(PhysicalRange { pa: base, len })
    }
}

pub fn trap(
    uc: *mut IOUserClient,
    index: u32,
    p1: u64,
    p2: u64,
    p3: u64,
    p4: u64,
    p5: u64,
    p6: u64,
) -> IOReturn {
    unsafe {
        if uc.is_null() {
            return IO_RETURN_BAD_ARGUMENT;
        }

        // Trap 0: Present framebuffer
        if index == 0 {
            if virtio_gpu::present() {
                return IO_RETURN_SUCCESS;
            } else {
                return IO_RETURN_NOT_READY;
            }
        }

        if let Some(vt) = (*uc).vtable {
            (vt.trap)(uc, index, p1, p2, p3, p4, p5, p6)
        } else {
            IO_RETURN_UNSUPPORTED
        }
    }
}
