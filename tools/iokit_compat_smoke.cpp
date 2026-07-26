// Tiny compile check for compat/IOKit headers (not linked against the kernel).
#include "IOKit/IOKitLib.h"

int main() {
    IOServiceRef root = IOService::registryRoot();
    (void)root;
    IOPCIDevice pci(nullptr);
    (void)pci.configRead16(0);
    IOFramebuffer fb(nullptr);
    uint32_t w = 0, h = 0;
    (void)fb.getDisplayMode(&w, &h);
    return 0;
}
