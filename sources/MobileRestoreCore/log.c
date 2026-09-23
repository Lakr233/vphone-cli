/*
 * log.c
 *
 * Copyright (c) 2024 Nikias Bassen. All Rights Reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 */

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <sys/time.h>
#endif
#include <errno.h>

#include <libimobiledevice-glue/thread.h>
#include <plist/plist.h>

#include "log.h"

static int stderr_enabled = 1;

enum loglevel log_level = LL_VERBOSE;
enum loglevel print_level = LL_INFO;

static logger_print_func print_func = NULL;

const char *_level_label[6] = {
	"  <Error>",
	"<Warning>",
	" <Notice>",
	"   <Info>",
	"<Verbose>",
	"  <Debug>"	
};

// Reference: https://stackoverflow.com/a/2390626/1806760
// Initializer/finalizer sample for MSVC and GCC/Clang.
// 2010-2016 Joe Lowe. Released into the public domain.

#ifdef __cplusplus
    #define INITIALIZER(f) \
        static void f(void); \
        struct f##_t_ { f##_t_(void) { f(); } }; static f##_t_ f##_; \
        static void f(void)
#elif defined(_MSC_VER)
    #pragma section(".CRT$XCU",read)
    #define INITIALIZER2_(f,p) \
        static void f(void); \
        __declspec(allocate(".CRT$XCU")) void (*f##_)(void) = f; \
        __pragma(comment(linker,"/include:" p #f "_")) \
        static void f(void)
    #ifdef _WIN64
        #define INITIALIZER(f) INITIALIZER2_(f,"")
    #else
        #define INITIALIZER(f) INITIALIZER2_(f,"_")
    #endif
#else
    #define INITIALIZER(f) \
        static void f(void) __attribute__((__constructor__)); \
        static void f(void)
#endif

static mutex_t log_mutex;

static void logger_deinit(void)
{
	mutex_destroy(&log_mutex);
}

INITIALIZER(logger_init)
{
	mutex_init(&log_mutex);
	atexit(logger_deinit);
}

void logger(enum loglevel level, const char *fmt, ...)
{
	va_list ap;
	va_list ap2;
	char *fs;

	if (level > log_level)
		return;

	mutex_lock(&log_mutex);

	size_t fslen = 24 + strlen(fmt);
	fs = malloc(fslen);

#ifdef _WIN32
	SYSTEMTIME lt;
	GetLocalTime(&lt);
	snprintf(fs, fslen, "%02d:%02d:%02d.%03d %s %s", lt.wHour, lt.wMinute, lt.wSecond, lt.wMilliseconds, _level_label[level], fmt);
#else
	struct timeval ts;
	struct tm *tp;

	gettimeofday(&ts, NULL);
#ifdef HAVE_LOCALTIME_R
	struct tm tp_;
	tp = localtime_r(&ts.tv_sec, &tp_);
#else
	tp = localtime(&ts.tv_sec);
#endif

	strftime(fs, 9, "%H:%M:%S", tp);
	snprintf(fs+8, fslen-8, ".%03d %s %s", (int)(ts.tv_usec / 1000), _level_label[level], fmt);
#endif

	va_start(ap, fmt);
	va_copy(ap2, ap);
	if (print_func) {
		if (stderr_enabled) {
			vfprintf(stderr, fs, ap);
			fflush(stderr);
		}
		if (level <= print_level) {
			// skip the timestamp and log level string
			print_func(level, fs+23, ap2);
		}
	} else {
		vprintf(fs, ap);
	}

	va_end(ap);
	va_end(ap2);

	free(fs);

	mutex_unlock(&log_mutex);
}

#if defined(__GNUC__) || defined(__clang__)
static void print_funcf(enum loglevel level, const char* fmt, ...) __attribute__ ((format (printf, 2, 3)));
#else
static void print_funcf(enum loglevel level, const char* fmt, ...);
#endif

static void print_funcf(enum loglevel level, const char* fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	print_func(level, fmt, ap);
	va_end(ap);
}

void logger_dump_hex(enum loglevel level, const void* buf, size_t len)
{
	char *fs;

	if (level > log_level)
		return;

	mutex_lock(&log_mutex);

	fs = (char*)malloc((len == 0) ? 2 : (len * 3 + 1));
	if (!fs) {
		mutex_unlock(&log_mutex);
		return;
	}
	if (len == 0) {
		fs[0] = '\n';
		fs[1] = '\0';
	}
	for (unsigned int i = 0; i < len; i++) {
		snprintf(fs + i*3, 4, "%02x%c", ((unsigned char*)buf)[i], (i < len-1) ? ' ' : '\n');
	}
	if (print_func) {
		if (stderr_enabled) {
			fprintf(stderr, "%s", fs);
			fflush(stderr);
		}
		if (level <= print_level) {
			print_funcf(level, "%s", fs);
		}
	} else {
		printf("%s", fs);
	}
	free(fs);
	
	mutex_unlock(&log_mutex);
}

void logger_dump_plist(enum loglevel level, plist_t plist, int human_readable)
{
	if (level > log_level)
		return;
	mutex_lock(&log_mutex);
	plist_write_to_stream(plist, stderr_enabled ? stderr : stdout, (human_readable) ? PLIST_FORMAT_PRINT : PLIST_FORMAT_XML, PLIST_OPT_NONE);
	mutex_unlock(&log_mutex);
}

int logger_set_logfile(const char* path)
{
	if (!path || !strcasecmp(path, "NULL") || !strcasecmp(path, "NONE")) {
		stderr_enabled = 0;
		return 0;
	}
	stderr_enabled = 1;
	if (strcmp(path, "-")) {
		FILE* newf = freopen(path, "w", stderr);
		if (!newf) {
			logger(LL_ERROR, "Could not open logfile '%s': %s\n", path, strerror(errno));
			return -1;
		}
	}
	return 0;
}

void logger_set_print_func(logger_print_func func)
{
	print_func = func;
}
