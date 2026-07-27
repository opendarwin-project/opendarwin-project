#!/usr/bin/env python3
"""Report which undefined symbols of some Mach-O inputs our libraries can't satisfy.

This is the driver loop for bringing up CoreFoundation (and anything else built
from upstream C sources) on our minimal libSystem: compile the sources, point
this script at the resulting .o/.a files, and it prints the exact list of
symbols still missing from src/libsystem.  Implement, repeat until empty.

    zig build
    ./tools/symbol_gap.py --provider zig-out/lib/libSystem.B.dylib \\
                          --provider zig-out/lib/SkyLight \\
                          build/CoreFoundation/*.o

Undefined symbols are grouped by a rough subsystem guess so it's obvious
whether the next chunk of work is malloc-ish, pthread-ish, Mach-ish, ...
"""

import argparse
import re
import subprocess
import sys
from collections import defaultdict

# Symbols a Mach-O object legitimately imports from the compiler runtime or the
# dynamic linker itself; they are never our libSystem's job.
IGNORED = {
    "dyld_stub_binder",
    "___stack_chk_guard",
    "___stack_chk_fail",
}

GROUPS = [
    ("malloc/allocator", r"^_(malloc|calloc|realloc|free|valloc|posix_memalign|malloc_|mach_vm_|vm_)"),
    ("string/mem", r"^_(mem|str|str[nl]|bcopy|bzero|snprintf|vsnprintf|asprintf|qsort|bsearch)"),
    ("stdio/file", r"^_(open|close|read|write|lseek|stat|fstat|fopen|fclose|fread|fwrite|fprintf|fputs|fflush|mkstemp|unlink|access|getcwd|opendir|readdir|closedir)"),
    ("pthread/TLS", r"^_(pthread_|_pthread|__tlv|tlv_)"),
    ("mach", r"^_(mach_|task_|thread_|host_|semaphore_|vm_|mig_|MIG|bootstrap_|ipc_)"),
    ("dispatch", r"^_(dispatch_|_dispatch)"),
    ("dyld/image", r"^_(dl|_dyld|__dyld|getsect|_NSGet)"),
    ("locking", r"^_(os_unfair_lock|OSSpinLock|OSAtomic|__ulock)"),
    ("time", r"^_(gettimeofday|clock_|time|mktime|localtime|gmtime|nanosleep|usleep|sleep)"),
    ("locale/ICU", r"^_(u_|ucol_|udat_|unum_|uloc_|ucnv_|localeconv|setlocale|nl_langinfo)"),
    ("notify/xpc/security", r"^_(notify_|xpc_|Sec|CC|audit)"),
    ("CoreFoundation-internal", r"^_(_?CF|__CF)"),
    ("process/env", r"^_(getenv|setenv|unsetenv|environ|getpid|getuid|geteuid|getgid|sysctl|issetugid|confstr|uname|abort|exit|atexit|__cxa)"),
]


def nm(args):
    out = subprocess.run(["nm"] + args, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"nm failed: {out.stderr.strip()}")
    return out.stdout


def defined_symbols(path):
    """Exported (external, defined) symbols of a dylib/archive/object."""
    syms = set()
    for line in nm(["-g", "-P", path]).splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1] not in ("U", "u"):
            syms.add(parts[0])
    return syms


def undefined_symbols(paths):
    """Undefined symbols of the inputs, mapped to the files that want them."""
    wants = defaultdict(set)
    for path in paths:
        for line in nm(["-u", "-P", path]).splitlines():
            parts = line.split()
            if parts:
                wants[parts[0]].add(path)
    return wants


def group_of(sym):
    for name, pattern in GROUPS:
        if re.match(pattern, sym):
            return name
    return "other"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+", help="Mach-O objects/archives/dylibs to analyse")
    ap.add_argument("--provider", action="append", default=[], help="library that already provides symbols (repeatable)")
    ap.add_argument("--show-users", action="store_true", help="list which input file needs each symbol")
    args = ap.parse_args()

    provided = set()
    for p in args.provider:
        provided |= defined_symbols(p)

    missing = defaultdict(dict)
    total = 0
    for sym, users in sorted(undefined_symbols(args.inputs).items()):
        if sym in provided or sym in IGNORED:
            continue
        # A symbol defined by one of the analysed inputs is satisfied too.
        missing[group_of(sym)][sym] = users
        total += 1

    for group in sorted(missing):
        print(f"\n=== {group} ({len(missing[group])}) ===")
        for sym, users in sorted(missing[group].items()):
            if args.show_users:
                print(f"  {sym}\t<- {', '.join(sorted(users))}")
            else:
                print(f"  {sym}")

    print(f"\n{total} unresolved symbol(s) across {len(args.inputs)} input(s), "
          f"{len(provided)} provided by {len(args.provider)} library(ies)")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
