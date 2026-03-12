/*
 * idevicerestore.c
 * Restore device firmware and filesystem
 *
 * Copyright (c) 2012-2019 Nikias Bassen. All Rights Reserved.
 * Copyright (c) 2010-2015 Martin Szulecki. All Rights Reserved.
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
#include "config.h"
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ctype.h>
#include <getopt.h>
#include <plist/plist.h>
#include <zlib.h>
#include <libgen.h>
#include <signal.h>

#include <curl/curl.h>

#include <libimobiledevice-glue/sha.h>
#include <libimobiledevice-glue/utils.h>
#include <libimobiledevice-glue/termcolors.h>
#include <libtatsu/tss.h>

#include "ace3.h"
#include "dfu.h"
#include "img3.h"
#include "img4.h"
#include "ipsw.h"
#include "common.h"
#include "normal.h"
#include "restore.h"
#include "download.h"
#include "recovery.h"
#include "idevicerestore.h"

#ifdef HAVE_LIMERA1N
#include "limera1n.h"
#endif

#include "locking.h"

#define VERSION_XML "version.xml"

#ifndef IDEVICERESTORE_NOMAIN
static struct option longopts[] = {
	{ "ecid",           required_argument, NULL, 'i' },
	{ "udid",           required_argument, NULL, 'u' },
	{ "debug",          no_argument,       NULL, 'd' },
	{ "help",           no_argument,       NULL, 'h' },
	{ "erase",          no_argument,       NULL, 'e' },
	{ "custom",         no_argument,       NULL, 'c' },
	{ "latest",         no_argument,       NULL, 'l' },
	{ "server",         required_argument, NULL, 's' },
	{ "exclude",        no_argument,       NULL, 'x' },
	{ "shsh",           no_argument,       NULL, 't' },
	{ "keep-pers",      no_argument,       NULL, 'k' },
#ifdef HAVE_LIMERA1N
	{ "pwn",            no_argument,       NULL, 'p' },
#endif
	{ "no-action",      no_argument,       NULL, 'n' },
	{ "cache-path",     required_argument, NULL, 'C' },
	{ "no-input",       no_argument,       NULL, 'y' },
	{ "plain-progress", no_argument,       NULL, 'P' },
	{ "restore-mode",   no_argument,       NULL, 'R' },
	{ "ticket",         required_argument, NULL, 'T' },
	{ "no-restore",     no_argument,       NULL, 'z' },
	{ "version",        no_argument,       NULL, 'v' },
	{ "ipsw-info",      no_argument,       NULL, 'I' },
	{ "ignore-errors",  no_argument,       NULL,  1  },
	{ "variant",        required_argument, NULL,  2  },
	{ "logfile",        required_argument, NULL,  3  },
	{ NULL, 0, NULL, 0 }
};

static void usage(int argc, char* argv[], int err)
{
#ifdef HAVE_LIMERA1N
#define PWN_FLAG_LINE "  -p, --pwn             Put device in pwned DFU mode and exit (limera1n devices)\n"
#else
#define PWN_FLAG_LINE ""
#endif
	char* name = strrchr(argv[0], '/');
	fprintf((err) ? stderr : stdout,
	"Usage: %s [OPTIONS] PATH\n" \
	"\n" \
	"Restore IPSW firmware at PATH to an iOS device.\n" \
	"\n" \
	"PATH can be a compressed .ipsw file or a directory containing all files\n" \
	"extracted from an IPSW.\n" \
	"\n" \
	"OPTIONS:\n" \
	"  -i, --ecid ECID       Target specific device by its ECID\n" \
	"                        e.g. 0xaabb123456 (hex) or 1234567890 (decimal)\n" \
	"  -u, --udid UDID       Target specific device by its device UDID\n" \
	"                        NOTE: only works with devices in normal mode.\n" \
	"  -l, --latest          Use latest available firmware (with download on demand).\n" \
	"                        Before performing any action it will interactively ask\n" \
	"                        to select one of the currently signed firmware versions,\n" \
	"                        unless -y has been given too.\n" \
	"                        The PATH argument is ignored when using this option.\n" \
	"                        DO NOT USE if you need to preserve the baseband/unlock!\n" \
	"                        USE WITH CARE if you want to keep a jailbreakable\n" \
	"                        firmware!\n" \
	"  -e, --erase           Perform full restore instead of update, erasing all data\n" \
	"                        DO NOT USE if you want to preserve user data on the device!\n" \
	"  -y, --no-input        Non-interactive mode, do not ask for any input.\n" \
	"                        WARNING: This will disable certain checks/prompts that\n" \
	"                        are supposed to prevent DATA LOSS. Use with caution.\n" \
	"  -n, --no-action       Do not perform any restore action. If combined with -l\n" \
	"                        option the on-demand ipsw download is performed before\n" \
	"                        exiting.\n" \
	"  --ipsw-info           Print information about the IPSW at PATH and exit.\n" \
	"  -h, --help            Prints this usage information\n" \
	"  -C, --cache-path DIR  Use specified directory for caching extracted or other\n" \
	"                        reused files.\n" \
	"  --logfile=PATH        Write logging output to file at PATH. If PATH equals\n" \
	"                        'NULL' or 'NONE', no log file will be written.\n" \
	"  -d, --debug           Print additional debug output\n" \
	"  -v, --version         Print version information\n" \
	"\n" \
	"Advanced/experimental options:\n"
	"  -c, --custom          Restore with a custom firmware (requires bootrom exploit)\n" \
	"  -s, --server URL      Override default signing server request URL\n" \
	"  -x, --exclude         Exclude nor/baseband upgrade (legacy devices)\n" \
	"  -t, --shsh            Fetch TSS record and save to .shsh file, then exit\n" \
	"  -z, --no-restore      Do not restore and end after booting to the ramdisk\n" \
	"  -k, --keep-pers       Write personalized components to files for debugging\n" \
	PWN_FLAG_LINE \
	"  -P, --plain-progress  Print progress as plain step and progress\n" \
	"  -R, --restore-mode    Allow restoring from Restore mode\n" \
	"  -T, --ticket PATH     Use file at PATH to send as AP ticket\n" \
	"  --variant VARIANT     Use given VARIANT to match the build identity to use,\n" \
        "                        e.g. 'Customer Erase Install (IPSW)'\n" \
	"  --ignore-errors       Try to continue the restore process after certain\n" \
	"                        errors (like a failed baseband update)\n" \
	"                        WARNING: This might render the device unable to boot\n" \
	"                        or only partially functioning. Use with caution.\n" \
	"\n" \
	"Homepage:    <" PACKAGE_URL ">\n" \
	"Bug Reports: <" PACKAGE_BUGREPORT ">\n",
	(name ? name + 1 : argv[0]));
}
#endif

const uint8_t lpol_file[22] = {
		0x30, 0x14, 0x16, 0x04, 0x49, 0x4d, 0x34, 0x50,
		0x16, 0x04, 0x6c, 0x70, 0x6f, 0x6c, 0x16, 0x03,
		0x31, 0x2e, 0x30, 0x04, 0x01, 0x00
};
const uint32_t lpol_file_length = 22;

static int load_version_data(struct idevicerestore_client_t* client)
{
	if (!client) {
		return -1;
	}

	struct stat fst;
	int cached = 0;

	char version_xml[1024];

	if (client->cache_dir) {
		if (stat(client->cache_dir, &fst) < 0) {
			mkdir_with_parents(client->cache_dir, 0755);
		}
		strcpy(version_xml, client->cache_dir);
		strcat(version_xml, "/");
		strcat(version_xml, VERSION_XML);
	} else {
		strcpy(version_xml, VERSION_XML);
	}

	if ((stat(version_xml, &fst) < 0) || ((time(NULL)-86400) > fst.st_mtime)) {
		char version_xml_tmp[1024];
		strcpy(version_xml_tmp, version_xml);
		strcat(version_xml_tmp, ".tmp");

		if (download_to_file("http://itunes.apple.com/check/version",  version_xml_tmp, 0) == 0) {
			remove(version_xml);
			if (rename(version_xml_tmp, version_xml) < 0) {
				logger(LL_ERROR, "Could not update '%s'\n", version_xml);
			} else {
				logger(LL_INFO, "Updated version data.\n");
			}
		}
	} else {
		cached = 1;
	}

	char *verbuf = NULL;
	size_t verlen = 0;
	read_file(version_xml, (void**)&verbuf, &verlen);

	if (!verbuf) {
		logger(LL_ERROR, "Could not load '%s'\n", version_xml);
		return -1;
	}

	client->version_data = NULL;
	plist_from_xml(verbuf, verlen, &client->version_data);
	free(verbuf);

	if (!client->version_data) {
		remove(version_xml);
		logger(LL_ERROR, "Cannot parse plist data from '%s'.\n", version_xml);
		return -1;
	}

	if (cached) {
		logger(LL_INFO, "Using cached version data\n");
	}

	return 0;
}

static int32_t get_version_num(const char *s_ver)
{
        int vers[3] = {0, 0, 0};
        if (sscanf(s_ver, "%d.%d.%d", &vers[0], &vers[1], &vers[2]) >= 2) {
                return ((vers[0] & 0xFF) << 16) | ((vers[1] & 0xFF) << 8) | (vers[2] & 0xFF);
        }
        return 0x00FFFFFF;
}

static int compare_versions(const char *s_ver1, const char *s_ver2)
{
	return (get_version_num(s_ver1) & 0xFFFF00) - (get_version_num(s_ver2) & 0xFFFF00);
}

static void idevice_event_cb(const idevice_event_t *event, void *userdata)
{
	struct idevicerestore_client_t *client = (struct idevicerestore_client_t*)userdata;
#ifdef HAVE_ENUM_IDEVICE_CONNECTION_TYPE
	if (event->conn_type != CONNECTION_USBMUXD) {
		// ignore everything but devices connected through USB
		return;
	}
#endif
	if (event->event == IDEVICE_DEVICE_ADD) {
		if (client->ignore_device_add_events) {
			return;
		}
		if (normal_check_mode(client) == 0) {
			mutex_lock(&client->device_event_mutex);
			client->mode = MODE_NORMAL;
			logger(LL_DEBUG, "%s: device %016" PRIx64 " (udid: %s) connected in normal mode\n", __func__, client->ecid, client->udid);
			cond_signal(&client->device_event_cond);
			mutex_unlock(&client->device_event_mutex);
		} else if (client->ecid && restore_check_mode(client) == 0) {
			mutex_lock(&client->device_event_mutex);
			client->mode = MODE_RESTORE;
			logger(LL_DEBUG, "%s: device %016" PRIx64 " (udid: %s) connected in restore mode\n", __func__, client->ecid, client->udid);
			cond_signal(&client->device_event_cond);
			mutex_unlock(&client->device_event_mutex);
		}
		if (!client->device) {
			client->device = get_irecv_device(client);
		}
	} else if (event->event == IDEVICE_DEVICE_REMOVE) {
		if (client->udid && !strcmp(event->udid, client->udid)) {
			mutex_lock(&client->device_event_mutex);
			client->mode = MODE_UNKNOWN;
			logger(LL_DEBUG, "%s: device %016" PRIx64 " (udid: %s) disconnected\n", __func__, client->ecid, client->udid);
			client->ignore_device_add_events = 0;
			cond_signal(&client->device_event_cond);
			mutex_unlock(&client->device_event_mutex);
		}
	}
}

static void irecv_event_cb(const irecv_device_event_t* event, void *userdata)
{
	struct idevicerestore_client_t *client = (struct idevicerestore_client_t*)userdata;
	if (event->type == IRECV_DEVICE_ADD) {
		if (!client->udid && !client->ecid) {
			client->ecid = event->device_info->ecid;
		}
		if (client->ecid && event->device_info->ecid == client->ecid) {
			mutex_lock(&client->device_event_mutex);
			switch (event->mode) {
				case IRECV_K_WTF_MODE:
					client->mode = MODE_WTF;
					break;
				case IRECV_K_DFU_MODE:
					client->mode = MODE_DFU;
					break;
				case IRECV_K_PORT_DFU_MODE:
					client->mode = MODE_PORTDFU;
					break;
				case IRECV_K_RECOVERY_MODE_1:
				case IRECV_K_RECOVERY_MODE_2:
				case IRECV_K_RECOVERY_MODE_3:
				case IRECV_K_RECOVERY_MODE_4:
					client->mode = MODE_RECOVERY;
					break;
				default:
					client->mode = MODE_UNKNOWN;
			}
			logger(LL_DEBUG, "%s: device %016" PRIx64 " (udid: %s) connected in %s mode\n", __func__, client->ecid, (client->udid) ? client->udid : "N/A", client->mode->string);
			if (!client->device) {
				client->device = get_irecv_device(client);
			}
			cond_signal(&client->device_event_cond);
			mutex_unlock(&client->device_event_mutex);
		}
	} else if (event->type == IRECV_DEVICE_REMOVE) {
		if (client->ecid && event->device_info->ecid == client->ecid) {
			mutex_lock(&client->device_event_mutex);
			client->mode = MODE_UNKNOWN;
			logger(LL_DEBUG, "%s: device %016" PRIx64 " (udid: %s) disconnected\n", __func__, client->ecid, (client->udid) ? client->udid : "N/A");
			if (event->mode == IRECV_K_PORT_DFU_MODE) {
				// We have to reset the ECID here if a port DFU device disconnects,
				// because when the device reconnects in a different mode, it will
				// have the actual device ECID and wouldn't get detected.
				client->ecid = 0;
			}
			cond_signal(&client->device_event_cond);
			mutex_unlock(&client->device_event_mutex);
		}
	}
}

int build_identity_check_components_in_ipsw(plist_t build_identity, ipsw_archive_t ipsw);

int idevicerestore_start(struct idevicerestore_client_t* client)
{
	int tss_enabled = 0;
	int result = 0;

	if (!client) {
		return -1;
	}

	if ((client->flags & FLAG_LATEST) && (client->flags & FLAG_CUSTOM)) {
		logger(LL_ERROR, "FLAG_LATEST cannot be used with FLAG_CUSTOM.\n");
		return -1;
	}

	if (!client->ipsw && !(client->flags & FLAG_PWN) && !(client->flags & FLAG_LATEST)) {
		logger(LL_ERROR, "no ipsw file given\n");
		return -1;
	}

	if (client->debug_level > 0) {
		idevicerestore_debug = 1;
		if (client->debug_level > 1) {
			irecv_set_debug_level(1);
		}
		if (client->debug_level > 2) {
			idevice_set_debug_level(1);
		}
		tss_set_debug_level(client->debug_level);
	}

	progress_reset_tag();

	idevicerestore_progress(client, RESTORE_STEP_DETECT, 0.0);

	if (!client->irecv_e_ctx) {
		irecv_device_event_subscribe(&client->irecv_e_ctx, irecv_event_cb, client);
	}

	if (!client->idevice_e_ctx) {
		idevice_event_subscribe(idevice_event_cb, client);
		client->idevice_e_ctx = idevice_event_cb;
	}

	// check which mode the device is currently in so we know where to start
	mutex_lock(&client->device_event_mutex);
	if (client->mode == MODE_UNKNOWN) {
		cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 10000);
		if (client->mode == MODE_UNKNOWN || (client->flags & FLAG_QUIT)) {
			mutex_unlock(&client->device_event_mutex);
			logger(LL_ERROR, "Unable to discover device mode. Please make sure a device is attached.\n");
			return -1;
		}
	}
	idevicerestore_progress(client, RESTORE_STEP_DETECT, 0.1);
	logger(LL_INFO, "Found device in %s mode\n", client->mode->string);
	mutex_unlock(&client->device_event_mutex);

	if (client->mode == MODE_WTF) {
		unsigned int cpid = 0;

		if (dfu_client_new(client) != 0) {
			logger(LL_ERROR, "Could not open device in WTF mode\n");
			return -1;
		}
		if ((dfu_get_cpid(client, &cpid) < 0) || (cpid == 0)) {
			logger(LL_ERROR, "Could not get CPID for WTF mode device\n");
			dfu_client_free(client);
			return -1;
		}

		char wtfname[256];
		snprintf(wtfname, sizeof(wtfname), "Firmware/dfu/WTF.s5l%04xxall.RELEASE.dfu", cpid);
		void* wtftmp = NULL;
		size_t wtfsize = 0;

		// Prefer to get WTF file from the restore IPSW
		ipsw_extract_to_memory(client->ipsw, wtfname, &wtftmp, &wtfsize);
		if (!wtftmp) {
			// update version data (from cache, or apple if too old)
			load_version_data(client);

			// Download WTF IPSW
			char* s_wtfurl = NULL;
			plist_t wtfurl = plist_access_path(client->version_data, 7, "MobileDeviceSoftwareVersionsByVersion", "5", "RecoverySoftwareVersions", "WTF", "304218112", "5", "FirmwareURL");
			if (wtfurl && (plist_get_node_type(wtfurl) == PLIST_STRING)) {
				plist_get_string_val(wtfurl, &s_wtfurl);
			}
			if (!s_wtfurl) {
				logger(LL_INFO, "Using hardcoded x12220000_5_Recovery.ipsw URL\n");
				s_wtfurl = strdup("http://appldnld.apple.com.edgesuite.net/content.info.apple.com/iPhone/061-6618.20090617.Xse7Y/x12220000_5_Recovery.ipsw");
			}

			// make a local file name
			char* fnpart = strrchr(s_wtfurl, '/');
			if (!fnpart) {
				fnpart = (char*)"x12220000_5_Recovery.ipsw";
			} else {
				fnpart++;
			}
			struct stat fst;
			char wtfipsw[1024];
			if (client->cache_dir) {
				if (stat(client->cache_dir, &fst) < 0) {
					mkdir_with_parents(client->cache_dir, 0755);
				}
				strcpy(wtfipsw, client->cache_dir);
				strcat(wtfipsw, "/");
				strcat(wtfipsw, fnpart);
			} else {
				strcpy(wtfipsw, fnpart);
			}
			if (stat(wtfipsw, &fst) != 0) {
				download_to_file(s_wtfurl, wtfipsw, 0);
			}

			ipsw_archive_t wtf_ipsw = ipsw_open(wtfipsw);
			ipsw_extract_to_memory(wtf_ipsw, wtfname, &wtftmp, &wtfsize);
			ipsw_close(wtf_ipsw);
			if (!wtftmp) {
				logger(LL_ERROR, "Could not extract WTF\n");
			}
		}

		mutex_lock(&client->device_event_mutex);
		if (wtftmp) {
			if (dfu_send_buffer(client, wtftmp, wtfsize) != 0) {
				logger(LL_ERROR, "Could not send WTF...\n");
			}
		}
		dfu_client_free(client);

		free(wtftmp);

		cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 10000);
		if (client->mode != MODE_DFU || (client->flags & FLAG_QUIT)) {
			mutex_unlock(&client->device_event_mutex);
			/* TODO: verify if it actually goes from 0x1222 -> 0x1227 */
			logger(LL_ERROR, "Failed to put device into DFU from WTF mode\n");
			return -1;
		}
		mutex_unlock(&client->device_event_mutex);
	}

	// discover the device type
	client->device = get_irecv_device(client);
	if (client->device == NULL) {
		logger(LL_ERROR, "Unable to discover device type\n");
		return -1;
	}
	if (client->ecid == 0) {
		logger(LL_ERROR, "Unable to determine ECID\n");
		return -1;
	}
	logger(LL_INFO, "ECID: %" PRIu64 "\n", client->ecid);

	idevicerestore_progress(client, RESTORE_STEP_DETECT, 0.2);
	logger(LL_INFO, "Identified device as %s, %s\n", client->device->hardware_model, client->device->product_type);

	if ((client->flags & FLAG_PWN) && (client->mode != MODE_DFU)) {
		logger(LL_ERROR, "you need to put your device into DFU mode to pwn it.\n");
		return -1;
	}

	if (client->mode == MODE_NORMAL) {
		plist_t pver = normal_get_lockdown_value(client, NULL, "ProductVersion");
		if (pver) {
			plist_get_string_val(pver, &client->device_version);
			plist_free(pver);
		}
		pver = normal_get_lockdown_value(client, NULL, "BuildVersion");
		if (pver) {
			plist_get_string_val(pver, &client->device_build);
			plist_free(pver);
		}
	}
	logger(LL_INFO, "Device Product Version: %s\n", (client->device_version) ? client->device_version : "N/A");
	logger(LL_INFO, "Device Product Build: %s\n", (client->device_build) ? client->device_build : "N/A");

	if (client->flags & FLAG_PWN) {
#ifdef HAVE_LIMERA1N
		recovery_client_free(client);

		if (client->mode != MODE_DFU) {
			logger(LL_ERROR, "Device needs to be in DFU mode for this option.\n");
			return -1;
		}

		logger(LL_INFO, "connecting to DFU\n");
		if (dfu_client_new(client) < 0) {
			return -1;
		}

		if (limera1n_is_supported(client->device)) {
			logger(LL_INFO, "exploiting with limera1n...\n");
			if (limera1n_exploit(client->device, &client->dfu->client) != 0) {
				logger(LL_ERROR, "limera1n exploit failed\n");
				dfu_client_free(client);
				return -1;
			}
			dfu_client_free(client);
			logger(LL_INFO, "Device should be in pwned DFU state now.\n");

			return 0;
		}
		else {
			dfu_client_free(client);
			logger(LL_ERROR, "This device is not supported by the limera1n exploit");
			return -1;
		}
#endif
	}

	if (client->flags & FLAG_LATEST) {
		char *fwurl = NULL;
		unsigned char fwsha1[20];
		unsigned char *p_fwsha1 = NULL;
		plist_t signed_fws = NULL;
		int res = ipsw_get_signed_firmwares(client->device->product_type, &signed_fws);
		if (res < 0) {
			logger(LL_ERROR, "Could not fetch list of signed firmwares.\n");
			return res;
		}
		uint32_t count = plist_array_get_size(signed_fws);
		if (count == 0) {
			plist_free(signed_fws);
			logger(LL_ERROR, "No firmwares are currently being signed for %s (REALLY?!)\n", client->device->product_type);
			return -1;
		}
		plist_t selected_fw = NULL;
		if (client->flags & FLAG_INTERACTIVE) {
			uint32_t i = 0;
			logger(LL_INFO, "The following firmwares are currently being signed for %s:\n", client->device->product_type);
			for (i = 0; i < count; i++) {
				plist_t fw = plist_array_get_item(signed_fws, i);
				plist_t p_version = plist_dict_get_item(fw, "version");
				plist_t p_build = plist_dict_get_item(fw, "buildid");
				logger(LL_INFO, "  [%d] %s (build %s)\n", i+1, plist_get_string_ptr(p_version, NULL), plist_get_string_ptr(p_build, NULL));
			}
			while (1) {
				char input[64];
				printf("Select the firmware you want to restore: ");
				fflush(stdout);
				fflush(stdin);
				get_user_input(input, 63, 0);
				if (*input == '\0') {
					plist_free(signed_fws);
					return -1;
				}
				if (client->flags & FLAG_QUIT) {
					return -1;
				}
				unsigned long selected = strtoul(input, NULL, 10);
				if (selected == 0 || selected > count) {
					printf("Invalid input value. Must be in range: 1..%u\n", count);
					continue;
				}
				selected_fw = plist_array_get_item(signed_fws, (uint32_t)selected-1);
				break;
			}
		} else {
			logger(LL_NOTICE, "Running non-interactively, automatically selecting latest available version\n");
			selected_fw = plist_array_get_item(signed_fws, 0);
		}
		if (!selected_fw) {
			logger(LL_ERROR, "failed to select latest firmware?!\n");
			plist_free(signed_fws);
			return -1;
		} else {
			plist_t p_version = plist_dict_get_item(selected_fw, "version");
			plist_t p_build = plist_dict_get_item(selected_fw, "buildid");
			logger(LL_NOTICE, "Selected firmware %s (build %s)\n", plist_get_string_ptr(p_version, NULL), plist_get_string_ptr(p_build, NULL));
			plist_t p_url = plist_dict_get_item(selected_fw, "url");
			plist_t p_sha1 = plist_dict_get_item(selected_fw, "sha1sum");
			char *s_sha1 = NULL;
			plist_get_string_val(p_url, &fwurl);
			plist_get_string_val(p_sha1, &s_sha1);
			if (strlen(s_sha1) == 40) {
				int i;
				int v;
				for (i = 0; i < 40; i+=2) {
					v = 0;
					sscanf(s_sha1+i, "%02x", &v);
					fwsha1[i/2] = (unsigned char)v;
				}
				p_fwsha1 = &fwsha1[0];
			} else {
				logger(LL_ERROR, "unexpected size of sha1sum\n");
			}
		}
		plist_free(signed_fws);

		if (!fwurl || !p_fwsha1) {
			logger(LL_ERROR, "Missing firmware URL or SHA1\n");
			return -1;
		}

		char* ipsw = NULL;
		res = ipsw_download_fw(fwurl, p_fwsha1, client->cache_dir, &ipsw);
		if (res != 0) {
			free(ipsw);
			return res;
		} else {
			client->ipsw = ipsw_open(ipsw);
			if (!client->ipsw) {
				logger(LL_ERROR, "Failed to open ipsw '%s'\n", ipsw);
				free(ipsw);
				return -1;
			}
			free(ipsw);
		}
	}
	idevicerestore_progress(client, RESTORE_STEP_DETECT, 0.6);

	if (client->flags & FLAG_NOACTION) {
		return 0;
	}

	// extract buildmanifest
	if (client->flags & FLAG_CUSTOM) {
		logger(LL_INFO, "Extracting Restore.plist from IPSW\n");
		if (ipsw_extract_restore_plist(client->ipsw, &client->build_manifest) < 0) {
			logger(LL_ERROR, "Unable to extract Restore.plist from %s. Firmware file might be corrupt.\n", client->ipsw->path);
			return -1;
		}
	} else {
		logger(LL_INFO, "Extracting BuildManifest from IPSW\n");
		if (ipsw_extract_build_manifest(client->ipsw, &client->build_manifest, &tss_enabled) < 0) {
			logger(LL_ERROR, "Unable to extract BuildManifest from %s. Firmware file might be corrupt.\n", client->ipsw->path);
			return -1;
		}
	}

	if (client->flags & FLAG_CUSTOM) {
		// prevent attempt to sign custom firmware
		tss_enabled = 0;
		logger(LL_INFO, "Custom firmware requested; TSS has been disabled.\n");
	}

	if (client->mode == MODE_RESTORE) {
		if (!(client->flags & FLAG_ALLOW_RESTORE_MODE)) {
			if (restore_reboot(client) < 0) {
				logger(LL_ERROR, "Unable to exit restore mode\n");
				return -2;
			}

			// we need to refresh the current mode again
			mutex_lock(&client->device_event_mutex);
			cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 60000);
			if (client->mode == MODE_UNKNOWN || (client->flags & FLAG_QUIT)) {
				mutex_unlock(&client->device_event_mutex);
				logger(LL_ERROR, "Unable to discover device mode. Please make sure a device is attached.\n");
				return -1;
			}
			logger(LL_INFO, "Found device in %s mode\n", client->mode->string);
			mutex_unlock(&client->device_event_mutex);
		}
	}

	if (client->mode == MODE_PORTDFU) {
		unsigned int pdfu_bdid = 0;
		unsigned int pdfu_cpid = 0;
		unsigned int prev = 0;

		if (dfu_get_bdid(client, &pdfu_bdid) < 0) {
			logger(LL_ERROR, "Failed to get bdid for Port DFU device!\n");
			return -1;
		}
		if (dfu_get_cpid(client, &pdfu_cpid) < 0) {
			logger(LL_ERROR, "Failed to get cpid for Port DFU device!\n");
			return -1;
		}
		if (dfu_get_prev(client, &prev) < 0) {
			logger(LL_ERROR, "Failed to get PREV for Port DFU device!\n");
			return -1;
		}

		unsigned char* pdfu_nonce = NULL;
		unsigned int pdfu_nsize = 0;
		if (dfu_get_portdfu_nonce(client, &pdfu_nonce, &pdfu_nsize) < 0) {
			logger(LL_ERROR, "Failed to get nonce for Port DFU device!\n");
			return -1;
		}

		plist_t build_identity = build_manifest_get_build_identity_for_model_with_variant(client->build_manifest, client->device->hardware_model, RESTORE_VARIANT_ERASE_INSTALL, 0);
		if (!build_identity) {
			logger(LL_ERROR, "ERORR: Failed to get build identity\n");
			return -1;
		}

		unsigned int b_pdfu_cpid = (unsigned int)plist_dict_get_uint(build_identity, "USBPortController1,ChipID");
		if (b_pdfu_cpid != pdfu_cpid) {
			logger(LL_ERROR, "cpid 0x%02x doesn't match USBPortController1,ChipID in build identity (0x%02x)\n", pdfu_cpid, b_pdfu_cpid);
			return -1;
		}
		unsigned int b_pdfu_bdid = (unsigned int)plist_dict_get_uint(build_identity, "USBPortController1,BoardID");
		if (b_pdfu_bdid != pdfu_bdid) {
			logger(LL_ERROR, "bdid 0x%x doesn't match USBPortController1,BoardID in build identity (0x%x)\n", pdfu_bdid, b_pdfu_bdid);
			return -1;
		}

		plist_t parameters = plist_new_dict();
		plist_dict_set_item(parameters, "@USBPortController1,Ticket", plist_new_bool(1));
		plist_dict_set_item(parameters, "USBPortController1,ECID", plist_new_int(client->ecid));
		plist_dict_copy_item(parameters, build_identity, "USBPortController1,BoardID", NULL);
		plist_dict_copy_item(parameters, build_identity, "USBPortController1,ChipID", NULL);
		plist_dict_copy_item(parameters, build_identity, "USBPortController1,SecurityDomain", NULL);
		plist_dict_set_item(parameters, "USBPortController1,SecurityMode", plist_new_bool(1));
		plist_dict_set_item(parameters, "USBPortController1,ProductionMode", plist_new_bool(1));
		int is_mac = plist_access_path(build_identity, 2, "Info", "MacOSVariant") != NULL;
		plist_t usbf = plist_access_path(build_identity, 2, "Manifest", "USBPortController1,USBFirmware");
		if (!usbf) {
			plist_free(parameters);
			logger(LL_ERROR, "Unable to find USBPortController1,USBFirmware in build identity\n");
			return -1;
		}
		plist_t p_fwpath = plist_access_path(usbf, 2, "Info", "Path");
		if (!p_fwpath) {
			plist_free(parameters);
			logger(LL_ERROR, "Unable to find path of USBPortController1,USBFirmware component\n");
			return -1;
		}
		const char* fwpath = plist_get_string_ptr(p_fwpath, NULL);
		if (!fwpath) {
			plist_free(parameters);
			logger(LL_ERROR, "Unable to get path of USBPortController1,USBFirmware component\n");
			return -1;
		}
		void* uarp_buf = NULL;
		size_t uarp_size = 0;
		if (ipsw_extract_to_memory(client->ipsw, fwpath, &uarp_buf, &uarp_size) < 0) {
			plist_free(parameters);
			logger(LL_ERROR, "Unable to extract '%s' from IPSW\n", fwpath);
			return -1;
		}
		usbf = plist_copy(usbf);
		plist_dict_remove_item(usbf, "Info");
		plist_dict_set_item(parameters, "USBPortController1,USBFirmware", usbf);
		plist_dict_set_item(parameters, "USBPortController1,Nonce", plist_new_data((const char*)pdfu_nonce, pdfu_nsize));

		plist_t request = tss_request_new(NULL);
		if (request == NULL) {
			plist_free(parameters);
			logger(LL_ERROR, "Unable to create TSS request\n");
			return -1;
		}
		plist_dict_merge(&request, parameters);
		plist_free(parameters);

		// send request and grab response
		plist_t response = tss_request_send(request, client->tss_url);
		plist_free(request);
		if (response == NULL) {
			logger(LL_ERROR, "Unable to send TSS request\n");
			return -1;
		}
		logger(LL_INFO, "Received USBPortController1,Ticket\n");

		logger(LL_INFO, "Creating Ace3Binary\n");
		void* ace3bin = NULL;
		size_t ace3bin_size = 0;
		if (ace3_create_binary(uarp_buf, uarp_size, pdfu_bdid, prev, response, &ace3bin, &ace3bin_size) < 0) {
			logger(LL_ERROR, "Could not create Ace3Binary\n");
			return -1;
		}
		plist_free(response);
		free(uarp_buf);

		if (client->flags & FLAG_KEEP_PERS) {
			write_file("Ace3Binary", ace3bin, ace3bin_size);
		}

		if (dfu_send_buffer_with_options(client, ace3bin, ace3bin_size, IRECV_SEND_OPT_DFU_NOTIFY_FINISH | IRECV_SEND_OPT_DFU_SMALL_PKT) < 0) {
			logger(LL_ERROR, "Could not send Ace3Buffer to device\n");
			return -1;
		}

		logger(LL_DEBUG, "Waiting for device to disconnect...\n");
		cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 5000);
		if (client->mode != MODE_UNKNOWN || (client->flags & FLAG_QUIT)) {
			mutex_unlock(&client->device_event_mutex);

			if (!(client->flags & FLAG_QUIT)) {
				logger(LL_ERROR, "Device did not disconnect. Port DFU failed.\n");
			}
			return -2;
		}
		dfu_client_free(client);
		logger(LL_DEBUG, "Waiting for device to reconnect in DFU mode...\n");
		cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 20000);
		if (client->mode != MODE_DFU || (client->flags & FLAG_QUIT)) {
			mutex_unlock(&client->device_event_mutex);
			if (!(client->flags & FLAG_QUIT)) {
				logger(LL_ERROR, "Device did not reconnect in DFU mode. Port DFU failed.\n");
				if (is_mac) {
					logger(LL_ERROR, "Make sure to use the correct USB port for this model, see https://support.apple.com/120694\n");
				}
			}
			return -2;
		}
		mutex_unlock(&client->device_event_mutex);

		if (client->flags & FLAG_NOACTION) {
			logger(LL_INFO, "Port DFU restore successful.\n");
			return 0;
		} else {
			logger(LL_INFO, "Port DFU restore successful. Continuing.\n");
		}
	}

	idevicerestore_progress(client, RESTORE_STEP_DETECT, 0.8);

	/* check if device type is supported by the given build manifest */
	if (build_manifest_check_compatibility(client->build_manifest, client->device->product_type) < 0) {
		logger(LL_ERROR, "Could not make sure this firmware is suitable for the current device. Refusing to continue.\n");
		return -1;
	}

	/* print iOS information from the manifest */
	build_manifest_get_version_information(client->build_manifest, client);

	logger(LL_INFO, "IPSW Product Version: %s\n", client->version);
	logger(LL_INFO, "IPSW Product Build: %s Major: %d\n", client->build, client->build_major);

	client->image4supported = is_image4_supported(client);
	logger(LL_INFO, "Device supports Image4: %s\n", (client->image4supported) ? "true" : "false");

	// choose whether this is an upgrade or a restore (default to upgrade)
	client->tss = NULL;
	plist_t build_identity = NULL;
	int build_identity_needs_free = 0;
	if (client->flags & FLAG_CUSTOM) {
		build_identity = plist_new_dict();
		build_identity_needs_free = 1;
		{
			plist_t node;
			plist_t comp;
			plist_t inf;
			plist_t manifest;

			char tmpstr[256];
			char p_all_flash[128];
			char lcmodel[8];
			strcpy(lcmodel, client->device->hardware_model);
			int x = 0;
			while (lcmodel[x]) {
				lcmodel[x] = tolower(lcmodel[x]);
				x++;
			}

			snprintf(p_all_flash, sizeof(p_all_flash), "Firmware/all_flash/all_flash.%s.%s", lcmodel, "production");
			strcpy(tmpstr, p_all_flash);
			strcat(tmpstr, "/manifest");

			// get all_flash file manifest
			char *files[16];
			void *fmanifest = NULL;
			size_t msize = 0;
			if (ipsw_extract_to_memory(client->ipsw, tmpstr, &fmanifest, &msize) < 0) {
				logger(LL_ERROR, "could not extract %s from IPSW\n", tmpstr);
				free(build_identity);
				return -1;
			}

			char *tok = strtok(fmanifest, "\r\n");
			int fc = 0;
			while (tok) {
				files[fc++] = strdup(tok);
				if (fc >= 16) {
					break;
				}
				tok = strtok(NULL, "\r\n");
			}
			free(fmanifest);

			manifest = plist_new_dict();

			for (x = 0; x < fc; x++) {
				inf = plist_new_dict();
				strcpy(tmpstr, p_all_flash);
				strcat(tmpstr, "/");
				strcat(tmpstr, files[x]);
				plist_dict_set_item(inf, "Path", plist_new_string(tmpstr));
				comp = plist_new_dict();
				plist_dict_set_item(comp, "Info", inf);
				const char* compname = get_component_name(files[x]);
				if (compname) {
					plist_dict_set_item(manifest, compname, comp);
					if (!strncmp(files[x], "DeviceTree", 10)) {
						plist_dict_set_item(manifest, "RestoreDeviceTree", plist_copy(comp));
					}
				} else {
					logger(LL_WARNING, "Unhandled component %s\n", files[x]);
					plist_free(comp);
				}
				free(files[x]);
				files[x] = NULL;
			}

			// add iBSS
			snprintf(tmpstr, sizeof(tmpstr), "Firmware/dfu/iBSS.%s.%s.dfu", lcmodel, "RELEASE");
			inf = plist_new_dict();
			plist_dict_set_item(inf, "Path", plist_new_string(tmpstr));
			comp = plist_new_dict();
			plist_dict_set_item(comp, "Info", inf);
			plist_dict_set_item(manifest, "iBSS", comp);

			// add iBEC
			snprintf(tmpstr, sizeof(tmpstr), "Firmware/dfu/iBEC.%s.%s.dfu", lcmodel, "RELEASE");
			inf = plist_new_dict();
			plist_dict_set_item(inf, "Path", plist_new_string(tmpstr));
			comp = plist_new_dict();
			plist_dict_set_item(comp, "Info", inf);
			plist_dict_set_item(manifest, "iBEC", comp);

			// add kernel cache
			plist_t kdict = NULL;

			node = plist_dict_get_item(client->build_manifest, "KernelCachesByTarget");
			if (node && (plist_get_node_type(node) == PLIST_DICT)) {
				char tt[4];
				strncpy(tt, lcmodel, 3);
				tt[3] = 0;
				kdict = plist_dict_get_item(node, tt);
			} else {
				// Populated in older iOS IPSWs
				kdict = plist_dict_get_item(client->build_manifest, "RestoreKernelCaches");
			}
			if (kdict && (plist_get_node_type(kdict) == PLIST_DICT)) {
				plist_t kc = plist_dict_get_item(kdict, "Release");
				if (kc && (plist_get_node_type(kc) == PLIST_STRING)) {
					inf = plist_new_dict();
					plist_dict_set_item(inf, "Path", plist_copy(kc));
					comp = plist_new_dict();
					plist_dict_set_item(comp, "Info", inf);
					plist_dict_set_item(manifest, "KernelCache", comp);
					plist_dict_set_item(manifest, "RestoreKernelCache", plist_copy(comp));
				}
			}

			// add ramdisk
			node = plist_dict_get_item(client->build_manifest, "RestoreRamDisks");
			if (node && (plist_get_node_type(node) == PLIST_DICT)) {
				plist_t rd = plist_dict_get_item(node, (client->flags & FLAG_ERASE) ? "User" : "Update");
				// if no "Update" ram disk entry is found try "User" ram disk instead
				if (!rd && !(client->flags & FLAG_ERASE)) {
					rd = plist_dict_get_item(node, "User");
					// also, set the ERASE flag since we actually change the restore variant
					client->flags |= FLAG_ERASE;
				}
				if (rd && (plist_get_node_type(rd) == PLIST_STRING)) {
					inf = plist_new_dict();
					plist_dict_set_item(inf, "Path", plist_copy(rd));
					comp = plist_new_dict();
					plist_dict_set_item(comp, "Info", inf);
					plist_dict_set_item(manifest, "RestoreRamDisk", comp);
				}
			}

			// add OS filesystem
			node = plist_dict_get_item(client->build_manifest, "SystemRestoreImages");
			if (!node) {
				logger(LL_ERROR, "missing SystemRestoreImages in Restore.plist\n");
			}
			plist_t os = plist_dict_get_item(node, "User");
			if (!os) {
				logger(LL_ERROR, "missing filesystem in Restore.plist\n");
			} else {
				inf = plist_new_dict();
				plist_dict_set_item(inf, "Path", plist_copy(os));
				comp = plist_new_dict();
				plist_dict_set_item(comp, "Info", inf);
				plist_dict_set_item(manifest, "OS", comp);
			}

			// add info
			inf = plist_new_dict();
			plist_dict_set_item(inf, "RestoreBehavior", plist_new_string((client->flags & FLAG_ERASE) ? "Erase" : "Update"));
			plist_dict_set_item(inf, "Variant", plist_new_string((client->flags & FLAG_ERASE) ? "Customer " RESTORE_VARIANT_ERASE_INSTALL : "Customer " RESTORE_VARIANT_UPGRADE_INSTALL));
			plist_dict_set_item(build_identity, "Info", inf);

			// finally add manifest
			plist_dict_set_item(build_identity, "Manifest", manifest);
		}
	} else if (client->restore_variant) {
		build_identity = build_manifest_get_build_identity_for_model_with_variant(client->build_manifest, client->device->hardware_model, client->restore_variant, 1);
	} else if (client->flags & FLAG_ERASE) {
		build_identity = build_manifest_get_build_identity_for_model_with_variant(client->build_manifest, client->device->hardware_model, RESTORE_VARIANT_ERASE_INSTALL, 0);
	} else {
		build_identity = build_manifest_get_build_identity_for_model_with_variant(client->build_manifest, client->device->hardware_model, RESTORE_VARIANT_UPGRADE_INSTALL, 0);
		if (!build_identity) {
			build_identity = build_manifest_get_build_identity_for_model(client->build_manifest, client->device->hardware_model);
		}
	}
	if (build_identity == NULL) {
		logger(LL_ERROR, "Unable to find a matching build identity\n");
		return -1;
	}

	client->macos_variant = build_manifest_get_build_identity_for_model_with_variant(client->build_manifest, client->device->hardware_model, RESTORE_VARIANT_MACOS_RECOVERY_OS, 1);

	/* print information about current build identity */
	build_identity_print_information(build_identity);

	if (client->macos_variant) {
		logger(LL_INFO, "Performing macOS restore\n");
	}

	if (client->mode == MODE_NORMAL && !(client->flags & FLAG_ERASE) && !(client->flags & FLAG_SHSHONLY)) {
		if (client->device_version && (compare_versions(client->device_version, client->version) > 0)) {
			if (client->flags & FLAG_INTERACTIVE) {
				char msgtext[512];
				snprintf(msgtext, 512, "You are trying to DOWNGRADE a %s device with an IPSW for %s while\n"
				    "trying to preserve the user data (Upgrade restore). This *might* work, but\n"
				    "there is a VERY HIGH chance it might FAIL BADLY with COMPLETE DATA LOSS.\n"
				    "If you want to take the risk (and have a backup of your important data!) you may continue.\n"
				    "You have been warned.\n", client->device_version, client->version);
				int pres = prompt_user("WARNING", msgtext);
				if (pres < 0) {
					client->flags |= FLAG_QUIT;
					return -1;
				}
			}
		}
	}

	if (client->flags & FLAG_ERASE && client->flags & FLAG_INTERACTIVE) {
		int pres = prompt_user(
		    "WARNING",
		    "You are about to perform an *ERASE* restore. ALL DATA on the target device will be IRREVERSIBLY DESTROYED. If you want to update your device without erasing the user data, cancel now and restart without -e or --erase command line switch.\n"
		);
		if (pres < 0) {
			client->flags |= FLAG_QUIT;
			return -1;
		}
#if 0
		char input[64];
		printf("################################ [ WARNING ] #################################\n"
		       "# You are about to perform an *ERASE* restore. ALL DATA on the target device #\n"
		       "# will be IRREVERSIBLY DESTROYED. If you want to update your device without  #\n"
		       "# erasing the user data, hit CTRL+C now and restart without -e or --erase    #\n"
		       "# command line switch.                                                       #\n"
		       "# If you want to continue with the ERASE, please type YES and press ENTER.   #\n"
		       "##############################################################################\n");
		while (1) {
			printf("> ");
			fflush(stdout);
			fflush(stdin);
			input[0] = '\0';
			get_user_input(input, 63, 0);
			if (client->flags & FLAG_QUIT) {
				return -1;
			}
			if (*input != '\0' && !strcmp(input, "YES")) {
				break;
			} else {
				printf("Invalid input. Please type YES or hit CTRL+C to abort.\n");
				continue;
			}
		}
#endif
	}

	idevicerestore_progress(client, RESTORE_STEP_PREPARE, 0.0);

	/* check if all components we need are actually there */
	logger(LL_INFO, "Checking IPSW for required components...\n");
	if (build_identity_check_components_in_ipsw(build_identity, client->ipsw) < 0) {
		logger(LL_ERROR, "Could not find all required components in IPSW %s\n", client->ipsw->path);
		return -1;
	}
	logger(LL_INFO, "All required components found in IPSW\n");

	/* Get OS (filesystem) name from build identity */
	char* os_path = NULL;
	if (build_identity_get_component_path(build_identity, "OS", &os_path) < 0) {
		logger(LL_ERROR, "Unable to get path for filesystem component\n");
		return -1;
	}

	/* check if IPSW has OS component 'stored' in ZIP archive, otherwise we need to extract it */
	int needs_os_extraction = 0;
	if (client->ipsw->zip) {
		ipsw_file_handle_t zfile = ipsw_file_open(client->ipsw, os_path);
		if (zfile) {
			if (!zfile->seekable) {
				needs_os_extraction = 1;
			}
			ipsw_file_close(zfile);
		}
	}

	if (needs_os_extraction && !(client->flags & FLAG_SHSHONLY)) {
		char* tmpf = NULL;
		struct stat st;
		if (client->cache_dir) {
			memset(&st, '\0', sizeof(struct stat));
			if (stat(client->cache_dir, &st) < 0) {
				mkdir_with_parents(client->cache_dir, 0755);
			}
			char* ipsw_basename = strdup(path_get_basename(client->ipsw->path));
			char* p = strrchr(ipsw_basename, '.');
			if (p && isalpha(*(p+1))) {
				*p = '\0';
			}
			tmpf = string_build_path(client->cache_dir, ipsw_basename, NULL);
			mkdir_with_parents(tmpf, 0755);
			free(tmpf);
			tmpf = string_build_path(client->cache_dir, ipsw_basename, os_path, NULL);
			free(ipsw_basename);
		} else {
			tmpf = get_temp_filename(NULL);
			client->delete_fs = 1;
		}

		/* check if we already have it extracted */
		uint64_t fssize = 0;
		ipsw_get_file_size(client->ipsw, os_path, &fssize);
		memset(&st, '\0', sizeof(struct stat));
		if (stat(tmpf, &st) == 0) {
			if ((fssize > 0) && ((uint64_t)st.st_size == fssize)) {
				logger(LL_INFO, "Using cached filesystem from '%s'\n", tmpf);
				client->filesystem = tmpf;
			}
		}

		if (!client->filesystem) {
			logger(LL_INFO, "Extracting filesystem from IPSW: %s\n", os_path);
			if (ipsw_extract_to_file_with_progress(client->ipsw, os_path, tmpf, 1) < 0) {
				logger(LL_ERROR, "Unable to extract filesystem from IPSW\n");
				logger(LL_INFO, "Removing %s\n", tmpf);
				unlink(tmpf);
				free(tmpf);
				return -1;
			}
			client->filesystem = tmpf;
		}
	}

	idevicerestore_progress(client, RESTORE_STEP_PREPARE, 0.2);

	/* retrieve shsh blobs if required */
	if (tss_enabled) {
		int stashbag_commit_required = 0;

		if (client->mode == MODE_NORMAL && !(client->flags & FLAG_ERASE) && !(client->flags & FLAG_SHSHONLY)) {
			plist_t node = normal_get_lockdown_value(client, NULL, "HasSiDP");
			uint8_t needs_preboard = 0;
			if (node && plist_get_node_type(node) == PLIST_BOOLEAN) {
				plist_get_bool_val(node, &needs_preboard);
			}
			if (needs_preboard) {
				logger(LL_INFO, "Checking if device requires stashbag...\n");
				plist_t manifest;
				if (get_preboard_manifest(client, build_identity, &manifest) < 0) {
					logger(LL_ERROR, "Unable to create preboard manifest.\n");
					return -1;
				}
				logger(LL_DEBUG, "creating stashbag...\n");
				int err = normal_handle_create_stashbag(client, manifest);
				if (err < 0) {
					if (err == -2) {
						logger(LL_ERROR, "Could not create stashbag (timeout).\n");
					} else {
						logger(LL_ERROR, "An error occurred while creating the stashbag.\n");
					}
					return -1;
				} else if (err == 1) {
					stashbag_commit_required = 1;
				}
				plist_free(manifest);
			}
		}

		if (client->build_major > 8) {
			unsigned char* nonce = NULL;
			unsigned int nonce_size = 0;
			if (get_ap_nonce(client, &nonce, &nonce_size) < 0) {
				/* the first nonce request with older firmware releases can fail and it's OK */
				logger(LL_NOTICE, "Unable to get nonce from device\n");
			}

			if (!client->nonce || (nonce_size != client->nonce_size) || (memcmp(nonce, client->nonce, nonce_size) != 0)) {
				if (client->nonce) {
					free(client->nonce);
				}
				client->nonce = nonce;
				client->nonce_size = nonce_size;
			} else {
				free(nonce);
			}
			if (client->mode == MODE_NORMAL) {
				plist_t ap_params = normal_get_lockdown_value(client, NULL, "ApParameters");
				if (ap_params) {
					if (!client->parameters) {
						client->parameters = plist_new_dict();
					}
					plist_dict_merge(&client->parameters, ap_params);
					plist_t p_sep_nonce = plist_dict_get_item(ap_params, "SepNonce");
					uint64_t sep_nonce_size = 0;
					const char* sep_nonce = plist_get_data_ptr(p_sep_nonce, &sep_nonce_size);
					if (sep_nonce) {
						logger(LL_INFO, "Getting SepNonce in normal mode... ");
						logger_dump_hex(LL_INFO, sep_nonce, sep_nonce_size);
					}
					plist_free(ap_params);
				}
				plist_t req_nonce_slot = plist_access_path(build_identity, 2, "Info", "RequiresNonceSlot");
				if (req_nonce_slot) {
					plist_dict_set_item(client->parameters, "RequiresNonceSlot", plist_copy(req_nonce_slot));
				}
			}
		}

		if (client->flags & FLAG_QUIT) {
			return -1;
		}
		
		if (client->mode == MODE_RESTORE && client->root_ticket) {
			plist_t ap_ticket = plist_new_data((char*)client->root_ticket, client->root_ticket_len);
			if (!ap_ticket) {
				logger(LL_ERROR, "Failed to create ApImg4Ticket node value.\n");
				return -1;
			}
			client->tss = plist_new_dict();
			if (!client->tss) {
				logger(LL_ERROR, "Failed to create ApImg4Ticket node.\n");
				return -1;
			}
			plist_dict_set_item(client->tss, "ApImg4Ticket", ap_ticket);
		} else {
			if (get_tss_response(client, build_identity, &client->tss) < 0) {
				logger(LL_ERROR, "Unable to get SHSH blobs for this device\n");
				return -1;
			}
			if (client->macos_variant) {
				if (get_local_policy_tss_response(client, build_identity, &client->tss_localpolicy) < 0) {
					logger(LL_ERROR, "Unable to get SHSH blobs for this device (local policy)\n");
					return -1;
				}
				if (get_recoveryos_root_ticket_tss_response(client, build_identity, &client->tss_recoveryos_root_ticket) < 0) {
					logger(LL_ERROR, "Unable to get SHSH blobs for this device (recovery OS Root Ticket)\n");
					return -1;
				}
			} else {
				plist_t recovery_variant = plist_access_path(build_identity, 2, "Info", "RecoveryVariant");
				if (recovery_variant) {
					const char* recovery_variant_str = plist_get_string_ptr(recovery_variant, NULL);
					client->recovery_variant = build_manifest_get_build_identity_for_model_with_variant(client->build_manifest, client->device->hardware_model, recovery_variant_str, 1);
					if (!client->recovery_variant) {
						logger(LL_ERROR, "Variant '%s' not found in BuildManifest\n", recovery_variant_str);
						return -1;
					}
					if (get_tss_response(client, client->recovery_variant, &client->tss_recoveryos_root_ticket) < 0) {
						logger(LL_ERROR, "Unable to get SHSH blobs for this device (%s)\n", recovery_variant_str);
						return -1;
					}
				}
			}
		}

		if (stashbag_commit_required) {
			plist_t ticket = plist_dict_get_item(client->tss, "ApImg4Ticket");
			if (!ticket || plist_get_node_type(ticket) != PLIST_DATA) {
				logger(LL_ERROR, "Missing ApImg4Ticket in TSS response for stashbag commit\n");
				return -1;
			}
			logger(LL_INFO, "Committing stashbag...\n");
			int err = normal_handle_commit_stashbag(client, ticket);
			if (err < 0) {
				logger(LL_ERROR, "Could not commit stashbag (%d). Aborting.\n", err);
				return -1;
			}
		}
	}

	if (client->flags & FLAG_QUIT) {
		return -1;
	}
	if (client->flags & FLAG_SHSHONLY) {
		if (!tss_enabled) {
			logger(LL_INFO, "This device does not require a TSS record\n");
			return 0;
		}
		if (!client->tss) {
			logger(LL_ERROR, "could not fetch TSS record\n");
			return -1;
		} else {
			char *bin = NULL;
			uint32_t blen = 0;
			plist_to_bin(client->tss, &bin, &blen);
			if (bin) {
				char zfn[1024];
				if (client->cache_dir) {
					strcpy(zfn, client->cache_dir);
					strcat(zfn, "/shsh");
				} else {
					strcpy(zfn, "shsh");
				}
				mkdir_with_parents(zfn, 0755);
				snprintf(&zfn[0]+strlen(zfn), sizeof(zfn)-strlen(zfn), "/%" PRIu64 "-%s-%s.shsh", client->ecid, client->device->product_type, client->version);
				struct stat fst;
				if (stat(zfn, &fst) != 0) {
					gzFile zf = gzopen(zfn, "wb");
					gzwrite(zf, bin, blen);
					gzclose(zf);
					logger(LL_INFO, "SHSH saved to '%s'\n", zfn);
				} else {
					logger(LL_INFO, "SHSH '%s' already present.\n", zfn);
				}
				free(bin);
			} else {
				logger(LL_ERROR, "could not get TSS record data\n");
			}
			plist_free(client->tss);
			return 0;
		}
	}

	/* verify if we have tss records if required */
	if ((tss_enabled) && (client->tss == NULL)) {
		logger(LL_ERROR, "Unable to proceed without a TSS record.\n");
		return -1;
	}

	if ((tss_enabled) && client->tss) {
		/* fix empty dicts */
		fixup_tss(client->tss);
	}
	idevicerestore_progress(client, RESTORE_STEP_PREPARE, 0.25);
	if (client->flags & FLAG_QUIT) {
		return -1;
	}

	// if the device is in normal mode, place device into recovery mode
	if (client->mode == MODE_NORMAL) {
		logger(LL_INFO, "Entering recovery mode...\n");
		if (normal_enter_recovery(client) < 0) {
			logger(LL_ERROR, "Unable to place device into recovery mode from normal mode\n");
			if (client->tss)
				plist_free(client->tss);
			return -5;
		}
	}

	idevicerestore_progress(client, RESTORE_STEP_PREPARE, 0.3);
	if (client->flags & FLAG_QUIT) {
		return -1;
	}

	if (client->mode == MODE_DFU) {
		// if the device is in DFU mode, place it into recovery mode
		dfu_client_free(client);
		recovery_client_free(client);
#ifdef HAVE_LIMERA1N
		if ((client->flags & FLAG_CUSTOM) && limera1n_is_supported(client->device)) {
			logger(LL_INFO, "connecting to DFU\n");
			if (dfu_client_new(client) < 0) {
				return -1;
			}
			logger(LL_INFO, "exploiting with limera1n\n");
			if (limera1n_exploit(client->device, &client->dfu->client) != 0) {
				logger(LL_ERROR, "limera1n exploit failed\n");
				dfu_client_free(client);
				return -1;
			}
			dfu_client_free(client);
			logger(LL_INFO, "exploited\n");
		}
#endif
		if (dfu_enter_recovery(client, build_identity) < 0) {
			logger(LL_ERROR, "Unable to place device into recovery mode from DFU mode\n");
			if (client->tss)
				plist_free(client->tss);
			return -2;
		}
	} else if (client->mode == MODE_RECOVERY) {
		// device is in recovery mode
		if ((client->build_major > 8) && !(client->flags & FLAG_CUSTOM)) {
			if (!client->image4supported) {
				/* send ApTicket */
				if (recovery_send_ticket(client) < 0) {
					logger(LL_ERROR, "Unable to send APTicket\n");
					return -2;
				}
			}
		}

		mutex_lock(&client->device_event_mutex);

		/* now we load the iBEC */
		if (recovery_send_ibec(client, build_identity) < 0) {
			mutex_unlock(&client->device_event_mutex);
			logger(LL_ERROR, "Unable to send iBEC\n");
			return -2;
		}
		recovery_client_free(client);

		logger(LL_DEBUG, "Waiting for device to disconnect...\n");
		cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 60000);
		if (client->mode != MODE_UNKNOWN || (client->flags & FLAG_QUIT)) {
			mutex_unlock(&client->device_event_mutex);

			if (!(client->flags & FLAG_QUIT)) {
				logger(LL_ERROR, "Device did not disconnect. Possibly invalid iBEC. Reset device and try again.\n");
			}
			return -2;
		}
		recovery_client_free(client);
		logger(LL_DEBUG, "Waiting for device to reconnect in recovery mode...\n");
		cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 60000);
		if (client->mode != MODE_RECOVERY || (client->flags & FLAG_QUIT)) {
			mutex_unlock(&client->device_event_mutex);
			if (!(client->flags & FLAG_QUIT)) {
				logger(LL_ERROR, "Device did not reconnect in recovery mode. Possibly invalid iBEC. Reset device and try again.\n");
			}
			return -2;
		}
		mutex_unlock(&client->device_event_mutex);
	}
	idevicerestore_progress(client, RESTORE_STEP_PREPARE, 0.5);
	if (client->flags & FLAG_QUIT) {
		return -1;
	}

	if (!client->image4supported && (client->build_major > 8)) {
		// we need another tss request with nonce.
		unsigned char* nonce = NULL;
		unsigned int nonce_size = 0;
		int nonce_changed = 0;
		if (get_ap_nonce(client, &nonce, &nonce_size) < 0) {
			logger(LL_ERROR, "Unable to get nonce from device!\n");
			recovery_send_reset(client);
			return -2;
		}

		if (!client->nonce || (nonce_size != client->nonce_size) || (memcmp(nonce, client->nonce, nonce_size) != 0)) {
			nonce_changed = 1;
			if (client->nonce) {
				free(client->nonce);
			}
			client->nonce = nonce;
			client->nonce_size = nonce_size;
		} else {
			free(nonce);
		}

		if (nonce_changed && !(client->flags & FLAG_CUSTOM)) {
			// Welcome iOS5. We have to re-request the TSS with our nonce.
			plist_free(client->tss);
			if (get_tss_response(client, build_identity, &client->tss) < 0) {
				logger(LL_ERROR, "Unable to get SHSH blobs for this device\n");
				return -1;
			}
			if (!client->tss) {
				logger(LL_ERROR, "can't continue without TSS\n");
				return -1;
			}
			fixup_tss(client->tss);
		}
	}
	idevicerestore_progress(client, RESTORE_STEP_PREPARE, 0.7);
	if (client->flags & FLAG_QUIT) {
		return -1;
	}

	// now finally do the magic to put the device into restore mode
	if (client->mode == MODE_RECOVERY) {
		if (recovery_enter_restore(client, build_identity) < 0) {
			logger(LL_ERROR, "Unable to place device into restore mode\n");
			if (client->tss)
				plist_free(client->tss);
			return -2;
		}
		recovery_client_free(client);
	}
	idevicerestore_progress(client, RESTORE_STEP_PREPARE, 0.9);

	if (client->mode != MODE_RESTORE) {
		mutex_lock(&client->device_event_mutex);
		logger(LL_INFO, "Waiting for device to enter restore mode...\n");
		cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 300000);
		if (client->mode != MODE_RESTORE || (client->flags & FLAG_QUIT)) {
			mutex_unlock(&client->device_event_mutex);
			logger(LL_ERROR, "Device failed to enter restore mode.\n");
			if (client->mode == MODE_UNKNOWN) {
				logger(LL_ERROR, "Make sure that usbmuxd is running.\n");
			} else if (client->mode == MODE_RECOVERY || client->mode == MODE_DFU) {
				logger(LL_ERROR, "Device reconnected in %s mode, most likely image personalization failed.\n", client->mode->string);
			}
			return -1;
		}
		mutex_unlock(&client->device_event_mutex);
	}

	// device is finally in restore mode, let's do this
	if (client->mode == MODE_RESTORE) {
		if ((client->flags & FLAG_NO_RESTORE) != 0) {
			logger(LL_INFO, "Device is now in restore mode. Exiting as requested.\n");
			return 0;
		}
		client->ignore_device_add_events = 1;
		logger(LL_INFO, "About to restore device... \n");
		result = restore_device(client, build_identity);
		if (result < 0) {
			logger(LL_ERROR, "Unable to restore device\n");
			return result;
		}
	}

	/* special handling of older AppleTVs as they enter Recovery mode on boot when plugged in to USB */
	if ((strncmp(client->device->product_type, "AppleTV", 7) == 0) && (client->device->product_type[7] < '5')) {
		if (recovery_client_new(client) == 0) {
			if (recovery_set_autoboot(client, 1) == 0) {
				recovery_send_reset(client);
			} else {
				logger(LL_ERROR, "Setting auto-boot failed?!\n");
			}
		} else {
			logger(LL_ERROR, "Could not connect to device in recovery mode.\n");
		}
	}

	if (result == 0) {
		logger(LL_INFO, "DONE\n");
		idevicerestore_progress(client, RESTORE_NUM_STEPS-1, 1.0);
	} else {
		logger(LL_INFO, "RESTORE FAILED\n");
	}

	if (build_identity_needs_free)
		plist_free(build_identity);

	return result;
}

