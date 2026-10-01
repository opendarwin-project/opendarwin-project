//! Mach task IPC space (`ipc_space`).

use crate::ipc::entry::IpcEntry;
use crate::ipc::types::MachPortNameT;

pub const IPC_SPACE_DEFAULT_SIZE: usize = 64;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct IpcSpace {
    pub is_table: [IpcEntry; IPC_SPACE_DEFAULT_SIZE],
    pub is_table_size: usize,
    pub is_table_free: usize,
    pub is_tree_total: usize,
    pub is_active: bool,
}

unsafe impl Send for IpcSpace {}
unsafe impl Sync for IpcSpace {}

impl Default for IpcSpace {
    fn default() -> Self {
        Self::new()
    }
}

impl IpcSpace {
    pub const fn new() -> Self {
        Self {
            is_table: [IpcEntry {
                ie_object: core::ptr::null_mut(),
                ie_bits: 0,
                ie_index: 0,
            }; IPC_SPACE_DEFAULT_SIZE],
            is_table_size: IPC_SPACE_DEFAULT_SIZE,
            is_table_free: 0,
            is_tree_total: 0,
            is_active: false,
        }
    }

    pub fn init(&mut self) {
        self.is_table_size = IPC_SPACE_DEFAULT_SIZE;
        self.is_table_free = 0;
        self.is_tree_total = 0;
        self.is_active = true;
        for entry in self.is_table.iter_mut() {
            *entry = IpcEntry::default();
        }
    }

    pub fn lookup(&self, name: MachPortNameT) -> Option<&IpcEntry> {
        let index = (name >> 8) as usize;
        if index >= self.is_table_size {
            return None;
        }
        let entry = &self.is_table[index];
        if entry.type_of() == 0 {
            return None;
        }
        Some(entry)
    }

    pub fn lookup_mut(&mut self, name: MachPortNameT) -> Option<&mut IpcEntry> {
        let index = (name >> 8) as usize;
        if index >= self.is_table_size {
            return None;
        }
        let entry = &mut self.is_table[index];
        if entry.type_of() == 0 {
            return None;
        }
        Some(entry)
    }

    pub fn allocate_name(&mut self) -> Option<MachPortNameT> {
        for i in 1..self.is_table_size {
            if self.is_table[i].type_of() == 0 {
                let generation = self.is_table[i].generation().wrapping_add(1) & 0x3f;
                return Some(((i as u32) << 8) | generation);
            }
        }
        None
    }

    pub fn insert(&mut self, name: MachPortNameT, entry: IpcEntry) -> bool {
        let index = (name >> 8) as usize;
        if index >= self.is_table_size {
            return false;
        }
        self.is_table[index] = entry;
        true
    }

    pub fn remove(&mut self, name: MachPortNameT) -> bool {
        let index = (name >> 8) as usize;
        if index >= self.is_table_size {
            return false;
        }
        let generation = self.is_table[index].generation();
        self.is_table[index] = IpcEntry::default();
        self.is_table[index].init(
            core::ptr::null_mut(),
            0,
            generation.wrapping_add(1) & 0x3f,
            0,
        );
        true
    }
}
