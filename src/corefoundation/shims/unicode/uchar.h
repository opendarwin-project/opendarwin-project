/* Minimal ICU stand-in: CF only needs u_charDigitValue from <unicode/uchar.h>. */
#ifndef CF_OPENDARWIN_ICU_UCHAR_H
#define CF_OPENDARWIN_ICU_UCHAR_H
#include <stdint.h>
typedef int32_t UChar32;
extern int32_t u_charDigitValue(UChar32 c);
#endif
