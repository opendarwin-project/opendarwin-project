#pragma once

#include "IOReturn.h"
#include "IOTypes.h"

#ifdef __cplusplus
extern "C" {
#endif

IOServiceRef IOKit_RegistryRoot(void);
const char *IOKit_ServiceGetName(IOServiceRef svc, size_t *out_len);
const char *IOKit_ServiceGetClassName(IOServiceRef svc, size_t *out_len);
IOServiceRef IOKit_ServiceGetProvider(IOServiceRef svc);
IOReturn IOKit_ServiceGetPropertyU64(IOServiceRef svc, const char *key_ptr, size_t key_len, uint64_t *out);
IOReturn IOKit_ServiceStart(IOServiceRef svc, IOServiceRef provider);
uint16_t IOKit_PCI_ConfigRead16(IOServiceRef svc, uint16_t offset);
uint32_t IOKit_PCI_ConfigRead32(IOServiceRef svc, uint16_t offset);
IOMemoryDescriptorRef IOKit_PCI_MapBAR(IOServiceRef svc, uint8_t bar_index);
uint64_t IOKit_Memory_GetVirtualAddress(IOMemoryDescriptorRef desc);
uint64_t IOKit_Memory_GetLength(IOMemoryDescriptorRef desc);
IOReturn IOKit_Framebuffer_GetDisplayMode(IOServiceRef svc, uint32_t *width, uint32_t *height, uint32_t *depth);
IOReturn IOKit_Framebuffer_GetAperture(IOServiceRef svc, uint64_t *base, uint64_t *len);

#ifdef __cplusplus
}
#endif
