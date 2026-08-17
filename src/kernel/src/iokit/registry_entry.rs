//! Base IORegistryEntry class: hierarchical tree and property tables.

use crate::iokit::types::{MAX_CHILDREN, MAX_PROPERTIES};

#[derive(Clone, Copy)]
pub struct Property {
    pub key: [u8; 32],
    pub key_len: usize,
    pub val_str: [u8; 64],
    pub val_str_len: usize,
    pub val_u64: u64,
    pub is_str: bool,
    pub in_use: bool,
}

impl Property {
    pub const fn empty() -> Self {
        Self {
            key: [0; 32],
            key_len: 0,
            val_str: [0; 64],
            val_str_len: 0,
            val_u64: 0,
            is_str: false,
            in_use: false,
        }
    }
}

pub struct IORegistryEntry {
    pub name: [u8; 32],
    pub name_len: usize,
    pub parent: Option<*mut IORegistryEntry>,
    pub children: [Option<*mut IORegistryEntry>; MAX_CHILDREN],
    pub child_count: usize,
    pub properties: [Property; MAX_PROPERTIES],
}

impl Default for IORegistryEntry {
    fn default() -> Self {
        Self::new()
    }
}

impl IORegistryEntry {
    pub const fn new() -> Self {
        Self {
            name: [0; 32],
            name_len: 0,
            parent: None,
            children: [None; MAX_CHILDREN],
            child_count: 0,
            properties: [Property::empty(); MAX_PROPERTIES],
        }
    }

    pub fn init(&mut self, name: &str) {
        self.set_name(name);
        self.parent = None;
        self.child_count = 0;
        for c in self.children.iter_mut() {
            *c = None;
        }
        for p in self.properties.iter_mut() {
            *p = Property::empty();
        }
    }

    pub fn get_name(&self) -> &str {
        core::str::from_utf8(&self.name[..self.name_len]).unwrap_or("")
    }

    pub fn set_name(&mut self, name: &str) {
        let n = name.len().min(self.name.len());
        self.name[..n].copy_from_slice(&name.as_bytes()[..n]);
        self.name_len = n;
    }

    pub fn add_child(&mut self, child: *mut IORegistryEntry) -> bool {
        if self.child_count >= MAX_CHILDREN {
            return false;
        }
        self.children[self.child_count] = Some(child);
        self.child_count += 1;
        unsafe {
            (*child).parent = Some(self as *mut IORegistryEntry);
        }
        true
    }

    pub fn set_property_u64(&mut self, key: &str, val: u64) -> bool {
        for p in self.properties.iter_mut() {
            if p.in_use && p.key_len == key.len() && &p.key[..p.key_len] == key.as_bytes() {
                p.val_u64 = val;
                p.is_str = false;
                return true;
            }
        }
        for p in self.properties.iter_mut() {
            if !p.in_use {
                let n = key.len().min(p.key.len());
                p.key[..n].copy_from_slice(&key.as_bytes()[..n]);
                p.key_len = n;
                p.val_u64 = val;
                p.is_str = false;
                p.in_use = true;
                return true;
            }
        }
        false
    }

    pub fn get_property_u64(&self, key: &str) -> Option<u64> {
        for p in self.properties.iter() {
            if p.in_use
                && p.key_len == key.len()
                && &p.key[..p.key_len] == key.as_bytes()
                && !p.is_str
            {
                return Some(p.val_u64);
            }
        }
        None
    }

    pub fn set_property_str(&mut self, key: &str, val: &str) -> bool {
        for p in self.properties.iter_mut() {
            if p.in_use && p.key_len == key.len() && &p.key[..p.key_len] == key.as_bytes() {
                let vn = val.len().min(p.val_str.len());
                p.val_str[..vn].copy_from_slice(&val.as_bytes()[..vn]);
                p.val_str_len = vn;
                p.is_str = true;
                return true;
            }
        }
        for p in self.properties.iter_mut() {
            if !p.in_use {
                let n = key.len().min(p.key.len());
                p.key[..n].copy_from_slice(&key.as_bytes()[..n]);
                p.key_len = n;
                let vn = val.len().min(p.val_str.len());
                p.val_str[..vn].copy_from_slice(&val.as_bytes()[..vn]);
                p.val_str_len = vn;
                p.is_str = true;
                p.in_use = true;
                return true;
            }
        }
        false
    }

    pub fn get_property_str<'a>(&'a self, key: &str) -> Option<&'a str> {
        for p in self.properties.iter() {
            if p.in_use
                && p.key_len == key.len()
                && &p.key[..p.key_len] == key.as_bytes()
                && p.is_str
            {
                return core::str::from_utf8(&p.val_str[..p.val_str_len]).ok();
            }
        }
        None
    }
}
