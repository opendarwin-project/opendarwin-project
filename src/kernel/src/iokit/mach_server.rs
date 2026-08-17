//! IOKit Mach message server for Darwin io_* RPCs over Mach messages.

use crate::arch::aarch64::cpu;
use crate::iokit::framebuffer;
use crate::iokit::registry;
use crate::iokit::service::IOService;
use crate::iokit::user_client::{self, PortObjectTag};
use crate::ipc::kmsg::{IpcKmsg, MachMsgHeader};
use crate::ipc::types::{IE_BITS_TYPE_RECEIVE, IE_BITS_TYPE_SEND, MACH_PORT_NULL, MachPortNameT};
use crate::ipc::{IpcPort, host, right};
use crate::proc::sched;
use crate::proc::task::Task;
use crate::syscall::usercopy;

pub const MSG_GET_MATCHING_SERVICE: u32 = 2900;
pub const MSG_SERVICE_OPEN: u32 = 2901;
pub const MSG_CONNECT_MAP_MEMORY: u32 = 2902;
pub const MSG_OBJECT_RELEASE: u32 = 2904;

pub const KERN_SUCCESS: i32 = 0;
pub const KERN_INVALID_ADDRESS: i32 = 1;
pub const KERN_NO_SPACE: i32 = 3;
pub const KERN_INVALID_ARGUMENT: i32 = 4;
pub const KERN_FAILURE: i32 = 5;

const CLASS_NAME_MAX: usize = 64;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MatchingBody {
    pub class_len: u32,
    pub class_name: [u8; CLASS_NAME_MAX],
}

