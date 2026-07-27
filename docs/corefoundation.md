# Bringing up CoreFoundation on OpenDarwin

Short answer to "can we just wire libSystem up to real CF C sources?": **yes,
and that is the cheapest path** — CF is plain C, it is one of the few Apple
frameworks with a genuinely portable upstream, and its dependency surface is
almost entirely POSIX + pthreads + malloc + a handful of Mach calls we already
have trap wrappers for. The work is not "write CF", it is "close a symbol gap",
which is a mechanical loop (see *Workflow* below).

## Which CF sources (settled: swift-corelibs, 5.1.5)

`build.zig.zon` pins:

```
.corefoundation = git+https://github.com/swiftlang/swift-corelibs-foundation
                  ?ref=swift-5.1.5-RELEASE
```

Why that exact source, having tried the alternatives:

| candidate | verdict |
| --- | --- |
| swift-corelibs **6.0.3** (`Sources/CoreFoundation`) | **Rejected.** `DEPLOYMENT_RUNTIME_C` is gone; `CFRuntime.c` allocates with `swift_allocObject` and retains with `swift_retain`/`swift_release` unconditionally. Adopting it means adopting the Swift runtime. |
| **apple-oss-distributions/CF (CF-1153)** | Rejected for now. Pristine macOS CF, but wants `auto_zone.h` (ObjC GC), CrashReporterClient, and the Apple SDK's private headers before the first file compiles. |
| swift-corelibs **5.1.5** (`CoreFoundation/`) | **Chosen.** Same CF-1153 lineage, still has the non-Swift C refcounting path, and compiles clean with a force-included prefix and six shim headers. |

The configuration is deliberately a hybrid that no upstream `DEPLOYMENT_TARGET_*`
describes, because it is exactly what OpenDarwin is:

- `-DDEPLOYMENT_TARGET_LINUX=1` — "not Apple's userland": no ObjC runtime, no
  Swift runtime, no ICU, no CFNetwork, C refcounting.
- target triple `aarch64-macos-none` — so `TARGET_OS_MAC` stays 1 and CF's
  Mach-O paths (including the `__UNICODE` segment trick) remain live.

`src/corefoundation/cf_prefix.h` is force-included to reconcile the two, and
`src/corefoundation/shims/` shadows headers Apple has but we do not. Upstream
sources are used byte-for-byte; nothing is patched.

| shim | why |
| --- | --- |
| `objc/{objc,message,runtime,NSObject,objc-auto,objc-sync}.h` | empty — shadow the SDK's real ObjC headers, which conflict with CF's own placeholder `id`/`Class` typedefs |
| `asl.h` | no syslogd; `CFLog`'s ASL path becomes no-ops and the stderr path does the work |
| `vproc.h` | no launchd |
| `mach/mach_vm.h` | zig ships no `mach_vm.h`; declares the three calls `CFUtilities.c` uses |
| `mach-o/ldsyms.h` | ditto for `_mh_dylib_header` |
| `unicode/uchar.h` | CF's only ICU reference in this tier is `u_charDigitValue` |

The prefix header itself supplies just three things: `DECLARE_STATIC_CLASS_REF`
(defined only in the Swift branch upstream), a pre-include of
`ForSwiftFoundationOnly.h` (for `__CFSwiftBridge` and the `_CFThread*`
typedefs that non-Darwin code names inside `CF_IS_SWIFT()`-dead branches), and
a constant-zero `__CFDoExternRefOperation` (the ObjC external-refcount side
table).

## What builds today

```sh
zig build corefoundation   # -> zig-out/lib/libCoreFoundationCore.a
zig build cf-gap           # -> what libSystem still owes CF
```

24 upstream translation units compile clean and produce **327 exported `CF*`
symbols**, including the reason for doing this at all:

`CFDictionaryCreate` / `CFDictionaryCreateMutable` / `CFDictionarySetValue` /
`CFDictionaryGetValue` / `CFDictionaryApplyFunction`, `CFStringCreateWithCString`,
`CFNumberCreate`, `CFBooleanGetTypeID`, `CFEqual`, `CFHash`, `CFRetain`/`CFRelease`
— i.e. everything needed to make `IOServiceMatching()` return a real
`CFMutableDictionaryRef` instead of the current ad-hoc struct, and to hand real
CF property dictionaries to the kernel's IOKit registry.

The tier is: `CFBase`, `CFRuntime`, `CFPlatform`, `CFSortFunctions`,
`CFFileUtilities`, `CFUtilities`, `CFArray`, `CFBag`, `CFBasicHash`, `CFData`,
`CFDictionary`, `CFSet`, `CFStorage`, `CFString`, `CFCharacterSet`,
`CFStringEncodingConverter`, `CFStringEncodingDatabase`, `CFBuiltinConverters`,
`CFPlatformConverters`, `CFUniChar`, `CFUnicodeDecomposition`,
`CFUnicodePrecomposition`, `CFNumber`, `CFError`.

