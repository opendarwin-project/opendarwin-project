# To Do

- signal follow-ups: sigpending/sigsuspend/sigaltstack syscalls, job-control stop/continue, full NEON mcontext
- Prism VK/EGL ICD for aarch64-macos guest (software HAL + Darwin IOKit Surface)
- IOSurface-shaped / Metal-compatible layer in Prism
- Richer CF matching dicts + complex mach_msg port descriptors for IOKit MIG
- Run `fb-smoke` / `window-smoke` as guest MAIN to verify QEMU scanout via IOKitLib + trap 100
- SkyLight (src/skylight): move the compositor out of the client process into a
  real WindowServer task, with the CGS* exports becoming Mach RPC stubs
- SkyLight: damage regions (CGSFlushWindow currently recomposites everything),
  CGSSetWindowShape/clip regions, and title-bar text (needs a bitmap font)
- SkyLight: event plumbing (CGSGetEventPort / CGEventTap) once HID input exists;
  hit testing already lives in the compositor
- SkyLight: back window surfaces with IOSurface instead of malloc'd backing
  stores, so Prism can present zero-copy
- CoreFoundation bring-up (plan: docs/corefoundation.md) — vendor
  swift-corelibs CoreFoundation tier by tier and close the libSystem gap with
  `tools/symbol_gap.py`:
  - libSystem: vsnprintf/snprintf/strtod family (biggest single chunk)
  - libSystem: pthread_key/once/mutex/rwlock/cond on top of __ulock_*
  - libSystem: os_unfair_lock / OSSpinLock / OSAtomic, gettimeofday,
    mach_absolute_time + mach_timebase_info, getenv/environ, uuid_generate
  - libSystem: strcmp/strchr/strdup/strlcpy, qsort/bsearch, memcmp/memchr
  - CF tier 0-3 (runtime, containers, strings, plists) + a `cf-smoke` program
  - CFRunLoop/CFMachPort once mach_port_allocate + complex descriptors exist
- Minimal shell (zsh-like) as a userland program so the boot binary stops
  being a build-time choice; until then `zig build zig-smoke-rootfs -Dmain=<name>`
  swaps it (see userland_programs in build.zig)
