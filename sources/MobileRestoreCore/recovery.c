/*
 * recovery.c
 * Functions for handling idevices in recovery mode
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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libirecovery.h>
#include <libimobiledevice/restore.h>
#include <libimobiledevice/libimobiledevice.h>

#include <libtatsu/tss.h>

#include "idevicerestore.h"
#include "img3.h"
#include "restore.h"
#include "recovery.h"

static int recovery_progress_callback(irecv_client_t client, const irecv_event_t* event)
{
	if (event->type == IRECV_PROGRESS) {
		set_progress('RECV', (double)(event->progress/100.0));
	}
	return 0;
}

void recovery_client_free(struct idevicerestore_client_t* client)
{
	if (client) {
		finalize_progress('RECV');
		if (client->recovery) {
			if(client->recovery->client) {
				irecv_close(client->recovery->client);
				client->recovery->client = NULL;
			}
			free(client->recovery);
			client->recovery = NULL;
		}
	}
}

int recovery_client_new(struct idevicerestore_client_t* client)
{
	int i = 0;
	int attempts = 20;
	irecv_client_t recovery = NULL;
	irecv_error_t recovery_error = IRECV_E_UNKNOWN_ERROR;

	if(client->recovery == NULL) {
		client->recovery = (struct recovery_client_t*)malloc(sizeof(struct recovery_client_t));
		if (client->recovery == NULL) {
			logger(LL_ERROR, "Out of memory\n");
			return -1;
		}
		memset(client->recovery, 0, sizeof(struct recovery_client_t));
	}

	for (i = 1; i <= attempts; i++) {
		recovery_error = irecv_open_with_ecid(&recovery, client->ecid);
		if (recovery_error == IRECV_E_SUCCESS) {
			break;
		}

		if (i >= attempts) {
			logger(LL_ERROR, "Unable to connect to device in recovery mode\n");
			return -1;
		}

		sleep(4);
		logger(LL_DEBUG, "Retrying connection...\n");
	}

	if (client->srnm == NULL) {
		const struct irecv_device_info *device_info = irecv_get_device_info(recovery);
		if (device_info && device_info->srnm) {
			client->srnm = strdup(device_info->srnm);
			logger(LL_INFO, "INFO: device serial number is %s\n", client->srnm);
		}
	}

	irecv_event_subscribe(recovery, IRECV_PROGRESS, &recovery_progress_callback, NULL);
	client->recovery->client = recovery;
	return 0;
}

int recovery_set_autoboot(struct idevicerestore_client_t* client, int enable)
{
	irecv_error_t recovery_error = IRECV_E_SUCCESS;

	recovery_error = irecv_send_command(client->recovery->client, (enable) ? "setenv auto-boot true" : "setenv auto-boot false");
	if (recovery_error != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "Unable to set auto-boot environmental variable\n");
		return -1;
	}

	recovery_error = irecv_send_command(client->recovery->client, "saveenv");
	if (recovery_error != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "Unable to save environmental variable\n");
		return -1;
	}

	return 0;
}

int recovery_enter_restore(struct idevicerestore_client_t* client, plist_t build_identity)
{
    if (client->macos_variant) {
        client->restore_boot_args = strdup("rd=md0 nand-enable-reformat=1 -progress -restore");
    } else if (client->build_major >= 8) {
        client->restore_boot_args = strdup("rd=md0 nand-enable-reformat=1 -progress");
    }

	/* upload data to make device boot restore mode */

	if(client->recovery == NULL) {
		if (recovery_client_new(client) < 0) {
			return -1;
		}
	}

	if ((client->build_major > 8) && !(client->flags & FLAG_CUSTOM)) {
		if (!client->image4supported) {
			/* send ApTicket */
			if (recovery_send_ticket(client) < 0) {
				logger(LL_ERROR, "Unable to send APTicket\n");
				return -1;
			}
		}
	}

	logger(LL_INFO, "Recovery Mode Environment:\n");
	char* value = NULL;
	irecv_getenv(client->recovery->client, "build-version", &value);
	logger(LL_INFO, "iBoot build-version=%s\n", (value) ? value : "(unknown)");
	free(value);
	value = NULL;

	irecv_getenv(client->recovery->client, "build-style", &value);
	logger(LL_INFO, "iBoot build-style=%s\n", (value) ? value : "(unknown)");
	free(value);
	value = NULL;

	unsigned long boot_stage = 0;
	irecv_getenv(client->recovery->client, "boot-stage", &value);
	if (value) {
		boot_stage = strtoul(value, NULL, 0);
	}
	if (boot_stage > 0) {
		logger(LL_INFO, "iBoot boot-stage=%s\n", value);
		free(value);
		value = NULL;
		if (boot_stage != 2) {
			logger(LL_ERROR, "iBoot should be at boot stage 2, continuing anyway...\n");
		}
	}

	unsigned long radio_error = 0;
	irecv_getenv(client->recovery->client, "radio-error", &value);
	if (value) {
		radio_error = strtoul(value, NULL, 0);
	}
	if (radio_error > 0) {
		logger(LL_INFO, "radio-error=%s\n", value);
		free(value);
		value = NULL;
		irecv_getenv(client->recovery->client, "radio-error-string", &value);
		if (value) {
			logger(LL_INFO, "radio-error-string=%s\n", value);
			free(value);
			value = NULL;
		}
	}

	if (recovery_set_autoboot(client, 0) < 0) {
		return -1;
	}

	/* send logo and show it */
	if (recovery_send_applelogo(client, build_identity) < 0) {
		logger(LL_ERROR, "Unable to send AppleLogo\n");
		return -1;
	}

	/* send components loaded by iBoot */
	if (recovery_send_loaded_by_iboot(client, build_identity) < 0) {
		logger(LL_ERROR, "Unable to send components supposed to be loaded by iBoot\n");
		return -1;
	}

	/* send ramdisk and run it */
	if (recovery_send_ramdisk(client, build_identity) < 0) {
		logger(LL_ERROR, "Unable to send Ramdisk\n");
		return -1;
	}

	/* send devicetree and load it */
	if (recovery_send_component_and_command(client, build_identity, "RestoreDeviceTree", "devicetree") < 0) {
		logger(LL_ERROR, "Unable to send DeviceTree\n");
		return -1;
	}

	if (build_identity_has_component(build_identity, "RestoreSEP")) {
		/* send rsepfirmware and load it */
		if (recovery_send_component_and_command(client, build_identity, "RestoreSEP", "rsepfirmware") < 0) {
			logger(LL_ERROR, "Unable to send RestoreSEP\n");
			return -1;
		}
	}

	mutex_lock(&client->device_event_mutex);
	if (recovery_send_kernelcache(client, build_identity) < 0) {
		mutex_unlock(&client->device_event_mutex);
		logger(LL_ERROR, "Unable to send KernelCache\n");
		return -1;
	}

	logger(LL_DEBUG, "Waiting for device to disconnect...\n");
	cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 30000);
	if (client->mode == MODE_RECOVERY || (client->flags & FLAG_QUIT)) {
		mutex_unlock(&client->device_event_mutex);
		logger(LL_ERROR, "Failed to place device in restore mode\n");
		return -1;
	}
	mutex_unlock(&client->device_event_mutex);

	return 0;
}