struct idevicerestore_client_t* idevicerestore_client_new(void)
{
	struct idevicerestore_client_t* client = (struct idevicerestore_client_t*) malloc(sizeof(struct idevicerestore_client_t));
	if (client == NULL) {
		logger(LL_ERROR, "Out of memory\n");
		return NULL;
	}
	memset(client, '\0', sizeof(struct idevicerestore_client_t));
	client->mode = MODE_UNKNOWN;
	mutex_init(&client->device_event_mutex);
	cond_init(&client->device_event_cond);
	return client;
}

void idevicerestore_client_free(struct idevicerestore_client_t* client)
{
	if (!client) {
		return;
	}

	if (client->irecv_e_ctx) {
		irecv_device_event_unsubscribe(client->irecv_e_ctx);
	}
	if (client->idevice_e_ctx) {
		idevice_event_unsubscribe();
	}
	cond_destroy(&client->device_event_cond);
	mutex_destroy(&client->device_event_mutex);

	if (client->tss_url) {
		free(client->tss_url);
	}
	if (client->version_data) {
		plist_free(client->version_data);
	}
	if (client->nonce) {
		free(client->nonce);
	}
	if (client->udid) {
		free(client->udid);
	}
	if (client->srnm) {
		free(client->srnm);
	}
	if (client->ipsw) {
		ipsw_close(client->ipsw);
	}
	if (client->filesystem) {
		if (client->delete_fs) {
			unlink(client->filesystem);
		}
		free(client->filesystem);
	}
	free(client->version);
	free(client->build);
	free(client->device_version);
	free(client->device_build);
	if (client->restore_boot_args) {
		free(client->restore_boot_args);
	}
	if (client->cache_dir) {
		free(client->cache_dir);
	}
	if (client->root_ticket) {
		free(client->root_ticket);
	}
	if (client->build_manifest) {
		plist_free(client->build_manifest);
	}
	if (client->firmware_preflight_info) {
		plist_free(client->firmware_preflight_info);
	}
	if (client->preflight_info) {
		plist_free(client->preflight_info);
	}
	free(client->restore_variant);
	free(client);
}

