#pragma once

#include "IOService.h"

#ifdef __cplusplus

class IOFramebuffer : public IOService {
public:
    explicit IOFramebuffer(IOServiceRef handle = nullptr) : IOService(handle) {}

    IOReturn getDisplayMode(uint32_t *width, uint32_t *height, uint32_t *depth = nullptr) const {
        return IOKit_Framebuffer_GetDisplayMode(handle_, width, height, depth);
    }

    IOReturn getAperture(uint64_t *base, uint64_t *len) const {
        return IOKit_Framebuffer_GetAperture(handle_, base, len);
    }
};

#endif // __cplusplus
