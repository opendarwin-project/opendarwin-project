#pragma once

#include <stdint.h>

typedef int32_t IOReturn;

enum {
    kIOReturnSuccess = 0,
    kIOReturnError = -1,
    kIOReturnBadArgument = -2,
    kIOReturnNoMemory = -3,
    kIOReturnUnsupported = -4,
    kIOReturnNotReady = -5,
    kIOReturnNoDevice = -6,
    kIOReturnAborted = -7,
};
