/*
 * log.h
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

#ifndef LOG_H
#define LOG_H

#include <plist/plist.h>

enum loglevel {
	LL_ERROR = 0,
	LL_WARNING,
	LL_NOTICE,
	LL_INFO,
	LL_VERBOSE,
	LL_DEBUG
};

extern enum loglevel log_level;

typedef void (*logger_print_func)(enum loglevel level, const char*, va_list);

void logger(enum loglevel level, const char *fmt, ...) __attribute__ ((format (printf, 2, 3)));
int logger_set_logfile(const char* path);
void logger_set_print_func(logger_print_func func);
void logger_dump_hex(enum loglevel level, const void* buf, size_t len);
void logger_dump_plist(enum loglevel level, plist_t plist, int human_readable);

#endif
