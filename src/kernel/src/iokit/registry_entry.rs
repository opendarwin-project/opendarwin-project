//! Base IORegistryEntry class: multi-plane hierarchical tree and rich OSObject properties.
//!
//! Mirrors Darwin IOKit/IORegistryEntry.h and libkern/c++/OS*.h:
//! - Multi-plane registry: `gIOServicePlane`, `gIODTPlane`, `gIOPowerPlane`.
//! - Structured properties: `OSObject` (String, Number, Data, Boolean, Array, Dictionary).

use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RegistryPlane {
    Service = 0,
    DeviceTree = 1,
    Power = 2,
}

pub const NUM_PLANES: usize = 3;

#[allow(non_upper_case_globals)]
pub const gIOServicePlane: RegistryPlane = RegistryPlane::Service;
#[allow(non_upper_case_globals)]
pub const gIODTPlane: RegistryPlane = RegistryPlane::DeviceTree;
#[allow(non_upper_case_globals)]
pub const gIOPowerPlane: RegistryPlane = RegistryPlane::Power;

/// Structured property value matching Darwin OSObject subclasses.
#[derive(Clone, Debug, PartialEq)]
pub enum OSObject {
    String(String),
    Number(u64),
    Data(Vec<u8>),
    Boolean(bool),
    Array(Vec<OSObject>),
    Dictionary(BTreeMap<String, OSObject>),
}

impl OSObject {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            OSObject::String(s) => Some(s.as_str()),
            _ => None,
        }
    }

    pub fn as_u64(&self) -> Option<u64> {
        match self {
            OSObject::Number(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_bytes(&self) -> Option<&[u8]> {
        match self {
            OSObject::Data(d) => Some(d.as_slice()),
            OSObject::String(s) => Some(s.as_bytes()),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            OSObject::Boolean(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[OSObject]> {
        match self {
            OSObject::Array(arr) => Some(arr.as_slice()),
            _ => None,
        }
    }

    pub fn as_dict(&self) -> Option<&BTreeMap<String, OSObject>> {
        match self {
            OSObject::Dictionary(d) => Some(d),
            _ => None,
        }
    }
}

pub struct IORegistryEntry {
    pub name: String,
    pub location: String,
    pub parents: [Option<*mut IORegistryEntry>; NUM_PLANES],
    pub children: [Vec<*mut IORegistryEntry>; NUM_PLANES],
    pub properties: BTreeMap<String, OSObject>,
}

unsafe impl Send for IORegistryEntry {}
unsafe impl Sync for IORegistryEntry {}

impl Default for IORegistryEntry {
    fn default() -> Self {
        Self::new()
    }
}

impl IORegistryEntry {
    pub const fn new() -> Self {
        Self {
            name: String::new(),
            location: String::new(),
            parents: [None, None, None],
            children: [Vec::new(), Vec::new(), Vec::new()],
            properties: BTreeMap::new(),
        }
    }

    pub fn init(&mut self, name: &str) {
        self.name = String::from(name);
        self.location.clear();
        self.parents = [None, None, None];
        for c in &mut self.children {
            c.clear();
        }
        self.properties.clear();
    }

    pub fn get_name(&self) -> &str {
        &self.name
    }

    pub fn set_name(&mut self, name: &str) {
        self.name = String::from(name);
    }

    pub fn get_location(&self) -> &str {
        &self.location
    }

    pub fn set_location(&mut self, location: &str) {
        self.location = String::from(location);
    }

    // --- Multi-Plane Hierarchy ---

    pub fn attach_to_parent(&mut self, parent: *mut IORegistryEntry, plane: RegistryPlane) -> bool {
        let plane_idx = plane as usize;
        self.parents[plane_idx] = Some(parent);
        unsafe {
            let p = &mut *parent;
            if !p.children[plane_idx].contains(&(self as *mut IORegistryEntry)) {
                p.children[plane_idx].push(self as *mut IORegistryEntry);
            }
        }
        true
    }

    pub fn detach_from_parent(&mut self, plane: RegistryPlane) -> bool {
        let plane_idx = plane as usize;
        if let Some(parent) = self.parents[plane_idx] {
            unsafe {
                let p = &mut *parent;
                p.children[plane_idx].retain(|&c| c != (self as *mut IORegistryEntry));
            }
            self.parents[plane_idx] = None;
            true
        } else {
            false
        }
    }

    pub fn add_child(&mut self, child: *mut IORegistryEntry) -> bool {
        self.add_child_in_plane(child, gIOServicePlane)
    }

    pub fn add_child_in_plane(
        &mut self,
        child: *mut IORegistryEntry,
        plane: RegistryPlane,
    ) -> bool {
        unsafe { (*child).attach_to_parent(self as *mut IORegistryEntry, plane) }
    }

    pub fn get_parent(&self, plane: RegistryPlane) -> Option<*mut IORegistryEntry> {
        self.parents[plane as usize]
    }

    pub fn get_children(&self, plane: RegistryPlane) -> &[*mut IORegistryEntry] {
        &self.children[plane as usize]
    }

    // --- Property Table Access ---

    pub fn set_property(&mut self, key: &str, obj: OSObject) {
        self.properties.insert(String::from(key), obj);
    }

    pub fn get_property(&self, key: &str) -> Option<&OSObject> {
        self.properties.get(key)
    }

    pub fn set_property_str(&mut self, key: &str, val: &str) -> bool {
        self.properties
            .insert(String::from(key), OSObject::String(String::from(val)));
        true
    }

    pub fn get_property_str<'a>(&'a self, key: &str) -> Option<&'a str> {
        self.properties.get(key).and_then(|obj| obj.as_str())
    }

    pub fn set_property_u64(&mut self, key: &str, val: u64) -> bool {
        self.properties
            .insert(String::from(key), OSObject::Number(val));
        true
    }

    pub fn get_property_u64(&self, key: &str) -> Option<u64> {
        self.properties.get(key).and_then(|obj| obj.as_u64())
    }

    pub fn set_property_bytes(&mut self, key: &str, bytes: &[u8]) {
        self.properties
            .insert(String::from(key), OSObject::Data(bytes.to_vec()));
    }

    pub fn get_property_bytes<'a>(&'a self, key: &str) -> Option<&'a [u8]> {
        self.properties.get(key).and_then(|obj| obj.as_bytes())
    }

    pub fn set_property_bool(&mut self, key: &str, val: bool) {
        self.properties
            .insert(String::from(key), OSObject::Boolean(val));
    }

    pub fn get_property_bool(&self, key: &str) -> Option<bool> {
        self.properties.get(key).and_then(|obj| obj.as_bool())
    }

    pub fn set_property_array(&mut self, key: &str, arr: Vec<OSObject>) {
        self.properties
            .insert(String::from(key), OSObject::Array(arr));
    }
}
