/*
 * normal.h
 * Functions for handling idevices in normal mode
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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libirecovery.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/preboard.h>
#include <usbmuxd.h>

#include "common.h"
#include "normal.h"
#include "recovery.h"

static int normal_idevice_new(struct idevicerestore_client_t* client, idevice_t* device)
{
	int num_devices = 0;
	char **devices = NULL;
	idevice_t dev = NULL;
	idevice_error_t device_error;
	lockdownd_client_t lockdown = NULL;
	plist_t node = NULL;

	*device = NULL;

	if (client->udid) {
		device_error = idevice_new(&dev, client->udid);
		if (device_error != IDEVICE_E_SUCCESS) {
			logger(LL_DEBUG, "%s: can't open device with UDID %s\n", __func__, client->udid);
			return -1;
		}

		if (lockdownd_client_new(dev, &lockdown, "idevicerestore") != LOCKDOWN_E_SUCCESS) {
			logger(LL_ERROR, "%s: can't connect to lockdownd on device with UDID %s\n", __func__, client->udid);
			return -1;

		}
		char* type = NULL;
		if (lockdownd_query_type(lockdown, &type) != LOCKDOWN_E_SUCCESS) {
			return -1;
		}
		if (strcmp(type, "com.apple.mobile.lockdown") != 0) {
			free(type);
			return -1;
		}
		free(type);
		if (lockdownd_get_value(lockdown, NULL, "UniqueChipID", &node) == LOCKDOWN_E_SUCCESS) {
			plist_get_uint_val(node, &client->ecid);
			plist_free(node);
		}
		lockdownd_client_free(lockdown);
		lockdown = NULL;

		*device = dev;
		return 0;
	}

	idevice_get_device_list(&devices, &num_devices);
	if (num_devices == 0) {
		return -1;
	}
	int j;
	for (j = 0; j < num_devices; j++) {
		if (lockdown != NULL) {
			lockdownd_client_free(lockdown);
			lockdown = NULL;
		}
		if (dev != NULL) {
			idevice_free(dev);
			dev = NULL;
		}
		device_error = idevice_new(&dev, devices[j]);
		if (device_error != IDEVICE_E_SUCCESS) {
			logger(LL_DEBUG, "%s: can't open device with UDID %s\n", __func__, devices[j]);
			continue;
		}

		if (lockdownd_client_new(dev, &lockdown, "idevicerestore") != LOCKDOWN_E_SUCCESS) {
			logger(LL_ERROR, "%s: can't connect to lockdownd on device with UDID %s\n", __func__, devices[j]);
			continue;

		}
		char* type = NULL;
		if (lockdownd_query_type(lockdown, &type) != LOCKDOWN_E_SUCCESS) {
			continue;
		}
		if (strcmp(type, "com.apple.mobile.lockdown") != 0) {
			free(type);
			continue;
		}
		free(type);

		node = NULL;
		if ((lockdownd_get_value(lockdown, NULL, "UniqueChipID", &node) != LOCKDOWN_E_SUCCESS) || !node || (plist_get_node_type(node) != PLIST_UINT)){
			if (node) {
				plist_free(node);
			}
			continue;
		}
		lockdownd_client_free(lockdown);
		lockdown = NULL;

		uint64_t this_ecid = 0;
		plist_get_uint_val(node, &this_ecid);
		plist_free(node);

		if (client->ecid != 0) {
			if (this_ecid != client->ecid) {
				continue;
			}
		} else {
			client->ecid = this_ecid;
		}
		client->udid = strdup(devices[j]);
		*device = dev;
		break;
	}
	idevice_device_list_free(devices);

	return 0;
}

int normal_check_mode(struct idevicerestore_client_t* client)
{
	idevice_t device = NULL;

	normal_idevice_new(client, &device);
	if (!device) {
		return -1;
	}
	idevice_free(device);

	return 0;
}

irecv_device_t normal_get_irecv_device(struct idevicerestore_client_t* client)
{
	idevice_t device = NULL;
	lockdownd_client_t lockdown = NULL;
	lockdownd_error_t lockdown_error = LOCKDOWN_E_SUCCESS;
	irecv_device_t irecv_device = NULL;

	normal_idevice_new(client, &device);
	if (!device) {
		return NULL;
	}

	lockdown_error = lockdownd_client_new_with_handshake(device, &lockdown, "idevicerestore");
	if (!(client->flags & FLAG_ERASE) && lockdown_error == LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING) {
		show_banner("Device is not paired with this computer. Please trust this computer on the device to continue.\n");
		while (!(client->flags & FLAG_QUIT)) {
			lockdown_error = lockdownd_client_new_with_handshake(device, &lockdown, "idevicerestore");
			if (lockdown_error != LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING) {
				break;
			}
			sleep(1);
		}
		hide_banner();
		if (client->flags & FLAG_QUIT) {
			return NULL;
		}
	}
	if (lockdown_error != LOCKDOWN_E_SUCCESS) {
		lockdown_error = lockdownd_client_new(device, &lockdown, "idevicerestore");
	}
	if (lockdown_error != LOCKDOWN_E_SUCCESS) {
		idevice_free(device);
		return NULL;
	}

	plist_t pval = NULL;
	lockdownd_get_value(lockdown, NULL, "HardwareModel", &pval);
	if (pval && (plist_get_node_type(pval) == PLIST_STRING)) {
		char *strval = NULL;
		plist_get_string_val(pval, &strval);
		if (strval) {
			irecv_devices_get_device_by_hardware_model(strval, &irecv_device);
			free(strval);
		}
	}
	plist_free(pval);

	lockdownd_client_free(lockdown);
	idevice_free(device);

	return irecv_device;
}

int normal_enter_recovery(struct idevicerestore_client_t* client)
{
	idevice_t device = NULL;
	lockdownd_client_t lockdown = NULL;
	idevice_error_t device_error = IDEVICE_E_SUCCESS;
	lockdownd_error_t lockdown_error = LOCKDOWN_E_SUCCESS;

	device_error = idevice_new(&device, client->udid);
	if (device_error != IDEVICE_E_SUCCESS) {
		logger(LL_ERROR, "Unable to find device\n");
		return -1;
	}

	lockdown_error = lockdownd_client_new(device, &lockdown, "idevicerestore");
	if (lockdown_error != LOCKDOWN_E_SUCCESS) {
		logger(LL_ERROR, "Unable to connect to lockdownd: %s (%d)\n", lockdownd_strerror(lockdown_error), lockdown_error);
		idevice_free(device);
		return -1;
	}

	lockdown_error = lockdownd_enter_recovery(lockdown);
	if (lockdown_error == LOCKDOWN_E_SESSION_INACTIVE) {
		lockdownd_client_free(lockdown);
		lockdown = NULL;
		if (LOCKDOWN_E_SUCCESS != (lockdown_error = lockdownd_client_new_with_handshake(device, &lockdown, "idevicerestore"))) {
			logger(LL_ERROR, "Could not connect to lockdownd: %s (%d)\n", lockdownd_strerror(lockdown_error), lockdown_error);
			idevice_free(device);
			return -1;
		}
		lockdown_error = lockdownd_enter_recovery(lockdown);
	}
	if (lockdown_error != LOCKDOWN_E_SUCCESS) {
		logger(LL_ERROR, "Unable to place device in recovery mode: %s (%d)\n", lockdownd_strerror(lockdown_error), lockdown_error);
		lockdownd_client_free(lockdown);
		idevice_free(device);
		return -1;
	}

	lockdownd_client_free(lockdown);
	idevice_free(device);
	lockdown = NULL;
	device = NULL;

	mutex_lock(&client->device_event_mutex);
	logger(LL_DEBUG, "Waiting for device to disconnect...\n");
	cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 60000);
	if (client->mode == MODE_NORMAL || (client->flags & FLAG_QUIT)) {
		mutex_unlock(&client->device_event_mutex);
		logger(LL_ERROR, "Failed to place device in recovery mode\n");
		return -1;
	}

	logger(LL_DEBUG, "Waiting for device to connect in recovery mode...\n");
	cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 60000);
	if (client->mode != MODE_RECOVERY || (client->flags & FLAG_QUIT)) {
		mutex_unlock(&client->device_event_mutex);
		logger(LL_ERROR, "Failed to enter recovery mode\n");
		return -1;
	}
	mutex_unlock(&client->device_event_mutex);

	if (recovery_client_new(client) < 0) {
		logger(LL_ERROR, "Unable to enter recovery mode\n");
		return -1;
	}

	/* remove pair record for given device */
	usbmuxd_delete_pair_record(client->udid);

	return 0;
}

