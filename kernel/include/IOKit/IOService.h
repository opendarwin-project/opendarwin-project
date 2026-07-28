#pragma once

#include "IORegistryEntry.h"

#ifdef __cplusplus

class IOService : public IORegistryEntry {
public:
    explicit IOService(IOServiceRef handle = nullptr) : IORegistryEntry(handle) {}

    const char *getClassName(size_t *out_len = nullptr) const {
        return IOKit_ServiceGetClassName(handle_, out_len);
    }

    IOService *getProvider() const {
        // Caller owns lifetime of temporary wrapper; use getProviderHandle for raw.
        return nullptr;
    }

    IOServiceRef getProviderHandle() const {
        return IOKit_ServiceGetProvider(handle_);
    }

    IOReturn start(IOServiceRef provider) {
        return IOKit_ServiceStart(handle_, provider);
    }

    static IOServiceRef registryRoot() {
        return IOKit_RegistryRoot();
    }
};

#endif // __cplusplus
