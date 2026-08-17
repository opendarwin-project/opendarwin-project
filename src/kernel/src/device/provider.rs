#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum DeviceClass {
    Block,
    Display,
    Uart,
    Intc,
    Pci,
    #[default]
    Other,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Info {
    pub class: DeviceClass,
    pub name: &'static str,
    pub mmio_base: u64,
    pub mmio_len: u64,
    pub irq: u64,
    pub pci_segment: u16,
    pub pci_bus: u8,
    pub pci_device: u8,
    pub pci_function: u8,
    pub pci_vendor_id: u16,
    pub pci_device_id: u16,
    pub pci_class_code: u8,
    pub pci_subclass: u8,
    pub pci_prog_if: u8,
}
