/*
 * dfu.c
 * Functions for handling idevices in DFU mode
 *
 * Copyright (c) 2012-2019 Nikias Bassen. All Rights Reserved.
 * Copyright (c) 2010-2013 Martin Szulecki. All Rights Reserved.
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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libirecovery.h>

#include <libtatsu/tss.h>

#include "dfu.h"
#include "recovery.h"
#include "idevicerestore.h"
#include "common.h"

static int dfu_progress_callback(irecv_client_t client, const irecv_event_t* event) {
	if (event->type == IRECV_PROGRESS) {
		set_progress('DFUP', (double)event->progress/100.0);
	}
	return 0;
}

int dfu_client_new(struct idevicerestore_client_t* client)
{
	irecv_client_t dfu = NULL;

	if (client->dfu == NULL) {
		client->dfu = (struct dfu_client_t*)malloc(sizeof(struct dfu_client_t));
		memset(client->dfu, 0, sizeof(struct dfu_client_t));
		if (client->dfu == NULL) {
			logger(LL_ERROR, "Out of memory\n");
			return -1;
		}
	}

	if (irecv_open_with_ecid_and_attempts(&dfu, client->ecid, 10) != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "Unable to connect to device in DFU mode\n");
		return -1;
	}

	irecv_event_subscribe(dfu, IRECV_PROGRESS, &dfu_progress_callback, NULL);
	client->dfu->client = dfu;
	return 0;
}

void dfu_client_free(struct idevicerestore_client_t* client)
{
	if(client != NULL) {
		finalize_progress('DFUP');
		if (client->dfu != NULL) {
			if(client->dfu->client != NULL) {
				irecv_close(client->dfu->client);
				client->dfu->client = NULL;
			}
			free(client->dfu);
		}
		client->dfu = NULL;
	}
}

irecv_device_t dfu_get_irecv_device(struct idevicerestore_client_t* client)
{
	irecv_client_t dfu = NULL;
	irecv_error_t dfu_error = IRECV_E_SUCCESS;
	irecv_device_t device = NULL;

	if (irecv_open_with_ecid_and_attempts(&dfu, client->ecid, 10) != IRECV_E_SUCCESS) {
		return NULL;
	}

	dfu_error = irecv_devices_get_device_by_client(dfu, &device);
	if (dfu_error == IRECV_E_SUCCESS) {
		if (client->ecid == 0) {
			const struct irecv_device_info *device_info = irecv_get_device_info(dfu);
			client->ecid = device_info->ecid;
		}
	}
	irecv_close(dfu);
	if (dfu_error != IRECV_E_SUCCESS) {
		return NULL;
	}

	return device;
}

int dfu_send_buffer_with_options(struct idevicerestore_client_t* client, const void* buffer, size_t size, unsigned int irecv_options)
{
	irecv_error_t err = 0;

	logger(LL_INFO, "Sending data (%zu bytes)...\n", size);

	err = irecv_send_buffer(client->dfu->client, (unsigned char*)buffer, size, irecv_options);
	if (err != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "Unable to send data: %s\n", irecv_strerror(err));
		return -1;
	}

	return 0;
}

int dfu_send_buffer(struct idevicerestore_client_t* client, const void* buffer, size_t size)
{
	return dfu_send_buffer_with_options(client, buffer, size, IRECV_SEND_OPT_DFU_NOTIFY_FINISH);
}

int dfu_send_component(struct idevicerestore_client_t* client, plist_t build_identity, const char* component)
{
	char* path = NULL;

	// Use a specific TSS ticket for the Ap,LocalPolicy component
	plist_t tss = client->tss;
	if (strcmp(component, "Ap,LocalPolicy") == 0) {
		tss = client->tss_localpolicy;
	}

	void* component_data = NULL;
	size_t component_size = 0;

	if (strcmp(component, "Ap,LocalPolicy") == 0) {
		// If Ap,LocalPolicy => Inject an empty policy
		component_data = malloc(sizeof(lpol_file));
		component_size = sizeof(lpol_file);
		memcpy(component_data, lpol_file, component_size);
	} else {
		if (tss) {
			if (tss_response_get_path_by_entry(tss, component, &path) < 0) {
				logger(LL_DEBUG, "No path for component %s in TSS, will fetch from build_identity\n", component);
			}
		}
		if (!path) {
			if (build_identity_get_component_path(build_identity, component, &path) < 0) {
				logger(LL_ERROR, "Unable to get path for component '%s'\n", component);
				free(path);
				return -1;
			}
		}

		if (extract_component(client->ipsw, path, &component_data, &component_size) < 0) {
			logger(LL_ERROR, "Unable to extract component: %s\n", component);
			free(path);
			return -1;
		}
		free(path);
		path = NULL;
	}

	void* data = NULL;
	size_t size = 0;

	if (personalize_component(client, component, component_data, component_size, tss, &data, &size) < 0) {
		logger(LL_ERROR, "Unable to get personalized component: %s\n", component);
		free(component_data);
		return -1;
	}
	free(component_data);
	component_data = NULL;

	if (!client->image4supported && client->build_major > 8 && !(client->flags & FLAG_CUSTOM) && !strcmp(component, "iBEC")) {
		unsigned char* ticket = NULL;
		unsigned int tsize = 0;
		if (tss_response_get_ap_ticket(client->tss, &ticket, &tsize) < 0) {
			logger(LL_ERROR, "Unable to get ApTicket from TSS request\n");
			return -1;
		}
		uint32_t fillsize = 0;
		if (tsize % 64 != 0) {
			fillsize = ((tsize / 64) + 1) * 64;
		}
		logger(LL_DEBUG, "ticket size = %d\nfillsize = %d\n", tsize, fillsize);
		unsigned char* newdata = (unsigned char*)malloc(size + fillsize);
		memcpy(newdata, ticket, tsize);
		memset(newdata + tsize, '\xFF', fillsize - tsize);
		memcpy(newdata + fillsize, data, size);
		free(data);
		data = newdata;
		size += fillsize;
	}

	logger(LL_INFO, "Sending %s (%zu bytes)...\n", component, size);

	register_progress('DFUP', "Uploading");
	irecv_error_t err = irecv_send_buffer(client->dfu->client, data, size, IRECV_SEND_OPT_DFU_NOTIFY_FINISH);
	finalize_progress('DFUP');
	if (err != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "Unable to send %s component: %s\n", component, irecv_strerror(err));
		free(data);
		return -1;
	}

	free(data);
	return 0;
}

int dfu_get_bdid(struct idevicerestore_client_t* client, unsigned int* bdid)
{
	if(client->dfu == NULL) {
		if (dfu_client_new(client) < 0) {
			return -1;
		}
	}

	const struct irecv_device_info *device_info = irecv_get_device_info(client->dfu->client);
	if (!device_info) {
		return -1;
	}

	*bdid = device_info->bdid;

	return 0;
}

int dfu_get_cpid(struct idevicerestore_client_t* client, unsigned int* cpid)
{
	if(client->dfu == NULL) {
		if (dfu_client_new(client) < 0) {
			return -1;
		}
	}

	const struct irecv_device_info *device_info = irecv_get_device_info(client->dfu->client);
	if (!device_info) {
		return -1;
	}

	*cpid = device_info->cpid;

	return 0;
}

int dfu_get_prev(struct idevicerestore_client_t* client, unsigned int* prev)
{
	if(client->dfu == NULL) {
		if (dfu_client_new(client) < 0) {
			return -1;
		}
	}

	const struct irecv_device_info *device_info = irecv_get_device_info(client->dfu->client);
	if (!device_info) {
		return -1;
	}
	char* ptr = strstr(device_info->serial_string, "PREV:");
	if (ptr) {
		sscanf(ptr, "PREV:%x", prev);
		return 0;
	}
	return -1;
}


int dfu_is_image4_supported(struct idevicerestore_client_t* client)
{
	if(client->dfu == NULL) {
		if (dfu_client_new(client) < 0) {
			return 0;
		}
	}

	const struct irecv_device_info *device_info = irecv_get_device_info(client->dfu->client);
	if (!device_info) {
		return 0;
	}

	return (device_info->ibfl & IBOOT_FLAG_IMAGE4_AWARE);
}

int dfu_get_portdfu_nonce(struct idevicerestore_client_t* client, unsigned char** nonce, unsigned int* nonce_size)
{
	if(client->dfu == NULL) {
		if (dfu_client_new(client) < 0) {
			return -1;
		}
	}

	const struct irecv_device_info *device_info = irecv_get_device_info(client->dfu->client);
	if (!device_info) {
		return -1;
	}

	if (device_info->ap_nonce && device_info->ap_nonce_size > 0) {
		*nonce = (unsigned char*)malloc(device_info->ap_nonce_size);
		if (!*nonce) {
			return -1;
		}
		*nonce_size = device_info->ap_nonce_size;
		// The nonce is backwards, so we have to swap the bytes
		unsigned int i = 0;
		for (i = 0; i < *nonce_size; i++) {
			(*nonce)[(*nonce_size)-1-i] = device_info->ap_nonce[i];
		}
	}

	return 0;
}

int dfu_get_ap_nonce(struct idevicerestore_client_t* client, unsigned char** nonce, unsigned int* nonce_size)
{
	if(client->dfu == NULL) {
		if (dfu_client_new(client) < 0) {
			return -1;
		}
	}

	const struct irecv_device_info *device_info = irecv_get_device_info(client->dfu->client);
	if (!device_info) {
		return -1;
	}

	if (device_info->ap_nonce && device_info->ap_nonce_size > 0) {
		*nonce = (unsigned char*)malloc(device_info->ap_nonce_size);
		if (!*nonce) {
			return -1;
		}
		*nonce_size = device_info->ap_nonce_size;
		memcpy(*nonce, device_info->ap_nonce, *nonce_size);
	}

	return 0;
}

int dfu_get_sep_nonce(struct idevicerestore_client_t* client, unsigned char** nonce, unsigned int* nonce_size)
{
	if(client->dfu == NULL) {
		if (dfu_client_new(client) < 0) {
			return -1;
		}
	}

	const struct irecv_device_info *device_info = irecv_get_device_info(client->dfu->client);
	if (!device_info) {
		return -1;
	}

	if (device_info->sep_nonce && device_info->sep_nonce_size > 0) {
		*nonce = (unsigned char*)malloc(device_info->sep_nonce_size);
		if (!*nonce) {
			return -1;
		}
		*nonce_size = device_info->sep_nonce_size;
		memcpy(*nonce, device_info->sep_nonce, *nonce_size);
	}

	return 0;
}

int dfu_send_component_and_command(struct idevicerestore_client_t* client, plist_t build_identity, const char* component, const char* command)
{
	irecv_error_t dfu_error = IRECV_E_SUCCESS;

	if (dfu_send_component(client, build_identity, component) < 0) {
		logger(LL_ERROR, "Unable to send %s to device.\n", component);
		return -1;
	}

	logger(LL_INFO, "INFO: executing command: %s\n", command);
	dfu_error = irecv_send_command(client->dfu->client, command);
	if (dfu_error != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "Unable to execute %s\n", command);
		return -1;
	}

	return 0;
}

int dfu_send_command(struct idevicerestore_client_t* client, const char* command)
{
	irecv_error_t dfu_error = IRECV_E_SUCCESS;

	logger(LL_INFO, "INFO: executing command: %s\n", command);
	dfu_error = irecv_send_command(client->dfu->client, command);
	if (dfu_error != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "Unable to execute %s\n", command);
		return -1;
	}

	return 0;
}

int dfu_send_iboot_stage1_components(struct idevicerestore_client_t* client, plist_t build_identity)
{
	plist_t manifest_node = plist_dict_get_item(build_identity, "Manifest");
	if (!manifest_node || plist_get_node_type(manifest_node) != PLIST_DICT) {
		logger(LL_ERROR, "Unable to find manifest node\n");
		return -1;
	}

	plist_dict_iter iter = NULL;
	plist_dict_new_iter(manifest_node, &iter);
	int err = 0;
	while (iter) {
		char *key = NULL;
		plist_t node = NULL;
		plist_dict_next_item(manifest_node, iter, &key, &node);
		if (key == NULL)
			break;

		plist_t iboot_node = plist_access_path(node, 2, "Info", "IsLoadedByiBoot");
		plist_t iboot_stg1_node = plist_access_path(node, 2, "Info", "IsLoadedByiBootStage1");
		uint8_t is_stg1 = 0;
		if (iboot_stg1_node && plist_get_node_type(iboot_stg1_node) == PLIST_BOOLEAN) {
			plist_get_bool_val(iboot_stg1_node, &is_stg1);
		}
		if (iboot_node && plist_get_node_type(iboot_node) == PLIST_BOOLEAN && is_stg1) {
			uint8_t b = 0;
			plist_get_bool_val(iboot_node, &b);
			if (b) {
				logger(LL_DEBUG, "%s is loaded by iBoot Stage 1 and iBoot.\n", key);
			} else {
				logger(LL_DEBUG, "%s is loaded by iBoot Stage 1 but not iBoot...\n", key);
			}
			if (dfu_send_component_and_command(client, build_identity, key, "firmware") < 0) {
				logger(LL_ERROR, "Unable to send component '%s' to device.\n", key);
				err++;
			}
		}
		free(key);
	}
	free(iter);

	return (err) ? -1 : 0;
}

int dfu_enter_recovery(struct idevicerestore_client_t* client, plist_t build_identity)
{
	int mode = 0;

	if (dfu_client_new(client) < 0) {
		logger(LL_ERROR, "Unable to connect to DFU device\n");
		return -1;
	}

	irecv_get_mode(client->dfu->client, &mode);

	if (mode != IRECV_K_DFU_MODE) {
		logger(LL_NOTICE, "device is not in DFU mode, assuming recovery mode.\n");
		client->mode = MODE_RECOVERY;
		return 0;
	}

	mutex_lock(&client->device_event_mutex);

	if (dfu_send_component(client, build_identity, "iBSS") < 0) {
		logger(LL_ERROR, "Unable to send iBSS to device\n");
		irecv_close(client->dfu->client);
		client->dfu->client = NULL;
		return -1;
	}
	dfu_client_free(client);

	if (client->build_major > 8) {
		/* reconnect */
		logger(LL_DEBUG, "Waiting for device to disconnect...\n");
		cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 10000);
		if (client->mode != MODE_UNKNOWN || (client->flags & FLAG_QUIT)) {
			mutex_unlock(&client->device_event_mutex);
			if (!(client->flags & FLAG_QUIT)) {
				logger(LL_ERROR, "Device did not disconnect. Possibly invalid iBSS. Reset device and try again.\n");
			}
			return -1;
		}
		logger(LL_DEBUG, "Waiting for device to reconnect...\n");
		cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 10000);
		if ((client->mode != MODE_DFU && client->mode != MODE_RECOVERY) || (client->flags & FLAG_QUIT)) {
			mutex_unlock(&client->device_event_mutex);
			if (!(client->flags & FLAG_QUIT)) {
				logger(LL_ERROR, "Device did not reconnect in DFU or recovery mode. Possibly invalid iBSS. Reset device and try again.\n");
			}
			return -1;
		}
		mutex_unlock(&client->device_event_mutex);
		dfu_client_new(client);

		/* get nonce */
		unsigned char* nonce = NULL;
		unsigned int nonce_size = 0;
		int nonce_changed = 0;
		if (dfu_get_ap_nonce(client, &nonce, &nonce_size) < 0) {
			logger(LL_ERROR, "Unable to get ApNonce from device!\n");
			return -1;
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

		logger(LL_INFO, "Nonce: ");
		logger_dump_hex(LL_INFO, client->nonce, client->nonce_size);

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

		if (irecv_usb_set_configuration(client->dfu->client, 1) < 0) {
			logger(LL_ERROR, "set configuration failed\n");
		}

		mutex_lock(&client->device_event_mutex);

		// Now, before sending iBEC, we must send necessary firmwares on new versions.
		if (client->macos_variant) {
			// Without this empty policy file & its special signature, iBEC won't start.
			if (dfu_send_component_and_command(client, build_identity, "Ap,LocalPolicy", "lpolrestore") < 0) {
				mutex_unlock(&client->device_event_mutex);
				logger(LL_ERROR, "Unable to send Ap,LocalPolicy to device\n");
				irecv_close(client->dfu->client);
				client->dfu->client = NULL;
				return -1;
			}

			char *value = NULL;
			unsigned long boot_stage = 0;
			irecv_getenv(client->dfu->client, "boot-stage", &value);
			if (value) {
				boot_stage = strtoul(value, NULL, 0);
			}
			if (boot_stage > 0) {
				logger(LL_INFO, "iBoot boot-stage=%s\n", value);
				free(value);
				value = NULL;
				if (boot_stage != 1) {
					logger(LL_ERROR, "iBoot should be at boot stage 1, continuing anyway...\n");
				}
			}

			if (dfu_send_iboot_stage1_components(client, build_identity) < 0) {
				mutex_unlock(&client->device_event_mutex);
				logger(LL_ERROR, "Unable to send iBoot stage 1 components to device\n");
				irecv_close(client->dfu->client);
				client->dfu->client = NULL;
				return -1;
			}

			if (dfu_send_command(client, "setenv auto-boot false") < 0) {
				mutex_unlock(&client->device_event_mutex);
				logger(LL_ERROR, "Unable to send command to device\n");
				irecv_close(client->dfu->client);
				client->dfu->client = NULL;
				return -1;
			}

			if (dfu_send_command(client, "saveenv") < 0) {
				mutex_unlock(&client->device_event_mutex);
				logger(LL_ERROR, "Unable to send command to device\n");
				irecv_close(client->dfu->client);
				client->dfu->client = NULL;
				return -1;
			}

			if (dfu_send_command(client, "setenvnp boot-args rd=md0 nand-enable-reformat=1 -progress -restore") < 0) {
				mutex_unlock(&client->device_event_mutex);
				logger(LL_ERROR, "Unable to send command to device\n");
				irecv_close(client->dfu->client);
				client->dfu->client = NULL;
				return -1;
			}

			if (dfu_send_component(client, build_identity, "RestoreLogo") < 0) {
				mutex_unlock(&client->device_event_mutex);
				logger(LL_ERROR, "Unable to send RestoreDCP to device\n");
				irecv_close(client->dfu->client);
				client->dfu->client = NULL;
				return -1;
			}

			if (dfu_send_command(client, "setpicture 4") < 0) {
				mutex_unlock(&client->device_event_mutex);
				logger(LL_ERROR, "Unable to send command to device\n");
				irecv_close(client->dfu->client);
				client->dfu->client = NULL;
				return -1;
			}

			if (dfu_send_command(client, "bgcolor 0 0 0") < 0) {
				mutex_unlock(&client->device_event_mutex);
				logger(LL_ERROR, "Unable to send command to device\n");
				irecv_close(client->dfu->client);
				client->dfu->client = NULL;
				return -1;
			}
		}

		/* send iBEC */
		if (dfu_send_component(client, build_identity, "iBEC") < 0) {
			mutex_unlock(&client->device_event_mutex);
			logger(LL_ERROR, "Unable to send iBEC to device\n");
			irecv_close(client->dfu->client);
			client->dfu->client = NULL;
			return -1;
		}

		if (client->mode == MODE_RECOVERY) {
			sleep(1);
			if (irecv_send_command_breq(client->dfu->client, "go", 1) != IRECV_E_SUCCESS) {
				mutex_unlock(&client->device_event_mutex);
				logger(LL_ERROR, "Unable to execute iBEC\n");
				return -1;
			}

			if (client->build_major < 20) {
				irecv_usb_control_transfer(client->dfu->client, 0x21, 1, 0, 0, 0, 0, 5000);
			}
		}
		dfu_client_free(client);
	}

	logger(LL_DEBUG, "Waiting for device to disconnect...\n");
	cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 10000);
	if (client->mode != MODE_UNKNOWN || (client->flags & FLAG_QUIT)) {
		mutex_unlock(&client->device_event_mutex);
		if (!(client->flags & FLAG_QUIT)) {
			logger(LL_ERROR, "Device did not disconnect. Possibly invalid %s. Reset device and try again.\n", (client->build_major > 8) ? "iBEC" : "iBSS");
		}
		return -1;
	}
	logger(LL_DEBUG, "Waiting for device to reconnect in recovery mode...\n");
	cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 10000);
	if (client->mode != MODE_RECOVERY || (client->flags & FLAG_QUIT)) {
		mutex_unlock(&client->device_event_mutex);
		if (!(client->flags & FLAG_QUIT)) {
			logger(LL_ERROR, "Device did not reconnect in recovery mode. Possibly invalid %s. Reset device and try again.\n", (client->build_major > 8) ? "iBEC" : "iBSS");
		}
		return -1;
	}
	mutex_unlock(&client->device_event_mutex);

	if (recovery_client_new(client) < 0) {
		logger(LL_ERROR, "Unable to connect to recovery device\n");
		if (client->recovery->client) {
			irecv_close(client->recovery->client);
			client->recovery->client = NULL;
		}
		return -1;
	}

	return 0;
}

