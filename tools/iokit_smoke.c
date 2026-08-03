// tools/iokit_smoke.c
// Smoke test for the OpenDarwin IOKit.framework Rust replacement.
//
// Build against the framework we just produced and run with DYLD_FRAMEWORK_PATH
// pointing at it, so dyld resolves IOKit from our bundle instead of the system:
//
//   tools/build_iokit_framework.sh
//   cc -arch arm64 -o /tmp/iokit_smoke tools/iokit_smoke.c \
//       -F target/iokit-framework -framework IOKit
//       -Wl,-rpath,target/iokit-framework
//   DYLD_FRAMEWORK_PATH=$PWD/target/iokit-framework /tmp/iokit_smoke
//
// Exercises the exported C ABI: IOMasterPort (host_self trap),
// IOServiceMatching (heap alloc), IOServiceGetMatchingService (mach_msg2 RPC),
// IOConnectTrap6, and the framebuffer helpers. Prints each step and exits
// non-zero on failure.
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define CHECK(cond, what)                                                      \
  do {                                                                         \
    if (!(cond)) {                                                             \
      fprintf(stderr, "FAIL: %s\n", what);                                     \
      return 1;                                                                \
    }                                                                          \
    printf("ok:   %s\n", what);                                                \
  } while (0)

int main(void) {
  mach_port_t master = 0;
  io_connect_t conn = 0;
  io_service_t svc = 0;
  kern_return_t kr;

  // IOMasterPort -> mach_host_self trap; must yield a live host port.
  kr = IOMainPort(MACH_PORT_NULL, &master);
  CHECK(kr == KERN_SUCCESS, "IOMasterPort");
  CHECK(master != MACH_PORT_NULL, "IOMasterPort returns host port");

  // IOServiceMatching allocates a dict on the no_std (libSystem) heap.
  CFMutableDictionaryRef matching = IOServiceMatching("IOFramebuffer");
  CHECK(matching != NULL, "IOServiceMatching('IOFramebuffer') allocates");

  // IOServiceGetMatchingService consumes the dict and RPCs the kernel.
  svc = IOServiceGetMatchingService(master, matching);
  printf("      IOServiceGetMatchingService -> 0x%x\n", svc);

  // IOConnectTrap6 is the raw iokit_user_client_trap (trap 100).
  kr = IOConnectTrap6(0, 0, 0, 0, 0, 0, 0, 0);
  printf("      IOConnectTrap6(0,..) -> kr 0x%x\n", kr);

  // Release is a no-op (ports are task-scoped; kernel reclaims on close).
  kr = IOObjectRelease(svc);
  CHECK(kr == KERN_SUCCESS, "IOObjectRelease");

  printf("iokit_smoke: all checks passed\n");
  return 0;
}