int recovery_send_ticket(struct idevicerestore_client_t* client)
{
	if (!client->tss) {
		logger(LL_ERROR, "ApTicket requested but no TSS present\n");
		return -1;
	}

	unsigned char* data = NULL;
	uint32_t size = 0;
	if (tss_response_get_ap_ticket(client->tss, &data, &size) < 0) {
		logger(LL_ERROR, "Unable to get ApTicket from TSS request\n");
		return -1;
	}

	logger(LL_INFO, "Sending APTicket (%d bytes)\n", size);
	irecv_error_t err = irecv_send_buffer(client->recovery->client, data, size, 0);
	free(data);
	if (err != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "Unable to send APTicket: %s\n", irecv_strerror(err));
		return -1;
	}

	err = irecv_send_command(client->recovery->client, "ticket");
	if (err != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "Unable to send ticket command\n");
		return -1;
	}

	return 0;
}

int recovery_send_component(struct idevicerestore_client_t* client, plist_t build_identity, const char* component)
{
	size_t size = 0;
	void* data = NULL;
	char* path = NULL;
	irecv_error_t err = 0;

	if (client->tss) {
		if (tss_response_get_path_by_entry(client->tss, component, &path) < 0) {
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

	void* component_data = NULL;
	size_t component_size = 0;
	int ret = extract_component(client->ipsw, path, &component_data, &component_size);
	free(path);
	if (ret < 0) {
		logger(LL_ERROR, "Unable to extract component: %s\n", component);
		return -1;
	}

	ret = personalize_component(client, component, component_data, component_size, client->tss, &data, &size);
	free(component_data);
	if (ret < 0) {
		logger(LL_ERROR, "Unable to get personalized component: %s\n", component);
		return -1;
	}

	logger(LL_INFO, "Sending %s (%zu bytes)...\n", component, size);

	// FIXME: Did I do this right????
	register_progress('RECV', "Uploading");
	err = irecv_send_buffer(client->recovery->client, data, size, 0);
	free(data);
	finalize_progress('RECV');
	if (err != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "Unable to send %s component: %s\n", component, irecv_strerror(err));
		return -1;
	}

	return 0;
}

int recovery_send_component_and_command(struct idevicerestore_client_t* client, plist_t build_identity, const char* component, const char* command)
{
	irecv_error_t recovery_error = IRECV_E_SUCCESS;

	if (recovery_send_component(client, build_identity, component) < 0) {
		logger(LL_ERROR, "Unable to send %s to device.\n", component);
		return -1;
	}

	recovery_error = irecv_send_command(client->recovery->client, command);
	if (recovery_error != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "Unable to execute %s\n", component);
		return -1;
	}

	return 0;
}