plist_t normal_get_lockdown_value(struct idevicerestore_client_t* client, const char* domain, const char* key)
{
	idevice_t device = NULL;
	plist_t node = NULL;
	lockdownd_client_t lockdown = NULL;
	idevice_error_t device_error = IDEVICE_E_SUCCESS;
	lockdownd_error_t lockdown_error = LOCKDOWN_E_SUCCESS;

	device_error = idevice_new(&device, client->udid);
	if (device_error != IDEVICE_E_SUCCESS) {
		logger(LL_ERROR, "Unable to connect to device?!\n");
		return NULL;
	}

	lockdown_error = lockdownd_client_new(device, &lockdown, "idevicerestore");
	if (lockdown_error != LOCKDOWN_E_SUCCESS) {
		logger(LL_ERROR, "Unable to connect to lockdownd\n");
		idevice_free(device);
		return NULL;
	}

	lockdown_error = lockdownd_get_value(lockdown, domain, key, &node);
	if (lockdown_error != LOCKDOWN_E_SUCCESS) {
		logger(LL_DEBUG, "ERROR: Unable to get %s-%s from lockdownd\n", domain, key);
		lockdownd_client_free(lockdown);
		idevice_free(device);
		return NULL;
	}

	lockdownd_client_free(lockdown);
	idevice_free(device);
	lockdown = NULL;
	device = NULL;

	return node;
}

