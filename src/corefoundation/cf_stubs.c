/*
 * OpenDarwin CoreFoundation stubs for tiers excluded from initial bring-up
 * (locale/ICU, bundle, run loop, streams, etc.).
 */
#include <CoreFoundation/CFBase.h>
#include <CoreFoundation/CFRuntime.h>
#include <CoreFoundation/CFNumberFormatter.h>
#include <CoreFoundation/CFBundle.h>
#include <CoreFoundation/CFStream.h>
#include <CoreFoundation/CFTimeZone.h>
#include "CFRuntime_Internal.h"
#include "CFInternal.h"
#include "CFICUConverters.h"

#define STUB_CLASS(NAME) \
    const CFRuntimeClass __##NAME##Class = { \
        0, "CF" #NAME, NULL, NULL, NULL, NULL, NULL, NULL, NULL \
    }

STUB_CLASS(CFAttributedString);
STUB_CLASS(CFBinaryHeap);
STUB_CLASS(CFBitVector);
STUB_CLASS(CFBundle);
STUB_CLASS(CFCalendar);
STUB_CLASS(CFDateFormatter);
STUB_CLASS(CFDateIntervalFormatter);
STUB_CLASS(CFLocale);
STUB_CLASS(CFMachPort);
STUB_CLASS(CFMessagePort);
STUB_CLASS(CFPFactory);
STUB_CLASS(CFPlugInInstance);
STUB_CLASS(CFPreferencesDomain);
STUB_CLASS(CFReadStream);
STUB_CLASS(CFRunArray);
STUB_CLASS(CFRunLoop);
STUB_CLASS(CFRunLoopMode);
STUB_CLASS(CFRunLoopObserver);
STUB_CLASS(CFRunLoopSource);
STUB_CLASS(CFRunLoopTimer);
STUB_CLASS(CFSocket);
STUB_CLASS(CFTree);
STUB_CLASS(CFURLComponents);
STUB_CLASS(CFUUID);
STUB_CLASS(CFWriteStream);
STUB_CLASS(CFXMLNode);
STUB_CLASS(CFXMLParser);
STUB_CLASS(CFNumberFormatter);
STUB_CLASS(CFTimeZone);

CF_EXPORT const CFStringRef __kCFLocaleCollatorID = CFSTR("locale:collator id");
CF_EXPORT const CFStringRef kCFLocaleDecimalSeparatorKey = CFSTR("kCFLocaleDecimalSeparatorKey");
CF_EXPORT const CFStringRef kCFNumberFormatterFormatWidthKey = CFSTR("kCFNumberFormatterFormatWidthKey");
CF_EXPORT const CFStringRef kCFNumberFormatterGroupingSizeKey = CFSTR("kCFNumberFormatterGroupingSizeKey");
CF_EXPORT const CFStringRef kCFNumberFormatterMaxFractionDigitsKey = CFSTR("kCFNumberFormatterMaxFractionDigitsKey");
CF_EXPORT const CFStringRef kCFNumberFormatterMaxSignificantDigitsKey = CFSTR("kCFNumberFormatterMaxSignificantDigitsKey");
CF_EXPORT const CFStringRef kCFNumberFormatterMinFractionDigitsKey = CFSTR("kCFNumberFormatterMinFractionDigitsKey");
CF_EXPORT const CFStringRef kCFNumberFormatterMinIntegerDigitsKey = CFSTR("kCFNumberFormatterMinIntegerDigitsKey");
CF_EXPORT const CFStringRef kCFNumberFormatterMinSignificantDigitsKey = CFSTR("kCFNumberFormatterMinSignificantDigitsKey");
CF_EXPORT const CFStringRef kCFNumberFormatterPaddingCharacterKey = CFSTR("kCFNumberFormatterPaddingCharacterKey");
CF_EXPORT const CFStringRef kCFNumberFormatterPaddingPositionKey = CFSTR("kCFNumberFormatterPaddingPositionKey");
CF_EXPORT const CFStringRef kCFNumberFormatterSecondaryGroupingSizeKey = CFSTR("kCFNumberFormatterSecondaryGroupingSizeKey");
CF_EXPORT const CFStringRef kCFNumberFormatterUseSignificantDigitsKey = CFSTR("kCFNumberFormatterUseSignificantDigitsKey");

