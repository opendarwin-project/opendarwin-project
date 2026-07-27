/*
 * OpenDarwin: there is no ObjC runtime.  CF's non-Apple path defines its own
 * placeholder `id`/`Class`/`SEL` typedefs in CoreFoundation_Prefix.h, so these
 * headers exist purely to shadow the SDK's real ones (which CF pulls in via
 * ForFoundationOnly.h because the target triple is still *-macos).
 */