static int normal_get_nonce_by_key(struct idevicerestore_client_t* client, const char* key, unsigned char** nonce, unsigned int* nonce_size)
{
	plist_t nonce_node = normal_get_lockdown_value(client, NULL, key);

	if (!nonce_node || plist_get_node_type(nonce_node) != PLIST_DATA) {
		logger(LL_ERROR, "Unable to get %s\n", key);
		return -1;
	}

	uint64_t n_size = 0;
	plist_get_data_val(nonce_node, (char**)nonce, &n_size);
	*nonce_size = (unsigned int)n_size;
	plist_free(nonce_node);

	return 0;
}

int normal_get_sep_nonce(struct idevicerestore_client_t* client, unsigned char** nonce, unsigned int* nonce_size)
{
	plist_t node = normal_get_lockdown_value(client, NULL, "ApParameters");
	if (PLIST_IS_DICT(node)) {
		plist_t nonce_node = plist_dict_get_item(node, "SepNonce");
		if (nonce_node) {
			uint64_t n_size = 0;
			plist_get_data_val(nonce_node, (char**)nonce, &n_size);
			*nonce_size = (unsigned int)n_size;
			plist_free(node);
			return 0;
		}
	}
	plist_free(node);
	return normal_get_nonce_by_key(client, "SEPNonce", nonce, nonce_size);
}

int normal_get_ap_nonce(struct idevicerestore_client_t* client, unsigned char** nonce, unsigned int* nonce_size)
{
	return normal_get_nonce_by_key(client, "ApNonce", nonce, nonce_size);
}

int normal_is_image4_supported(struct idevicerestore_client_t* client)
{
	plist_t node = normal_get_lockdown_value(client, NULL, "Image4Supported");

	if (!node || plist_get_node_type(node) != PLIST_BOOLEAN) {
		return 0;
	}

	uint8_t bval = 0;
	plist_get_bool_val(node, &bval);
	plist_free(node);

	return bval;
}

int normal_get_firmware_preflight_info(struct idevicerestore_client_t* client, plist_t *preflight_info)
{
	uint8_t has_telephony_capability = 0;
	plist_t node;

	node = normal_get_lockdown_value(client, NULL, "TelephonyCapability");
	plist_get_bool_val(node, &has_telephony_capability);
	plist_free(node);

	if (has_telephony_capability) {
		node = normal_get_lockdown_value(client, NULL, "FirmwarePreflightInfo");
		if (!node || plist_get_node_type(node) != PLIST_DICT) {
			logger(LL_ERROR, "Unable to get FirmwarePreflightInfo\n");
			return -1;
		}
		*preflight_info = node;
	} else {
		logger(LL_DEBUG, "Device does not have TelephonyCapability, no FirmwarePreflightInfo\n");
		*preflight_info = NULL;
	}

	return 0;
}

