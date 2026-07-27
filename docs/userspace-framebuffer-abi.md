# OpenDarwin userspace framebuffer (Darwin IOKit)

Present path uses Darwin IOKitLib names and XNU Mach traps — not a custom
BSD syscall ABI.

## Flow

```
IOMasterPort (mach_host_self, trap 29)
  → IOServiceMatching("IOFramebuffer")
  → IOServiceGetMatchingService          # mach_msg to master
  → IOServiceOpen → io_connect_t         # mach_msg
  → IOConnectMapMemory                   # mach_msg
  → IOConnectTrap / IOFramebufferPresent # mach trap 100
```

### Mach trap numbers (XNU-accurate)

| Trap    | Name                                          |
| ------- | --------------------------------------------- |
| 26      | `mach_reply_port`                             |
| 27–29   | thread/task/host self                         |
| 31–32   | `mach_msg` / overwrite                        |
| **100** | `iokit_user_client_trap` (`IOConnectTrap0…6`) |

Method dispatch for getInfo (index 0) and present (index 1) goes through
trap 100. Match / open / mapMemory still use simplified mach_msg RPCs.

Kernel: `VirtioGpuFramebuffer` publishes into the IORegistry; UserClient
ports carry IOKit kobjects (`src/kernel/iokit/user_client.zig`,
`mach_server.zig`).

## Userspace

Headers: [`include/IOKit/IOKitLib.h`](../include/IOKit/IOKitLib.h)  
libSystem: [`src/iokit/iokit.zig`](../src/iokit/iokit.zig) (IOKit.framework dylib)

## Prism

`platform.darwin` DynLib-loads `IOFramebufferOpenDefault` /
`IOFramebufferPresent` from IOKit.framework and presents through that connect.

## Smoke

`zig build fb-smoke` — paints RGB bars via IOKitLib.
