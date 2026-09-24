/*
 * config.h
 *
 * Hand-written stand-in for the config.h that idevicerestore's autotools build
 * generates. It is NOT an upstream file: everything else under this target is
 * upstream's own source, and this is the one file SwiftPM has to supply in
 * autoconf's place. It lives beside the .c files rather than in Include/ for
 * the same reason MobileRecoveryCore's does — Include/ is this target's public
 * header directory and becomes the generated module's umbrella, and no
 * dependent should inherit a PACKAGE_VERSION it did not ask for. Two targets
 * in this package now carry a config.h, and if both were public they would
 * collide in any translation unit that imported both modules.
 * `.headerSearchPath(".")` plus `.define("HAVE_CONFIG_H")` is what reaches it.
 *
 * Every value below is read off upstream's configure.ac rather than guessed:
 *
 *   - PKG_CHECK_MODULES only decides whether to build at all; it defines
 *     nothing. libirecovery is MobileRecoveryCore, and libimobiledevice, its
 *     glue, libplist, libusbmuxd and libtatsu come from the
 *     AppleMobileDeviceLibrary xcframeworks. zlib and libcurl are the system
 *     ones in /usr/lib. libzip is the exception — see zip.h.
 *   - AC_CHECK_FUNCS([strsep strcspn mkstemp realpath]) — all four are in libc
 *     on macOS, so all four are defined. That is also what keeps common.c's
 *     own strsep()/realpath() fallbacks compiled out.
 *   - The `darwin*` arm of the host_os case defines _DARWIN_BETTER_REALPATH.
 *   - The four AC_CACHE_CHECK compile tests all pass against the
 *     libimobiledevice 1.4.0 headers this package links: IDEVICE_E_TIMEOUT is
 *     in libimobiledevice.h, RESTORE_E_RECEIVE_TIMEOUT in restore.h, `enum
 *     idevice_connection_type` in libimobiledevice.h, and reverse_proxy.h
 *     declares reverse_proxy_client_create_with_port.
 *   - --with-limera1n defaults to yes, so HAVE_LIMERA1N is defined and
 *     limera1n.c is part of the target, exactly as in an upstream build.
 *   - AC_CHECK_HEADER(endian.h) fails on macOS, which is why configure would
 *     define __LITTLE_ENDIAN/__BIG_ENDIAN/__BYTE_ORDER itself. Those are NOT
 *     defined here: endianness.h already supplies the identical values behind
 *     its own #ifndef guards, and clang defines __LITTLE_ENDIAN__ on every
 *     Apple target, so __BYTE_ORDER resolves the same way. Defining them here
 *     would only risk a clash with Darwin's <machine/endian.h>.
 *   - AC_SYS_LARGEFILE defines nothing: off_t is already 64-bit on macOS.
 *   - WIN32, LT_OBJDIR and the Windows/mingw fallbacks stay undefined.
 *
 * Two entries are this package's rather than autoconf's, both marked below:
 * IDEVICERESTORE_NOMAIN and HAVE_LOCALTIME_R.
 */

#ifndef VPHONE_MOBILERESTORECORE_CONFIG_H
#define VPHONE_MOBILERESTORECORE_CONFIG_H

/*
 * Version. configure gets this from git-version-gen, which needs either a git
 * checkout or a .tarball-version file; the upstream snapshot vendored here is
 * a source export with neither, so ./configure would have stopped with
 * "PACKAGE_VERSION is not defined". 1.1.0 is the series this snapshot belongs
 * to — it is the version in upstream's own README sample output, and the
 * generated string would have been "1.1.0-git-<commit>". PACKAGE_VERSION
 * reaches exactly two places: the startup banner, and the curl User-Agent in
 * download.c ("InetURL/1.0 idevicerestore/1.1.0").
 */
#define PACKAGE "idevicerestore"
#define PACKAGE_NAME "idevicerestore"
#define PACKAGE_TARNAME "idevicerestore"
#define PACKAGE_VERSION "1.1.0"
#define PACKAGE_STRING "idevicerestore 1.1.0"
#define VERSION "1.1.0"
#define PACKAGE_BUGREPORT "https://github.com/libimobiledevice/idevicerestore/issues"
#define PACKAGE_URL "https://libimobiledevice.org"

/* AC_CHECK_FUNCS([strsep strcspn mkstemp realpath]) */
#define HAVE_STRSEP 1
#define HAVE_STRCSPN 1
#define HAVE_MKSTEMP 1
#define HAVE_REALPATH 1

/* case ${host_os} in darwin*) */
#define _DARWIN_BETTER_REALPATH 1

/* The four AC_CACHE_CHECK compile tests, against libimobiledevice 1.4.0. */
#define HAVE_IDEVICE_E_TIMEOUT 1
#define HAVE_RESTORE_E_RECEIVE_TIMEOUT 1
#define HAVE_ENUM_IDEVICE_CONNECTION_TYPE 1
#define HAVE_REVERSE_PROXY 1

/* AC_ARG_WITH([limera1n]) defaults to yes. */
#define HAVE_LIMERA1N 1

/* Headers: the set autoheader always emits, all of which exist on macOS. */
#define STDC_HEADERS 1
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

/*
 * NOT autoconf's. idevicerestore is a program upstream and a library here, so
 * src/idevicerestore.c's main(), its getopt table, its usage text and its
 * SIGINT handler are all excluded. Everything the library needs is above that
 * guard: idevicerestore_client_new/_free, the idevicerestore_set_* setters and
 * idevicerestore_start. vphone_restore_bridge.c is what stands in for main().
 */
#define IDEVICERESTORE_NOMAIN 1

/*
 * NOT autoconf's either — configure.ac never tests for localtime_r, so an
 * upstream macOS build leaves this undefined and log.c calls localtime(3).
 * That returns a pointer into a single process-wide struct tm. In a program
 * that is fine; in a library linked into a GUI app whose own code may be
 * calling localtime() on another thread, it is a data race on every log line.
 * localtime_r is in libc on macOS, so define it and let log.c use the
 * reentrant call.
 */
#define HAVE_LOCALTIME_R 1

/*
 * Deliberately left undefined, to match a macOS ./configure with the defaults:
 *   WIN32, __MINGW_USE_VC2005_COMPAT                   (not Windows)
 *   __LITTLE_ENDIAN, __BIG_ENDIAN, __BYTE_ORDER        (endianness.h covers it)
 *   _FILE_OFFSET_BITS, _LARGE_FILES, _TIME_BITS        (off_t is 64-bit)
 *   LT_OBJDIR                                          (no libtool)
 */

#endif /* VPHONE_MOBILERESTORECORE_CONFIG_H */
