Current State Summary

Your kernel has the core pieces plus an IOKit-compatible layer:

- conduit handles device discovery (DTB/Registry) and provides Zig driver
  implementations (virtio_blk, virtio_gpu)
- Zig IOKit core (`src/kernel/iokit/`) provides IORegistryEntry / IOService
  vtables, IOPCIDevice, IOFramebuffer, IOAccelerator, and matching
- C ABI exports (`iokit/compat.zig`) + C++ shim headers (`compat/IOKit/`)
- Display bind: built-in `VirtioGpuFramebuffer` matches published IOPCIDevice
  nubs (the asm VIRTIGPU / `KernelApi.start_display` path has been removed)
- kext system (kext/api.zig, ABI 3) remains for non-display kexts
  (register_driver / log only)

Recommended Architecture: Three-Layer Design

### Layer 1: Zig IOKit Core (pure Zig, the real implementation) — DONE

```
  IORegistryEntry          — base: name, location, properties dict
    └─ IOService           — lifecycle (init/probe/start/stop), matching
         ├─ IOFramebuffer  — display timing, VRAM aperture
         ├─ IOAccelerator  — command queues, fences (stubs for Prism)
         └─ IOPCIDevice    — PCI config space, BAR mapping
```

### Layer 2: C++ Compatibility Headers — DONE

`compat/IOKit/*.h` thin wrappers call `extern "C"` `IOKit_*` exports.
Zero C++ in the kernel build.

### Layer 3: Zig Driver Authoring — DONE for virtio-gpu

`src/kernel/iokit/drivers/virtio_gpu_fb.zig` implements IOFramebuffer and
owns conduit bind/start.

Migration Path

1. Add IORegistryEntry / IOService vtable structs — done
2. Build IORegistry tree from conduit discovery results — done
3. Add IOPCIDevice wrapping existing PCI config space access — done
4. Add C ABI exports + C++ shim headers — done
5. Implement IOFramebuffer / IOAccelerator abstract bases — done
6. Migrate virtio_gpu from DISPLAY kext to Zig IOFramebuffer — done
   (asm kext + start_display removed)

Next

- Prism userspace present via Darwin IOKitLib — done
  (`mach_host_self` / match / open / `IOConnectMapMemory` via mach_msg;
  getInfo/present via XNU trap **100** `iokit_user_client_trap`).
  See `docs/userspace-framebuffer-abi.md`.
- Port prism-vk / prism-egl builds + WSI to aarch64-macos using Darwin
  `platform.Surface` (software HAL first; Metal later)
- Richer IOKitPersonalities / CF matching for out-of-tree kexts
- Real IOWorkLoop / interrupt wiring for VSync
- Optional Metal-compatible / IOSurface-shaped layer in Prism
