const conduit = @import("conduit");

pub const Info = struct {
    class: conduit.Class,
    name: []const u8,
    mmio_base: u64 = 0,
    mmio_len: u64 = 0,
    irq: u64 = 0,
    pci_segment: u16 = 0,
    pci_bus: u8 = 0,
    pci_device: u8 = 0,
    pci_function: u8 = 0,
    pci_vendor_id: u16 = 0,
    pci_device_id: u16 = 0,
    pci_class_code: u8 = 0,
    pci_subclass: u8 = 0,
    pci_prog_if: u8 = 0,
};

pub fn fromConduitMatch(m: *const conduit.Match) Info {
    const mmio = m.mmio();
    const irq = m.irq(0);
    const pci = m.pci;
    return .{
        .class = m.class,
        .name = m.name,
        .mmio_base = if (mmio) |r| r.base else 0,
        .mmio_len = if (mmio) |r| r.size else 0,
        .irq = if (irq) |r| r.number else 0,
        .pci_segment = if (pci) |p| p.segment else 0,
        .pci_bus = if (pci) |p| p.bus else 0,
        .pci_device = if (pci) |p| p.device else 0,
        .pci_function = if (pci) |p| p.function else 0,
        .pci_vendor_id = if (pci) |p| p.vendor_id else 0,
        .pci_device_id = if (pci) |p| p.device_id else 0,
        .pci_class_code = if (pci) |p| p.class_code else 0,
        .pci_subclass = if (pci) |p| p.subclass else 0,
        .pci_prog_if = if (pci) |p| p.prog_if else 0,
    };
}