void idevicerestore_set_ecid(struct idevicerestore_client_t* client, uint64_t ecid)
{
	if (!client)
		return;
	client->ecid = ecid;
}

void idevicerestore_set_udid(struct idevicerestore_client_t* client, const char* udid)
{
	if (!client)
		return;
	if (client->udid) {
		free(client->udid);
		client->udid = NULL;
	}
	if (udid) {
		client->udid = strdup(udid);
	}
}

void idevicerestore_set_flags(struct idevicerestore_client_t* client, int flags)
{
	if (!client)
		return;
	client->flags = flags;
}

void idevicerestore_set_ipsw(struct idevicerestore_client_t* client, const char* path)
{
	if (!client)
		return;
	if (client->ipsw) {
		ipsw_close(client->ipsw);
		client->ipsw = NULL;
	}
	if (path) {
		client->ipsw = ipsw_open(path);
	}
}

void idevicerestore_set_cache_path(struct idevicerestore_client_t* client, const char* path)
{
	if (!client)
		return;
	if (client->cache_dir) {
		free(client->cache_dir);
		client->cache_dir = NULL;
	}
	if (path) {
		client->cache_dir = strdup(path);
	}
}

void idevicerestore_set_progress_callback(struct idevicerestore_client_t* client, idevicerestore_progress_cb_t cbfunc, void* userdata)
{
	if (!client)
		return;
	client->progress_cb = cbfunc;
	client->progress_cb_data = userdata;
}

