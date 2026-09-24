/*
 * download.c
 * file download helper functions
 *
 * Copyright (c) 2012-2019 Nikias Bassen. All Rights Reserved.
 * Copyright (c) 2012-2013 Martin Szulecki. All Rights Reserved.
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
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <curl/curl.h>

#include "download.h"
#include "common.h"

typedef struct {
	int length;
	char* content;
} curl_response;

static size_t download_write_buffer_callback(char* data, size_t size, size_t nmemb, curl_response* response) {
	size_t total = size * nmemb;
	if (total != 0) {
		response->content = realloc(response->content, response->length + total + 1);
		memcpy(response->content + response->length, data, total);
		response->content[response->length + total] = '\0';
		response->length += total;
	}
	return total;
}

int download_to_buffer(const char* url, void** buf, size_t* length)
{
	int res = 0;
	CURL* handle = curl_easy_init();
	if (handle == NULL) {
		logger(LL_ERROR, "could not initialize CURL\n");
		return -1;
	}

	curl_response response;
	response.length = 0;
	response.content = malloc(1);
	response.content[0] = '\0';

	if (log_level >= LL_DEBUG)
		curl_easy_setopt(handle, CURLOPT_VERBOSE, 1);

	/* disable SSL verification to allow download from untrusted https locations */
	curl_easy_setopt(handle, CURLOPT_SSL_VERIFYPEER, 0);

	curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, (curl_write_callback)&download_write_buffer_callback);
	curl_easy_setopt(handle, CURLOPT_WRITEDATA, &response);
	if (strncmp(url, "https://api.ipsw.me/", 20) == 0) {
		curl_easy_setopt(handle, CURLOPT_USERAGENT, USER_AGENT_STRING " idevicerestore/" PACKAGE_VERSION);
	} else {
		curl_easy_setopt(handle, CURLOPT_USERAGENT, USER_AGENT_STRING);
	}
	curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 1);
	curl_easy_setopt(handle, CURLOPT_URL, url);

	curl_easy_perform(handle);
	curl_easy_cleanup(handle);

	if (response.length > 0) {
		*length = response.length;
		*buf = response.content;
	} else {
		res = -1;
	}

	return res;
}

#if LIBCURL_VERSION_NUM >= 0x072000
static int download_progress(void *clientp, curl_off_t dltotal, curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow)
#else
static int download_progress(void *clientp, double dltotal, double dlnow, double ultotal, double ulnow)
#endif
{
	double p = ((double)dlnow / (double)dltotal);

	set_progress('DNLD', p);

	if (global_quit_flag > 0) {
		return 1;
	}

	return 0;
}

int download_to_file(const char* url, const char* filename, int enable_progress)
{
	int res = 0;
	CURL* handle = curl_easy_init();
	if (handle == NULL) {
		logger(LL_ERROR, "Could not initialize CURL\n");
		return -1;
	}

	FILE* f = fopen(filename, "wb");
	if (!f) {
		logger(LL_ERROR, "Cannot open '%s' for writing\n", filename);
		return -1;
	}

	if (log_level >= LL_DEBUG)
		curl_easy_setopt(handle, CURLOPT_VERBOSE, 1);

	/* disable SSL verification to allow download from untrusted https locations */
	curl_easy_setopt(handle, CURLOPT_SSL_VERIFYPEER, 0);

	curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, NULL);
	curl_easy_setopt(handle, CURLOPT_WRITEDATA, f);

	if (enable_progress > 0) {
		register_progress('DNLD', "Downloading");
#if LIBCURL_VERSION_NUM >= 0x072000
		curl_easy_setopt(handle, CURLOPT_XFERINFOFUNCTION, (curl_progress_callback)&download_progress);
#else
		curl_easy_setopt(handle, CURLOPT_PROGRESSFUNCTION, (curl_progress_callback)&download_progress);
#endif
	}

	curl_easy_setopt(handle, CURLOPT_NOPROGRESS, enable_progress > 0 ? 0: 1);
	curl_easy_setopt(handle, CURLOPT_USERAGENT, USER_AGENT_STRING);
	curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 1);
	curl_easy_setopt(handle, CURLOPT_URL, url);

	curl_easy_perform(handle);

	if (enable_progress) {
		finalize_progress('DNLD');
	}

	curl_easy_cleanup(handle);

#ifdef WIN32
	fflush(f);
	uint64_t sz = _lseeki64(fileno(f), 0, SEEK_CUR);
#else
	off_t sz = ftello(f);
#endif
	fclose(f);

	if ((sz == 0) || ((int64_t)sz == (int64_t)-1)) {
		res = -1;
		remove(filename);
	}
	if (global_quit_flag > 0) {
		res = -2;
	}

	return res;
}
