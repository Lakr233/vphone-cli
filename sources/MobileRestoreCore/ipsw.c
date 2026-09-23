/*
 * ipsw.c
 * Utilities for extracting and manipulating IPSWs
 *
 * Copyright (c) 2012-2019 Nikias Bassen. All Rights Reserved.
 * Copyright (c) 2010-2012 Martin Szulecki. All Rights Reserved.
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
#include <limits.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <zip.h>

#include <libimobiledevice-glue/sha.h>
#include <libimobiledevice-glue/termcolors.h>
#include <plist/plist.h>

#include "ipsw.h"
#include "locking.h"
#include "download.h"
#include "common.h"
#include "idevicerestore.h"

#define BUFSIZE 0x100000

static int cancel_flag = 0;

static char* build_path(const char* path, const char* file)
{
	size_t plen = strlen(path);
	size_t flen = strlen(file);
	char *fullpath = malloc(plen + flen + 2);
	if (!fullpath) {
		return NULL;
	}
	memcpy(fullpath, path, plen);
	fullpath[plen] = '/';
	memcpy(fullpath+plen+1, file, flen);
	fullpath[plen+1+flen] = '\0';
	return fullpath;
}

int ipsw_print_info(const char* path)
{
	struct stat fst;

	if (stat(path, &fst) != 0) {
		logger(LL_ERROR, "'%s': %s\n", path, strerror(errno));
		return -1;
	}

	char thepath[PATH_MAX];

	if (S_ISDIR(fst.st_mode)) {
		snprintf(thepath, sizeof(thepath), "%s/BuildManifest.plist", path);
		if (stat(thepath, &fst) != 0) {
			logger(LL_ERROR, "'%s': %s\n", thepath, strerror(errno));
			return -1;
		}
	} else {
		snprintf(thepath, sizeof(thepath), "%s", path);
	}

	FILE* f = fopen(thepath, "r");
	if (!f) {
		logger(LL_ERROR, "Can't open '%s': %s\n", thepath, strerror(errno));
		return -1;
	}
	uint32_t magic;
	if (fread(&magic, 1, 4, f) != 4) {
		fclose(f);
		logger(LL_ERROR, "Failed to read from '%s'\n", path);
		return -1;
	}
	fclose(f);

	void* plist_buf = NULL;
	uint32_t plist_len = 0;

	if (memcmp(&magic, "PK\x03\x04", 4) == 0) {
		ipsw_archive_t ipsw = ipsw_open(thepath);
		size_t rlen = 0;
		if (ipsw_extract_to_memory(ipsw, "BuildManifest.plist", &plist_buf, &rlen) < 0) {
			ipsw_close(ipsw);
			logger(LL_ERROR, "Failed to extract BuildManifest.plist from IPSW!\n");
			return -1;
		}
		ipsw_close(ipsw);
		plist_len = (uint32_t)rlen;
	} else {
		size_t rlen = 0;
		if (read_file(thepath, &plist_buf, &rlen) < 0) {
			logger(LL_ERROR, "Failed to read BuildManifest.plist!\n");
			return -1;
		}
		plist_len = (uint32_t)rlen;
	}

	plist_t manifest = NULL;
	plist_from_memory(plist_buf, plist_len, &manifest, NULL);
	free(plist_buf);

	plist_t val;

	char* prod_ver = NULL;
	char* build_ver = NULL;

	val = plist_dict_get_item(manifest, "ProductVersion");
	if (val) {
		plist_get_string_val(val, &prod_ver);
	}

	val = plist_dict_get_item(manifest, "ProductBuildVersion");
	if (val) {
		plist_get_string_val(val, &build_ver);
	}

	cprintf(FG_WHITE "Product Version: " FG_BRIGHT_YELLOW "%s" COLOR_RESET FG_WHITE "   Build: " FG_BRIGHT_YELLOW "%s" COLOR_RESET "\n", prod_ver, build_ver);
	free(prod_ver);
	free(build_ver);
	cprintf(FG_WHITE "Supported Product Types:" COLOR_RESET);
	val = plist_dict_get_item(manifest, "SupportedProductTypes");
	if (val) {
		plist_array_iter iter = NULL;
		plist_array_new_iter(val, &iter);
		if (iter) {
			plist_t item = NULL;
			do {
				plist_array_next_item(val, iter, &item);
				if (item) {
					char* item_str = NULL;
					plist_get_string_val(item, &item_str);
					cprintf(" " FG_BRIGHT_CYAN "%s" COLOR_RESET, item_str);
					free(item_str);
				}
			} while (item);
			free(iter);
		}
	}
	cprintf("\n");

	cprintf(FG_WHITE "Build Identities:" COLOR_RESET "\n");

	plist_t build_ids_grouped = plist_new_dict();

	plist_t build_ids = plist_dict_get_item(manifest, "BuildIdentities");
	plist_array_iter build_id_iter = NULL;
	plist_array_new_iter(build_ids, &build_id_iter);
	if (build_id_iter) {
		plist_t build_identity = NULL;
		do {
			plist_array_next_item(build_ids, build_id_iter, &build_identity);
			if (!build_identity) {
				break;
			}
			plist_t node;
			char* variant_str = NULL;

			node = plist_access_path(build_identity, 2, "Info", "Variant");
			plist_get_string_val(node, &variant_str);

			plist_t entries = NULL;
			plist_t group = plist_dict_get_item(build_ids_grouped, variant_str);
			if (!group) {
				group = plist_new_dict();
				node = plist_access_path(build_identity, 2, "Info", "RestoreBehavior");
				if (node) {
					plist_dict_set_item(group, "RestoreBehavior", plist_copy(node));
				} else {
					if (strstr(variant_str, "Upgrade")) {
						plist_dict_set_item(group, "RestoreBehavior", plist_new_string("Update"));
					} else if (strstr(variant_str, "Erase")) {
						plist_dict_set_item(group, "RestoreBehavior", plist_new_string("Erase"));
					}
				}
				entries = plist_new_array();
				plist_dict_set_item(group, "Entries", entries);
				plist_dict_set_item(build_ids_grouped, variant_str, group);
			} else {
				entries = plist_dict_get_item(group, "Entries");
			}
			free(variant_str);
			plist_array_append_item(entries, plist_copy(build_identity));
		} while (build_identity);
		free(build_id_iter);
	}

	plist_dict_iter build_ids_group_iter = NULL;
	plist_dict_new_iter(build_ids_grouped, &build_ids_group_iter);
	if (build_ids_group_iter) {
		plist_t group = NULL;
		int group_no = 0;
		do {
			group = NULL;
			char* key = NULL;
			plist_dict_next_item(build_ids_grouped, build_ids_group_iter, &key, &group);
			if (!key) {
				break;
			}
			plist_t node;
			char* rbehavior = NULL;

			group_no++;
			node = plist_dict_get_item(group, "RestoreBehavior");
			plist_get_string_val(node, &rbehavior);
			cprintf("  " FG_WHITE "[%d] Variant: " FG_BRIGHT_CYAN "%s" FG_WHITE "   Behavior: " FG_BRIGHT_CYAN "%s" COLOR_RESET "\n", group_no, key, rbehavior);
			free(key);
			free(rbehavior);

			build_ids = plist_dict_get_item(group, "Entries");
			if (!build_ids) {
				continue;
			}
			build_id_iter = NULL;
			plist_array_new_iter(build_ids, &build_id_iter);
			if (!build_id_iter) {
				continue;
			}
			plist_t build_id;
			do {
				build_id = NULL;
				plist_array_next_item(build_ids, build_id_iter, &build_id);
				if (!build_id) {
					break;
				}
				uint64_t chip_id = 0;
				uint64_t board_id = 0;
				char* hwmodel = NULL;

				node = plist_dict_get_item(build_id, "ApChipID");
				if (PLIST_IS_STRING(node)) {
					char* strval = NULL;
					plist_get_string_val(node, &strval);
					if (strval) {
						chip_id = strtoull(strval, NULL, 0);
						free(strval);
					}
				} else {
					plist_get_uint_val(node, &chip_id);
				}

				node = plist_dict_get_item(build_id, "ApBoardID");
				if (PLIST_IS_STRING(node)) {
					char* strval = NULL;
					plist_get_string_val(node, &strval);
					if (strval) {
						board_id = strtoull(strval, NULL, 0);
						free(strval);
					}
				} else {
					plist_get_uint_val(node, &board_id);
				}

				node = plist_access_path(build_id, 2, "Info", "DeviceClass");
				plist_get_string_val(node, &hwmodel);

				irecv_device_t irecvdev = NULL;
				if (irecv_devices_get_device_by_hardware_model(hwmodel, &irecvdev) == 0) {
					cprintf("    ChipID: " FG_GREEN "%04x" COLOR_RESET "   BoardID: " FG_GREEN "%02x" COLOR_RESET "   Model: " FG_YELLOW "%-8s" COLOR_RESET "  " FG_MAGENTA "%s" COLOR_RESET "\n", (int)chip_id, (int)board_id, hwmodel, irecvdev->display_name);
				} else {
					cprintf("    ChipID: " FG_GREEN "%04x" COLOR_RESET "   BoardID: " FG_GREEN "%02x" COLOR_RESET "   Model: " FG_YELLOW "%s" COLOR_RESET "\n", (int)chip_id, (int)board_id, hwmodel);
				}
				free(hwmodel);
			} while (build_id);
			free(build_id_iter);
		} while (group);
		free(build_ids_group_iter);
	}
	plist_free(build_ids_grouped);

	plist_free(manifest);

	return 0;
}

ipsw_archive_t ipsw_open(const char* ipsw)
{
	int err = 0;
	ipsw_archive_t archive = (ipsw_archive_t)calloc(1, sizeof(struct ipsw_archive));
	if (archive == NULL) {
		logger(LL_ERROR, "Out of memory\n");
		return NULL;
	}

	struct stat fst;
	if (stat(ipsw, &fst) != 0) {
		logger(LL_ERROR, "ipsw_open %s: %s\n", ipsw, strerror(errno));
		return NULL;
	}
	if (S_ISDIR(fst.st_mode)) {
		archive->zip = 0;
	} else {
		struct zip *zip = zip_open(ipsw, 0, &err);
		if (zip == NULL) {
			logger(LL_ERROR, "zip_open: %s: %d\n", ipsw, err);
			free(archive);
			return NULL;
		}
		archive->zip = 1;
	}
	archive->path = strdup(ipsw);
	return (ipsw_archive_t)archive;
}

void ipsw_close(ipsw_archive_t ipsw)
{
	if (ipsw != NULL) {
		free(ipsw->path);
		free(ipsw);
	}
}

int ipsw_is_directory(const char* ipsw)
{
	struct stat fst;
	memset(&fst, '\0', sizeof(fst));
	if (stat(ipsw, &fst) != 0) {
		return 0;
	}
	return S_ISDIR(fst.st_mode);
}

int ipsw_get_file_size(ipsw_archive_t ipsw, const char* infile, uint64_t* size)
{
	if (ipsw == NULL) {
		logger(LL_ERROR, "Invalid archive\n");
		return -1;
	}

	if (ipsw->zip) {
		int err = 0;
		struct zip *zip = zip_open(ipsw->path, 0, &err);
		if (zip == NULL) {
			logger(LL_ERROR, "zip_open: %s: %d\n", ipsw->path, err);
			return -1;
		}
		int zindex = zip_name_locate(zip, infile, 0);
		if (zindex < 0) {
			logger(LL_ERROR, "zip_name_locate: %s\n", infile);
			zip_unchange_all(zip);
			zip_close(zip);
			return -1;
		}

		struct zip_stat zstat;
		zip_stat_init(&zstat);
		if (zip_stat_index(zip, zindex, 0, &zstat) != 0) {
			logger(LL_ERROR, "zip_stat_index: %s\n", infile);
			zip_unchange_all(zip);
			zip_close(zip);
			return -1;
		}
		zip_unchange_all(zip);
		zip_close(zip);

		*size = zstat.size;
	} else {
		char *filepath = build_path(ipsw->path, infile);
		struct stat fst;
		if (stat(filepath, &fst) != 0) {
			free(filepath);
			return -1;
		}
		free(filepath);

		*size = fst.st_size;
	}

	return 0;
}

int ipsw_extract_to_file_with_progress(ipsw_archive_t ipsw, const char* infile, const char* outfile, int print_progress)
{
	int ret = 0;

	if (!ipsw || !infile || !outfile) {
		logger(LL_ERROR, "Invalid argument\n");
		return -1;
	}

	cancel_flag = 0;

	if (ipsw->zip) {
		int err = 0;
		struct zip *zip = zip_open(ipsw->path, 0, &err);
		if (zip == NULL) {
			logger(LL_ERROR, "zip_open: %s: %d\n", ipsw->path, err);
			return -1;
		}

		int zindex = zip_name_locate(zip, infile, 0);
		if (zindex < 0) {
			zip_unchange_all(zip);
			zip_close(zip);
			logger(LL_ERROR, "zip_name_locate: %s\n", infile);
			return -1;
		}

		struct zip_stat zstat;
		zip_stat_init(&zstat);
		if (zip_stat_index(zip, zindex, 0, &zstat) != 0) {
			zip_unchange_all(zip);
			zip_close(zip);
			logger(LL_ERROR, "zip_stat_index: %s\n", infile);
			return -1;
		}

		char* buffer = (char*) malloc(BUFSIZE);
		if (buffer == NULL) {
			zip_unchange_all(zip);
			zip_close(zip);
			logger(LL_ERROR, "Unable to allocate memory\n");
			return -1;
		}

		struct zip_file* zfile = zip_fopen_index(zip, zindex, 0);
		if (zfile == NULL) {
			zip_unchange_all(zip);
			zip_close(zip);
			logger(LL_ERROR, "zip_fopen_index: %s\n", infile);
			return -1;
		}

		FILE* fd = fopen(outfile, "wb");
		if (fd == NULL) {
			zip_fclose(zfile);
			zip_unchange_all(zip);
			zip_close(zip);
			logger(LL_ERROR, "Unable to open output file: %s\n", outfile);
			return -1;
		}

		if (print_progress) {
			register_progress('IPSW', "Extracting");
		}
		uint64_t i, bytes = 0;
		int count, size = BUFSIZE;
		for(i = zstat.size; i > 0; i -= count) {
			if (cancel_flag) {
				break;
			}
			if (i < BUFSIZE)
				size = i;
			count = zip_fread(zfile, buffer, size);
			if (count < 0) {
				int zep = 0;
				int sep = 0;
				zip_file_error_get(zfile, &zep, &sep);
				logger(LL_ERROR, "zip_fread: %s %d %d\n", infile, zep, sep);
				ret = -1;
				break;
			}
			if (fwrite(buffer, 1, count, fd) != count) {
				logger(LL_ERROR, "Writing to '%s' failed: %s\n", outfile, strerror(errno));
				ret = -1;
				break;
			}

			bytes += size;
			if (print_progress) {
				double progress = ((double)bytes / (double)zstat.size);
				set_progress('IPSW', progress);
			}
		}
		free(buffer);
		if (print_progress) {
			finalize_progress('IPSW');
		}
		fclose(fd);
		zip_fclose(zfile);
		zip_unchange_all(zip);
		zip_close(zip);
	} else {
		char *filepath = build_path(ipsw->path, infile);
		char actual_filepath[PATH_MAX+1];
		char actual_outfile[PATH_MAX+1];
		if (!filepath) {
			ret = -1;
			goto leave;
		}
		if (!realpath(filepath, actual_filepath)) {
			logger(LL_ERROR, "realpath failed on %s: %s\n", filepath, strerror(errno));
			ret = -1;
			goto leave;
		} else {
			actual_outfile[0] = '\0';
			if (realpath(outfile, actual_outfile) && (strcmp(actual_filepath, actual_outfile) == 0)) {
				/* files are identical */
				ret = 0;
			} else {
				if (actual_outfile[0] == '\0') {
					strcpy(actual_outfile, outfile);
				}
				FILE *fi = fopen(actual_filepath, "rb");
				if (!fi) {
					logger(LL_ERROR, "fopen: %s: %s\n", actual_filepath, strerror(errno));
					ret = -1;
					goto leave;
				}
				struct stat fst;
				if (fstat(fileno(fi), &fst) != 0) {
					fclose(fi);
					logger(LL_ERROR, "fstat: %s: %s\n", actual_filepath, strerror(errno));
					ret = -1;
					goto leave;
				}
				FILE *fo = fopen(actual_outfile, "wb");
				if (!fo) {
					fclose(fi);
					logger(LL_ERROR, "fopen: %s: %s\n", actual_outfile, strerror(errno));
					ret = -1;
					goto leave;
				}
				char* buffer = (char*) malloc(BUFSIZE);
				if (buffer == NULL) {
					fclose(fi);
					fclose(fo);
					logger(LL_ERROR, "Unable to allocate memory\n");
					ret = -1;
					goto leave;;
				}

				if (print_progress) {
					register_progress('IPSW', "Extracting");
				}
				uint64_t bytes = 0;
				while (!feof(fi)) {
					if (cancel_flag) {
						break;
					}
					ssize_t r = fread(buffer, 1, BUFSIZE, fi);
					if (r < 0) {
						logger(LL_ERROR, "fread failed: %s\n", strerror(errno));
						ret = -1;
						break;
					}
					if (fwrite(buffer, 1, r, fo) != r) {
						logger(LL_ERROR, "Writing to '%s' failed: %s\n", actual_outfile, strerror(errno));
						ret = -1;
						break;
					}
					bytes += r;
					if (print_progress) {
						double progress = ((double)bytes / (double)fst.st_size);
						set_progress('IPSW', progress);
					}
				}
				if (print_progress) {
					finalize_progress('IPSW');
				}

				free(buffer);
				fclose(fi);
				fclose(fo);
			}
		}
	leave:
		free(filepath);
	}
	if (cancel_flag) {
		ret = -2;
	}
	return ret;
}