int normal_get_preflight_info(struct idevicerestore_client_t* client, plist_t *preflight_info)
{
	plist_t node = normal_get_lockdown_value(client, NULL, "PreflightInfo");
	if (PLIST_IS_DICT(node)) {
		*preflight_info = node;
	} else {
		logger(LL_DEBUG, "No PreflightInfo available.\n");
		*preflight_info = NULL;
	}
	return 0;
}

int normal_handle_create_stashbag(struct idevicerestore_client_t* client, plist_t manifest)
{
	int result = -1;

	idevice_t device = NULL;
	idevice_error_t device_err;
	lockdownd_client_t lockdown;
	lockdownd_service_descriptor_t service = NULL;
	lockdownd_error_t lerr;
	preboard_client_t preboard = NULL;
	preboard_error_t perr;

	device_err = idevice_new(&device, client->udid);
	if (device_err != IDEVICE_E_SUCCESS) {
		logger(LL_ERROR, "Could not connect to device (%d)\n", device_err);
		return -1;
	}

	lerr = lockdownd_client_new_with_handshake(device, &lockdown, "idevicerestore");
	if (lerr == LOCKDOWN_E_PASSWORD_PROTECTED) {
		logger(LL_ERROR, "Device is locked. Unlock device and try again.\n");
		idevice_free(device);
		return -1;
	}
	if (lerr != LOCKDOWN_E_SUCCESS) {
		logger(LL_ERROR, "Could not connect to lockdownd (%d)\n", lerr);
		idevice_free(device);
		return -1;
	}

	lerr = lockdownd_start_service(lockdown, PREBOARD_SERVICE_NAME, &service);
	if (lerr == LOCKDOWN_E_PASSWORD_PROTECTED) {
		show_banner("Device is locked. Please unlock the device to continue.\n");
		while (1) {
			lerr = lockdownd_start_service(lockdown, PREBOARD_SERVICE_NAME, &service);
			if (lerr != LOCKDOWN_E_PASSWORD_PROTECTED) {
				break;
			}
			sleep(1);
		}
	}

	if (lerr != LOCKDOWN_E_SUCCESS) {
		logger(LL_ERROR, "Could not start preboard service (%d)\n", lerr);
		lockdownd_client_free(lockdown);
		idevice_free(device);
		return -1;
	}

	perr = preboard_client_new(device, service, &preboard);
	lockdownd_service_descriptor_free(service);
	lockdownd_client_free(lockdown);
	if (perr != PREBOARD_E_SUCCESS) {
		logger(LL_ERROR, "Could not connect to preboard service (%d)\n", perr);
		idevice_free(device);
		return -1;
	}

	perr = preboard_create_stashbag(preboard, manifest, NULL, NULL);
	if (perr != PREBOARD_E_SUCCESS) {
		logger(LL_ERROR, "Failed to trigger stashbag creation (%d)\n", perr);
		preboard_client_free(preboard);
		idevice_free(device);
		return -1;
	}

	int ticks = 0;
	while (ticks++ < 130 && !(client->flags & FLAG_QUIT)) {
		plist_t pl = NULL;
		perr = preboard_receive_with_timeout(preboard, &pl, 1000);
		if (perr == PREBOARD_E_TIMEOUT) {
			continue;
		} else if (perr != PREBOARD_E_SUCCESS) {
			logger(LL_ERROR, "could not receive from preboard service\n");
			break;
		} else {
			plist_t node;

			if (plist_dict_get_bool(pl, "Skip")) {
				result = 0;
				logger(LL_INFO, "Device does not require stashbag.\n");
				break;
			}

			if (plist_dict_get_bool(pl, "ShowDialog")) {
				logger(LL_INFO, "Device requires stashbag.\n");
				show_banner(
				       "Please enter your passcode on the device.  The device will store a token\n"
				       "that will be used after restore to access the user data partition.  This\n"
				       "prevents an 'Attempting data recovery' process occurring after reboot that\n"
				       "may take a long time to complete and will _also_ require the passcode."
				);
				plist_free(pl);
				continue;
			}
			node = plist_dict_get_item(pl, "Error");
			if (node) {
				char *strval = NULL;
				node = plist_dict_get_item(pl, "ErrorString");
				if (node) {
					plist_get_string_val(node, &strval);
				}
				logger(LL_ERROR, "Could not create stashbag: %s\n", (strval) ? strval : "(Unknown error)");
				free(strval);
				plist_free(pl);
				break;
			}
			if (plist_dict_get_bool(pl, "Timeout")) {
				logger(LL_ERROR, "Timeout while waiting for user to enter passcode.\n");
				result = -2;
				plist_free(pl);
				break;
			}
			if (plist_dict_get_bool(pl, "HideDialog")) {
				plist_free(pl);
				/* hide dialog */
				result = 1;
				logger(LL_INFO, "Stashbag created.\n");
				break;
			}
		}
		plist_free(pl);
	}

	hide_banner();

	preboard_client_free(preboard);
	idevice_free(device);

	return result;
}