CF_EXPORT CFBundleRef __CFBundleMainID = NULL;

static CFLocaleRef nullLocale = NULL;

CFLocaleRef __CFLocaleGetNullLocale(void) {
    return nullLocale;
}

void __CFLocaleSetNullLocale(CFLocaleRef locale) {
    nullLocale = locale;
}

CFTypeRef __CFCharToUniCharTable = NULL;

void __CFSetCharToUniCharFunc(void *func) {
    (void)func;
}

CFStringEncoding CFStringConvertIANACharSetNameToEncoding(CFStringRef charsetName) {
    (void)charsetName;
    return kCFStringEncodingUTF8;
}

CFComparisonResult _CFCompareStringsWithLocale(CFStringInlineBuffer *str1, CFRange str1Range,
    CFStringInlineBuffer *str2, CFRange str2Range, CFOptionFlags options, const void *compareLocale) {
    (void)str1;
    (void)str1Range;
    (void)str2;
    (void)str2Range;
    (void)options;
    (void)compareLocale;
    return kCFCompareEqualTo;
}

// ICU converter tier excluded — no-op stubs with correct signatures.
const char *__CFStringEncodingGetICUName(CFStringEncoding encoding) {
    (void)encoding;
    return "UTF-8";
}

CFStringEncoding *__CFStringEncodingCreateICUEncodings(CFAllocatorRef allocator, CFIndex *numberOfIndex) {
    if (numberOfIndex) *numberOfIndex = 0;
    (void)allocator;
    return NULL;
}

CFIndex __CFStringEncodingICUByteLength(const char *icuName, uint32_t flags, const UniChar *characters, CFIndex numChars) {
    (void)icuName;
    (void)flags;
    (void)characters;
    return numChars;
}

CFIndex __CFStringEncodingICUCharLength(const char *icuName, uint32_t flags, const uint8_t *bytes, CFIndex numBytes) {
    (void)icuName;
    (void)flags;
    (void)bytes;
    return numBytes;
}

CFIndex __CFStringEncodingICUToBytes(const char *icuName, uint32_t flags, const UniChar *characters, CFIndex numChars,
    CFIndex *usedCharLen, uint8_t *bytes, CFIndex maxByteLen, CFIndex *usedByteLen) {
    (void)icuName;
    (void)flags;
    (void)characters;
    (void)numChars;
    (void)bytes;
    (void)maxByteLen;
    if (usedCharLen) *usedCharLen = 0;
    if (usedByteLen) *usedByteLen = 0;
    return 0;
}

CFIndex __CFStringEncodingICUToUnicode(const char *icuName, uint32_t flags, const uint8_t *bytes, CFIndex numBytes,
    CFIndex *usedByteLen, UniChar *characters, CFIndex maxCharLen, CFIndex *usedCharLen) {
    (void)icuName;
    (void)flags;
    (void)bytes;
    (void)numBytes;
    (void)characters;
    (void)maxCharLen;
    if (usedByteLen) *usedByteLen = 0;
    if (usedCharLen) *usedCharLen = 0;
    return 0;
}

// Locale / formatter API stubs (ICU tier excluded).
CFLocaleRef CFLocaleCopyCurrent(void) {
    return NULL;
}

CFTypeID CFLocaleGetTypeID(void) {
    static CFTypeID typeID = _kCFRuntimeNotATypeID;
    if (typeID == _kCFRuntimeNotATypeID) {
        typeID = _CFRuntimeRegisterClass(&__CFLocaleClass);
    }
    return typeID;
}

CFStringRef CFLocaleGetIdentifier(CFLocaleRef locale) {
    (void)locale;
    return CFSTR("en_US_POSIX");
}

CFTypeRef CFLocaleGetValue(CFLocaleRef locale, CFStringRef key) {
    (void)locale;
    (void)key;
    return NULL;
}