int ipsw_extract_to_file(ipsw_archive_t ipsw, const char* infile, const char* outfile)
{
	return ipsw_extract_to_file_with_progress(ipsw, infile, outfile, 0);
}

int ipsw_file_exists(ipsw_archive_t ipsw, const char* infile)
{
	if (!ipsw) {
		return 0;
	}

	if (ipsw->zip) {
		int err = 0;
		struct zip *zip = zip_open(ipsw->path, 0, &err);
		if (zip == NULL) {
			logger(LL_ERROR, "zip_open: %s: %d\n", ipsw->path, err);
			return 0;
		}
		int zindex = zip_name_locate(zip, infile, 0);
		zip_unchange_all(zip);
		zip_close(zip);
		if (zindex < 0) {
			return 0;
		}
	} else {
		char *filepath = build_path(ipsw->path, infile);
		if (access(filepath, R_OK) != 0) {
			free(filepath);
			return 0;
		}
		free(filepath);
	}

	return 1;
}

int ipsw_extract_to_memory(ipsw_archive_t ipsw, const char* infile, void** pbuffer, size_t* psize)
{
	size_t size = 0;
	unsigned char* buffer = NULL;
	if (ipsw == NULL) {
		logger(LL_ERROR, "Invalid archive\n");
		return -1;
	}

	if (ipsw->zip) {
		int err = 0;
		struct zip *zip = zip_open(ipsw->path, 0, &err);
		if (zip == NULL) {
			logger(LL_ERROR, "zip_open: %s: %d\n", ipsw->path, err);
			return -1;
		}

		int zindex = zip_name_locate(zip, infile, 0);
		if (zindex < 0) {
			zip_unchange_all(zip);
			zip_close(zip);
			logger(LL_DEBUG, "zip_name_locate: '%s' not found in archive.\n", infile);
			return -1;
		}

		struct zip_stat zstat;
		zip_stat_init(&zstat);
		if (zip_stat_index(zip, zindex, 0, &zstat) != 0) {
			zip_unchange_all(zip);
			zip_close(zip);
			logger(LL_ERROR, "zip_stat_index: %s\n", infile);
			return -1;
		}

		struct zip_file* zfile = zip_fopen_index(zip, zindex, 0);
		if (zfile == NULL) {
			zip_unchange_all(zip);
			zip_close(zip);
			logger(LL_ERROR, "zip_fopen_index: %s\n", infile);
			return -1;
		}

		size = zstat.size;
		if ((uint64_t)size != (uint64_t)zstat.size) {
			logger(LL_ERROR, "Not enough memory to allocate a buffer of size %" PRIu64 "\n", (uint64_t)zstat.size);
			zip_fclose(zfile);
			zip_unchange_all(zip);
			zip_close(zip);
			return -1;
		}
		buffer = (unsigned char*) malloc(size+1);
		if (buffer == NULL) {
			logger(LL_ERROR, "Out of memory\n");
			zip_fclose(zfile);
			zip_unchange_all(zip);
			zip_close(zip);
			return -1;
		}

		zip_int64_t zr = zip_fread(zfile, buffer, size);
		zip_fclose(zfile);
		zip_unchange_all(zip);
		zip_close(zip);
		if (zr < 0) {
			int zep = 0;
			int sep = 0;
			zip_file_error_get(zfile, &zep, &sep);
			logger(LL_ERROR, "zip_fread: %s %d %d\n", infile, zep, sep);
			free(buffer);
			return -1;
		} else if (zr != size) {
			logger(LL_ERROR, "zip_fread: %s got only %zu of %zu\n", infile, (size_t)zr, size);
			free(buffer);
			return -1;
		}

		buffer[size] = '\0';
	} else {
		char *filepath = build_path(ipsw->path, infile);
		struct stat fst;
#ifdef WIN32
		if (stat(filepath, &fst) != 0) {
#else
		if (lstat(filepath, &fst) != 0) {
#endif
			logger(LL_ERROR, "%s: stat failed for %s: %s\n", __func__, filepath, strerror(errno));
			free(filepath);
			return -1;
		}
		size = fst.st_size;
		if ((uint64_t)size != (uint64_t)fst.st_size) {
			logger(LL_ERROR, "Not enough memory to allocate a buffer of size %" PRIu64 "\n", (uint64_t)fst.st_size);
			free(filepath);
			return -1;
		}
		buffer = (unsigned char*)malloc(size+1);
		if (buffer == NULL) {
			logger(LL_ERROR, "Out of memory\n");
			free(filepath);
			return -1;
		}

#ifndef WIN32
		if (S_ISLNK(fst.st_mode)) {
			if (readlink(filepath, (char*)buffer, size) < 0) {
				logger(LL_ERROR, "%s: readlink failed for %s: %s\n", __func__, filepath, strerror(errno));
				free(filepath);
				free(buffer);
				return -1;
			}
		} else {
#endif
			FILE *f = fopen(filepath, "rb");
			if (!f) {
				logger(LL_ERROR, "%s: fopen failed for %s: %s\n", __func__, filepath, strerror(errno));
				free(filepath);
				free(buffer);
				return -2;
			}
			if (fread(buffer, 1, size, f) != size) {
				fclose(f);
				logger(LL_ERROR, "%s: fread failed for %s: %s\n", __func__, filepath, strerror(errno));
				free(filepath);
				free(buffer);
				return -1;
			}
			fclose(f);
#ifndef WIN32
		}
#endif
		buffer[size] = '\0';

		free(filepath);
	}

	*pbuffer = buffer;
	*psize = size;
	return 0;
}

int ipsw_extract_send(ipsw_archive_t ipsw, const char* infile, int blocksize, ipsw_send_cb send_callback, void* ctx)
{
	unsigned char* buffer = NULL;
	size_t done = 0;
	size_t total_size = 0;

	if (ipsw == NULL) {
		logger(LL_ERROR, "Invalid archive\n");
		return -1;
	}

	if (ipsw->zip) {
		int err = 0;
		struct zip *zip = zip_open(ipsw->path, 0, &err);
		if (zip == NULL) {
			logger(LL_ERROR, "zip_open: %s: %d\n", ipsw->path, err);
			return -1;
		}

		int zindex = zip_name_locate(zip, infile, 0);
		if (zindex < 0) {
			zip_unchange_all(zip);
			zip_close(zip);
			logger(LL_DEBUG, "zip_name_locate: '%s' not found in archive.\n", infile);
			return -1;
		}

		struct zip_stat zstat;
		zip_stat_init(&zstat);
		if (zip_stat_index(zip, zindex, 0, &zstat) != 0) {
			zip_unchange_all(zip);
			zip_close(zip);
			logger(LL_ERROR, "zip_stat_index: %s\n", infile);
			return -1;
		}

		struct zip_file* zfile = zip_fopen_index(zip, zindex, 0);
		if (zfile == NULL) {
			zip_unchange_all(zip);
			zip_close(zip);
			logger(LL_ERROR, "zip_fopen_index: %s\n", infile);
			return -1;
		}

		total_size = zstat.size;
		buffer = (unsigned char*) malloc(blocksize);
		if (buffer == NULL) {
			zip_fclose(zfile);
			zip_unchange_all(zip);
			zip_close(zip);
			logger(LL_ERROR, "Out of memory\n");
			return -1;
		}

		while (done < total_size) {
			size_t size = total_size-done;
			if (size > blocksize) size = blocksize;
			zip_int64_t zr = zip_fread(zfile, buffer, size);
			if (zr < 0) {
				logger(LL_ERROR, "%s: zip_fread: %s\n", __func__, infile);
				break;
			} else if (zr == 0) {
				// EOF
				break;
			}
			if (send_callback(ctx, buffer, zr, done, total_size) < 0) {
				logger(LL_ERROR, "%s: send failed\n", __func__);
				break;
			}
			done += zr;
		}
		free(buffer);
		zip_fclose(zfile);
		zip_unchange_all(zip);
		zip_close(zip);
	} else {
		char *filepath = build_path(ipsw->path, infile);
		struct stat fst;
#ifdef WIN32
		if (stat(filepath, &fst) != 0) {
#else
		if (lstat(filepath, &fst) != 0) {
#endif
			logger(LL_ERROR, "%s: stat failed for %s: %s\n", __func__, filepath, strerror(errno));
			free(filepath);
			return -1;
		}
		total_size = fst.st_size;
		buffer = (unsigned char*)malloc(blocksize);
		if (buffer == NULL) {
			logger(LL_ERROR, "Out of memory\n");
			free(filepath);
			return -1;
		}

#ifndef WIN32
		if (S_ISLNK(fst.st_mode)) {
			ssize_t rl = readlink(filepath, (char*)buffer, (total_size > blocksize) ? blocksize : total_size);
			if (rl < 0) {
				logger(LL_ERROR, "%s: readlink failed for %s: %s\n", __func__, filepath, strerror(errno));
				free(filepath);
				free(buffer);
				return -1;
			}
			send_callback(ctx, buffer, (size_t)rl, 0, 0);
		} else {
#endif
			FILE *f = fopen(filepath, "rb");
			if (!f) {
				logger(LL_ERROR, "%s: fopen failed for %s: %s\n", __func__, filepath, strerror(errno));
				free(filepath);
				free(buffer);
				return -2;
			}

			while (done < total_size) {
				size_t size = total_size-done;
				if (size > blocksize) size = blocksize;
				size_t fr = fread(buffer, 1, size, f);
				if (fr != size) {
					logger(LL_ERROR, "%s: fread failed for %s: %s\n", __func__, filepath, strerror(errno));
					break;
				}
				if (send_callback(ctx, buffer, fr, done, total_size) < 0) {
					logger(LL_ERROR, "%s: send failed\n", __func__);
					break;
				}
				done += fr;
			}
			fclose(f);
#ifndef WIN32
		}
#endif
		free(filepath);
		free(buffer);
	}

	if (done < total_size) {
		logger(LL_ERROR, "%s: Sending file data for %s failed (sent %" PRIu64 "/%" PRIu64 ")\n", __func__, infile, (uint64_t)done, (uint64_t)total_size);
		return -1;
	}

	// send a NULL buffer to mark end of transfer
	send_callback(ctx, NULL, 0, done, total_size);

	return 0;
}

int ipsw_extract_build_manifest(ipsw_archive_t ipsw, plist_t* buildmanifest, int *tss_enabled)
{
	size_t size = 0;
	void* data = NULL;

	*tss_enabled = 0;

	/* older devices don't require personalized firmwares and use a BuildManifesto.plist */
	if (ipsw_file_exists(ipsw, "BuildManifesto.plist")) {
		if (ipsw_extract_to_memory(ipsw, "BuildManifesto.plist", &data, &size) == 0) {
			plist_from_memory((char*)data, size, buildmanifest, NULL);
			free(data);
			return 0;
		}
	}

	data = NULL;
	size = 0;

	/* whereas newer devices do not require personalized firmwares and use a BuildManifest.plist */
	if (ipsw_extract_to_memory(ipsw, "BuildManifest.plist", &data, &size) == 0) {
		*tss_enabled = 1;
		plist_from_memory((char*)data, size, buildmanifest, NULL);
		free(data);
		return 0;
	}

	return -1;
}

int ipsw_extract_restore_plist(ipsw_archive_t ipsw, plist_t* restore_plist)
{
	size_t size = 0;
	void* data = NULL;

	if (ipsw_extract_to_memory(ipsw, "Restore.plist", &data, &size) == 0) {
		plist_from_memory((char*)data, size, restore_plist, NULL);
		free(data);
		return 0;
	}

	return -1;
}

static int ipsw_list_contents_recurse(ipsw_archive_t ipsw, const char *path, ipsw_list_cb cb, void *ctx)
{
	int ret = 0;
	char *base = build_path(ipsw->path, path);

	DIR *dirp = opendir(base);

	if (!dirp) {
		logger(LL_ERROR, "failed to open directory %s\n", base);
		free(base);
		return -1;
	}

	while (ret >= 0) {
		struct dirent *dir = readdir(dirp);
		if (!dir)
			break;

		if (!strcmp(dir->d_name, ".") || !strcmp(dir->d_name, ".."))
			continue;

		char *fpath = build_path(base, dir->d_name);
		char *subpath;
		if (*path)
			subpath = build_path(path, dir->d_name);
		else
			subpath = strdup(dir->d_name);

		struct stat st;
#ifdef WIN32
		ret = stat(fpath, &st);
#else
		ret = lstat(fpath, &st);
#endif
		if (ret != 0) {
			logger(LL_ERROR, "%s: stat failed for %s: %s\n", __func__, fpath, strerror(errno));
			free(fpath);
			free(subpath);
			break;
		}

		ret = cb(ctx, ipsw, subpath, &st);

		if (ret >= 0 && S_ISDIR(st.st_mode))
			ipsw_list_contents_recurse(ipsw, subpath, cb, ctx);

		free(fpath);
		free(subpath);
	}

	closedir(dirp);
	free(base);
	return ret;
}

int ipsw_list_contents(ipsw_archive_t ipsw, ipsw_list_cb cb, void *ctx)
{
	int ret = 0;

	if (ipsw == NULL) {
		logger(LL_ERROR, "Invalid IPSW archive\n");
		return -1;
	}

	if (ipsw->zip) {
		int err = 0;
		struct zip *zip = zip_open(ipsw->path, 0, &err);
		if (zip == NULL) {
			logger(LL_ERROR, "zip_open: %s: %d\n", ipsw->path, err);
			return -1;
		}

		int64_t entries = zip_get_num_entries(zip, 0);
		if (entries < 0) {
			logger(LL_ERROR, "zip_get_num_entries failed\n");
			return -1;
		}

		for (int64_t index = 0; index < entries; index++) {
			zip_stat_t stat;

			zip_stat_init(&stat);
			if (zip_stat_index(zip, index, 0, &stat) < 0) {
				logger(LL_ERROR, "zip_stat_index failed for %s\n", stat.name);
				ret = -1;
				continue;
			}

			uint8_t opsys;
			uint32_t attributes;
			if (zip_file_get_external_attributes(zip, index, 0, &opsys, &attributes) < 0) {
				logger(LL_ERROR, "zip_file_get_external_attributes failed for %s\n", stat.name);
				ret = -1;
				continue;
			}
			if (opsys != ZIP_OPSYS_UNIX) {
				logger(LL_ERROR, "File %s does not have UNIX attributes\n", stat.name);
				ret = -1;
				continue;
			}

			struct stat st;
			memset(&st, 0, sizeof(st));
			st.st_ino = 1 + index;
			st.st_nlink = 1;
			st.st_mode = attributes >> 16;
			st.st_size = stat.size;

			char *name = strdup(stat.name);
			if (name[strlen(name) - 1] == '/')
				name[strlen(name) - 1] = '\0';

			ret = cb(ctx, ipsw, name, &st);

			free(name);

			if (ret < 0)
				break;
		}
	} else {
		ret = ipsw_list_contents_recurse(ipsw, "", cb, ctx);
	}

	return ret;
}

int ipsw_get_signed_firmwares(const char* product, plist_t* firmwares)
{
	char url[256];
	char *jdata = NULL;
	size_t jsize = 0;
	plist_t dict = NULL;
	plist_t node = NULL;
	plist_t fws = NULL;
	const char* product_type = NULL;
	uint32_t count = 0;
	uint32_t i = 0;

	if (!product || !firmwares) {
		return -1;
	}

	*firmwares = NULL;
	snprintf(url, sizeof(url), "https://api.ipsw.me/v4/device/%s", product);

	if (download_to_buffer(url, (void**)&jdata, &jsize) < 0) {
		logger(LL_ERROR, "Download from %s failed.\n", url);
		return -1;
	}
	plist_from_json(jdata, jsize, &dict);
	free(jdata);
	if (!dict || plist_get_node_type(dict) != PLIST_DICT) {
		logger(LL_ERROR, "Failed to parse json data.\n");
		plist_free(dict);
		return -1;
	}

	node = plist_dict_get_item(dict, "identifier");
	if (!node || plist_get_node_type(node) != PLIST_STRING) {
		logger(LL_ERROR, "Unexpected json data returned - missing 'identifier'\n");
		plist_free(dict);
		return -1;
	}
	product_type = plist_get_string_ptr(node, NULL);
	if (!product_type || strcmp(product_type, product) != 0) {
		logger(LL_ERROR, "Unexpected json data returned - failed to read identifier\n");
		plist_free(dict);
		return -1;
	}
	fws = plist_dict_get_item(dict, "firmwares");
	if (!fws || plist_get_node_type(fws) != PLIST_ARRAY) {
		logger(LL_ERROR, "Unexpected json data returned - missing 'firmwares'\n");
		plist_free(dict);
		return -1;
	}

	*firmwares = plist_new_array();
	count = plist_array_get_size(fws);
	for (i = 0; i < count; i++) {
		plist_t fw = plist_array_get_item(fws, i);
		node = plist_dict_get_item(fw, "signed");
		if (node && plist_get_node_type(node) == PLIST_BOOLEAN) {
			uint8_t bv = 0;
			plist_get_bool_val(node, &bv);
			if (bv) {
				plist_array_append_item(*firmwares, plist_copy(fw));
			}
		}
	}
	plist_free(dict);

	return 0;
}

int ipsw_get_latest_fw(plist_t version_data, const char* product, char** fwurl, unsigned char* sha1buf)
{
	*fwurl = NULL;
	if (sha1buf != NULL) {
		memset(sha1buf, '\0', 20);
	}

	plist_t n1 = plist_dict_get_item(version_data, "MobileDeviceSoftwareVersionsByVersion");
	if (!n1) {
		logger(LL_ERROR, "%s: ERROR: Can't find MobileDeviceSoftwareVersionsByVersion dict in version data\n", __func__);
		return -1;
	}

	plist_dict_iter iter = NULL;
	plist_dict_new_iter(n1, &iter);
	if (!iter) {
		logger(LL_ERROR, "%s: ERROR: Can't get dict iter\n", __func__);
		return -1;
	}
	char* key = NULL;
	uint64_t major = 0;
	plist_t val = NULL;
	do {
		plist_dict_next_item(n1, iter, &key, &val);
		if (key) {
			plist_t pr = plist_access_path(n1, 3, key, "MobileDeviceSoftwareVersions", product);
			if (pr) {
				long long unsigned int v = strtoull(key, NULL, 10);
				if (v > major)
					major = v;
			}
			free(key);
		}
	} while (val);
	free(iter);

	if (major == 0) {
		logger(LL_ERROR, "%s: ERROR: Can't find major version?!\n", __func__);
		return -1;
	}

	char majstr[32]; // should be enough for a uint64_t value
	snprintf(majstr, sizeof(majstr), "%"PRIu64, (uint64_t)major);
	n1 = plist_access_path(version_data, 7, "MobileDeviceSoftwareVersionsByVersion", majstr, "MobileDeviceSoftwareVersions", product, "Unknown", "Universal", "Restore");
	if (!n1) {
		logger(LL_ERROR, "%s: ERROR: Can't get Unknown/Universal/Restore node?!\n", __func__);
		return -1;
	}

	plist_t n2 = plist_dict_get_item(n1, "BuildVersion");
	if (!n2 || (plist_get_node_type(n2) != PLIST_STRING)) {
		logger(LL_ERROR, "%s: ERROR: Can't get build version node?!\n", __func__);
		return -1;
	}

	char* strval = NULL;
	plist_get_string_val(n2, &strval);

	n1 = plist_access_path(version_data, 5, "MobileDeviceSoftwareVersionsByVersion", majstr, "MobileDeviceSoftwareVersions", product, strval);
	if (!n1) {
		logger(LL_ERROR, "%s: ERROR: Can't get MobileDeviceSoftwareVersions/%s node?!\n", __func__, strval);
		free(strval);
		return -1;
	}
	free(strval);

	strval = NULL;
	n2 = plist_dict_get_item(n1, "SameAs");
	if (n2) {
		plist_get_string_val(n2, &strval);
	}
	if (strval) {
		n1 = plist_access_path(version_data, 5, "MobileDeviceSoftwareVersionsByVersion", majstr, "MobileDeviceSoftwareVersions", product, strval);
		free(strval);
		strval = NULL;
		if (!n1 || (plist_dict_get_size(n1) == 0)) {
			logger(LL_ERROR, "%s: ERROR: Can't get MobileDeviceSoftwareVersions/%s dict\n", __func__, product);
			return -1;
		}
	}

	n2 = plist_access_path(n1, 2, "Update", "BuildVersion");
	if (n2) {
		strval = NULL;
		plist_get_string_val(n2, &strval);
		if (strval) {
			n1 = plist_access_path(version_data, 5, "MobileDeviceSoftwareVersionsByVersion", majstr, "MobileDeviceSoftwareVersions", product, strval);
			free(strval);
			strval = NULL;
		}
	}

	n2 = plist_access_path(n1, 2, "Restore", "FirmwareURL");
	if (!n2 || (plist_get_node_type(n2) != PLIST_STRING)) {
		logger(LL_ERROR, "%s: ERROR: Can't get FirmwareURL node\n", __func__);
		return -1;
	}

	plist_get_string_val(n2, fwurl);

	if (sha1buf != NULL) {
		n2 = plist_access_path(n1, 2, "Restore", "FirmwareSHA1");
		if (n2 && plist_get_node_type(n2) == PLIST_STRING) {
			strval = NULL;
			plist_get_string_val(n2, &strval);
			if (strval) {
				if (strlen(strval) == 40) {
					int i;
					int v;
					for (i = 0; i < 40; i+=2) {
						v = 0;
						sscanf(strval+i, "%02x", &v);
						sha1buf[i/2] = (unsigned char)v;
					}
				}
				free(strval);
			}
		}
	}

	return 0;
}

static int sha1_verify_fp(FILE* f, unsigned char* expected_sha1)
{
	unsigned char tsha1[20];
	char buf[8192];
	size_t total = 0;
	struct stat fst;
	int lastprog = 0;
	if (!f) return 0;
	sha1_context sha1ctx;
	sha1_init(&sha1ctx);
	rewind(f);
	fstat(fileno(f), &fst);
	while (!feof(f)) {
		size_t sz = fread(buf, 1, 8192, f);
		sha1_update(&sha1ctx, buf, sz);
		total += sz;
		double p = (double)total / (double)fst.st_size;
		if ((int)(p*100) > lastprog) {
			set_progress('SHA1', p);
			lastprog = (int)(p*100);
		}
	}
	sha1_final(&sha1ctx, tsha1);
	return (memcmp(expected_sha1, tsha1, 20) == 0) ? 1 : 0;
}

int ipsw_download_fw(const char *fwurl, unsigned char* isha1, const char* todir, char** ipswfile)
{
	char* fwfn = strrchr(fwurl, '/');
	if (!fwfn) {
		logger(LL_ERROR, "can't get local filename for firmware ipsw\n");
		return -2;
	}
	fwfn++;

	char fwlfn[PATH_MAX - 5];
	if (todir) {
		snprintf(fwlfn, sizeof(fwlfn), "%s/%s", todir, fwfn);
	} else {
		snprintf(fwlfn, sizeof(fwlfn), "%s", fwfn);
	}

	char fwlock[PATH_MAX];
	snprintf(fwlock, sizeof(fwlock), "%s.lock", fwlfn);

	lock_info_t lockinfo;

	if (lock_file(fwlock, &lockinfo) != 0) {
		logger(LL_WARNING, "Could not lock file '%s'\n", fwlock);
	}

	int need_dl = 0;
	unsigned char zsha1[20] = {0, };
	FILE* f = fopen(fwlfn, "rb");
	if (f) {
		if (memcmp(zsha1, isha1, 20) != 0) {
			logger(LL_INFO, "Verifying '%s'...\n", fwlfn);
			register_progress('SHA1', "Verifying");
			if (sha1_verify_fp(f, isha1)) {
				logger(LL_INFO, "Checksum matches.\n");
			} else {
				logger(LL_INFO, "Checksum does not match.\n");
				need_dl = 1;
			}
			finalize_progress('SHA1');
		}
		fclose(f);
	} else {
		need_dl = 1;
	}

	int res = 0;
	if (need_dl) {
		if (strncmp(fwurl, "protected:", 10) == 0) {
			logger(LL_ERROR, "Can't download '%s' because it needs a purchase.\n", fwfn);
			res = -3;
		} else {
			remove(fwlfn);
			logger(LL_INFO, "Downloading firmware (%s)\n", fwurl);
			download_to_file(fwurl, fwlfn, 1);
			if (global_quit_flag > 0) {
				logger(LL_NOTICE, "Download aborted by user\n");
				return -1;
			}
			if (memcmp(isha1, zsha1, 20) != 0) {
				logger(LL_INFO, "Verifying '%s'...\n", fwlfn);
				FILE* f = fopen(fwlfn, "rb");
				if (f) {
					register_progress('SHA1', "Verifying");
					if (sha1_verify_fp(f, isha1)) {
						logger(LL_INFO, "Checksum matches.\n");
					} else {
						logger(LL_ERROR, "File download failed (checksum mismatch).\n");
						res = -4;
					}
					finalize_progress('SHA1');
					fclose(f);

					// make sure to remove invalid files
					if (res < 0)
						remove(fwlfn);
				} else {
					logger(LL_ERROR, "Can't open '%s' for checksum verification\n", fwlfn);
					res = -5;
				}
			}
		}
	}
	if (res == 0) {
		*ipswfile = strdup(fwlfn);
	}

	if (unlock_file(&lockinfo) != 0) {
		logger(LL_WARNING, "Could not unlock file '%s'\n", fwlock);
	}

	return res;
}

int ipsw_download_latest_fw(plist_t version_data, const char* product, const char* todir, char** ipswfile)
{
	char* fwurl = NULL;
	unsigned char isha1[20];

	*ipswfile = NULL;

	if ((ipsw_get_latest_fw(version_data, product, &fwurl, isha1) < 0) || !fwurl) {
		logger(LL_ERROR, "can't get URL for latest firmware\n");
		return -1;
	}
	char* fwfn = strrchr(fwurl, '/');
	if (!fwfn) {
		logger(LL_ERROR, "can't get local filename for firmware ipsw\n");
		return -2;
	}
	fwfn++;

	logger(LL_INFO, "Latest firmware is %s\n", fwfn);

	int res = ipsw_download_fw(fwurl, isha1, todir, ipswfile);

	free(fwurl);

	return res;
}

void ipsw_cancel(void)
{
	cancel_flag++;
}

ipsw_file_handle_t ipsw_file_open(ipsw_archive_t ipsw, const char* path)
{
	ipsw_file_handle_t handle = (ipsw_file_handle_t)calloc(1, sizeof(struct ipsw_file_handle));
	if (ipsw->zip) {
		int err = 0;
		struct zip *zip = zip_open(ipsw->path, 0, &err);
		if (zip == NULL) {
			logger(LL_ERROR, "zip_open: %s: %d\n", ipsw->path, err);
			return NULL;
		}

		zip_stat_t zst;
		zip_int64_t zindex = zip_name_locate(zip, path, 0);
		if (zindex < 0) {
			logger(LL_ERROR, "zip_name_locate: %s not found\n", path);
			zip_unchange_all(zip);
			zip_close(zip);
			free(handle);
			return NULL;
		}
		handle->zfile = zip_fopen_index(zip, zindex, 0);
		if (handle->zfile == NULL) {
			logger(LL_ERROR, "zip_fopen_index: %s could not be opened\n", path);
			zip_unchange_all(zip);
			zip_close(zip);
			free(handle);
			return NULL;
		}
		zip_stat_init(&zst);
		zip_stat(zip, path, 0, &zst);
		handle->size = zst.size;
		handle->seekable = (zst.comp_method == ZIP_CM_STORE);
		handle->zip = zip;
	} else {
		struct stat st;
		char *filepath = build_path(ipsw->path, path);
		handle->file = fopen(filepath, "rb");
		free(filepath);
		if (!handle->file) {
			logger(LL_ERROR, "fopen: %s could not be opened\n", path);
			free(handle);
			return NULL;
		}
		fstat(fileno(handle->file), &st);
		handle->size = st.st_size;
		handle->seekable = 1;
	}
	return handle;
}

void ipsw_file_close(ipsw_file_handle_t handle)
{
	if (handle && handle->zfile) {
		zip_fclose(handle->zfile);
		zip_unchange_all(handle->zip);
		zip_close(handle->zip);
	} else if (handle && handle->file) {
		fclose(handle->file);
	}
	free(handle);
}

uint64_t ipsw_file_size(ipsw_file_handle_t handle)
{
	if (handle) {
		return handle->size;
	}
	return 0;
}

int64_t ipsw_file_read(ipsw_file_handle_t handle, void* buffer, size_t size)
{
	if (handle && handle->zfile) {
		zip_int64_t zr = zip_fread(handle->zfile, buffer, size);
		return (int64_t)zr;
	} else if (handle && handle->file) {
		return fread(buffer, 1, size, handle->file);
	} else {
		logger(LL_ERROR, "%s: Invalid file handle\n", __func__);
		return -1;
	}
}

int ipsw_file_seek(ipsw_file_handle_t handle, int64_t offset, int whence)
{
	if (handle && handle->zfile) {
		return zip_fseek(handle->zfile, offset, whence);
	} else if (handle && handle->file) {
#ifdef WIN32
		if (whence == SEEK_SET) {
			rewind(handle->file);
		}
		return (_lseeki64(fileno(handle->file), offset, whence) < 0) ? -1 : 0;
#else
		return fseeko(handle->file, offset, whence);
#endif
	} else {
		logger(LL_ERROR, "%s: Invalid file handle\n", __func__);
		return -1;
	}
}

int64_t ipsw_file_tell(ipsw_file_handle_t handle)
{
	if (handle && handle->zfile) {
		return zip_ftell(handle->zfile);
	} else if (handle && handle->file) {
#ifdef WIN32
		return _lseeki64(fileno(handle->file), 0, SEEK_CUR);
#else
		return ftello(handle->file);
#endif
	} else {
		logger(LL_ERROR, "%s: Invalid file handle\n", __func__);
		return -1;
	}
}
