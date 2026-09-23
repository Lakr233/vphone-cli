/*
 * common.c
 * Misc functions used in idevicerestore
 *
 * Copyright (c) 2012-2019 Nikias Bassen. All Rights Reserved.
 * Copyright (c) 2012 Martin Szulecki. All Rights Reserved.
 * Copyright (c) 2010 Joshua Hill. All Rights Reserved.
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
#include <unistd.h>
#include <errno.h>
#include <libgen.h>
#include <time.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <ctype.h>
#include <libimobiledevice-glue/thread.h>
#include <libimobiledevice-glue/collection.h>

#ifdef WIN32
#include <windows.h>
#include <conio.h>
#ifndef _O_EXCL
#define _O_EXCL  0x0400
#endif
#ifndef O_EXCL
#define O_EXCL   _O_EXCL
#endif
#else
#include <sys/time.h>
#include <pthread.h>
#include <termios.h>
#endif

#include "common.h"
#include "endianness.h"

#define MAX_PRINT_LEN 64*1024

int global_quit_flag = 0;
static const char* STARS  = "******************************************************************************";
static const char* SPACES = "                                                                              ";
static const char* POUNDS = "##############################################################################";

static uint32_t progress_unique_tag = 1;

struct idevicerestore_mode_t idevicerestore_modes[] = {
	{  0, "Unknown"  },
	{  1, "WTF"      },
	{  2, "DFU"      },
	{  3, "Recovery" },
	{  4, "Restore"  },
	{  5, "Normal"   },
	{  6, "Port DFU" },
};

int idevicerestore_debug = 0;

static void (*banner_func)(const char*) = NULL;
static void (*banner_hide_func)(void) = NULL;

int write_file(const char* filename, const void* data, size_t size) {
	size_t bytes = 0;
	FILE* file = NULL;

	logger(LL_DEBUG, "Writing data to %s\n", filename);
	file = fopen(filename, "wb");
	if (file == NULL) {
		logger(LL_ERROR, "write_file: Unable to open file %s\n", filename);
		return -1;
	}

	bytes = fwrite(data, 1, size, file);
	fclose(file);

	if (bytes != size) {
		logger(LL_ERROR, "Unable to write entire file: %s: %d of %d\n", filename, (int)bytes, (int)size);
		return -1;
	}

	return size;
}

int read_file(const char* filename, void** data, size_t* size) {
	size_t bytes = 0;
	size_t length = 0;
	FILE* file = NULL;
	char* buffer = NULL;
	struct stat fst;

	logger(LL_DEBUG, "Reading data from %s\n", filename);

	*size = 0;
	*data = NULL;

	file = fopen(filename, "rb");
	if (file == NULL) {
		logger(LL_ERROR, "read_file: cannot open %s: %s\n", filename, strerror(errno));
		return -1;
	}

	if (fstat(fileno(file), &fst) < 0) {
		logger(LL_ERROR, "read_file: fstat: %s\n", strerror(errno));
		return -1;
	}
	length = fst.st_size;

	buffer = (char*) malloc(length);
	if (buffer == NULL) {
		logger(LL_ERROR, "Out of memory\n");
		fclose(file);
		return -1;
	}
	bytes = fread(buffer, 1, length, file);
	fclose(file);

	if (bytes != length) {
		logger(LL_ERROR, "Unable to read entire file\n");
		free(buffer);
		return -1;
	}

	*size = length;
	*data = buffer;
	return 0;
}

int process_text_lines(const char* text, int maxwidth, struct tuple** lines_out, int* maxlen_out)
{
	if (!text) return 0;
	int len = strlen(text);
	int numlines = 0;
	int maxlen = 0;
	int linestart = 0;
	int linelen = 0;
	int lastspace = 0;
	int maxlines = 8;
	int count = 0;
	struct tuple* lines = (struct tuple*)malloc(sizeof(struct tuple) * maxlines);
	int i = 0;
	while (i <= len) {
		int split_line = 0;
		if ((text[i] & 0xE0) == 0xC0) i += 1;
		else if ((text[i] & 0xF0) == 0xE0) i += 2;
		else if ((text[i] & 0xF8) == 0xF0) i += 3;
		if (i > len) i = len;
		linelen = i - linestart;
		if (text[i] == '\0') {
			split_line = 1;
		}
		if (linelen > maxwidth) {
			if (lastspace > linestart+maxwidth/2+6) {
				count -= i-lastspace;
				i = lastspace;
				linelen = i - linestart;
				split_line = 1;
			} else {
				split_line = 1;
			}
		}
		if ((linelen > 0 && split_line) || text[i] == '\n') {
			split_line = 0;
			if (numlines == maxlines) {
				maxlines += 8;
				struct tuple* newlines = (struct tuple*)realloc(lines, sizeof(struct tuple) * maxlines);
				if (!newlines) {
					printf("FATAL: Out of memory\n");
					return -1;
				}
				lines = newlines;
			}
			lines[numlines].idx = linestart;
			lines[numlines].len = linelen;
			lines[numlines].plen = count;
			if (count > maxlen) maxlen = count;
			numlines++;
			linestart = i+1;
			count = 0;
		}
		else if (text[i] == ' ') {
			lastspace = i;
			count++;
		} else {
			count++;
		}
		i++;
	}
	*lines_out = lines;
	*maxlen_out = maxlen;
	return numlines;
}

void set_banner_funcs(void (*showfunc)(const char*), void (*hidefunc)(void))
{
	banner_func = showfunc;
	banner_hide_func = hidefunc;
}

void show_banner(const char* text)
{
	if (banner_func) {
		banner_func(text);
	} else {
		int i;
		int maxlen = 0;
		struct tuple* lines = NULL;
		int numlines = process_text_lines(text, 74, &lines, &maxlen);
		printf("%.*s\n", maxlen + 4, STARS);
		for (i = 0; i < numlines; i++) {
			printf("* %.*s%.*s *\n", lines[i].len, text + lines[i].idx, maxlen-lines[i].plen, SPACES);
		}
		printf("%.*s\n", maxlen + 4, STARS);
		free(lines);
	}
}

void hide_banner()
{
	if (banner_hide_func) {
		banner_hide_func();
	}
}

static int (*prompt_func)(const char* title, const char* text) = NULL;

void set_prompt_func(int (*func)(const char* title, const char* text))
{
	prompt_func = func;
}

int prompt_user(const char* title, const char* text)
{
	if (!text) return -1;
	if (prompt_func) {
		return prompt_func(title, text);
	}
	int i;
	int result = 0;
	int maxlen = 0;
	struct tuple* lines = NULL;
	int numlines = process_text_lines(text, 74, &lines, &maxlen);
	int outerlen = maxlen+4;
	int titlelen = (title) ? strlen(title) : 0;
	if (titlelen > 0) {
		int lefttitlelen = (titlelen+4)/2;
		int leftpounds = outerlen/2 - lefttitlelen;
		int rightpounds = outerlen-(titlelen+4) - leftpounds;
		printf("%.*s[ %.*s ]%.*s\n", leftpounds, POUNDS, titlelen, title, rightpounds, POUNDS);
	} else {
		printf("%.*s\n", outerlen, POUNDS);
	}
	for (i = 0; i < numlines; i++) {
		printf("%c %.*s%.*s %c\n", *POUNDS, lines[i].len, text + lines[i].idx, maxlen-lines[i].plen, SPACES, *POUNDS);
	}
	free(lines);
	const char* yesmsg = "Type YES and press ENTER to continue, or hit CTRL+C to cancel.";
	int ylen = strlen(yesmsg);
	printf("%c %.*s%.*s %c\n", *POUNDS, ylen, yesmsg, maxlen-ylen, SPACES, *POUNDS);
	printf("%.*s\n", outerlen, POUNDS);

	char input[64];
	while (1) {
		printf("> ");
		fflush(stdout);
		fflush(stdin);
		input[0] = '\0';
		get_user_input(input, 63, 0);
		if (global_quit_flag) {
			result = -1;
			break;
		}
		if (*input != '\0' && !strcmp(input, "YES")) {
			result = 1;
			break;
		} else {
			printf("Invalid input. Please type YES or hit CTRL+C to abort.\n");
			continue;
		}
	}
	return result;
}

static void (*update_progress_func)(struct progress_info_entry** list, int count) = NULL;
static double progress_granularity = 0.001;

void set_update_progress_func(void (*func)(struct progress_info_entry** list, int count))
{
	update_progress_func = func;
}

void set_progress_granularity(double granularity)
{
	progress_granularity = granularity;
}

mutex_t prog_mutex;
struct collection progress_info;
thread_once_t progress_info_once = THREAD_ONCE_INIT;
static void _init_progress_info(void)
{
	mutex_init(&prog_mutex);
	collection_init(&progress_info);
}

uint32_t progress_get_next_tag(void)
{
	mutex_lock(&prog_mutex);
	uint32_t newtag = ++progress_unique_tag;
	mutex_unlock(&prog_mutex);
	return newtag;
}

void progress_reset_tag(void)
{
	progress_unique_tag = 1;
}

void register_progress(uint32_t tag, const char* label)
{
	thread_once(&progress_info_once, _init_progress_info);
	if (!label) {
		return;
	}
	mutex_lock(&prog_mutex);
	struct progress_info_entry* found = NULL;
	FOREACH(struct progress_info_entry* e, &progress_info) {
		if (e->tag == tag) {
			found = e;
			break;
		}
	} ENDFOREACH
	if (found) {
		if (strcmp(found->label, label) != 0) {
			free(found->label);
			found->label = strdup(label);
			if (update_progress_func) {
				update_progress_func((struct progress_info_entry**)(&progress_info)->list, progress_info.capacity);
			} else {
				print_progress_bar(found->label, found->progress);
			}
		}
		mutex_unlock(&prog_mutex);
		return;
	}
	struct progress_info_entry* newinfo = (struct progress_info_entry*)calloc(1, sizeof(struct progress_info_entry));
	if (!newinfo) {
		logger(LL_ERROR, "Out of memory?!\n");
		exit(1);
	}
	newinfo->tag = tag;
	newinfo->label = strdup(label);
	newinfo->progress = 0;
	collection_add(&progress_info, newinfo);
	if (update_progress_func) {
		update_progress_func((struct progress_info_entry**)(&progress_info)->list, progress_info.capacity);
	} else {
		print_progress_bar(newinfo->label, newinfo->progress);
	}
	mutex_unlock(&prog_mutex);
}

void finalize_progress(uint32_t tag)
{
	mutex_lock(&prog_mutex);
	struct progress_info_entry* found = NULL;
	FOREACH(struct progress_info_entry* e, &progress_info) {
		if (e->tag == tag) {
			found = e;
			break;
		}
	} ENDFOREACH
	if (!found) {
		mutex_unlock(&prog_mutex);
		return;
	}
	collection_remove(&progress_info, found);
	free(found->label);
	free(found);
	if (update_progress_func) {
		update_progress_func((struct progress_info_entry**)(&progress_info)->list, progress_info.capacity);
	}
	mutex_unlock(&prog_mutex);
}

void print_progress_bar(const char* prefix, double progress)
{
	int i = 0;
	if (progress < 0) return;
	if (progress > 1) progress = 1;
	if (prefix) {
		printf("\r%s [", prefix);
	} else {
		printf("\r[");
	}
	for (i = 0; i < 50; i++) {
		if (i < (int)(progress*50.0)) printf("=");
		else printf(" ");
	}
	printf("] %5.1f%% ", progress*100.0);
	if (progress >= 1) printf("\n");
	fflush(stdout);
}

void set_progress(uint32_t tag, double progress)
{
	mutex_lock(&prog_mutex);
	struct progress_info_entry* found = NULL;
	FOREACH(struct progress_info_entry* e, &progress_info) {
		if (e->tag == tag) {
			found = e;
			break;
		}
	} ENDFOREACH
	if (!found) {
		mutex_unlock(&prog_mutex);
		return;
	}
	if (progress < 0) progress = 0;
	if (progress > 1.0) progress = 1.0;
	found->progress = progress;
	if ((progress == 0) || (found->progress - found->lastprog >= progress_granularity)) {
		if (update_progress_func) {
			update_progress_func((struct progress_info_entry**)(&progress_info)->list, progress_info.capacity);
		} else {
			print_progress_bar(found->label, found->progress);
		}
		found->lastprog = found->progress;
	}
	mutex_unlock(&prog_mutex);
}

#define GET_RAND(min, max) ((rand() % (max - min)) + min)

char *generate_guid(void)
{
	char *guid = (char *) malloc(sizeof(char) * 37);
	const char *chars = "ABCDEF0123456789";
	srand(time(NULL));
	int i = 0;

	for (i = 0; i < 36; i++) {
		if (i == 8 || i == 13 || i == 18 || i == 23) {
			guid[i] = '-';
			continue;
		} else {
			guid[i] = chars[GET_RAND(0, 16)];
		}
	}
	guid[36] = '\0';
	return guid;
}

int mkdir_with_parents(const char *dir, int mode)
{
	if (!dir) return -1;
	if (__mkdir(dir, mode) == 0) {
		return 0;
	} else {
		if (errno == EEXIST) {
			return 0;
		} else if (errno == ENOENT) {
			// ignore
		} else {
			return -1;
		}
	}
	int res;
	char *parent = strdup(dir);
	char *parentdir = dirname(parent);
	if (parentdir && (strcmp(parentdir, ".") != 0) && (strcmp(parentdir, dir) != 0)) {
		res = mkdir_with_parents(parentdir, mode);
	} else {
		res = -1;
	}
	free(parent);
	if (res == 0) {
		mkdir_with_parents(dir, mode);
	}
	return res;
}

#ifndef HAVE_MKSTEMP
/* Based on libc's __gen_tempname() from sysdeps/posix/tempname.c
   Copyright (C) 1991-2018 Free Software Foundation, Inc.
   With changes from https://stackoverflow.com/a/6036308 and some
   additional changes. */