int normal_handle_commit_stashbag(struct idevicerestore_client_t* client, plist_t manifest)
{
	int result = -1;

	idevice_t device = NULL;
	idevice_error_t device_err;
	lockdownd_client_t lockdown;
	lockdownd_service_descriptor_t service = NULL;
	lockdownd_error_t lerr;
	preboard_client_t preboard = NULL;
	preboard_error_t perr;
	plist_t pl = NULL;

	device_err = idevice_new(&device, client->udid);
	if (device_err != IDEVICE_E_SUCCESS) {
		logger(LL_ERROR, "Could not connect to device (%d)\n", device_err);
		return -1;
	}

	lerr = lockdownd_client_new_with_handshake(device, &lockdown, "idevicerestore");
	if (lerr != LOCKDOWN_E_SUCCESS) {
		logger(LL_ERROR, "Could not connect to lockdownd (%d)\n", lerr);
		idevice_free(device);
		return -1;
	}

	lerr = lockdownd_start_service(lockdown, PREBOARD_SERVICE_NAME, &service);
	if (lerr == LOCKDOWN_E_PASSWORD_PROTECTED) {
		show_banner("Device is locked. Please unlock the device to continue.\n");
		while (1) {
			lerr = lockdownd_start_service(lockdown, PREBOARD_SERVICE_NAME, &service);
			if (lerr != LOCKDOWN_E_PASSWORD_PROTECTED) {
				break;
			}
			sleep(1);
		}
		hide_banner();
	}

	if (lerr != LOCKDOWN_E_SUCCESS) {
		logger(LL_ERROR, "Could not start preboard service (%d)\n", lerr);
		lockdownd_client_free(lockdown);
		idevice_free(device);
		return -1;
	}

	perr = preboard_client_new(device, service, &preboard);
	lockdownd_service_descriptor_free(service);
	lockdownd_client_free(lockdown);
	if (perr != PREBOARD_E_SUCCESS) {
		logger(LL_ERROR, "Could not connect to preboard service (%d)\n", perr);
		idevice_free(device);
		return -1;
	}

	perr = preboard_commit_stashbag(preboard, manifest, NULL, NULL);
	if (perr != PREBOARD_E_SUCCESS) {
		logger(LL_ERROR, "Failed to trigger stashbag creation (%d)\n", perr);
		preboard_client_free(preboard);
		idevice_free(device);
		return -1;
	}

	perr = preboard_receive_with_timeout(preboard, &pl, 30000);
	if (perr != PREBOARD_E_SUCCESS) {
		logger(LL_ERROR, "could not receive from preboard service (%d)\n", perr);
	} else {
		plist_t node = plist_dict_get_item(pl, "Error");
		if (node) {
			char *strval = NULL;
			node = plist_dict_get_item(pl, "ErrorString");
			if (node) {
				plist_get_string_val(node, &strval);
			}
			logger(LL_ERROR, "Could not commit stashbag: %s\n", (strval) ? strval : "(Unknown error)");
			free(strval);
		} else if (plist_dict_get_bool(pl, "StashbagCommitComplete")) {
			logger(LL_INFO, "Stashbag committed!\n");
			result = 0;
		} else {
			logger(LL_ERROR, "Unexpected reply from preboard service\n");
			logger_dump_plist(LL_VERBOSE, pl, 1);
		}
		plist_free(pl);
	}
	preboard_client_free(preboard);
	idevice_free(device);

	return result;
}
