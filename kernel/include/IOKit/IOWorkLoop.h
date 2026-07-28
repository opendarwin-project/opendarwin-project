#pragma once

#include "IOReturn.h"
#include "IOTypes.h"

#ifdef __cplusplus

// Stub workloop — interrupt wiring is not implemented in the Zig core yet.
class IOWorkLoop {
public:
    IOReturn runAction(void (*action)(void *, void *), void *target, void *arg) {
        if (action) action(target, arg);
        return kIOReturnSuccess;
    }
};

class IOInterruptEventSource {
public:
    void enable() {}
    void disable() {}
};

#endif // __cplusplus