int recovery_send_ibec(struct idevicerestore_client_t* client, plist_t build_identity)
{
	const char* component = "iBEC";
	irecv_error_t recovery_error = IRECV_E_SUCCESS;

	if (client->recovery == NULL) {
		if (recovery_client_new(client) < 0) {
			return -1;
		}
	}

	if (recovery_send_component(client, build_identity, component) < 0) {
		logger(LL_ERROR, "Unable to send %s to device.\n", component);
		return -1;
	}

	recovery_error = irecv_send_command_breq(client->recovery->client, "go", 1);
	if (recovery_error != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "Unable to execute %s\n", component);
		return -1;
	}
	irecv_usb_control_transfer(client->recovery->client, 0x21, 1, 0, 0, 0, 0, 5000);

	return 0;
}

int recovery_send_applelogo(struct idevicerestore_client_t* client, plist_t build_identity)
{
	const char* component = "RestoreLogo";
	irecv_error_t recovery_error = IRECV_E_SUCCESS;

	if (!build_identity_has_component(build_identity, component)) {
		return 0;
	}

	logger(LL_INFO, "Sending %s...\n", component);
	if (client->recovery == NULL) {
		if (recovery_client_new(client) < 0) {
			return -1;
		}
	}

	if (recovery_send_component(client, build_identity, component) < 0) {
		logger(LL_ERROR, "Unable to send %s to device.\n", component);
		return -1;
	}

	recovery_error = irecv_send_command(client->recovery->client, "setpicture 4");
	if (recovery_error != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "Unable to set %s\n", component);
		return -1;
	}

	recovery_error = irecv_send_command(client->recovery->client, "bgcolor 0 0 0");
	if (recovery_error != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "Unable to display %s\n", component);
		return -1;
	}

	return 0;
}

