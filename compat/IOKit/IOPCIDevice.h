#pragma once

#include "IOService.h"
#include "IOMemoryDescriptor.h"

#ifdef __cplusplus

class IOPCIDevice : public IOService {
public:
    explicit IOPCIDevice(IOServiceRef handle = nullptr) : IOService(handle) {}

    uint16_t configRead16(uint16_t offset) const {
        return IOKit_PCI_ConfigRead16(handle_, offset);
    }

    uint32_t configRead32(uint16_t offset) const {
        return IOKit_PCI_ConfigRead32(handle_, offset);
    }

    IOMemoryDescriptor mapDeviceMemoryWithRegister(uint8_t bar) const {
        return IOMemoryDescriptor(IOKit_PCI_MapBAR(handle_, bar));
    }
};

#endif // __cplusplus
