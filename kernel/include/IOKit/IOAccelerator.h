#pragma once

#include <stddef.h>
#include <stdint.h>

#include "IOService.h"

#ifdef __cplusplus

// Accelerator surface for a future Metal-like (Prism) path. Methods are
// placeholders until command submission is wired through the Zig core.
class IOAccelerator : public IOService {
public:
    explicit IOAccelerator(IOServiceRef handle = nullptr) : IOService(handle) {}

    IOReturn submitCommands(const uint8_t *, size_t) {
        return kIOReturnUnsupported;
    }

    IOReturn waitFence(uint64_t) {
        return kIOReturnUnsupported;
    }

    IOReturn signalFence(uint64_t) {
        return kIOReturnUnsupported;
    }
};

#endif // __cplusplus