#ifndef IDEVICERESTORE_NOMAIN
static struct idevicerestore_client_t* idevicerestore_client = NULL;

static void handle_signal(int sig)
{
	if (idevicerestore_client) {
		idevicerestore_client->flags |= FLAG_QUIT;
		global_quit_flag++;
		ipsw_cancel();
	}
}

void plain_progress_cb(int step, double step_progress, void* userdata)
{
	printf("progress: %u %f\n", step, step_progress);
	fflush(stdout);
}

static void plain_progress_func(struct progress_info_entry** progress_info, int count)
{
	int i = 0;
	for (i = 0; i < count; i++) {
		if (!progress_info[i]) continue;
		printf("%s: %5.1f\n", progress_info[i]->label, progress_info[i]->progress);
		fflush(stdout);
	}
}

static void tty_print(enum loglevel level, const char* fmt, va_list ap)
{
	switch (level) {
		case 0:
			cprintf(FG_RED STYLE_BRIGHT);
			break;
		case 1:
			cprintf(FG_YELLOW STYLE_BRIGHT);
			break;
		case 2:
			cprintf(STYLE_BRIGHT);
			break;
		default:
			break;
	}

	cvfprintf(stdout, fmt, ap);

	cprintf(COLOR_RESET);
}

int main(int argc, char* argv[])
{
	int opt = 0;
	int optindex = 0;
	char* ipsw = NULL;
	int ipsw_info = 0;
	int result = 0;
	const char* logfile = NULL;

	logger_set_print_func(tty_print);

	struct idevicerestore_client_t* client = idevicerestore_client_new();
	if (client == NULL) {
		logger(LL_ERROR, "Could not create idevicerestore client\n");
		return EXIT_FAILURE;
	}

	idevicerestore_client = client;

#ifdef WIN32
	signal(SIGINT, handle_signal);
	signal(SIGTERM, handle_signal);
	signal(SIGABRT, handle_signal);
#else
	struct sigaction sa;
	memset(&sa, 0, sizeof(struct sigaction));
	sa.sa_handler = handle_signal;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGQUIT, &sa, NULL);
	sa.sa_handler = SIG_IGN;
	sigaction(SIGPIPE, &sa, NULL);