int mkstemp(char *tmpl)
{
	static const char letters[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
	int len;
	char *XXXXXX;
	static unsigned long long value;
	unsigned long long random_time_bits;
	unsigned int count;
	int fd = -1;
	int save_errno = errno;

	/* A lower bound on the number of temporary files to attempt to
	   generate.  The maximum total number of temporary file names that
	   can exist for a given template is 62**6.  It should never be
	   necessary to try all these combinations.  Instead if a reasonable
	   number of names is tried (we define reasonable as 62**3) fail to
	   give the system administrator the chance to remove the problems.  */
#define ATTEMPTS_MIN (62 * 62 * 62)

	/* The number of times to attempt to generate a temporary file.  To
	   conform to POSIX, this must be no smaller than TMP_MAX.  */
#if ATTEMPTS_MIN < TMP_MAX
	unsigned int attempts = TMP_MAX;
#else
	unsigned int attempts = ATTEMPTS_MIN;
#endif

	len = strlen (tmpl);
	if (len < 6 || strcmp (&tmpl[len - 6], "XXXXXX"))
	{
		errno = EINVAL;
		return -1;
	}

	/* This is where the Xs start.  */
	XXXXXX = &tmpl[len - 6];

	/* Get some more or less random data.  */
#ifdef WIN32
	{
		SYSTEMTIME stNow;
		FILETIME ftNow;

		// get system time
		GetSystemTime(&stNow);
		if (!SystemTimeToFileTime(&stNow, &ftNow))
		{
			errno = -1;
			return -1;
		}

		random_time_bits = (((unsigned long long)ftNow.dwHighDateTime << 32)
		                    | (unsigned long long)ftNow.dwLowDateTime);
	}
	value += random_time_bits ^ ((unsigned long long)GetCurrentProcessId() << 32 | (unsigned long long)GetCurrentThreadId());
#else
	{
		struct timeval tvNow = {0, 0};
		gettimeofday(&tvNow, NULL);
		random_time_bits = (((unsigned long long)tvNow.tv_sec << 32)
		                    | (unsigned long long)tvNow.tv_usec);
	}
	value += random_time_bits ^ ((unsigned long long)getpid() << 32 | (unsigned long long)(uintptr_t)pthread_self());
#endif

	for (count = 0; count < attempts; value += 7777, ++count)
	{
		unsigned long long v = value;

		/* Fill in the random bits.  */
		XXXXXX[0] = letters[v % 62];
		v /= 62;
		XXXXXX[1] = letters[v % 62];
		v /= 62;
		XXXXXX[2] = letters[v % 62];
		v /= 62;
		XXXXXX[3] = letters[v % 62];
		v /= 62;
		XXXXXX[4] = letters[v % 62];
		v /= 62;
		XXXXXX[5] = letters[v % 62];

#ifdef WIN32
		fd = open (tmpl, O_RDWR | O_CREAT | O_EXCL, _S_IREAD | _S_IWRITE);
#else
		fd = open (tmpl, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
#endif
		if (fd >= 0)
		{
			errno = save_errno;
			return fd;
		}
		else if (errno != EEXIST)
			return -1;
	}

	/* We got out of the loop because we ran out of combinations to try.  */
	errno = EEXIST;
	return -1;
}
#endif

char *get_temp_filename(const char *prefix)
{
	char *result = NULL;
	char *tmpdir;
	size_t lt;
	size_t lp;
	const char *TMPVARS[] = { "TMPDIR", "TMP", "TEMP", "TEMPDIR", NULL };
	int i = 0;
	int fd;

	/* check the prefix parameter */
	if (!prefix) {
		prefix = "tmp_";
	}
#ifdef WIN32
	if (strchr(prefix, '/') || strchr(prefix, '\\')) return NULL;
#else
	if (strchr(prefix, '/')) return NULL;
#endif

	while (TMPVARS[i] && ((tmpdir = getenv(TMPVARS[i])) == NULL)) i++;
	if (!tmpdir || access(tmpdir, W_OK|X_OK) != 0) {
#ifdef WIN32
		tmpdir = "C:\\WINDOWS\\TEMP";
#else
		tmpdir = P_tmpdir;
#endif
	}
	if (!tmpdir || access(tmpdir, W_OK|X_OK) != 0) {
		return NULL;
	}

	lt = strlen(tmpdir);
	if (lt < 1) {
		return NULL;
	}
	lp = strlen(prefix);
	result = malloc(lt + lp + 8);
	memcpy(result, tmpdir, lt);
#ifdef WIN32
	if (tmpdir[lt-1] != '/' && tmpdir[lt-1] != '\\') result[lt++] = '\\';
#else
	if (tmpdir[lt-1] != '/') result[lt++] = '/';
#endif
	strncpy(result + lt, prefix, lp);
	strcpy(result + lt + lp, "XXXXXX");
	fd = mkstemp(result);
	if (fd < 0) {
		free(result);
		result = NULL;
	}
	close(fd);
	return result;
}

void idevicerestore_progress(struct idevicerestore_client_t* client, int step, double progress)
{
	if(client && client->progress_cb) {
		client->progress_cb(step, progress, client->progress_cb_data);
	} else {
		// we don't want to be too verbose in regular idevicerestore.
		if ((step == RESTORE_STEP_UPLOAD_FS) || (step == RESTORE_STEP_VERIFY_FS) || (step == RESTORE_STEP_FLASH_FW) || (step == RESTORE_STEP_UPLOAD_IMG)) {
			print_progress_bar(NULL, progress);
		}
	}
}

#ifndef HAVE_STRSEP
char* strsep(char** strp, const char* delim)
{
        char *p, *s;
        if (strp == NULL || *strp == NULL || **strp == '\0') return NULL;
        s = *strp;
        p = s + strcspn(s, delim);
        if (*p != '\0') *p++ = '\0';
        *strp = p;
        return s;
}
#endif

#ifndef HAVE_REALPATH
char* realpath(const char *filename, char *resolved_name)
{
#ifdef WIN32
	if (access(filename, F_OK) != 0) {
		return NULL;
	}
	if (GetFullPathName(filename, MAX_PATH, resolved_name, NULL) == 0) {
		return NULL;
	}
	return resolved_name;
#else
#error please provide a realpath implementation for this platform
	return NULL;
#endif
}
#endif

#ifdef WIN32
#define BS_CC '\b'
#define CTRL_C_CC 0x03
#define ESC_CC 0x1B
#define my_getch _getch
#else
#define BS_CC 0x7f
static int my_getch(void)
{
	struct termios oldt, newt;
	int ch;
	tcgetattr(STDIN_FILENO, &oldt);
	newt = oldt;
	newt.c_lflag &= ~(ICANON | ECHO);
	tcsetattr(STDIN_FILENO, TCSANOW, &newt);
	ch = getchar();
	tcsetattr(STDIN_FILENO, TCSANOW, &oldt);
	return ch;
}
#endif

void get_user_input(char *buf, int maxlen, int secure)
{
	int len = 0;
	int c;

	while ((c = my_getch()) > 0) {
		if ((c == '\r') || (c == '\n')) {
			break;
		} else if (isprint(c)) {
			if (len < maxlen-1)
				buf[len++] = c;
			fputc((secure) ? '*' : c, stdout);
		} else if (c == BS_CC) {
			if (len > 0) {
				fputs("\b \b", stdout);
				len--;
			}
		}
#ifdef WIN32
		else if (c == CTRL_C_CC || c == ESC_CC) {
			c = -1;
			break;
		}
#endif
	}
	if (c < 0) {
		len = 0;
	}
	fputs("\n", stdout);
	buf[len] = 0;
}

const char* path_get_basename(const char* path)
{
#ifdef WIN32
	const char *p = path + strlen(path);
	while (p > path) {
		if ((*p == '/') || (*p == '\\')) {
			return p+1;
		}
		p--;
	}
	return p;
#else
	const char *p = strrchr(path, '/');
	return p ? p + 1 : path;
#endif
}