CFNumberFormatterRef CFNumberFormatterCreate(CFAllocatorRef alloc, CFLocaleRef locale, CFNumberFormatterStyle style) {
    (void)alloc;
    (void)locale;
    (void)style;
    return NULL;
}

CFStringRef CFNumberFormatterCreateStringWithValue(CFAllocatorRef allocator, CFNumberFormatterRef formatter,
    CFNumberType numberType, const void *valuePtr) {
    (void)allocator;
    (void)formatter;
    (void)numberType;
    (void)valuePtr;
    return NULL;
}

CFTypeRef CFNumberFormatterCopyProperty(CFNumberFormatterRef formatter, CFStringRef key) {
    (void)formatter;
    (void)key;
    return NULL;
}

CFStringRef CFNumberFormatterGetFormat(CFNumberFormatterRef formatter) {
    (void)formatter;
    return NULL;
}

CFLocaleRef CFNumberFormatterGetLocale(CFNumberFormatterRef formatter) {
    (void)formatter;
    return NULL;
}

void CFNumberFormatterSetFormat(CFNumberFormatterRef formatter, CFStringRef formatString) {
    (void)formatter;
    (void)formatString;
}

void CFNumberFormatterSetProperty(CFNumberFormatterRef formatter, CFStringRef key, CFTypeRef value) {
    (void)formatter;
    (void)key;
    (void)value;
}

CFBundleRef CFBundleCreate(CFAllocatorRef alloc, CFURLRef bundleURL) {
    (void)alloc;
    (void)bundleURL;
    return NULL;
}

CFBundleRef CFBundleGetBundleWithIdentifier(CFStringRef identifier) {
    (void)identifier;
    return NULL;
}

CFStringRef CFBundleCopyLocalizedString(CFBundleRef bundle, CFStringRef key, CFStringRef value, CFStringRef tableName) {
    (void)bundle;
    (void)tableName;
    if (value) return (CFStringRef)CFRetain(value);
    if (key) return (CFStringRef)CFRetain(key);
    return NULL;
}

CFArrayRef CFCopySearchPathForDirectoriesInDomains(CFSearchPathDirectory directory,
    CFSearchPathDomainMask domainMask, Boolean expandSymlinks) {
    (void)directory;
    (void)domainMask;
    (void)expandSymlinks;
    return NULL;
}

CF_EXPORT const CFStringRef kCFStreamPropertyDataWritten = CFSTR("kCFStreamPropertyDataWritten");

CFTimeInterval CFTimeZoneGetSecondsFromGMT(CFTimeZoneRef tz, CFAbsoluteTime at) {
    (void)tz;
    (void)at;
    return 0.0;
}

CFIndex CFReadStreamRead(CFReadStreamRef stream, UInt8 *buffer, CFIndex bufferLength) {
    (void)stream;
    (void)buffer;
    (void)bufferLength;
    return 0;
}

CFErrorRef CFReadStreamCopyError(CFReadStreamRef stream) {
    (void)stream;
    return NULL;
}

CFWriteStreamRef CFWriteStreamCreateWithAllocatedBuffers(CFAllocatorRef alloc, CFAllocatorRef bufferAllocator) {
    (void)alloc;
    (void)bufferAllocator;
    return NULL;
}

Boolean CFWriteStreamOpen(CFWriteStreamRef stream) {
    (void)stream;
    return false;
}

void CFWriteStreamClose(CFWriteStreamRef stream) {
    (void)stream;
}

CFIndex CFWriteStreamWrite(CFWriteStreamRef stream, const UInt8 *buffer, CFIndex bufferLength) {
    (void)stream;
    (void)buffer;
    (void)bufferLength;
    return 0;
}

CFTypeRef CFWriteStreamCopyProperty(CFWriteStreamRef stream, CFStreamPropertyKey propertyName) {
    (void)stream;
    (void)propertyName;
    return NULL;
}

CFErrorRef CFWriteStreamCopyError(CFWriteStreamRef stream) {
    (void)stream;
    return NULL;
}
