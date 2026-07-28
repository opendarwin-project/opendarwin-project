#pragma once

#include "IOLib.h"
#include "IOReturn.h"
#include "IOTypes.h"

#ifdef __cplusplus

class IORegistryEntry {
public:
    explicit IORegistryEntry(IOServiceRef handle = nullptr) : handle_(handle) {}

    IOServiceRef getHandle() const { return handle_; }

    const char *getName(size_t *out_len = nullptr) const {
        return IOKit_ServiceGetName(handle_, out_len);
    }

    IOReturn getProperty(const char *key, uint64_t *out) const {
        if (!key) return kIOReturnBadArgument;
        size_t len = 0;
        while (key[len] != '\0') ++len;
        return IOKit_ServiceGetPropertyU64(handle_, key, len, out);
    }

protected:
    IOServiceRef handle_;
};

#endif // __cplusplus