#endif

	if (!isatty(fileno(stdin)) || !isatty(fileno(stdout))) {
		client->flags &= ~FLAG_INTERACTIVE;
	} else {
		client->flags |= FLAG_INTERACTIVE;
	}

#ifdef HAVE_LIMERA1N
#define P_FLAG "p"
#else
#define P_FLAG ""
#endif

	while ((opt = getopt_long(argc, argv, "dhces:xtli:u:nC:kyPRT:zv" P_FLAG, longopts, &optindex)) > 0) {
		switch (opt) {
		case 'h':
			usage(argc, argv, 0);
			return EXIT_SUCCESS;

		case 'd':
			client->flags |= FLAG_DEBUG;
			client->debug_level++;
			if (client->debug_level > 0) {
				log_level = LL_DEBUG;
			}
			break;

		case 'e':
			client->flags |= FLAG_ERASE;
			break;

		case 'c':
			client->flags |= FLAG_CUSTOM;
			break;

		case 's': {
			if (!*optarg) {
				logger(LL_ERROR, "URL argument for --server must not be empty!\n");
				usage(argc, argv, 1);
				return EXIT_FAILURE;
			}
			char *baseurl = NULL;
			if (!strncmp(optarg, "http://", 7) && (strlen(optarg) > 7) && (optarg[7] != '/')) {
				baseurl = optarg+7;
			} else if (!strncmp(optarg, "https://", 8) && (strlen(optarg) > 8) && (optarg[8] != '/')) {
				baseurl = optarg+8;
			}
			if (baseurl) {
				char *p = strchr(baseurl, '/');
				if (!p || *(p+1) == '\0') {
					// no path component, add default path
					const char default_path[] = "/TSS/controller?action=2";
					size_t usize = strlen(optarg)+sizeof(default_path);
					char* newurl = malloc(usize);
					snprintf(newurl, usize, "%s%s", optarg, (p) ? default_path+1 : default_path);
					client->tss_url = newurl;
				} else {
					client->tss_url = strdup(optarg);
				}
			} else {
				logger(LL_ERROR, "URL argument for --server is invalid, must start with http:// or https://\n");
				usage(argc, argv, 1);
				return EXIT_FAILURE;
			}
		}
			break;

		case 'x':
			client->flags |= FLAG_EXCLUDE;
			break;

		case 'l':
			client->flags |= FLAG_LATEST;
			break;

		case 'i':
			if (optarg) {
				char* tail = NULL;
				client->ecid = strtoull(optarg, &tail, 0);
				if (tail && (tail[0] != '\0')) {
					client->ecid = 0;
				}
				if (client->ecid == 0) {
					logger(LL_ERROR, "Could not parse ECID from '%s'\n", optarg);
					return EXIT_FAILURE;
				}
			}
			break;

		case 'u':
			if (!*optarg) {
				logger(LL_ERROR, "UDID must not be empty!\n");
				usage(argc, argv, 1);
				return EXIT_FAILURE;
			}
			client->udid = strdup(optarg);
			break;

		case 't':
			client->flags |= FLAG_SHSHONLY;
			break;

		case 'k':
			client->flags |= FLAG_KEEP_PERS;
			break;

#ifdef HAVE_LIMERA1N
		case 'p':
			client->flags |= FLAG_PWN;
			break;
#endif

		case 'n':
			client->flags |= FLAG_NOACTION;
			break;

		case 'C':
			client->cache_dir = strdup(optarg);
			break;

		case 'y':
			client->flags &= ~FLAG_INTERACTIVE;
			break;

		case 'P':
			idevicerestore_set_progress_callback(client, plain_progress_cb, NULL);
			set_update_progress_func(plain_progress_func);
			set_progress_granularity(0.01); // 1% granularity
			break;

		case 'R':
			client->flags |= FLAG_ALLOW_RESTORE_MODE;
			break;

		case 'z':
			client->flags |= FLAG_NO_RESTORE;
			break;

		case 'v':
			printf("%s %s (libirecovery %s, libtatsu %s)\n", PACKAGE_NAME, PACKAGE_VERSION, irecv_version(), libtatsu_version());
			return EXIT_SUCCESS;

		case 'T': {
			size_t root_ticket_len = 0;
			unsigned char* root_ticket = NULL;
			if (read_file(optarg, (void**)&root_ticket, &root_ticket_len) != 0) {
				return EXIT_FAILURE;
			}
			client->root_ticket = root_ticket;
			client->root_ticket_len = (int)root_ticket_len;
			logger(LL_INFO, "Using ApTicket found at %s length %u\n", optarg, client->root_ticket_len);
			break;
		}

		case 'I':
			ipsw_info = 1;
			break;

		case 1:
			client->flags |= FLAG_IGNORE_ERRORS;
			break;

		case 2:
			free(client->restore_variant);
			client->restore_variant = strdup(optarg);
			break;

		case 3:
			if (!*optarg) {
				logger(LL_ERROR, "logfile must not be empty!\n");
				usage(argc, argv, 1);
				return EXIT_FAILURE;
			}
			logfile = optarg;
			break;

		default:
			usage(argc, argv, 1);
			return EXIT_FAILURE;
		}
	}

	if (ipsw_info) {
		if (argc-optind != 1) {
			logger(LL_ERROR, "--ipsw-info requires an IPSW path.\n");
			usage(argc, argv, 1);
			return EXIT_FAILURE;
		}
		return (ipsw_print_info(*(argv + optind)) == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
	}

	if (((argc-optind) == 1) || (client->flags & FLAG_PWN) || (client->flags & FLAG_LATEST)) {
		argc -= optind;
		argv += optind;

		ipsw = argv[0];
	} else {
		usage(argc, argv, 1);
		return EXIT_FAILURE;
	}

	if ((client->flags & FLAG_LATEST) && (client->flags & FLAG_CUSTOM)) {
		logger(LL_ERROR, "You can't use --custom and --latest options at the same time.\n");
		return EXIT_FAILURE;
	}

	if (!logfile) {
		char logfn[256];
		int64_t timestamp = time(NULL);
		if (client->ecid) {
			snprintf(logfn, sizeof(logfn), "restore_%016" PRIx64 "_%" PRIi64 ".log", client->ecid, timestamp);
		} else if (client->udid) {
			snprintf(logfn, sizeof(logfn), "restore_%s_%" PRIi64 ".log", client->udid, timestamp);
		} else {
			snprintf(logfn, sizeof(logfn), "restore_%" PRIi64 ".log", timestamp);
		}
		logger_set_logfile(logfn);
	} else {
		logger_set_logfile(logfile);
	}

	logger(LL_INFO, "%s %s (libirecovery %s, libtatsu %s)\n", PACKAGE_NAME, PACKAGE_VERSION, irecv_version(), libtatsu_version());

	if (ipsw) {
		// verify if ipsw file exists
		client->ipsw = ipsw_open(ipsw);
		if (!client->ipsw) {
			logger(LL_ERROR, "Firmware file %s cannot be opened.\n", ipsw);
			return -1;
		}
	}

	curl_global_init(CURL_GLOBAL_ALL);

	client->flags |= FLAG_IN_PROGRESS;
	result = idevicerestore_start(client);
	client->flags &= ~FLAG_IN_PROGRESS;

	idevicerestore_client_free(client);

	curl_global_cleanup();

	return (result == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}
#endif

irecv_device_t get_irecv_device(struct idevicerestore_client_t *client)
{
	int mode = _MODE_UNKNOWN;

	if (client->mode) {
		mode = client->mode->index;
	}

	switch (mode) {
	case _MODE_RESTORE:
		return restore_get_irecv_device(client);

	case _MODE_NORMAL:
		return normal_get_irecv_device(client);

	case _MODE_DFU:
	case _MODE_PORTDFU:
	case _MODE_RECOVERY:
		return dfu_get_irecv_device(client);

	default:
		return NULL;
	}
}

int is_image4_supported(struct idevicerestore_client_t* client)
{
	int res = 0;
	int mode = _MODE_UNKNOWN;

	if (client->mode) {
		mode = client->mode->index;
	}

	switch (mode) {
	case _MODE_NORMAL:
		res = normal_is_image4_supported(client);
		break;
	case _MODE_RESTORE:
		res = restore_is_image4_supported(client);
		break;
	case _MODE_DFU:
		res = dfu_is_image4_supported(client);
		break;
	case _MODE_RECOVERY:
		res = recovery_is_image4_supported(client);
		break;
	default:
		logger(LL_ERROR, "Device is in an invalid state\n");
		return 0;
	}
	return res;
}

int get_ap_nonce(struct idevicerestore_client_t* client, unsigned char** nonce, unsigned int* nonce_size)
{
	int mode = _MODE_UNKNOWN;

	*nonce = NULL;
	*nonce_size = 0;

	if (client->mode) {
		mode = client->mode->index;
	}

	switch (mode) {
	case _MODE_NORMAL:
		logger(LL_INFO, "Getting ApNonce in Normal mode... ");
		if (normal_get_ap_nonce(client, nonce, nonce_size) < 0) {
			logger(LL_INFO, "failed\n");
			return -1;
		}
		break;
	case _MODE_DFU:
		logger(LL_INFO, "Getting ApNonce in DFU mode... ");
		if (dfu_get_ap_nonce(client, nonce, nonce_size) < 0) {
			logger(LL_INFO, "failed\n");
			return -1;
		}
		break;
	case _MODE_RECOVERY:
		logger(LL_INFO, "Getting ApNonce in Recovery mode... ");
		if (recovery_get_ap_nonce(client, nonce, nonce_size) < 0) {
			logger(LL_INFO, "failed\n");
			return -1;
		}
		break;

	default:
		logger(LL_INFO, "Getting ApNonce failed\n");
		logger(LL_ERROR, "Device is in an invalid state\n");
		return -1;
	}

	logger_dump_hex(LL_INFO, *nonce, *nonce_size);

	return 0;
}

int get_sep_nonce(struct idevicerestore_client_t* client, unsigned char** nonce, unsigned int* nonce_size)
{
	int mode = _MODE_UNKNOWN;

	*nonce = NULL;
	*nonce_size = 0;

	if (client->mode) {
		mode = client->mode->index;
	}

	switch (mode) {
	case _MODE_NORMAL:
		logger(LL_INFO, "Getting SepNonce in normal mode... ");
		if (normal_get_sep_nonce(client, nonce, nonce_size) < 0) {
			logger(LL_INFO, "failed\n");
			return -1;
		}
		break;
	case _MODE_DFU:
		logger(LL_INFO, "Getting SepNonce in dfu mode... ");
		if (dfu_get_sep_nonce(client, nonce, nonce_size) < 0) {
			logger(LL_INFO, "failed\n");
			return -1;
		}
		break;
	case _MODE_RECOVERY:
		logger(LL_INFO, "Getting SepNonce in recovery mode... ");
		if (recovery_get_sep_nonce(client, nonce, nonce_size) < 0) {
			logger(LL_INFO, "failed\n");
			return -1;
		}
		break;

	default:
		logger(LL_INFO, "Getting SepNonce failed\n");
		logger(LL_ERROR, "Device is in an invalid state\n");
		return -1;
	}

	logger_dump_hex(LL_INFO, *nonce, *nonce_size);

	return 0;
}

plist_t build_manifest_get_build_identity_for_model_with_variant(plist_t build_manifest, const char *hardware_model, const char *variant, int exact)
{
	plist_t build_identities_array = plist_dict_get_item(build_manifest, "BuildIdentities");
	if (!build_identities_array || plist_get_node_type(build_identities_array) != PLIST_ARRAY) {
		logger(LL_ERROR, "Unable to find build identities node\n");
		return NULL;
	}

	uint32_t i;
	for (i = 0; i < plist_array_get_size(build_identities_array); i++) {
		plist_t ident = plist_array_get_item(build_identities_array, i);
		if (!ident || plist_get_node_type(ident) != PLIST_DICT) {
			continue;
		}
		plist_t info_dict = plist_dict_get_item(ident, "Info");
		if (!info_dict || plist_get_node_type(ident) != PLIST_DICT) {
			continue;
		}
		plist_t devclass = plist_dict_get_item(info_dict, "DeviceClass");
		if (!devclass || plist_get_node_type(devclass) != PLIST_STRING) {
			continue;
		}
		const char *str = plist_get_string_ptr(devclass, NULL);
		if (strcasecmp(str, hardware_model) != 0) {
			continue;
		}
		if (variant) {
			plist_t rvariant = plist_dict_get_item(info_dict, "Variant");
			if (!rvariant || plist_get_node_type(rvariant) != PLIST_STRING) {
				continue;
			}
			str = plist_get_string_ptr(rvariant, NULL);
			if (strcmp(str, variant) != 0) {
				/* if it's not a full match, let's try a partial match, but ignore "*Research*" */
				if (!exact && strstr(str, variant) && !strstr(str, "Research")) {
					return ident;
				}
				continue;
			} else {
				return ident;
			}
		} else {
			return ident;
		}
	}

	return NULL;
}

plist_t build_manifest_get_build_identity_for_model(plist_t build_manifest, const char *hardware_model)
{
	return build_manifest_get_build_identity_for_model_with_variant(build_manifest, hardware_model, NULL, 0);
}

int get_preboard_manifest(struct idevicerestore_client_t* client, plist_t build_identity, plist_t* manifest)
{
	plist_t request = NULL;
	*manifest = NULL;

	if (!client->image4supported) {
		return -1;
	}

	/* populate parameters */
	plist_t parameters = plist_new_dict();

	plist_t overrides = plist_new_dict();
	plist_dict_set_item(overrides, "@APTicket", plist_new_bool(1));
	plist_dict_set_item(overrides, "ApProductionMode", plist_new_uint(0));
	plist_dict_set_item(overrides, "ApSecurityDomain", plist_new_uint(1));

	plist_dict_set_item(parameters, "ApProductionMode", plist_new_bool(0));
	plist_dict_set_item(parameters, "ApSecurityMode", plist_new_bool(0));
	plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(1));

	tss_parameters_add_from_manifest(parameters, build_identity, true);

	/* create basic request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		logger(LL_ERROR, "Unable to create TSS request\n");
		plist_free(parameters);
		return -1;
	}

	/* add common tags from manifest */
	if (tss_request_add_common_tags(request, parameters, overrides) < 0) {
		logger(LL_ERROR, "Unable to add common tags\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	plist_dict_set_item(parameters, "_OnlyFWComponents", plist_new_bool(1));

	/* add tags from manifest */
	if (tss_request_add_ap_tags(request, parameters, NULL) < 0) {
		logger(LL_ERROR, "Unable to add ap tags\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	plist_t local_manifest = NULL;
	int res = img4_create_local_manifest(request, build_identity, &local_manifest);

	*manifest = local_manifest;

	plist_free(request);
	plist_free(parameters);
	plist_free(overrides);

	return res;
}

int get_tss_response(struct idevicerestore_client_t* client, plist_t build_identity, plist_t* tss)
{
	plist_t request = NULL;
	plist_t response = NULL;
	*tss = NULL;

	if ((client->build_major <= 8) || (client->flags & FLAG_CUSTOM)) {
		logger(LL_ERROR, "checking for local shsh\n");

		/* first check for local copy */
		char zfn[1024];
		if (client->version) {
			if (client->cache_dir) {
				snprintf(zfn, sizeof(zfn), "%s/shsh/%" PRIu64 "-%s-%s.shsh", client->cache_dir, client->ecid, client->device->product_type, client->version);
			} else {
				snprintf(zfn, sizeof(zfn), "shsh/%" PRIu64 "-%s-%s.shsh", client->ecid, client->device->product_type, client->version);
			}
			struct stat fst;
			if (stat(zfn, &fst) == 0) {
				gzFile zf = gzopen(zfn, "rb");
				if (zf) {
					int blen = 0;
					int readsize = 16384;
					int bufsize = readsize;
					char* bin = (char*)malloc(bufsize);
					char* p = bin;
					do {
						int bytes_read = gzread(zf, p, readsize);
						if (bytes_read < 0) {
							logger(LL_ERROR, "Error reading gz compressed data\n");
							exit(EXIT_FAILURE);
						}
						blen += bytes_read;
						if (bytes_read < readsize) {
							if (gzeof(zf)) {
								bufsize += bytes_read;
								break;
							}
						}
						bufsize += readsize;
						bin = realloc(bin, bufsize);
						p = bin + blen;
					} while (!gzeof(zf));
					gzclose(zf);
					if (blen > 0) {
						if (memcmp(bin, "bplist00", 8) == 0) {
							plist_from_bin(bin, blen, tss);
						} else {
							plist_from_xml(bin, blen, tss);
						}
					}
					free(bin);
				}
			} else {
				logger(LL_ERROR, "no local file %s\n", zfn);
			}
		} else {
			logger(LL_ERROR, "No version found?!\n");
		}
	}

	if (*tss) {
		logger(LL_INFO, "Using cached SHSH\n");
		return 0;
	} else {
		logger(LL_INFO, "Trying to fetch new SHSH blob\n");
	}

	/* populate parameters */
	plist_t parameters = plist_new_dict();
	plist_dict_merge(&parameters, client->parameters);

	plist_dict_set_item(parameters, "ApECID", plist_new_uint(client->ecid));
	if (client->nonce) {
		plist_dict_set_item(parameters, "ApNonce", plist_new_data((const char*)client->nonce, client->nonce_size));
	}

	if (!plist_dict_get_item(parameters, "SepNonce")) {
		unsigned char* sep_nonce = NULL;
		unsigned int sep_nonce_size = 0;
		get_sep_nonce(client, &sep_nonce, &sep_nonce_size);
		if (sep_nonce) {
			plist_dict_set_item(parameters, "ApSepNonce", plist_new_data((const char*)sep_nonce, sep_nonce_size));
			free(sep_nonce);
		}
	}

	plist_dict_set_item(parameters, "ApProductionMode", plist_new_bool(1));
	if (client->image4supported) {
		plist_dict_set_item(parameters, "ApSecurityMode", plist_new_bool(1));
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(1));
	} else {
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(0));
	}

	tss_parameters_add_from_manifest(parameters, build_identity, true);

	/* create basic request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		logger(LL_ERROR, "Unable to create TSS request\n");
		plist_free(parameters);
		return -1;
	}

	/* add common tags from manifest */
	if (tss_request_add_common_tags(request, parameters, NULL) < 0) {
		logger(LL_ERROR, "Unable to add common tags to TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	/* add tags from manifest */
	if (tss_request_add_ap_tags(request, parameters, NULL) < 0) {
		logger(LL_ERROR, "Unable to add common tags to TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	if (client->image4supported) {
		/* add personalized parameters */
		if (tss_request_add_ap_img4_tags(request, parameters) < 0) {
			logger(LL_ERROR, "Unable to add img4 tags to TSS request\n");
			plist_free(request);
			plist_free(parameters);
			return -1;
		}
	} else {
		/* add personalized parameters */
		if (tss_request_add_ap_img3_tags(request, parameters) < 0) {
			logger(LL_ERROR, "Unable to add img3 tags to TSS request\n");
			plist_free(request);
			plist_free(parameters);
			return -1;
		}
	}

	if (client->mode == MODE_NORMAL) {
		/* normal mode; request baseband ticket aswell */
		plist_t pinfo = NULL;
		normal_get_firmware_preflight_info(client, &pinfo);
		if (pinfo) {
			plist_dict_copy_data(parameters, pinfo, "BbNonce", "Nonce");
			plist_dict_copy_uint(parameters, pinfo, "BbChipID", "ChipID");
			plist_dict_copy_uint(parameters, pinfo, "BbGoldCertId", "CertID");
			plist_dict_copy_data(parameters, pinfo, "BbSNUM", "ChipSerialNo");

			if (plist_dict_get_item(parameters, "BbSNUM")) {
				/* add baseband parameters */
				tss_request_add_baseband_tags(request, parameters, NULL);

				plist_dict_copy_uint(parameters, pinfo, "eUICC,ChipID", "EUICCChipID");
				if (plist_dict_get_uint(parameters, "eUICC,ChipID") >= 5) {
					plist_dict_copy_data(parameters, pinfo, "eUICC,EID", "EUICCCSN");
					plist_dict_copy_data(parameters, pinfo, "eUICC,RootKeyIdentifier", "EUICCCertIdentifier");
					plist_dict_copy_data(parameters, pinfo, "EUICCGoldNonce", NULL);
					plist_dict_copy_data(parameters, pinfo, "EUICCMainNonce", NULL);

					/* add vinyl parameters */
					tss_request_add_vinyl_tags(request, parameters, NULL);
				}
			}
		}
		client->firmware_preflight_info = pinfo;
		pinfo = NULL;

		normal_get_preflight_info(client, &pinfo);
		client->preflight_info = pinfo;
	}

	/* send request and grab response */
	response = tss_request_send(request, client->tss_url);
	if (response == NULL) {
		logger(LL_INFO, "ERROR: Unable to send TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	logger(LL_INFO, "Received SHSH blobs\n");

	plist_free(request);
	plist_free(parameters);

	*tss = response;

	return 0;
}

int get_recoveryos_root_ticket_tss_response(struct idevicerestore_client_t* client, plist_t build_identity, plist_t* tss)
{
	plist_t request = NULL;
	plist_t response = NULL;
	*tss = NULL;

	/* populate parameters */
	plist_t parameters = plist_new_dict();

	/* ApECID */
	plist_dict_set_item(parameters, "ApECID", plist_new_uint(client->ecid));
	plist_dict_set_item(parameters, "Ap,LocalBoot", plist_new_bool(0));

	/* ApNonce */
	if (client->nonce) {
		plist_dict_set_item(parameters, "ApNonce", plist_new_data((const char*)client->nonce, client->nonce_size));
	}
	unsigned char* sep_nonce = NULL;
	unsigned int sep_nonce_size = 0;
	get_sep_nonce(client, &sep_nonce, &sep_nonce_size);

	/* ApSepNonce */
	if (sep_nonce) {
		plist_dict_set_item(parameters, "ApSepNonce", plist_new_data((const char*)sep_nonce, sep_nonce_size));
		free(sep_nonce);
	}

	/* ApProductionMode */
	plist_dict_set_item(parameters, "ApProductionMode", plist_new_bool(1));

	/* ApSecurityMode */
	if (client->image4supported) {
		plist_dict_set_item(parameters, "ApSecurityMode", plist_new_bool(1));
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(1));
	} else {
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(0));
	}

	tss_parameters_add_from_manifest(parameters, build_identity, true);

	/* create basic request */
	/* Adds @HostPlatformInfo, @VersionInfo, @UUID */
	request = tss_request_new(NULL);
	if (request == NULL) {
		logger(LL_ERROR, "Unable to create TSS request\n");
		plist_free(parameters);
		return -1;
	}

	/* add common tags from manifest */
	/* Adds Ap,OSLongVersion, ApNonce, @ApImg4Ticket */
	if (tss_request_add_ap_img4_tags(request, parameters) < 0) {
		logger(LL_ERROR, "Unable to add AP IMG4 tags to TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	/* add AP tags from manifest */
	if (tss_request_add_common_tags(request, parameters, NULL) < 0) {
		logger(LL_ERROR, "Unable to add common tags to TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	/* add AP tags from manifest */
	/* Fills digests & co */
	if (tss_request_add_ap_recovery_tags(request, parameters, NULL) < 0) {
		logger(LL_ERROR, "Unable to add common tags to TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	/* send request and grab response */
	response = tss_request_send(request, client->tss_url);
	if (response == NULL) {
		logger(LL_INFO, "ERROR: Unable to send TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}
	// request_add_ap_tags

	logger(LL_INFO, "Received SHSH blobs\n");

	plist_free(request);
	plist_free(parameters);

	*tss = response;

	return 0;
}

int get_recovery_os_local_policy_tss_response(
				struct idevicerestore_client_t* client,
				plist_t build_identity,
				plist_t* tss,
				plist_t args)
{
	plist_t request = NULL;
	plist_t response = NULL;
	*tss = NULL;

	/* populate parameters */
	plist_t parameters = plist_new_dict();
	plist_dict_set_item(parameters, "ApECID", plist_new_uint(client->ecid));
	plist_dict_set_item(parameters, "Ap,LocalBoot", plist_new_bool(1));

	plist_dict_set_item(parameters, "ApProductionMode", plist_new_bool(1));
	if (client->image4supported) {
		plist_dict_set_item(parameters, "ApSecurityMode", plist_new_bool(1));
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(1));
	} else {
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(0));
	}

	tss_parameters_add_from_manifest(parameters, build_identity, true);

	// Add Ap,LocalPolicy
	uint8_t digest[SHA384_DIGEST_LENGTH];
	sha384(lpol_file, lpol_file_length, digest);
	plist_t lpol = plist_new_dict();
	plist_dict_set_item(lpol, "Digest", plist_new_data((char*)digest, SHA384_DIGEST_LENGTH));
	plist_dict_set_item(lpol, "Trusted", plist_new_bool(1));
	plist_dict_set_item(parameters, "Ap,LocalPolicy", lpol);

	plist_dict_copy_data(parameters, args, "Ap,NextStageIM4MHash", NULL);
	plist_dict_copy_data(parameters, args, "Ap,RecoveryOSPolicyNonceHash", NULL);

	plist_t vol_uuid_node = plist_dict_get_item(args, "Ap,VolumeUUID");
	char* vol_uuid_str = NULL;
	plist_get_string_val(vol_uuid_node, &vol_uuid_str);
	unsigned int vuuid[16];
	unsigned char vol_uuid[16];
	if (sscanf(vol_uuid_str, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", &vuuid[0], &vuuid[1], &vuuid[2], &vuuid[3], &vuuid[4], &vuuid[5], &vuuid[6], &vuuid[7], &vuuid[8], &vuuid[9], &vuuid[10], &vuuid[11], &vuuid[12], &vuuid[13], &vuuid[14], &vuuid[15]) != 16) {
		logger(LL_ERROR, "Failed to parse Ap,VolumeUUID (%s)\n", vol_uuid_str);
		free(vol_uuid_str);
		return -1;
	}
	free(vol_uuid_str);
	int i;
	for (i = 0; i < 16; i++) {
		vol_uuid[i] = (unsigned char)vuuid[i];
	}
	plist_dict_set_item(parameters, "Ap,VolumeUUID", plist_new_data((char*)vol_uuid, 16));

	/* create basic request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		logger(LL_ERROR, "Unable to create TSS request\n");
		plist_free(parameters);
		return -1;
	}

	/* add common tags from manifest */
	if (tss_request_add_local_policy_tags(request, parameters) < 0) {
		logger(LL_ERROR, "Unable to add common tags to TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	/* send request and grab response */
	response = tss_request_send(request, client->tss_url);
	if (response == NULL) {
		logger(LL_INFO, "ERROR: Unable to send TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	logger(LL_INFO, "Received SHSH blobs\n");

	plist_free(request);
	plist_free(parameters);

	*tss = response;

	return 0;
}

int get_local_policy_tss_response(struct idevicerestore_client_t* client, plist_t build_identity, plist_t* tss)
{
	plist_t request = NULL;
	plist_t response = NULL;
	*tss = NULL;

	/* populate parameters */
	plist_t parameters = plist_new_dict();
	plist_dict_set_item(parameters, "ApECID", plist_new_uint(client->ecid));
	plist_dict_set_item(parameters, "Ap,LocalBoot", plist_new_bool(0));
	if (client->nonce) {
		plist_dict_set_item(parameters, "ApNonce", plist_new_data((const char*)client->nonce, client->nonce_size));
	}
	unsigned char* sep_nonce = NULL;
	unsigned int sep_nonce_size = 0;
	get_sep_nonce(client, &sep_nonce, &sep_nonce_size);

	if (sep_nonce) {
		plist_dict_set_item(parameters, "ApSepNonce", plist_new_data((const char*)sep_nonce, sep_nonce_size));
		free(sep_nonce);
	}

	plist_dict_set_item(parameters, "ApProductionMode", plist_new_bool(1));
	if (client->image4supported) {
		plist_dict_set_item(parameters, "ApSecurityMode", plist_new_bool(1));
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(1));
	} else {
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(0));
	}

	tss_parameters_add_from_manifest(parameters, build_identity, true);

	// Add Ap,LocalPolicy
	uint8_t digest[SHA384_DIGEST_LENGTH];
	sha384(lpol_file, lpol_file_length, digest);
	plist_t lpol = plist_new_dict();
	plist_dict_set_item(lpol, "Digest", plist_new_data((char*)digest, SHA384_DIGEST_LENGTH));
	plist_dict_set_item(lpol, "Trusted", plist_new_bool(1));
	plist_dict_set_item(parameters, "Ap,LocalPolicy", lpol);

	// Add Ap,NextStageIM4MHash
	// Get previous TSS ticket
	uint8_t* ticket = NULL;
	uint32_t ticket_length = 0;
	tss_response_get_ap_img4_ticket(client->tss, &ticket, &ticket_length);
	// Hash it and add it as Ap,NextStageIM4MHash
	uint8_t hash[SHA384_DIGEST_LENGTH];
	sha384(ticket, ticket_length, hash);
	plist_dict_set_item(parameters, "Ap,NextStageIM4MHash", plist_new_data((char*)hash, SHA384_DIGEST_LENGTH));

	/* create basic request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		logger(LL_ERROR, "Unable to create TSS request\n");
		plist_free(parameters);
		return -1;
	}

	/* add common tags from manifest */
	if (tss_request_add_local_policy_tags(request, parameters) < 0) {
		logger(LL_ERROR, "Unable to add common tags to TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	/* send request and grab response */
	response = tss_request_send(request, client->tss_url);
	if (response == NULL) {
		logger(LL_INFO, "ERROR: Unable to send TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	logger(LL_INFO, "Received SHSH blobs\n");

	plist_free(request);
	plist_free(parameters);

	*tss = response;

	return 0;
}

void fixup_tss(plist_t tss)
{
	plist_t node;
	plist_t node2;
	node = plist_dict_get_item(tss, "RestoreLogo");
	if (node && (plist_get_node_type(node) == PLIST_DICT) && (plist_dict_get_size(node) == 0)) {
		node2 = plist_dict_get_item(tss, "AppleLogo");
		if (node2 && (plist_get_node_type(node2) == PLIST_DICT)) {
			plist_dict_remove_item(tss, "RestoreLogo");
			plist_dict_set_item(tss, "RestoreLogo", plist_copy(node2));
		}
	}
	node = plist_dict_get_item(tss, "RestoreDeviceTree");
	if (node && (plist_get_node_type(node) == PLIST_DICT) && (plist_dict_get_size(node) == 0)) {
		node2 = plist_dict_get_item(tss, "DeviceTree");
		if (node2 && (plist_get_node_type(node2) == PLIST_DICT)) {
			plist_dict_remove_item(tss, "RestoreDeviceTree");
			plist_dict_set_item(tss, "RestoreDeviceTree", plist_copy(node2));
		}
	}
	node = plist_dict_get_item(tss, "RestoreKernelCache");
	if (node && (plist_get_node_type(node) == PLIST_DICT) && (plist_dict_get_size(node) == 0)) {
		node2 = plist_dict_get_item(tss, "KernelCache");
		if (node2 && (plist_get_node_type(node2) == PLIST_DICT)) {
			plist_dict_remove_item(tss, "RestoreKernelCache");
			plist_dict_set_item(tss, "RestoreKernelCache", plist_copy(node2));
		}
	}
}

int build_manifest_get_identity_count(plist_t build_manifest)
{
	// fetch build identities array from BuildManifest
	plist_t build_identities_array = plist_dict_get_item(build_manifest, "BuildIdentities");
	if (!build_identities_array || plist_get_node_type(build_identities_array) != PLIST_ARRAY) {
		logger(LL_ERROR, "Unable to find build identities node\n");
		return -1;
	}
	return plist_array_get_size(build_identities_array);
}

int extract_component(ipsw_archive_t ipsw, const char* path, void** component_data, size_t* component_size)
{
	char* component_name = NULL;
	if (!ipsw || !path || !component_data || !component_size) {
		return -1;
	}

	component_name = strrchr(path, '/');
	if (component_name != NULL)
		component_name++;
	else
		component_name = (char*) path;

	logger(LL_INFO, "Extracting %s (%s)...\n", component_name, path);
	if (ipsw_extract_to_memory(ipsw, path, component_data, component_size) < 0) {
		logger(LL_ERROR, "Unable to extract %s from %s\n", component_name, ipsw->path);
		return -1;
	}

	return 0;
}

int personalize_component(struct idevicerestore_client_t* client, const char *component_name, const void* component_data, size_t component_size, plist_t tss_response, void** personalized_component, size_t* personalized_component_size)
{
	void* component_blob = NULL;
	void* stitched_component = NULL;
	size_t stitched_component_size = 0;

	if (tss_response && plist_dict_get_item(tss_response, "ApImg4Ticket")) {
		/* stitch ApImg4Ticket into IMG4 file */
		img4_stitch_component(component_name, component_data, component_size, client->parameters, tss_response, &stitched_component, &stitched_component_size);
	} else {
		/* try to get blob for current component from tss response */
		if (tss_response && tss_response_get_blob_by_entry(tss_response, component_name, (unsigned char**)&component_blob) < 0) {
			logger(LL_DEBUG, "NOTE: No SHSH blob found for component %s\n", component_name);
		}

		if (component_blob != NULL) {
			if (img3_stitch_component(component_name, component_data, component_size, component_blob, 64, &stitched_component, &stitched_component_size) < 0) {
				logger(LL_ERROR, "Unable to replace %s IMG3 signature\n", component_name);
				free(component_blob);
				return -1;
			}
		} else {
			logger(LL_INFO, "Not personalizing component %s...\n", component_name);
			stitched_component = (unsigned char*)malloc(component_size);
			if (stitched_component) {
				stitched_component_size = component_size;
				memcpy(stitched_component, component_data, component_size);
			}
		}
	}
	free(component_blob);

	if (client->flags & FLAG_KEEP_PERS) {
		write_file(component_name, stitched_component, stitched_component_size);
	}

	*personalized_component = stitched_component;
	*personalized_component_size = stitched_component_size;
	return 0;
}

int build_manifest_check_compatibility(plist_t build_manifest, const char* product)
{
	int res = -1;
	plist_t node = plist_dict_get_item(build_manifest, "SupportedProductTypes");
	if (!node || (plist_get_node_type(node) != PLIST_ARRAY)) {
		logger(LL_DEBUG, "%s: ERROR: SupportedProductTypes key missing\n", __func__);
		logger(LL_DEBUG, "%s: WARNING: If attempting to install iPhoneOS 2.x, be advised that Restore.plist does not contain the\n", __func__);
		logger(LL_DEBUG, "%s: WARNING: key 'SupportedProductTypes'. Recommendation is to manually add it to the Restore.plist.\n", __func__);
		return -1;
	}
	uint32_t pc = plist_array_get_size(node);
	uint32_t i;
	for (i = 0; i < pc; i++) {
		plist_t prod = plist_array_get_item(node, i);
		if (plist_get_node_type(prod) == PLIST_STRING) {
			char *val = NULL;
			plist_get_string_val(prod, &val);
			if (val && (strcmp(val, product) == 0)) {
				res = 0;
				free(val);
				break;
			}
		}
	}
	return res;
}

void build_manifest_get_version_information(plist_t build_manifest, struct idevicerestore_client_t* client)
{
	plist_t node = NULL;
	client->version = NULL;
	client->build = NULL;

	node = plist_dict_get_item(build_manifest, "ProductVersion");
	if (!node || plist_get_node_type(node) != PLIST_STRING) {
		logger(LL_ERROR, "Unable to find ProductVersion node\n");
		return;
	}
	plist_get_string_val(node, &client->version);

	node = plist_dict_get_item(build_manifest, "ProductBuildVersion");
	if (!node || plist_get_node_type(node) != PLIST_STRING) {
		logger(LL_ERROR, "Unable to find ProductBuildVersion node\n");
		return;
	}
	plist_get_string_val(node, &client->build);

	client->build_major = strtoul(client->build, NULL, 10);
}

void build_identity_print_information(plist_t build_identity)
{
	char* value = NULL;
	plist_t info_node = NULL;
	plist_t node = NULL;

	info_node = plist_dict_get_item(build_identity, "Info");
	if (!info_node || plist_get_node_type(info_node) != PLIST_DICT) {
		logger(LL_ERROR, "Unable to find Info node\n");
		return;
	}

	node = plist_dict_get_item(info_node, "Variant");
	if (!node || plist_get_node_type(node) != PLIST_STRING) {
		logger(LL_ERROR, "Unable to find Variant node\n");
		return;
	}
	plist_get_string_val(node, &value);

	logger(LL_INFO, "Variant: %s\n", value);

	if (strstr(value, RESTORE_VARIANT_UPGRADE_INSTALL))
		logger(LL_INFO, "This restore will update the device without erasing user data.\n");
	else if (strstr(value, RESTORE_VARIANT_ERASE_INSTALL))
		logger(LL_INFO, "This restore will erase all device data.\n");
	else
		logger(LL_INFO, "Unknown Variant '%s'\n", value);

	free(value);

	info_node = NULL;
	node = NULL;
}

int build_identity_check_components_in_ipsw(plist_t build_identity, ipsw_archive_t ipsw)
{
	plist_t manifest_node = plist_dict_get_item(build_identity, "Manifest");
	if (!manifest_node || plist_get_node_type(manifest_node) != PLIST_DICT) {
		return -1;
	}
	int res = 0;
	plist_dict_iter iter = NULL;
	plist_dict_new_iter(manifest_node, &iter);
	plist_t node = NULL;
	char *key = NULL;
	do {
		node = NULL;
		key = NULL;
		plist_dict_next_item(manifest_node, iter, &key, &node);
		if (key && node) {
			plist_t path = plist_access_path(node, 2, "Info", "Path");
			if (path) {
				char *comp_path = NULL;
				plist_get_string_val(path, &comp_path);
				if (comp_path) {
					if (!ipsw_file_exists(ipsw, comp_path)) {
						logger(LL_ERROR, "%s file %s not found in IPSW\n", key, comp_path);
						res = -1;
					}
					free(comp_path);
				}
			}
		}
		free(key);
	} while (node);
	return res;
}

int build_identity_has_component(plist_t build_identity, const char* component)
{
	plist_t manifest_node = plist_dict_get_item(build_identity, "Manifest");
	if (!manifest_node || plist_get_node_type(manifest_node) != PLIST_DICT) {
		return 0;
	}

	plist_t component_node = plist_dict_get_item(manifest_node, component);
	if (!component_node || plist_get_node_type(component_node) != PLIST_DICT) {
		return 0;
	}

	return 1;
}

int build_identity_get_component_path(plist_t build_identity, const char* component, char** path)
{
	char* filename = NULL;

	plist_t manifest_node = plist_dict_get_item(build_identity, "Manifest");
	if (!manifest_node || plist_get_node_type(manifest_node) != PLIST_DICT) {
		logger(LL_ERROR, "Unable to find manifest node\n");
		if (filename)
			free(filename);
		return -1;
	}

	plist_t component_node = plist_dict_get_item(manifest_node, component);
	if (!component_node || plist_get_node_type(component_node) != PLIST_DICT) {
		logger(LL_ERROR, "Unable to find component node for %s\n", component);
		if (filename)
			free(filename);
		return -1;
	}

	plist_t component_info_node = plist_dict_get_item(component_node, "Info");
	if (!component_info_node || plist_get_node_type(component_info_node) != PLIST_DICT) {
		logger(LL_ERROR, "Unable to find component info node for %s\n", component);
		if (filename)
			free(filename);
		return -1;
	}

	plist_t component_info_path_node = plist_dict_get_item(component_info_node, "Path");
	if (!component_info_path_node || plist_get_node_type(component_info_path_node) != PLIST_STRING) {
		logger(LL_ERROR, "Unable to find component info path node for %s\n", component);
		if (filename)
			free(filename);
		return -1;
	}
	plist_get_string_val(component_info_path_node, &filename);

	*path = filename;
	return 0;
}

const char* get_component_name(const char* filename)
{
	struct filename_component_map {
		const char *fnprefix;
		int matchlen;
		const char *compname;
	};
	struct filename_component_map fn_comp_map[] = {
		{ "LLB", 3, "LLB" },
		{ "iBoot", 5, "iBoot" },
		{ "DeviceTree", 10, "DeviceTree" },
		{ "applelogo", 9, "AppleLogo" },
		{ "liquiddetect", 12, "Liquid" },
		{ "lowpowermode", 12, "LowPowerWallet0" },
		{ "recoverymode", 12, "RecoveryMode" },
		{ "batterylow0", 11, "BatteryLow0" },
		{ "batterylow1", 11, "BatteryLow1" },
		{ "glyphcharging", 13, "BatteryCharging" },
		{ "glyphplugin", 11, "BatteryPlugin" },
		{ "batterycharging0", 16, "BatteryCharging0" },
		{ "batterycharging1", 16, "BatteryCharging1" },
		{ "batteryfull", 11, "BatteryFull" },
		{ "needservice", 11, "NeedService" },
		{ "SCAB", 4, "SCAB" },
		{ "sep-firmware", 12, "RestoreSEP" },
		{ NULL, 0, NULL }
	};
	int i = 0;
	while (fn_comp_map[i].fnprefix) {
		if (!strncmp(filename, fn_comp_map[i].fnprefix, fn_comp_map[i].matchlen)) {
			return fn_comp_map[i].compname;
		}
		i++;
	}
	logger(LL_WARNING, "Unhandled component '%s'", filename);
	return NULL;
}
