/* Minimal stand-in for Apple's <asl.h>.  OpenDarwin has no syslogd, so CFLog's
   ASL path degrades to no-ops and the fputs()-to-stderr path does the work. */
#ifndef CF_OPENDARWIN_ASL_H
#define CF_OPENDARWIN_ASL_H
#include <stddef.h>
typedef void *aslclient;
typedef void *aslmsg;
#define ASL_KEY_LEVEL "Level"
#define ASL_KEY_MSG "Message"
#define ASL_LEVEL_EMERG 0
#define ASL_LEVEL_DEBUG 7
#define ASL_OPT_NO_DELAY 0x02
#define ASL_TYPE_MSG 0
static inline aslclient asl_open(const char *i, const char *f, unsigned o) { (void)i; (void)f; (void)o; return NULL; }
static inline void asl_close(aslclient c) { (void)c; }
static inline aslmsg asl_new(unsigned t) { (void)t; return NULL; }
static inline void asl_free(aslmsg m) { (void)m; }
static inline int asl_set(aslmsg m, const char *k, const char *v) { (void)m; (void)k; (void)v; return 0; }
static inline int asl_send(aslclient c, aslmsg m) { (void)c; (void)m; return 0; }
#endif
