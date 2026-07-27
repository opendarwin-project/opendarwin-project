/*
 * OpenDarwin CoreFoundation prefix header.
 *
 * Force-included (-include) ahead of every upstream CF translation unit, the
 * way swift-corelibs' own CMake force-includes CoreFoundation_Prefix.h.  Its
 * whole job is to reconcile the configuration we build CF in — which upstream
 * never ships — with the code as written:
 *
 *   * We compile with DEPLOYMENT_TARGET_LINUX (i.e. "not Apple's userland":
 *     no ObjC runtime, no Swift runtime, no ICU, no CFNetwork) while the
 *     *target triple* is aarch64-macos, so TARGET_OS_MAC is still 1 and CF's
 *     Mach-O paths stay live.  That combination is exactly OpenDarwin, and no
 *     upstream DEPLOYMENT_TARGET_* describes it.
 *   * DEPLOYMENT_RUNTIME_SWIFT is off, so CF's C refcounting is used - but a
 *     handful of files still name __CFSwiftBridge and the _CFThread* typedefs
 *     from ForSwiftFoundationOnly.h inside branches that CF_IS_SWIFT() makes
 *     dead.  Pre-including that header gives them declarations without
 *     switching the runtime.
 *
 * Everything here is a compile-time reconciliation; no behaviour is patched.
 * Upstream sources stay byte-for-byte as fetched by build.zig.zon.
 */
#ifndef CF_OPENDARWIN_PREFIX_H
#define CF_OPENDARWIN_PREFIX_H

/* Only defined in the DEPLOYMENT_RUNTIME_SWIFT branch of ForFoundationOnly.h,
   but used unconditionally by CFBase.c / CFNumber.c / CFString.c. With no
   ObjC or Swift runtime the isa slot is NULL (STATIC_CLASS_REF(...) == NULL),
   so the referenced class symbol only needs to exist for the parser. */
#define DECLARE_STATIC_CLASS_REF(CLASSNAME) extern int __cf_static_class_unused_##CLASSNAME

#include "CoreFoundation_Prefix.h"

#include <CoreFoundation/CFBase.h>
#include <CoreFoundation/CFString.h>
#include <CoreFoundation/ForFoundationOnly.h>
#include <CoreFoundation/ForSwiftFoundationOnly.h>

/* CFRuntime.c's external-refcount side table is compiled only for the ObjC
   runtime, yet CFGetRetainCount()/CFRelease() reference it unconditionally.
   Without ObjC no object ever sets the high-refcount bit, so the operation is
   a constant zero. */
#ifndef __CFDoExternRefOperation
#define __CFDoExternRefOperation(op, obj) ((uintptr_t)0)
#endif

#endif /* CF_OPENDARWIN_PREFIX_H */