impl Default for MatchingBody {
    fn default() -> Self {
        Self {
            class_len: 0,
            class_name: [0; CLASS_NAME_MAX],
        }
    }
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct OpenBody {
    pub client_type: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct MapMemoryBody {
    pub memory_type: u32,
    pub flags: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ReplyBody {
    pub ret: i32,
    pub pad: u32,
    pub val0: u64,
    pub val1: u64,
    pub val2: u64,
    pub val3: u64,
    pub bytes: [u8; 64],
}

impl Default for ReplyBody {
    fn default() -> Self {
        Self {
            ret: KERN_FAILURE,
            pad: 0,
            val0: 0,
            val1: 0,
            val2: 0,
            val3: 0,
            bytes: [0; 64],
        }
    }
}

fn matches_class(svc: &IOService, want: &str) -> bool {
    let name = svc.get_class_name();
    if name == want {
        return true;
    }
    if want == framebuffer::CLASS_NAME && name == "VirtioGpuFramebuffer" {
        return true;
    }
    false
}

pub fn find_matching_service(class_name: &str) -> Option<*mut IOService> {
    for i in 0..registry::published_count() {
        let Some(svc) = registry::published_at(i) else {
            continue;
        };
        unsafe {
            if matches_class(&*svc, class_name) {
                return Some(svc);
            }
            for ci in 0..(*svc).entry.child_count {
                if let Some(child_entry) = (*svc).entry.children[ci] {
                    let child = IOService::from_entry(child_entry);
                    if matches_class(&*child, class_name) {
                        return Some(child);
                    }
                }
            }
        }
    }
    None
}

pub fn ensure_master_send_right(task: &mut Task) -> MachPortNameT {
    if task.iokit_master_name != MACH_PORT_NULL {
        return task.iokit_master_name;
    }
    let host = host::get_host_port();
    host.ip_kobject = user_client::master_port_object();
    let result = right::alloc(&mut task.ipc_space, host, IE_BITS_TYPE_SEND);
    task.iokit_master_name = result.name;
    result.name
}

fn insert_service_send_right(task: &mut Task, svc: *mut IOService) -> Option<MachPortNameT> {
    let port = IpcPort::alloc();
    unsafe {
        (*port).ip_receiver = host::get_host_port().ip_receiver;
        user_client::bind_service_port(svc, port);
    }
    let result = right::alloc(&mut task.ipc_space, port, IE_BITS_TYPE_SEND);
    Some(result.name)
}

fn insert_connect_send_right(
    task: &mut Task,
    uc: *mut user_client::IOUserClient,
) -> Option<MachPortNameT> {
    let port = IpcPort::alloc();
    unsafe {
        (*port).ip_receiver = host::get_host_port().ip_receiver;
        user_client::bind_connect_port(uc, port);
    }
    let result = right::alloc(&mut task.ipc_space, port, IE_BITS_TYPE_SEND);
    Some(result.name)
}

fn enqueue_reply(reply_port: *mut IpcPort, req_id: u32, body: ReplyBody, body_len: u32) -> bool {
    let header = MachMsgHeader {
        msgh_bits: 0,
        msgh_size: core::mem::size_of::<MachMsgHeader>() as u32 + body_len,
        msgh_remote_port: MACH_PORT_NULL,
        msgh_local_port: MACH_PORT_NULL,
        msgh_voucher_port: MACH_PORT_NULL,
        msgh_id: req_id + 100,
    };
    let Some(kmsg) = IpcKmsg::alloc(header) else {
        return false;
    };
    let dst = IpcKmsg::body(kmsg);
    let src = unsafe {
        core::slice::from_raw_parts(&body as *const ReplyBody as *const u8, body_len as usize)
    };
    let n = dst.len().min(src.len());
    dst[..n].copy_from_slice(&src[..n]);

    unsafe {
        if !(*reply_port).ip_messages.enqueue(kmsg) {
            IpcKmsg::free(kmsg);
            return false;
        }
    }
    true
}

pub fn handle_send(
    dest_port: *mut IpcPort,
    msg_addr: u64,
    _send_size: u32,
    header: MachMsgHeader,
) -> bool {
    let Some(po) = user_client::as_port_object(unsafe { (*dest_port).ip_kobject }) else {
        return false;
    };
    if po.tag == PortObjectTag::None {
        return false;
    }

    let task = sched::current_task(cpu::core_id());
    let Some(reply_lookup) = right::lookup(&mut task.ipc_space, header.msgh_local_port) else {
        return false;
    };
    let Some(reply_port) = reply_lookup.port else {
        return false;
    };
    if reply_lookup.entry.type_of() != IE_BITS_TYPE_RECEIVE {
        return false;
    }

    let mut reply = ReplyBody::default();
    let reply_len = (core::mem::size_of::<ReplyBody>() - 64) as u32;

    match header.msgh_id {
        MSG_GET_MATCHING_SERVICE => {
            if po.tag != PortObjectTag::Master {
                reply.ret = KERN_INVALID_ARGUMENT;
            } else if let Some(body) = usercopy::copy_in::<MatchingBody>(
                msg_addr + core::mem::size_of::<MachMsgHeader>() as u64,
            ) {
                let len = (body.class_len as usize).min(CLASS_NAME_MAX);
                let name = core::str::from_utf8(&body.class_name[..len]).unwrap_or("");
                if let Some(svc) = find_matching_service(name) {
                    if let Some(pname) = insert_service_send_right(task, svc) {
                        reply.ret = KERN_SUCCESS;
                        reply.val0 = pname as u64;
                    } else {
                        reply.ret = KERN_NO_SPACE;
                    }
                } else {
                    reply.ret = KERN_FAILURE;
                }
            } else {
                reply.ret = KERN_INVALID_ARGUMENT;
            }
        }
        MSG_SERVICE_OPEN => {
            if po.tag != PortObjectTag::Service {
                reply.ret = KERN_INVALID_ARGUMENT;
            } else if let Some(svc) = po.service {
                if let Some(uc) = user_client::open(svc) {
                    if let Some(pname) = insert_connect_send_right(task, uc) {
                        reply.ret = KERN_SUCCESS;
                        reply.val0 = pname as u64;
                    } else {
                        reply.ret = KERN_NO_SPACE;
                    }
                } else {
                    reply.ret = KERN_NO_SPACE;
                }
            } else {
                reply.ret = KERN_FAILURE;
            }
        }
        MSG_CONNECT_MAP_MEMORY => {
            if po.tag != PortObjectTag::Connect {
                reply.ret = KERN_INVALID_ARGUMENT;
            } else if let Some(uc) = po.connect {
                if let Some(phys) = user_client::framebuffer_map_aperture(uc) {
                    let vmm = sched::current_vmm(cpu::core_id());
                    let va = vmm.map_physical(phys.pa, phys.len);
                    if va == 0 {
                        reply.ret = KERN_NO_SPACE;
                    } else {
                        reply.ret = KERN_SUCCESS;
                        reply.val0 = va;
                        reply.val1 = phys.len;
                    }
                } else {
                    reply.ret = KERN_FAILURE;
                }
            } else {
                reply.ret = KERN_FAILURE;
            }
        }
        MSG_OBJECT_RELEASE => {
            reply.ret = KERN_SUCCESS;
        }
        _ => return false,
    }

    enqueue_reply(reply_port, header.msgh_id, reply, reply_len)
}
