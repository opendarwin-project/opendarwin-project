# Bringing up CoreFoundation on OpenDarwin

Short answer to "can we just wire libSystem up to real CF C sources?": **yes,
and that is the cheapest path** — CF is plain C, it is one of the few Apple
frameworks with a genuinely portable upstream, and its dependency surface is
almost entirely POSIX + pthreads + malloc + a handful of Mach calls we already
have trap wrappers for. The work is not "write CF", it is "close a symbol gap",
which is a mechanical loop (see *Workflow* below).

## Which CF sources

Two candidates:

| source | license | notes |
| --- | --- | --- |
| [`swift-corelibs-foundation/CoreFoundation`](https://github.com/swiftlang/swift-corelibs-foundation/tree/main/CoreFoundation) | APSL 2.0 | **Recommended.** Same CF-1153-era code, but already de-Apple-ised: builds on Linux/Windows with `DEPLOYMENT_RUNTIME_C`, has explicit non-Darwin branches in `CFPlatform.c`, no ObjC bridging required, and CMake glue we can ignore. |
| [`apple-oss-distributions/CF`](https://github.com/apple-oss-distributions/CF) | APSL 2.0 | Pristine macOS CF, but assumes objc4, dyld internals, `os/*` private headers, and libxpc in places. More faithful, much more yak. |

Start from swift-corelibs. Compile it with `zig cc` (same aarch64-macos-none
target as the rest of userland) so we keep one toolchain.

Do **not** pretend to be Linux: define a real platform flavor. CF's platform
branches are `DEPLOYMENT_TARGET_MACOSX` / `..._LINUX` / `..._FREEBSD`; the
honest configuration for us is "Mach-O + Mach + BSD syscalls, but no Apple
userland services", i.e. `TARGET_OS_MAC` with the XPC/notify/Security/ICU
call sites disabled. Practically that means a small
`src/corefoundation/CFPlatform_OpenDarwin.c` (or a patch overlay) holding our
overrides, plus a `-DCF_OPENDARWIN=1` guard added where upstream reaches for
something we do not have.

## Source tiers (build them in this order)

Each tier is independently linkable and testable with a small guest smoke.

- **Tier 0 — runtime core:** `CFBase.c`, `CFRuntime.c`, `CFPlatform.c`,
  `CFUtilities.c`, `CFSortFunctions.c`, `CFFileUtilities.c`.
  Gets you `CFRetain`/`CFRelease`/`CFGetTypeID`/`CFAllocator`. Needs: malloc,
  pthread mutex/once/TLS, `os_unfair_lock`, `mach_absolute_time`, `getenv`,
  `vsnprintf`.
- **Tier 1 — containers:** `CFBasicHash.c`, `CFArray.c`, `CFDictionary.c`,
  `CFSet.c`, `CFBag.c`, `CFData.c`, `CFStorage.c`, `CFNumber.c`.
  Almost no new syscalls; this tier should just fall out.
- **Tier 2 — strings:** `CFString.c`, `CFStringUtilities.c`,
  `CFStringEncodings.c`, `CFBuiltinConverters.c`, `CFUniChar.c`,
  `CFUnicodeDecomposition.c`, `CFCharacterSet.c`.
  The one real gotcha: the Unicode tables. CF loads
  `CFUniCharPropertyDatabase.data` / `CFCharacterSetBitmaps.bitmap` from
  `/System/Library/CoreServices/CharacterSets` unless built with the inline
  tables. Ship the blobs in the FAT rootfs (they are a few hundred KB) or
  `@embedFile` them behind our platform shim. Also: `CFSTR()` needs
  `-fconstant-cfstrings`, which emits `__DATA,__cfstring` records referencing
  `___CFConstantStringClassReference` — CF defines that symbol itself, but our
  Mach-O loader must map the section (it already maps `__DATA`).
- **Tier 3 — errors/URLs/plists:** `CFError.c`, `CFURL.c`,
  `CFPropertyList.c`, `CFBinaryPList.c`, `CFXMLPreferencesParser`-free subset.
  Unlocks reading real `Info.plist`s in userland, which pairs with the kernel's
  existing `src/kernel/kext/plist.zig`.
- **Tier 4 — time:** `CFDate.c`, `CFCalendar`/`CFTimeZone` (tzdata-dependent;
  stub `CFTimeZoneCopySystem` to UTC first).
- **Tier 5 — run loop:** `CFRunLoop.c`, `CFMachPort.c`, `CFSocket.c`,
  `CFStream.c`. This is where CF stops being pure computation and needs real
  Mach port sets (`mach_port_allocate`, `mach_port_insert_right`,
  `mach_msg` with port descriptors) plus `kevent`. It is also the tier
  SkyLight ultimately wants (`CGSFlushWindow` from a run-loop observer), so
  it lines up with the "out-of-process WindowServer" TODO.
- **Excluded for now:** `CFLocale*`, `CFDateFormatter`, `CFNumberFormatter`,
  `CFStringTransform` (all ICU), `CFBundle*` (dyld + `getsectiondata`),
  `CFPreferences` (needs cfprefsd), `CFUserNotification`, anything XPC.

## Expected libSystem gap

We already export ~200 symbols, and CF's needs overlap heavily with what is
there (`malloc`/`free`/`realloc`/`malloc_size`, `mmap`, `pthread_create`,
`__ulock_*`, `clock_gettime`, the openat/stat/dirent family, and — usefully —
the `dispatch_*` shims, which CF uses for `CFRunLoop`/`CFStream` timers).

What CF will demand that `src/libsystem` does **not** have yet, roughly in the
order the tiers hit it:

1. **stdio/formatting** — `vsnprintf`/`snprintf`/`asprintf`, `fprintf` to
   stderr, `strtod`/`strtol`. This is the single biggest chunk. Options:
   write a compact printf in `libsystem.zig` on top of `std.fmt` (no libc, we
   control it), or vendor a BSD-licensed printf. Recommend the former.
2. **pthread completion** — `pthread_key_create/getspecific/setspecific/
   key_delete`, `pthread_once`, `pthread_mutex_*` (incl. recursive),
   `pthread_rwlock_*`, `pthread_cond_*`. Our `__ulock_wait2`/`__ulock_wake`
   already give us the futex primitive to build them on.
3. **locking** — `os_unfair_lock_lock/unlock/trylock`, plus the legacy
   `OSSpinLock*` and `OSAtomic*` CF still references in a few places.
4. **time/env** — `gettimeofday`, `mach_absolute_time`, `mach_timebase_info`,
   `getenv`/`setenv`/`environ` (and `_NSGetEnviron`), `uuid_generate`.
5. **string/mem completion** — `strcmp`/`strncmp`/`strchr`/`strdup`/`strlcpy`,
   `qsort`/`bsearch`, `memcmp`, `memchr`.
6. **dyld/introspection** — `dlopen`/`dlsym`/`dladdr` (CFBundle, tier 6) and
   `getsectiondata`. Also fixes a real bug we already tripped over: Zig's
   `export fn _foo` emits `__foo`, so C-visible names like
   `_dyld_image_path_containing_address` need explicit `@export` aliases
   (now added at the bottom of the dyld section in `libsystem.zig`).
7. **Mach ports** — only for tier 5: `mach_port_allocate`,
   `mach_port_insert_right`, `mach_port_deallocate`, `mach_msg` with
   descriptors. Kernel-side this is the "complex mach_msg port descriptors"
   TODO item.

Notably absent from that list: ICU, notify, xpc, Security, objc. Keeping tiers
0–4 means never linking them.

## Workflow

`tools/symbol_gap.py` automates the loop:

```sh
zig build                                   # (re)build libSystem + SkyLight
zig cc -target aarch64-macos-none -c ...    # compile the CF tier you're on
./tools/symbol_gap.py --provider zig-out/lib/libSystem.B.dylib \
                      --provider zig-out/lib/SkyLight \
                      build/cf/*.o
```

It prints the still-unresolved symbols grouped by subsystem (malloc / pthread /
mach / stdio / ICU / ...), so each iteration is "pick a group, implement it in
`src/libsystem`, rerun". Exit status is non-zero while anything is missing, so
it can become a CI/build step once CF is wired into `build.zig`.

Suggested build integration when tier 0 compiles: an `addCoreFoundation()`
mirroring `addSkyLight()`, producing
`/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation` with the
right install name, plus a `cf-smoke` entry in `userland_programs` that does
`CFStringCreateWithCString` → `CFStringGetCString` → `write(1, ...)` and a
`CFDictionary` round trip. Select it as the boot binary with
`zig build zig-smoke-rootfs -Dmain=cf-smoke`.

## Why this order pays off

CF tiers 0–3 are exactly what an AppKit-shaped stack needs before anything
else: `CGSSetWindowProperty` currently takes a raw C string because we have no
`CFStringRef`, `CFNotificationCenter` is how AppKit-ish clients would talk to
SkyLight, and `CFRunLoop` (tier 5) is the missing piece behind
`[NSApplication run]`, which `tools/darwin_window_smoke.zig` calls on the host
and `src/userland/window_smoke.zig` cannot yet.
