#ifndef IOKit_IOKitLib_h
#define IOKit_IOKitLib_h

//! Userspace Darwin IOKitLib (OpenDarwin). Kernel C++ shims live under compat/IOKit/.

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t mach_port_t;
typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_connect_t;
typedef int32_t kern_return_t;
typedef kern_return_t IOReturn;

#ifndef KERN_SUCCESS
#define KERN_SUCCESS 0
#endif

#define kIOReturnSuccess 0

typedef struct IOFramebufferInfo {
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t format; /* 0 = BGRA8 / B8G8R8X8 */
    uint64_t size;
} IOFramebufferInfo;

/* IOFramebuffer UserClient selectors */
#define kIOFBSelectGetInfo 0u
#define kIOFBSelectPresent 1u

kern_return_t IOMasterPort(mach_port_t bootstrapPort, mach_port_t *masterPort);
void *IOServiceMatching(const char *name);
io_service_t IOServiceGetMatchingService(mach_port_t masterPort, void *matching);
kern_return_t IOServiceOpen(io_service_t service, mach_port_t owningTask, uint32_t type, io_connect_t *connect);
kern_return_t IOServiceClose(io_connect_t connect);
kern_return_t IOObjectRelease(io_object_t object);

kern_return_t IOConnectMapMemory(
    io_connect_t connect,
    uint32_t memoryType,
    mach_port_t intoTask,
    uint64_t *atAddress,
    uint64_t *ofSize,
    uint32_t options);

kern_return_t IOConnectCallMethod(
    io_connect_t connect,
    uint32_t selector,
    const uint64_t *input,
    uint32_t inputCnt,
    const void *inputStruct,
    size_t inputStructCnt,
    uint64_t *output,
    uint32_t *outputCnt,
    void *outputStruct,
    size_t *outputStructCnt);

/* Darwin IOConnectTrap → mach trap 100 (iokit_user_client_trap). */
kern_return_t IOConnectTrap0(io_connect_t connect, uint32_t index);
kern_return_t IOConnectTrap1(io_connect_t connect, uint32_t index, uintptr_t p1);
kern_return_t IOConnectTrap6(
    io_connect_t connect,
    uint32_t index,
    uintptr_t p1, uintptr_t p2, uintptr_t p3,
    uintptr_t p4, uintptr_t p5, uintptr_t p6);

/* OpenDarwin convenience helpers (implemented in libSystem). */
kern_return_t IOFramebufferOpenDefault(io_connect_t *connect_out, IOFramebufferInfo *info_out);
kern_return_t IOFramebufferPresent(io_connect_t connect);

#ifdef __cplusplus
}
#endif

#endif /* IOKit_IOKitLib_h */
