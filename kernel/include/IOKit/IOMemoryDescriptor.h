#pragma once

#include "IOLib.h"
#include "IOTypes.h"

#ifdef __cplusplus

class IOMemoryDescriptor {
public:
    explicit IOMemoryDescriptor(IOMemoryDescriptorRef handle = nullptr) : handle_(handle) {}

    IOVirtualAddress getVirtualAddress() const {
        return IOKit_Memory_GetVirtualAddress(handle_);
    }

    IOByteCount getLength() const {
        return IOKit_Memory_GetLength(handle_);
    }

    IOMemoryDescriptorRef getHandle() const { return handle_; }

private:
    IOMemoryDescriptorRef handle_;
};

using IOMemoryMap = IOMemoryDescriptor;

#endif // __cplusplus