It is a **static** library on purpose: the dylib cannot link until the symbol
gap below closes, and a static archive is an honest artifact that proves the
compile side is done.

## Remaining gap (from `zig build cf-gap`, 197 symbols)

- **77 `CF*`** from tiers we left out (`CFDate`, `CFTimeZone`, `CFURL`,
  `CFPropertyList`, `CFLocale`, `CFNumberFormatter`, `CFBundle`, `CFRunLoop`,
  the `__CF*Class` runtime-class table entries). Each is either "add the file"
  or "stub the class-table slot"; `CFLocale`/`CFNumberFormatter` should be
  stubbed, not built, since they are the ICU ones.
- **~120 libSystem symbols**, and the grouping is exactly as predicted:
  - *string/mem (16)*: `snprintf`/`vsnprintf`/`asprintf` + `_l` variants,
    `strcmp`/`strchr`/`strdup`/`strtol`/`qsort`/`memcmp`/`memchr`
  - *stdio (9)*: `fprintf`, `fflush`, `opendir`/`readdir`/`closedir`, `stat`
  - *pthread (10)*: `pthread_key_create`/`getspecific`/`setspecific`,
    `pthread_mutex_lock`/`unlock`, `pthread_main_np`, `pthread_atfork`
  - *locking (7)*: `os_unfair_lock_*`, `OSSpinLock*`, `OSAtomic*`
  - *malloc (12)*: `calloc`, `malloc_good_size`, the `malloc_zone_*` family,
    `mach_vm_allocate`/`deallocate`/`region`, `vm_page_size`
  - *dyld (8)*: `_dyld_image_count`/`get_image_header`/`vmaddr_slide`,
    `getsectbynamefromheader_64`, `dlopen`/`dlsym`, `_NSGetArgc`/`Argv`
  - *misc (48)*: blocks runtime (`_Block_copy`/`_NSConcrete*Block`),
    `__*_chk` fortified variants, `__stderrp`, `pow`/`fmod`/`modf`,
    `getpwuid`, and the `section$start$__UNICODE$*` markers below

### The `__UNICODE` segment

`CFUniChar.c` hard-defines `USE_MACHO_SEGMENT 1` whenever `TARGET_OS_MAC`, so
the Unicode tables are expected *inside the dylib* as a `__UNICODE` segment,
referenced through linker-synthesised `section$start$__UNICODE$__csbitmaps`
style symbols. That is good news — no runtime file loading — and upstream's own
Darwin link line tells us exactly how to produce it:

```
-sectcreate __UNICODE __csbitmaps  CharacterSets/CFCharacterSetBitmaps.bitmap
-sectcreate __UNICODE __properties CharacterSets/CFUniCharPropertyDatabase.data
-sectcreate __UNICODE __data       CharacterSets/CFUnicodeData-L.mapping
-segprot    __UNICODE r r
```

Those blobs ship in the dependency (`CoreFoundation/CharacterSets/`); wire the
flags in when the target becomes a dylib.

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

## Kernel VFS (prerequisite for CF file I/O)

Userspace `open`/`read`/`lseek`/`stat` now go through a minimal XNU/BSD-shaped
VFS (`src/kernel/fs/vfs.zig` + `namei.zig`) with FAT as the first filesystem
backend. The early boot loader still uses `fat.readFile` / `vfs.readFile`;
libSystem's stdio path is live for absolute paths on the read-only rootfs.
Still missing for CFFileUtilities / CFURL: `opendir`/`readdir` /
`__getdirentries64`, `openat`, and a real cwd.

## Workflow

`tools/symbol_gap.py` automates the loop:

```sh
zig build cf-gap    # builds CF, prints the grouped list of missing symbols
```

or by hand against any objects/archives/dylibs:

```sh
./tools/symbol_gap.py --provider zig-out/lib/libSystem.B.dylib \
                      --provider zig-out/lib/SkyLight \
                      zig-out/lib/libCoreFoundationCore.a
```

It prints the still-unresolved symbols grouped by subsystem (malloc / pthread /
mach / stdio / ICU / ...), so each iteration is "pick a group, implement it in
`src/libsystem`, rerun". Exit status is non-zero while anything is missing, so
it can become a CI/build step once CF is wired into `build.zig`.

Next build step, once the gap closes: turn `addCoreFoundation()`'s static
library into a dylib installed at
`/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation` (right
install name + the `-sectcreate __UNICODE` flags above), plus a `cf-smoke`
entry in `userland_programs` that does
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
