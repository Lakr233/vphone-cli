/*
 * config.h
 *
 * Hand-written stand-in for the config.h that libirecovery's autotools build
 * generates. It is NOT an upstream file: everything else under this target is
 * libirecovery 1.3.1 byte for byte, and this is the one file SwiftPM has to
 * supply in autoconf's place.
 *
 * Each value below is what `./configure` would have written on macOS, read off
 * upstream's configure.ac and config.h.in rather than guessed:
 *
 *   - CoreFoundation/CoreFoundation.h and IOKit/usb/IOUSBLib.h are both present
 *     in the macOS SDK, so configure takes the `darwin*` branch, sets
 *     have_iokit=yes, defaults --with-iokit to yes and defines HAVE_IOKIT. That
 *     is the IOKit USB backend; libusb is never reached and is not a dependency
 *     of this package.
 *   - USE_DUMMY stays undefined (--with-dummy defaults to no), or every
 *     transfer would compile down to IRECV_E_UNSUPPORTED.
 *   - BUILD_TOOLS and HAVE_READLINE stay undefined: tools/irecovery.c is not
 *     vendored, only src/libirecovery.c.
 *   - The HAVE_*_H / HAVE_<func> entries are the AC_CHECK_HEADERS and
 *     AC_CHECK_FUNCS lists from configure.ac, all of which hold on macOS.
 *   - AC_SYS_LARGEFILE defines nothing here: off_t is already 64-bit on macOS,
 *     so no _FILE_OFFSET_BITS / _LARGE_FILES.
 *   - The `const`, `size_t`, `ssize_t` and `uint{8,16,32}_t` fallbacks in
 *     config.h.in are for pre-C89 and Solaris hosts and stay undefined.
 *   - LT_OBJDIR is libtool's, and there is no libtool here.
 *
 * This target is built as a static library and linked into the executables of
 * this package, which is upstream's `--enable-static --disable-shared` case, so
 * IRECV_STATIC is defined too — in Package.swift, because libirecovery.h needs
 * it as well and this header is private to the target.
 */

#ifndef VPHONE_MOBILERECOVERYCORE_CONFIG_H
#define VPHONE_MOBILERECOVERYCORE_CONFIG_H

/* Name of package */
#define PACKAGE "libirecovery"

/* Define to the address where bug reports for this package should be sent. */
#define PACKAGE_BUGREPORT "https://github.com/libimobiledevice/libirecovery/issues"

/* Define to the full name of this package. */
#define PACKAGE_NAME "libirecovery"

/* Define to the full name and version of this package. */
#define PACKAGE_STRING "libirecovery 1.3.1"

/* Define to the one symbol short name of this package. */
#define PACKAGE_TARNAME "libirecovery"

/* Define to the home page for this package. */
#define PACKAGE_URL "https://libimobiledevice.org"

/* Define to the version of this package. */
#define PACKAGE_VERSION "1.3.1"

/* Version number of package */
#define VERSION "1.3.1"

/* Define if we have IOKit */
#define HAVE_IOKIT 1

/* Define to 1 if all of the C89 standard headers exist. */
#define STDC_HEADERS 1

/* Headers: the AC_CHECK_HEADERS list, plus the ones autoheader always emits. */
#define HAVE_DLFCN_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1

/* Functions: the AC_CHECK_FUNCS list. */
#define HAVE_CALLOC 1
#define HAVE_MALLOC 1
#define HAVE_REALLOC 1
#define HAVE_STRCASECMP 1
#define HAVE_STRDUP 1
#define HAVE_STRERROR 1
#define HAVE_STRNDUP 1

/*
 * Deliberately left undefined, to match a macOS ./configure with the defaults:
 *   BUILD_TOOLS, HAVE_READLINE, HAVE_READLINE_READLINE_H  (no tools built)
 *   USE_DUMMY                                             (real USB backend)
 *   LT_OBJDIR                                             (no libtool)
 *   _FILE_OFFSET_BITS, _LARGE_FILES, _TIME_BITS           (off_t is 64-bit)
 *   __MINGW_USE_VC2005_COMPAT                             (not mingw)
 *   _UINT32_T, _UINT8_T, const, size_t, ssize_t, uint*_t  (C99 host)
 */

#endif /* VPHONE_MOBILERECOVERYCORE_CONFIG_H */