int recovery_send_loaded_by_iboot(struct idevicerestore_client_t* client, plist_t build_identity)
{
	if (client->recovery == NULL) {
		if (recovery_client_new(client) < 0) {
			return -1;
		}
	}

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
		if (iboot_node && plist_get_node_type(iboot_node) == PLIST_BOOLEAN && !is_stg1) {
			uint8_t b = 0;
			plist_get_bool_val(iboot_node, &b);
			if (b) {
				logger(LL_DEBUG, "%s is loaded by iBoot.\n", key);
				if (recovery_send_component_and_command(client, build_identity, key, "firmware") < 0) {
					logger(LL_ERROR, "Unable to send component '%s' to device.\n", key);
					err++;
				}
			}
		}
		free(key);
	}
	free(iter);

	return (err) ? -1 : 0;
}

int recovery_send_ramdisk(struct idevicerestore_client_t* client, plist_t build_identity)
{
	const char *component = "RestoreRamDisk";
	irecv_error_t recovery_error = IRECV_E_SUCCESS;

	if(client->recovery == NULL) {
		if (recovery_client_new(client) < 0) {
			return -1;
		}
	}

	char* value = NULL;
	irecv_getenv(client->recovery->client, "ramdisk-size", &value);
	logger(LL_INFO, "ramdisk-size=%s\n", (value ? value : "(unknown)"));
	free(value);
	value = NULL;

	if (recovery_send_component(client, build_identity, component) < 0) {
		logger(LL_ERROR, "Unable to send %s to device.\n", component);
		return -1;
	}

	irecv_send_command(client->recovery->client, "getenv ramdisk-delay");

	recovery_error = irecv_send_command(client->recovery->client, "ramdisk");
	if (recovery_error != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "Unable to execute %s\n", component);
		return -1;
	}

	sleep(2);

	return 0;
}

int recovery_send_kernelcache(struct idevicerestore_client_t* client, plist_t build_identity)
{
	const char* component = "RestoreKernelCache";
	irecv_error_t recovery_error = IRECV_E_SUCCESS;

	if (client->recovery == NULL) {
		if (recovery_client_new(client) < 0) {
			return -1;
		}
	}

	if (recovery_send_component(client, build_identity, component) < 0) {
		logger(LL_ERROR, "Unable to send %s to device.\n", component);
		return -1;
	}

	irecv_usb_control_transfer(client->recovery->client, 0x21, 1, 0, 0, 0, 0, 5000);

	if (client->restore_boot_args) {
		char setba[256];
		strcpy(setba, "setenv boot-args ");
		strcat(setba, client->restore_boot_args);
		recovery_error = irecv_send_command(client->recovery->client, setba);
	}

	recovery_error = irecv_send_command_breq(client->recovery->client, "bootx", 1);
	if (recovery_error != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "Unable to execute %s\n", component);
		return -1;
	}

	return 0;
}

int recovery_is_image4_supported(struct idevicerestore_client_t* client)
{
	if(client->recovery == NULL) {
		if (recovery_client_new(client) < 0) {
			return 0;
		}
	}

	const struct irecv_device_info *device_info = irecv_get_device_info(client->recovery->client);
	if (!device_info) {
		return 0;
	}

	return (device_info->ibfl & IBOOT_FLAG_IMAGE4_AWARE);
}

int recovery_get_ap_nonce(struct idevicerestore_client_t* client, unsigned char** nonce, unsigned int* nonce_size)
{
	if(client->recovery == NULL) {
		if (recovery_client_new(client) < 0) {
			return -1;
		}
	}

	const struct irecv_device_info *device_info = irecv_get_device_info(client->recovery->client);
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

int recovery_get_sep_nonce(struct idevicerestore_client_t* client, unsigned char** nonce, unsigned int* nonce_size)
{
	if(client->recovery == NULL) {
		if (recovery_client_new(client) < 0) {
			return -1;
		}
	}

	const struct irecv_device_info *device_info = irecv_get_device_info(client->recovery->client);
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

int recovery_send_reset(struct idevicerestore_client_t* client)
{
	irecv_send_command_breq(client->recovery->client, "reset", 1);
	return 0;
}

