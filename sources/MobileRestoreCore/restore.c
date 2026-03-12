/*
 * restore.c
 * Functions for handling idevices in restore mode
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

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libgen.h>
#include <math.h>
#include <libimobiledevice/restore.h>
#include <libimobiledevice/property_list_service.h>
#include <libimobiledevice-glue/thread.h>
#ifdef HAVE_REVERSE_PROXY
#include <libimobiledevice/reverse_proxy.h>
#else
#warning Linking against libimobiledevice without reverse proxy support. Please update to a newer version of libimobiledevice, the legacy code used will be removed in a future version of idevicerestore.
#endif
#include <zip.h>
#include <libirecovery.h>
#include <libtatsu/tss.h>
#include <curl/curl.h>

#include "idevicerestore.h"
#include "asr.h"
#include "fdr.h"
#include "fls.h"
#include "mbn.h"
#include "ftab.h"
#include "ipsw.h"
#include "restore.h"
#include "common.h"
#include "endianness.h"

#define CREATE_PARTITION_MAP          11
#define CREATE_FILESYSTEM             12
#define RESTORE_IMAGE                 13
#define VERIFY_RESTORE                14
#define CHECK_FILESYSTEMS             15
#define MOUNT_FILESYSTEMS             16
#define FIXUP_VAR                     17
#define FLASH_FIRMWARE                18
#define UPDATE_BASEBAND               19
#define SET_BOOT_STAGE                20
#define REBOOT_DEVICE                 21
#define SHUTDOWN_DEVICE               22
#define TURN_ON_ACCESSORY_POWER       23
#define CLEAR_BOOTARGS                24
#define MODIFY_BOOTARGS               25
#define INSTALL_ROOT                  26
#define INSTALL_KERNELCACHE           27
#define WAIT_FOR_NAND                 28
#define UNMOUNT_FILESYSTEMS           29
#define SET_DATETIME                  30
#define EXEC_IBOOT                    31
#define FINALIZE_NAND_EPOCH_UPDATE    32
#define CHECK_INAPPR_BOOT_PARTITIONS  33
#define CREATE_FACTORY_RESTORE_MARKER 34
#define LOAD_FIRMWARE                 35
#define REQUESTING_FUD_DATA           36
#define REMOVING_ACTIVATION_RECORD    37
#define CHECK_BATTERY_VOLTAGE         38
#define WAIT_BATTERY_CHARGE           39
#define CLOSE_MODEM_TICKETS           40
#define MIGRATE_DATA                  41
#define WIPE_STORAGE_DEVICE           42
#define SEND_APPLE_LOGO               43
#define CHECK_LOGS                    44
#define CLEAR_NVRAM                   46
#define UPDATE_GAS_GAUGE              47
#define PREPARE_BASEBAND_UPDATE       48
#define BOOT_BASEBAND                 49
#define CREATE_SYSTEM_KEYBAG          50
#define UPDATE_IR_MCU_FIRMWARE        51
#define RESIZE_SYSTEM_PARTITION       52
#define COLLECTING_UPDATER_OUTPUT     53
#define PAIR_STOCKHOLM                54
#define UPDATE_STOCKHOLM              55
#define UPDATE_SWDHID                 56
#define CERTIFY_SEP                   57
#define UPDATE_NAND_FIRMWARE          58
#define UPDATE_SE_FIRMWARE            59
#define UPDATE_SAVAGE                 60
#define INSTALLING_DEVICETREE         61
#define CERTIFY_SAVAGE                62
#define SUBMITTING_PROVINFO           63
#define CERTIFY_YONKERS               64
#define UPDATE_ROSE                   65
#define UPDATE_VERIDIAN               66
#define CREATING_PROTECTED_VOLUME     67
#define RESIZING_MAIN_FS_PARTITION    68
#define CREATING_RECOVERY_OS_VOLUME   69
#define INSTALLING_RECOVERY_OS_FILES  70
#define INSTALLING_RECOVERY_OS_IMAGE  71
#define REQUESTING_EAN_DATA           74
#define SEALING_SYSTEM_VOLUME         77
#define UPDATING_APPLETCON            81

static int restore_finished = 0;

static int restore_device_connected = 0;

int restore_client_new(struct idevicerestore_client_t* client)
{
	struct restore_client_t* restore = (struct restore_client_t*) malloc(sizeof(struct restore_client_t));
	if (restore == NULL) {
		logger(LL_ERROR, "Out of memory\n");
		return -1;
	}

	if (restore_open_with_timeout(client) < 0) {
		restore_client_free(client);
		return -1;
	}

	client->restore = restore;
	return 0;
}

void restore_client_free(struct idevicerestore_client_t* client)
{
	if (client && client->restore) {
		if(client->restore->client) {
			restored_client_free(client->restore->client);
			client->restore->client = NULL;
		}
		if(client->restore->device) {
			idevice_free(client->restore->device);
			client->restore->device = NULL;
		}
		if(client->restore->bbtss) {
			plist_free(client->restore->bbtss);
			client->restore->bbtss = NULL;
		}
		free(client->restore);
		client->restore = NULL;
	}
}

static int restore_idevice_new(struct idevicerestore_client_t* client, idevice_t* device)
{
	int num_devices = 0;
	char **devices = NULL;
	idevice_get_device_list(&devices, &num_devices);
	if (num_devices == 0) {
		return -1;
	}
	*device = NULL;
	idevice_t dev = NULL;
	idevice_error_t device_error;
	restored_client_t restore = NULL;
	int j;
	for (j = 0; j < num_devices; j++) {
		if (restore != NULL) {
			restored_client_free(restore);
			restore = NULL;
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

		if (restored_client_new(dev, &restore, "idevicerestore") != RESTORE_E_SUCCESS) {
			logger(LL_DEBUG, "%s: can't connect to restored on device with UDID %s\n", __func__, devices[j]);
			continue;

		}
		char* type = NULL;
		uint64_t version = 0;
		if (restored_query_type(restore, &type, &version) != RESTORE_E_SUCCESS) {
			continue;
		}
		if (strcmp(type, "com.apple.mobile.restored") != 0) {
			free(type);
			continue;
		}
		free(type);

		if (client->ecid != 0) {
			plist_t node = NULL;
			plist_t hwinfo = NULL;

			if (restored_query_value(restore, "HardwareInfo", &hwinfo) != RESTORE_E_SUCCESS) {
				continue;
			}

			node = plist_dict_get_item(hwinfo, "UniqueChipID");
			if (!node || plist_get_node_type(node) != PLIST_UINT) {
				if (hwinfo) {
					plist_free(hwinfo);
				}
				continue;
			}
			restored_client_free(restore);
			restore = NULL;

			uint64_t this_ecid = 0;
			plist_get_uint_val(node, &this_ecid);
			plist_free(hwinfo);

			if (this_ecid != client->ecid) {
				continue;
			}
		}
		if (restore) {
			restored_client_free(restore);
			restore = NULL;
		}
		client->udid = strdup(devices[j]);
		*device = dev;
		break;
	}
	idevice_device_list_free(devices);

	return 0;
}

int restore_check_mode(struct idevicerestore_client_t* client)
{
	idevice_t device = NULL;

	restore_idevice_new(client, &device);
	if (!device) {
		return -1;
	}
	idevice_free(device);

	return 0;
}

irecv_device_t restore_get_irecv_device(struct idevicerestore_client_t* client)
{
	char* model = NULL;
	plist_t node = NULL;
	idevice_t device = NULL;
	restored_client_t restore = NULL;
	restored_error_t restore_error = RESTORE_E_SUCCESS;
	irecv_device_t irecv_device = NULL;

	restore_idevice_new(client, &device);
	if (!device) {
		return NULL;
	}

	restore_error = restored_client_new(device, &restore, "idevicerestore");
	if (restore_error != RESTORE_E_SUCCESS) {
		idevice_free(device);
		return NULL;
	}

	if (restored_query_type(restore, NULL, NULL) != RESTORE_E_SUCCESS) {
		restored_client_free(restore);
		idevice_free(device);
		return NULL;
	}

	if (client->srnm == NULL) {
		if (restored_get_value(restore, "SerialNumber", &node) == RESTORE_E_SUCCESS) {
			plist_get_string_val(node, &client->srnm);
			logger(LL_INFO, "INFO: device serial number is %s\n", client->srnm);
			plist_free(node);
			node = NULL;
		}
	}

	restore_error = restored_get_value(restore, "HardwareModel", &node);
	restored_client_free(restore);
	idevice_free(device);
	if (restore_error != RESTORE_E_SUCCESS || !node || plist_get_node_type(node) != PLIST_STRING) {
		logger(LL_ERROR, "Unable to get HardwareModel from restored\n");
		plist_free(node);
		return NULL;
	}

	plist_get_string_val(node, &model);
	irecv_devices_get_device_by_hardware_model(model, &irecv_device);
	free(model);

	return irecv_device;
}

int restore_is_image4_supported(struct idevicerestore_client_t* client)
{
	int result = 0;
	plist_t hwinfo = NULL;
	idevice_t device = NULL;
	restored_client_t restore = NULL;
	restored_error_t restore_error = RESTORE_E_SUCCESS;

	if (idevice_new(&device, client->udid) != IDEVICE_E_SUCCESS) {
		logger(LL_ERROR, "Could not connect to device %s\n", client->udid);
		return -1;
	}

	restore_error = restored_client_new(device, &restore, "idevicerestore");
	if (restore_error != RESTORE_E_SUCCESS) {
		idevice_free(device);
		return -1;
	}

	if (restored_query_type(restore, NULL, NULL) != RESTORE_E_SUCCESS) {
		restored_client_free(restore);
		idevice_free(device);
		return -1;
	}

	restore_error = restored_query_value(restore, "HardwareInfo", &hwinfo);
	if (restore_error == RESTORE_E_SUCCESS) {
		uint8_t b = 0;
		plist_t node = plist_dict_get_item(hwinfo, "SupportsImage4");
		if (node && plist_get_node_type(node) == PLIST_BOOLEAN) {
			plist_get_bool_val(node, &b);
			result = b;
		}
	}
	restored_client_free(restore);
	idevice_free(device);

	return result;
}

int restore_reboot(struct idevicerestore_client_t* client)
{
	if(client->restore == NULL) {
		if (restore_open_with_timeout(client) < 0) {
			logger(LL_ERROR, "Unable to open device in restore mode\n");
			return -1;
		}
	}

	mutex_lock(&client->device_event_mutex);

	logger(LL_INFO, "Rebooting restore mode device...\n");
	restored_reboot(client->restore->client);

	restored_client_free(client->restore->client);

	cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 30000);
	if (client->mode == MODE_RESTORE) {
		mutex_unlock(&client->device_event_mutex);
		return -1;
	}
	mutex_unlock(&client->device_event_mutex);

	return 0;
}

static int restore_is_current_device(struct idevicerestore_client_t* client, const char* udid)
{
	if (!client) {
		return 0;
	}
	if (!client->ecid) {
		logger(LL_ERROR, "%s: no ECID given in client data\n", __func__);
		return 0;
	}

	idevice_t device = NULL;
	idevice_error_t device_error;
	restored_client_t restored = NULL;
	restored_error_t restore_error;
	char *type = NULL;
	uint64_t version = 0;

	device_error = idevice_new(&device, udid);
	if (device_error != IDEVICE_E_SUCCESS) {
		logger(LL_DEBUG, "%s: can't open device with UDID %s\n", __func__, udid);
		return 0;
	}

	restore_error = restored_client_new(device, &restored, "idevicerestore");
	if (restore_error != RESTORE_E_SUCCESS) {
		logger(LL_DEBUG, "%s: can't connect to restored\n", __func__);
		idevice_free(device);
		return 0;
	}
	restore_error = restored_query_type(restored, &type, &version);
	if ((restore_error == RESTORE_E_SUCCESS) && type && (strcmp(type, "com.apple.mobile.restored") == 0)) {
		logger(LL_DEBUG, "%s: Connected to %s, version %d\n", __func__, type, (int)version);
	} else {
		logger(LL_DEBUG, "%s: device %s is not in restore mode\n", __func__, udid);
		restored_client_free(restored);
		idevice_free(device);
		return 0;
	}

	plist_t hwinfo = NULL;
	restore_error = restored_query_value(restored, "HardwareInfo", &hwinfo);
	if ((restore_error != RESTORE_E_SUCCESS) || !hwinfo) {
		logger(LL_ERROR, "%s: Unable to get HardwareInfo from restored\n", __func__);
		restored_client_free(restored);
		idevice_free(device);
		plist_free(hwinfo);
		return 0;
	}
	restored_client_free(restored);
	idevice_free(device);

	uint64_t this_ecid = 0;
	plist_t node = plist_dict_get_item(hwinfo, "UniqueChipID");
	if (node && plist_get_node_type(node) == PLIST_UINT) {
		plist_get_uint_val(node, &this_ecid);
	}
	plist_free(hwinfo);

	if (this_ecid == 0) {
		logger(LL_ERROR, "%s: Unable to get ECID from restored\n", __func__);
		return 0;
	}

	return (this_ecid == client->ecid);
}

int restore_open_with_timeout(struct idevicerestore_client_t* client)
{
	char *type = NULL;
	uint64_t version = 0;
	idevice_t device = NULL;
	restored_client_t restored = NULL;
	idevice_error_t device_error = IDEVICE_E_SUCCESS;
	restored_error_t restore_error = RESTORE_E_SUCCESS;

	// no context exists so bail
	if (client == NULL) {
		return -1;
	}

	if (client->ecid == 0) {
		logger(LL_ERROR, "no ECID in client data!\n");
		return -1;
	}

	// create our restore client if it doesn't yet exist
	if (client->restore == NULL) {
		client->restore = (struct restore_client_t*) malloc(sizeof(struct restore_client_t));
		if(client->restore == NULL) {
			logger(LL_ERROR, "Out of memory\n");
			return -1;
		}
		memset(client->restore, '\0', sizeof(struct restore_client_t));
	}

	restore_device_connected = 0;

	if (!restore_is_current_device(client, client->udid)) {
		logger(LL_ERROR, "Unable to connect to device in restore mode\n");
		return -1;
	}

	logger(LL_INFO, "Connecting now...\n");
	device_error = idevice_new(&device, client->udid);
	if (device_error != IDEVICE_E_SUCCESS) {
		return -1;
	}

	restore_error = restored_client_new(device, &restored, "idevicerestore");
	if (restore_error != RESTORE_E_SUCCESS) {
		idevice_free(device);
		return -1;
	}

	restore_error = restored_query_type(restored, &type, &version);
	if ((restore_error == RESTORE_E_SUCCESS) && type && (strcmp(type, "com.apple.mobile.restored") == 0)) {
		client->restore->protocol_version = version;
		logger(LL_INFO, "Connected to %s, version %d\n", type, (int)version);
	} else {
		logger(LL_ERROR, "Unable to connect to restored, error=%d\n", restore_error);
		restored_client_free(restored);
		idevice_free(device);
		return -1;
	}

	client->restore->device = device;
	client->restore->client = restored;
	return 0;
}

const char* restore_progress_string(unsigned int operation)
{
	switch (operation) {
	case CREATE_PARTITION_MAP:
		return "Creating partition map";
	case CREATE_FILESYSTEM:
		return "Creating filesystem";
	case RESTORE_IMAGE:
		return "Restoring image";
	case VERIFY_RESTORE:
		return "Verifying restore";
	case CHECK_FILESYSTEMS:
		return "Checking filesystems";
	case MOUNT_FILESYSTEMS:
		return "Mounting filesystems";
	case FIXUP_VAR:
		return "Fixing up /var";
	case FLASH_FIRMWARE:
		return "Flashing firmware";
	case UPDATE_BASEBAND:
		return "Updating baseband";
	case SET_BOOT_STAGE:
		return "Setting boot stage";
	case REBOOT_DEVICE:
		return "Rebooting device";
	case SHUTDOWN_DEVICE:
		return "Shutdown device";
	case TURN_ON_ACCESSORY_POWER:
		return "Turning on accessory power";
	case CLEAR_BOOTARGS:
		return "Clearing persistent boot-args";
	case MODIFY_BOOTARGS:
		return "Modifying persistent boot-args";
	case INSTALL_ROOT:
		return "Installing root";
	case INSTALL_KERNELCACHE:
		return "Installing kernelcache";
	case WAIT_FOR_NAND:
		return "Waiting for NAND";
	case UNMOUNT_FILESYSTEMS:
		return "Unmounting filesystems";
	case SET_DATETIME:
		return "Setting date and time on device";
	case EXEC_IBOOT:
		return "Executing iBEC to bootstrap update";
	case FINALIZE_NAND_EPOCH_UPDATE:
		return "Finalizing NAND epoch update";
	case CHECK_INAPPR_BOOT_PARTITIONS:
		return "Checking for inappropriate bootable partitions";
	case CREATE_FACTORY_RESTORE_MARKER:
		return "Creating factory restore marker";
	case LOAD_FIRMWARE:
		return "Loading firmware data to flash";
	case REQUESTING_FUD_DATA:
		return "Requesting FUD data";
	case REMOVING_ACTIVATION_RECORD:
		return "Removing activation record";
	case CHECK_BATTERY_VOLTAGE:
		return "Checking battery voltage";
	case WAIT_BATTERY_CHARGE:
		return "Waiting for battery to charge";
	case CLOSE_MODEM_TICKETS:
		return "Closing modem tickets";
	case MIGRATE_DATA:
		return "Migrating data";
	case WIPE_STORAGE_DEVICE:
		return "Wiping storage device";
	case SEND_APPLE_LOGO:
		return "Sending Apple logo to device";
	case CHECK_LOGS:
		return "Checking for uncollected logs";
	case CLEAR_NVRAM:
		return "Clearing NVRAM";
	case UPDATE_GAS_GAUGE:
		return "Updating gas gauge software";
	case PREPARE_BASEBAND_UPDATE:
		return "Preparing for baseband update";
	case BOOT_BASEBAND:
		return "Booting the baseband";
	case CREATE_SYSTEM_KEYBAG:
		return "Creating system key bag";
	case UPDATE_IR_MCU_FIRMWARE:
		return "Updating IR MCU firmware";
	case RESIZE_SYSTEM_PARTITION:
		return "Resizing system partition";
	case COLLECTING_UPDATER_OUTPUT:
		return "Collecting updater output";
	case PAIR_STOCKHOLM:
		return "Pairing Stockholm";
	case UPDATE_STOCKHOLM:
		return "Updating Stockholm";
	case UPDATE_SWDHID:
		return "Updating SWDHID";
	case CERTIFY_SEP:
		return "Certifying SEP";
	case UPDATE_NAND_FIRMWARE:
		return "Updating NAND Firmware";
	case UPDATE_SE_FIRMWARE:
		return "Updating SE Firmware";
	case UPDATE_SAVAGE:
		return "Updating Savage";
	case INSTALLING_DEVICETREE:
		return "Installing DeviceTree";
	case CERTIFY_SAVAGE:
		return "Certifying Savage";
	case SUBMITTING_PROVINFO:
		return "Submitting Provinfo";
	case CERTIFY_YONKERS:
		return "Certifying Yonkers";
	case UPDATE_ROSE:
		return "Updating Rose";
	case UPDATE_VERIDIAN:
		return "Updating Veridian";
	case CREATING_PROTECTED_VOLUME:
		return "Creating Protected Volume";
	case RESIZING_MAIN_FS_PARTITION:
		return "Resizing Main Filesystem Partition";
	case CREATING_RECOVERY_OS_VOLUME:
		return "Creating Recovery OS Volume";
	case INSTALLING_RECOVERY_OS_FILES:
		return "Installing Recovery OS Files";
	case INSTALLING_RECOVERY_OS_IMAGE:
		return "Installing Recovery OS Image";
	case REQUESTING_EAN_DATA:
		return "Requesting EAN Data";
	case SEALING_SYSTEM_VOLUME:
		return "Sealing System Volume";
	case UPDATING_APPLETCON:
		return "Updating AppleTCON";
	default:
		return "Unknown operation";
	}
}

struct restored_service_client {

};

#define SERVICE_TYPE_RESTORED 1
#define SERVICE_TYPE_PLIST 2

typedef struct restore_service_client {
	void* client;
	int type;
} *restore_service_client_t;

static void* _restore_get_service_client_for_data_request(struct idevicerestore_client_t *client, plist_t message)
{
	if (!client || !client->restore || !client->restore->client) return NULL;
	restore_service_client_t service = (restore_service_client_t)malloc(sizeof(struct restore_service_client));
	if (!PLIST_IS_DICT(message) || !plist_dict_get_item(message, "DataPort")) {
		service->client = client->restore->client;
		service->type = SERVICE_TYPE_RESTORED;
		return service;
	}
	plist_t data_type = plist_dict_get_item(message, "DataType");
	uint16_t data_port = plist_dict_get_uint(message, "DataPort");
	const char* data_type_str = plist_get_string_ptr(data_type, NULL);

	struct lockdownd_service_descriptor svcdesc = {
		data_port,
		0,
		(char*)data_type_str
	};
	property_list_service_client_t plclient = NULL;
	logger(LL_INFO, "Connecting to %s data port %u\n", data_type_str, data_port);
	if (property_list_service_client_new(client->restore->device, &svcdesc, &plclient) != PROPERTY_LIST_SERVICE_E_SUCCESS) {
		logger(LL_ERROR, "Failed to start service connection for %s on port %u\n", data_type_str, data_port);
		free(service);
		return NULL;
	}
	service->client = plclient;
	service->type = SERVICE_TYPE_PLIST;

	return service;
}

static int _restore_service_send(restore_service_client_t service, plist_t plist, plist_format_t fmt)
{
	if (!service) {
		return -1;
	}
	switch (service->type) {
		case SERVICE_TYPE_RESTORED:
			return restored_send((restored_client_t)service->client, plist);
		case SERVICE_TYPE_PLIST:
			if (fmt == PLIST_FORMAT_BINARY) {
				return property_list_service_send_binary_plist((property_list_service_client_t)service->client, plist);
			}
			return property_list_service_send_xml_plist((property_list_service_client_t)service->client, plist);
		default:
			break;
	}
	return -1;
}

static int _restore_service_recv_timeout(restore_service_client_t service, plist_t *plist, unsigned int timeout)
{
	struct restored_client_private {
		property_list_service_client_t parent;
		char *udid;
		char *label;
		plist_t info;
	};
	if (!service) {
		return -1;
	}
	switch (service->type) {
		case SERVICE_TYPE_RESTORED:
			return property_list_service_receive_plist_with_timeout(((struct restored_client_private*)service->client)->parent, plist, timeout);
		case SERVICE_TYPE_PLIST:
			return property_list_service_receive_plist_with_timeout((property_list_service_client_t)service->client, plist, timeout);
		default:
			break;
	}
	return -1;
}

static void _restore_service_free(restore_service_client_t service)
{
	if (!service) {
		return;
	}
	switch (service->type) {
		case SERVICE_TYPE_RESTORED:
			break;
		case SERVICE_TYPE_PLIST:
			property_list_service_client_free((property_list_service_client_t)service->client);
			break;
		default:
			break;
	}
	free(service);
}

static int lastop = 0;

static int restore_handle_previous_restore_log_msg(restored_client_t client, plist_t msg)
{
	plist_t node = NULL;
	char* restorelog = NULL;

	node = plist_dict_get_item(msg, "PreviousRestoreLog");
	if (!node || plist_get_node_type(node) != PLIST_STRING) {
		logger(LL_DEBUG, "Failed to parse restore log from PreviousRestoreLog plist\n");
		return -1;
	}
	plist_get_string_val(node, &restorelog);

	logger(LL_VERBOSE, "Previous Restore Log Received:\n%s\n", restorelog);
	free(restorelog);

	return 0;
}

int restore_handle_progress_msg(struct idevicerestore_client_t* client, plist_t msg)
{
	plist_t node = NULL;
	uint64_t progress = 0;
	uint64_t operation = 0;

	node = plist_dict_get_item(msg, "Operation");
	if (!node || plist_get_node_type(node) != PLIST_UINT) {
		logger(LL_DEBUG, "Failed to parse operation from ProgressMsg plist\n");
		return -1;
	}
	plist_get_uint_val(node, &operation);

	node = plist_dict_get_item(msg, "Progress");
	if (!node || plist_get_node_type(node) != PLIST_UINT) {
		logger(LL_DEBUG, "Failed to parse progress from ProgressMsg plist \n");
		return -1;
	}
	plist_get_uint_val(node, &progress);

	/* for restore protocol version < 14 all operation codes > 35 are 1 less so we add one */
	int adapted_operation = (int)operation;
	if (client && client->restore && client->restore->protocol_version < 14) {
		if (adapted_operation > 35) {
			adapted_operation++;
		}
	}

	if ((progress > 0) && (progress <= 100)) {
		if ((int)operation != lastop) {
			logger(LL_INFO, "%s (%d)\n", restore_progress_string(adapted_operation), (int)operation);
		}
		switch (adapted_operation) {
		case RESTORE_IMAGE:
			idevicerestore_progress(client, RESTORE_STEP_UPLOAD_FS, progress / 100.0);
			break;
		case VERIFY_RESTORE:
			idevicerestore_progress(client, RESTORE_STEP_VERIFY_FS, progress / 100.0);
			break;
		case FLASH_FIRMWARE:
			idevicerestore_progress(client, RESTORE_STEP_FLASH_FW, progress / 100.0);
			break;
		case UPDATE_BASEBAND:
		case UPDATE_IR_MCU_FIRMWARE:
			idevicerestore_progress(client, RESTORE_STEP_FLASH_BB, progress / 100.0);
			break;
		case REQUESTING_FUD_DATA:
			idevicerestore_progress(client, RESTORE_STEP_FUD, progress / 100.0);
			break;
		case UPDATE_ROSE:
		case UPDATE_VERIDIAN:
		case REQUESTING_EAN_DATA:
			break;
		default:
			logger(LL_DEBUG, "Unhandled progress operation %d (%d)\n", adapted_operation, (int)operation);
			break;
		}
	} else {
		logger(LL_INFO, "%s (%d)\n", restore_progress_string(adapted_operation), (int)operation);
	}
	lastop = (int)operation;

	return 0;
}

int restore_handle_status_msg(struct idevicerestore_client_t* client, plist_t msg)
{
	int result = 0;
	uint64_t value = 0;
	char* log = NULL;
	logger(LL_INFO, "Got status message\n");

	// read status code
	plist_t node = plist_dict_get_item(msg, "Status");
	plist_get_uint_val(node, &value);

	switch(value) {
		case 0:
			logger(LL_INFO, "Status: Restore Finished\n");
			restore_finished = 1;
			break;
		case 0xFFFFFFFFFFFFFFFFLL:
			logger(LL_INFO, "Status: Verification Error\n");
			break;
		case 6:
			logger(LL_INFO, "Status: Disk Failure\n");
			break;
		case 14:
			logger(LL_INFO, "Status: Fail\n");
			break;
		case 27:
			logger(LL_INFO, "Status: Failed to mount filesystems.\n");
			break;
		case 50:
		case 51:
			logger(LL_INFO, "Status: Failed to load SEP Firmware.\n");
			break;
		case 53:
			logger(LL_INFO, "Status: Failed to recover FDR data.\n");
			break;
		case 1015:
			logger(LL_INFO, "Status: X-Gold Baseband Update Failed. Defective Unit?\n");
			break;
		default:
			logger(LL_INFO, "Unhandled status message (%" PRIu64 ")\n", value);
			logger_dump_plist(LL_VERBOSE, msg, 1);
			break;
	}

	// read error code
	node = plist_dict_get_item(msg, "AMRError");
	if (node && plist_get_node_type(node) == PLIST_UINT) {
		plist_get_uint_val(node, &value);
		result = -value;
		if (result > 0) {
			result = -result;
		}
	}

	// check if log is available
	node = plist_dict_get_item(msg, "Log");
	if (node && plist_get_node_type(node) == PLIST_STRING) {
		plist_get_string_val(node, &log);
		logger(LL_INFO, "Log is available:\n%s\n", log);
		free(log);
		log = NULL;
	}

	return result;
}

static int restore_handle_baseband_updater_output_data(struct idevicerestore_client_t* client, plist_t message)
{
	int result = -1;
	plist_t node = plist_dict_get_item(message, "DataPort");
	uint64_t u64val = 0;
	plist_get_uint_val(node, &u64val);
	uint16_t data_port = (uint16_t)u64val;

	int attempts = 10;
	idevice_connection_t connection = NULL;
	idevice_error_t device_error = IDEVICE_E_SUCCESS;

	if (!client || !client->restore || !client->restore->build_identity || !client->restore->device) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return -1;
	}

	logger(LL_DEBUG, "Connecting to baseband updater data port\n");
	while (--attempts > 0) {
		device_error = idevice_connect(client->restore->device, data_port, &connection);
		if (device_error == IDEVICE_E_SUCCESS) {
			break;
		}
		sleep(1);
		logger(LL_DEBUG, "Retrying connection...\n");
	}
	if (device_error != IDEVICE_E_SUCCESS) {
		logger(LL_ERROR, "Unable to connect to baseband updater data port\n");
		return result;
	}

	int fl = snprintf(NULL, 0, "updater_output-%s.cpio", client->udid);
	if (fl < 0) {
		idevice_disconnect(connection);
		logger(LL_ERROR, "snprintf failed?!\n");
		return result;
	}
	char* updater_out_fn = malloc(fl+1);
	if (!updater_out_fn) {
		idevice_disconnect(connection);
		logger(LL_ERROR, "Could not allocate buffer for filename\n");
		return result;
	}
	snprintf(updater_out_fn, fl+1, "updater_output-%s.cpio", client->udid);
	FILE* f = fopen(updater_out_fn, "wb");
	if (!f) {
		logger(LL_ERROR, "Could not open %s for writing, will not write baseband updater output data.\n", updater_out_fn);
	}
	const int bufsize = 65536;
	char* buf = malloc(bufsize);
	if (!buf) {
		free(updater_out_fn);
		idevice_disconnect(connection);
		logger(LL_ERROR, "Could not allocate buffer\n");
		return result;
	}
	uint32_t size = 0;
	while (idevice_connection_receive(connection, buf, bufsize, &size) == IDEVICE_E_SUCCESS) {
		if (f) {
			fwrite(buf, 1, size, f);
		}
	}
	if (f) {
		fclose(f);
		logger(LL_INFO, "Wrote baseband updater output data to %s\n", updater_out_fn);
	}
	free(updater_out_fn);
	free(buf);
	idevice_disconnect(connection);
	result = 0;

	return result;
}

static int restore_handle_bb_update_status_msg(struct idevicerestore_client_t* client, plist_t message)
{
	int result = -1;
	plist_t node = plist_dict_get_item(message, "Accepted");
	uint8_t accepted = 0;
	plist_get_bool_val(node, &accepted);

	if (!accepted) {
		logger(LL_ERROR, "device didn't accept BasebandData\n");
		return result;
	}

	uint8_t done = 0;
	node = plist_access_path(message, 2, "Output", "done");
	if (node && plist_get_node_type(node) == PLIST_BOOLEAN) {
		plist_get_bool_val(node, &done);
	}

	if (done) {
		logger(LL_INFO, "Updating Baseband completed.\n");
		plist_t provisioning = plist_access_path(message, 2, "Output", "provisioning");
		if (provisioning && plist_get_node_type(provisioning) == PLIST_DICT) {
			char* sval = NULL;
			node = plist_dict_get_item(provisioning, "IMEI");
			if (node && plist_get_node_type(node) == PLIST_STRING) {
				plist_get_string_val(node, &sval);
				logger(LL_INFO, "Provisioning:\n");
				logger(LL_INFO, "IMEI:%s\n", sval);
				free(sval);
				sval = NULL;
			}
		}
	} else {
		logger(LL_INFO, "Updating Baseband in progress...\n");
	}
	result = 0;

	return result;
}

struct _restore_asr_progress_data {
	struct idevicerestore_client_t* client;
	uint32_t tag;
};

static void restore_asr_progress_cb(double progress, void* userdata)
{
	struct idevicerestore_client_t* client = (struct idevicerestore_client_t*)userdata;
	if (client) {
		idevicerestore_progress(client, RESTORE_STEP_UPLOAD_FS, progress);
	}
}

int restore_send_filesystem(struct idevicerestore_client_t* client, plist_t message)
{
	asr_client_t asr = NULL;
	ipsw_archive_t ipsw_dummy = NULL;
	ipsw_file_handle_t file = NULL;
	char* fsname = NULL;

	if (!client || !client->restore || !client->restore->build_identity || !client->restore->device) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return -1;
	}

	logger(LL_INFO, "About to send filesystem...\n");

	if (build_identity_get_component_path(client->restore->build_identity, "OS", &fsname) < 0) {
		logger(LL_ERROR, "Unable to get path for filesystem component\n");
		return -1;
	}
	if (client->filesystem) {
		char* path = strdup(client->filesystem);
		const char* fsname_base = path_get_basename(path);
		char* parent_dir = dirname(path);
		ipsw_dummy = ipsw_open(parent_dir);
		file = ipsw_file_open(ipsw_dummy, fsname_base);
		free(path);
	} else {
		file = ipsw_file_open(client->ipsw, fsname);
	}
	if (!file) {
		logger(LL_ERROR, "Unable to open '%s' in ipsw\n", fsname);
		free(fsname);
	}

	uint16_t asr_port = (uint16_t)plist_dict_get_uint(message, "DataPort");
	if (asr_port == 0) {
		asr_port = ASR_DEFAULT_PORT;
	}
	if (asr_open_with_timeout(client->restore->device, &asr, asr_port) < 0) {
		ipsw_file_close(file);
		ipsw_close(ipsw_dummy);
		logger(LL_ERROR, "Unable to connect to ASR\n");
		return -1;
	}
	logger(LL_INFO, "Connected to ASR\n");

	// this step sends requested chunks of data from various offsets to asr so
	// it can validate the filesystem before installing it
	logger(LL_INFO, "Validating the filesystem\n");
	if (asr_perform_validation(asr, file) < 0) {
		ipsw_file_close(file);
		ipsw_close(ipsw_dummy);
		logger(LL_ERROR, "ASR was unable to validate the filesystem\n");
		asr_free(asr);
		return -1;
	}
	logger(LL_INFO, "Filesystem validated\n");

	if (asr_port == ASR_DEFAULT_PORT) {
		asr_set_progress_callback(asr, restore_asr_progress_cb, client);
	}

	// once the target filesystem has been validated, ASR then requests the
	// entire filesystem to be sent.
	logger(LL_INFO, "Sending filesystem now...\n");
	if (asr_send_payload(asr, file) < 0) {
		ipsw_file_close(file);
		ipsw_close(ipsw_dummy);
		logger(LL_ERROR, "Unable to send payload to ASR\n");
		asr_free(asr);
		return -1;
	}
	ipsw_file_close(file);
	ipsw_close(ipsw_dummy);

	logger(LL_INFO, "Done sending filesystem\n");

	asr_free(asr);
	return 0;
}

int restore_send_recovery_os_root_ticket(struct idevicerestore_client_t* client, plist_t message)
{
	restored_error_t restore_error;
	plist_t dict;

	logger(LL_INFO, "About to send RecoveryOSRootTicket...\n");

	if (client->root_ticket) {
		dict = plist_new_dict();
		plist_dict_set_item(dict, "RecoveryOSRootTicketData", plist_new_data((char*)client->root_ticket, client->root_ticket_len));
	} else {
		unsigned char* data = NULL;
		unsigned int len = 0;

		if (!client->tss_recoveryos_root_ticket && !(client->flags & FLAG_CUSTOM)) {
			logger(LL_ERROR, "Cannot send RootTicket without TSS\n");
			return -1;
		}

		if (client->image4supported) {
			if (tss_response_get_ap_img4_ticket(client->tss_recoveryos_root_ticket, &data, &len) < 0) {
				logger(LL_ERROR, "Unable to get ApImg4Ticket from TSS\n");
				return -1;
			}
		} else {
			if (!(client->flags & FLAG_CUSTOM) && (tss_response_get_ap_ticket(client->tss, &data, &len) < 0)) {
				logger(LL_ERROR, "Unable to get ticket from TSS\n");
				return -1;
			}
		}

		dict = plist_new_dict();
		if (data && (len > 0)) {
			plist_dict_set_item(dict, "RootTicketData", plist_new_data((char*)data, len));
		} else {
			logger(LL_NOTICE, "Not sending RootTicketData (no data present)\n");
		}
		free(data);
	}

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	logger(LL_INFO, "Sending RecoveryOSRootTicket now...\n");
	restore_error = _restore_service_send(service, dict, 0);
	plist_free(dict);
	_restore_service_free(service);
	if (restore_error != RESTORE_E_SUCCESS) {
		logger(LL_ERROR, "Unable to send RootTicket (%d)\n", restore_error);
		return -1;
	}

	logger(LL_INFO, "Done sending RecoveryOS RootTicket\n");
	return 0;
}


int restore_send_root_ticket(struct idevicerestore_client_t* client, plist_t message)
{
	restored_error_t restore_error;
	plist_t dict;

	logger(LL_INFO, "About to send RootTicket...\n");

	if (client->root_ticket) {
		dict = plist_new_dict();
		plist_dict_set_item(dict, "RootTicketData", plist_new_data((char*)client->root_ticket, client->root_ticket_len));
	} else {
		unsigned char* data = NULL;
		unsigned int len = 0;

		if (!client->tss && !(client->flags & FLAG_CUSTOM)) {
			logger(LL_ERROR, "Cannot send RootTicket without TSS\n");
			return -1;
		}

		if (client->image4supported) {
			if (tss_response_get_ap_img4_ticket(client->tss, &data, &len) < 0) {
				logger(LL_ERROR, "Unable to get ApImg4Ticket from TSS\n");
				return -1;
			}
		} else {
			if (!(client->flags & FLAG_CUSTOM) && (tss_response_get_ap_ticket(client->tss, &data, &len) < 0)) {
				logger(LL_ERROR, "Unable to get ticket from TSS\n");
				return -1;
			}
		}

		dict = plist_new_dict();
		if (data && (len > 0)) {
			plist_dict_set_item(dict, "RootTicketData", plist_new_data((char*)data, len));
		} else {
			logger(LL_INFO, "Not sending RootTicketData (no data present)\n");
		}
		free(data);
	}

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	logger(LL_INFO, "Sending RootTicket now...\n");
	restore_error = _restore_service_send(service, dict, 0);
	plist_free(dict);
	_restore_service_free(service);
	if (restore_error != RESTORE_E_SUCCESS) {
		logger(LL_ERROR, "Unable to send RootTicket (%d)\n", restore_error);
		return -1;
	}

	logger(LL_INFO, "Done sending RootTicket\n");
	return 0;
}

typedef struct {
	int length;
	char* content;
} query_response;

static size_t _curl_write_callback(char* data, size_t size, size_t nmemb, query_response* response)
{
	size_t total = size * nmemb;
	if (total != 0) {
		response->content = realloc(response->content, response->length + total + 1);
		memcpy(response->content + response->length, data, total);
		response->content[response->length + total] = '\0';
		response->length += total;
	}

	return total;
}

static size_t _curl_header_callback(char* buffer, size_t size, size_t nitems, void* userdata)
{
	plist_t header_dict = (plist_t)userdata;
	size_t len = nitems*size;
	char* key = NULL;
	char* val = NULL;
	size_t i = 0;
	while (i < len) {
		if (buffer[i] == ':') {
			key = malloc(i+1);
			strncpy(key, buffer, i);
			key[i] = '\0';
			i++;
			while (i < len && (buffer[i] == ' ' || buffer[i] == '\t')) i++;
			val = malloc(len-i+1);
			strncpy(val, buffer+i, len-i);
			val[len-i] = '\0';
			break;
		}
		i++;
	}
	if (key && val) {
		plist_dict_set_item(header_dict, key, plist_new_string(val));
	}
	free(key);
	free(val);
	return len;
}

int restore_send_url_asset(struct idevicerestore_client_t* client, plist_t message)
{
	plist_t arguments = plist_dict_get_item(message, "Arguments");
	if (!PLIST_IS_DICT(arguments)) {
		logger(LL_ERROR, "%s: Unexpected arguments\n", __func__);
		logger_dump_plist(LL_VERBOSE, message, 1);
		return -1;
	}

	const char* request_method = plist_get_string_ptr(plist_dict_get_item(arguments, "RequestMethod"), NULL);
	if (!request_method) {
		logger(LL_ERROR, "%s: Unable to extract RequestMethod from Arguments\n", __func__);
		return -1;
	}
	if (strcmp(request_method, "GET")) {
		logger(LL_ERROR, "%s: Unexpected RequestMethod '%s' in message\n", __func__, request_method);
		return -1;
	}
	const char* request_url = plist_get_string_ptr(plist_dict_get_item(arguments, "RequestURL"), NULL);
	if (!request_url) {
		logger(LL_ERROR, "%s: Unable to extract RequestURL from Arguments\n", __func__);
		return -1;
	}
	logger(LL_INFO, "Requesting URLAsset from %s\n", request_url);

	char curl_error_message[CURL_ERROR_SIZE];
	CURL* handle = curl_easy_init();
	/* disable SSL verification to allow download from untrusted https locations */
	curl_easy_setopt(handle, CURLOPT_SSL_VERIFYPEER, 0);

	query_response* response = malloc(sizeof(query_response));
	if (response == NULL) {
		logger(LL_ERROR, "%s: Unable to allocate sufficient memory\n", __func__);
		return -1;
	}

	response->length = 0;
	response->content = malloc(1);
	response->content[0] = '\0';

	curl_easy_setopt(handle, CURLOPT_HTTPGET, 1L);
	curl_easy_setopt(handle, CURLOPT_ERRORBUFFER, curl_error_message);
	curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, (curl_write_callback)&_curl_write_callback);
	curl_easy_setopt(handle, CURLOPT_HEADERFUNCTION, &_curl_header_callback);
	plist_t response_headers = plist_new_dict();
	curl_easy_setopt(handle, CURLOPT_HEADERDATA, response_headers);
	curl_easy_setopt(handle, CURLOPT_WRITEDATA, response);
	if (client->debug_level > 0) {
		curl_easy_setopt(handle, CURLOPT_VERBOSE, 1L);
	}
	curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 1);
	curl_easy_setopt(handle, CURLOPT_URL, request_url);
	curl_easy_perform(handle);

	long http_response = 0;
	curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &http_response);

	curl_easy_cleanup(handle);

	plist_t dict = plist_new_dict();
	plist_dict_set_item(dict, "ResponseBody", plist_new_data(response->content, response->length));
	plist_dict_set_item(dict, "ResponseBodyDone", plist_new_bool(1));
	plist_dict_set_item(dict, "ResponseHeaders", response_headers);
	plist_dict_set_item(dict, "ResponseStatus", plist_new_uint(http_response));

	free(response);

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	_restore_service_send(service, dict, PLIST_FORMAT_BINARY);
	_restore_service_free(service);

	return 0;
}

int restore_send_streamed_image_decryption_key(struct idevicerestore_client_t* client, plist_t message)
{
	logger(LL_DEBUG, "%s\n", __func__);
	plist_t arguments = plist_dict_get_item(message, "Arguments");
	if (!PLIST_IS_DICT(arguments)) {
		logger(LL_ERROR, "%s: Unexpected arguments\n", __func__);
		logger_dump_plist(LL_VERBOSE, arguments, 1);
		return -1;
	}

	const char* request_method = plist_get_string_ptr(plist_dict_get_item(arguments, "RequestMethod"), NULL);
	if (!request_method) {
		logger(LL_ERROR, "%s: Unable to extract RequestMethod from Arguments\n", __func__);
		return -1;
	}
	if (strcmp(request_method, "POST")) {
		logger(LL_ERROR, "%s: Unexpected RequestMethod '%s' in message\n", __func__, request_method);
		return -1;
	}
	const char* request_url = plist_get_string_ptr(plist_dict_get_item(arguments, "RequestURL"), NULL);
	if (!request_url) {
		logger(LL_ERROR, "%s: Unable to extract RequestURL from Arguments\n", __func__);
		return -1;
	}

	struct curl_slist* header = NULL;

	plist_t headers = plist_dict_get_item(arguments, "RequestAdditionalHeaders");
	if (!headers) {
		logger(LL_ERROR, "%s: Missing 'RequestAdditionalHeaders'\n", __func__);
		return -1;
	}

	uint64_t request_body_size = 0;
	const char* request_body = plist_get_data_ptr(plist_dict_get_item(arguments, "RequestBody"), &request_body_size);
	if (!request_body) {
		logger(LL_ERROR, "%s: Missing 'RequestBody'\n", __func__);
		return -1;
	}

	logger(LL_INFO, "Requesting image decryption key from %s\n", request_url);

	char curl_error_message[CURL_ERROR_SIZE];
	char header_tmp[1024];
	plist_dict_iter iter = NULL;
	plist_dict_new_iter(headers, &iter);
	plist_t node = NULL;
	do {
		char *key = NULL;
		plist_dict_next_item(headers, iter, &key, &node);
		if (!node) break;
		snprintf(header_tmp, sizeof(header_tmp), "%s: %s", key, plist_get_string_ptr(node, NULL));
		curl_slist_append(header, header_tmp);
	} while (node);
	plist_mem_free(iter);

	CURL* handle = curl_easy_init();
	/* disable SSL verification to allow download from untrusted https locations */
	curl_easy_setopt(handle, CURLOPT_SSL_VERIFYPEER, 0);

	query_response* response = malloc(sizeof(query_response));
	if (response == NULL) {
		logger(LL_ERROR, "%s: Unable to allocate sufficient memory\n", __func__);
		return -1;
	}

	response->length = 0;
	response->content = malloc(1);
	response->content[0] = '\0';

	curl_easy_setopt(handle, CURLOPT_ERRORBUFFER, curl_error_message);
	curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, (curl_write_callback)&_curl_write_callback);
	curl_easy_setopt(handle, CURLOPT_HEADERFUNCTION, &_curl_header_callback);
	plist_t response_headers = plist_new_dict();
	curl_easy_setopt(handle, CURLOPT_HEADERDATA, response_headers);
	curl_easy_setopt(handle, CURLOPT_WRITEDATA, response);
	curl_easy_setopt(handle, CURLOPT_HTTPHEADER, header);
	curl_easy_setopt(handle, CURLOPT_POSTFIELDS, request_body);
	curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, (long)request_body_size);
	if (client->debug_level > 0) {
		curl_easy_setopt(handle, CURLOPT_VERBOSE, 1L);
	}
	curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 1);
	curl_easy_setopt(handle, CURLOPT_URL, request_url);
	curl_easy_perform(handle);
	curl_slist_free_all(header);

	long http_response = 0;
	curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &http_response);

	curl_easy_cleanup(handle);

	plist_t dict = plist_new_dict();
	plist_dict_set_item(dict, "ResponseBody", plist_new_data(response->content, response->length));
	plist_dict_set_item(dict, "ResponseBodyDone", plist_new_bool(1));
	plist_dict_set_item(dict, "ResponseHeaders", response_headers);
	plist_dict_set_item(dict, "ResponseStatus", plist_new_uint(http_response));

	free(response);

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	_restore_service_send(service, dict, PLIST_FORMAT_BINARY);
	_restore_service_free(service);

	return 0;
}

int restore_send_component(struct idevicerestore_client_t* client, plist_t message, const char* component, const char* component_name)
{
	size_t size = 0;
	void* data = NULL;
	char* path = NULL;
	plist_t blob = NULL;
	plist_t dict = NULL;
	restored_error_t restore_error = RESTORE_E_SUCCESS;

	if (!client || !client->restore || !client->restore->build_identity) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return -1;
	}

	if (component_name == NULL) {
		component_name = component;
	}

	logger(LL_INFO, "About to send %s...\n", component_name);

	if (client->tss) {
		if (tss_response_get_path_by_entry(client->tss, component, &path) < 0) {
			logger(LL_DEBUG, "No path for component %s in TSS, will fetch from build identity\n", component);
		}
	}
	if (!path) {
		if (build_identity_get_component_path(client->restore->build_identity, component, &path) < 0) {
			logger(LL_ERROR, "Unable to find %s path from build identity\n", component);
			return -1;
		}
	}

	void* component_data = NULL;
	size_t component_size = 0;
	int ret = extract_component(client->ipsw, path, &component_data, &component_size);
	free(path);
	path = NULL;
	if (ret < 0) {
		logger(LL_ERROR, "Unable to extract component %s\n", component);
		return -1;
	}

	ret = personalize_component(client, component, component_data, component_size, client->tss, &data, &size);
	free(component_data);
	component_data = NULL;
	if (ret < 0) {
		logger(LL_ERROR, "Unable to get personalized component %s\n", component);
		return -1;
	}

	dict = plist_new_dict();
	blob = plist_new_data((char*)data, size);
	char compkeyname[256];
	snprintf(compkeyname, sizeof(compkeyname), "%sFile", component_name);
	plist_dict_set_item(dict, compkeyname, blob);
	free(data);

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	logger(LL_INFO, "Sending %s now...\n", component_name);
	restore_error = _restore_service_send(service, dict, 0);
	plist_free(dict);
	_restore_service_free(service);
	if (restore_error != RESTORE_E_SUCCESS) {
		logger(LL_ERROR, "Unable to send component %s data\n", component_name);
		return -1;
	}

	logger(LL_INFO, "Done sending %s\n", component_name);
	return 0;
}

int restore_send_nor(struct idevicerestore_client_t* client, plist_t message)
{
	char* llb_path = NULL;
	char* llb_filename = NULL;
	char* sep_path = NULL;
	char* restore_sep_path = NULL;
	char firmware_path[PATH_MAX - 9];
	char manifest_file[PATH_MAX];
	size_t manifest_size = 0;
	void* manifest_data = NULL;
	char firmware_filename[PATH_MAX];
	size_t llb_size = 0;
	void* llb_data = NULL;
	plist_t dict = NULL;
	size_t nor_size = 0;
	void* nor_data = NULL;
	plist_t norimage = NULL;
	plist_t firmware_files = NULL;
	int flash_version_1 = 0;

	if (!client || !client->restore || !client->restore->build_identity) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return -1;
	}

	logger(LL_INFO, "About to send NORData...\n");

	plist_t arguments = plist_dict_get_item(message, "Arguments");
	if (arguments && plist_get_node_type(arguments) == PLIST_DICT) {
		flash_version_1 = plist_dict_get_item(arguments, "FlashVersion1") ? 1 : 0;
	}

	if (client->tss) {
		if (tss_response_get_path_by_entry(client->tss, "LLB", &llb_path) < 0) {
			logger(LL_DEBUG, "Could not get LLB path from TSS data, will fetch from build identity\n");
		}
	}
	if (llb_path == NULL) {
		if (build_identity_get_component_path(client->restore->build_identity, "LLB", &llb_path) < 0) {
			logger(LL_ERROR, "Unable to get component path for LLB\n");
			return -1;
		}
	}

	llb_filename = strstr(llb_path, "LLB");
	if (llb_filename == NULL) {
		logger(LL_ERROR, "Unable to extract firmware path from LLB filename\n");
		free(llb_path);
		return -1;
	}

	memset(firmware_path, '\0', sizeof(firmware_path));
	memcpy(firmware_path, llb_path, (llb_filename - 1) - llb_path);
	logger(LL_INFO, "Found firmware path %s\n", firmware_path);

	memset(manifest_file, '\0', sizeof(manifest_file));
	snprintf(manifest_file, sizeof(manifest_file), "%s/manifest", firmware_path);

	firmware_files = plist_new_dict();
	if (ipsw_file_exists(client->ipsw, manifest_file)) {
		ipsw_extract_to_memory(client->ipsw, manifest_file, &manifest_data, &manifest_size);
	}
	if (manifest_data && manifest_size > 0) {
		logger(LL_INFO, "Getting firmware manifest from %s\n", manifest_file);
		char *manifest_p = (char*)manifest_data;
		char *filename = NULL;
		while ((filename = strsep(&manifest_p, "\r\n")) != NULL) {
			if (*filename == '\0') continue;
			const char *compname = get_component_name(filename);
			if (!compname) continue;
			memset(firmware_filename, '\0', sizeof(firmware_filename));
			snprintf(firmware_filename, sizeof(firmware_filename), "%s/%s", firmware_path, filename);
			plist_dict_set_item(firmware_files, compname, plist_new_string(firmware_filename));
		}
		free(manifest_data);
	} else {
		logger(LL_INFO, "Getting firmware manifest from build identity\n");
		plist_dict_iter iter = NULL;
		plist_t build_id_manifest = plist_dict_get_item(client->restore->build_identity, "Manifest");
		if (build_id_manifest) {
			plist_dict_new_iter(build_id_manifest, &iter);
		}
		if (iter) {
			char *component = NULL;
			plist_t manifest_entry;
			do {
				component = NULL;
				manifest_entry = NULL;
				plist_dict_next_item(build_id_manifest, iter, &component, &manifest_entry);
				if (component && manifest_entry && plist_get_node_type(manifest_entry) == PLIST_DICT) {
					uint8_t is_fw = 0;
					uint8_t is_secondary_fw = 0;
					uint8_t loaded_by_iboot = 0;
					plist_t fw_node;

					fw_node = plist_access_path(manifest_entry, 2, "Info", "IsFirmwarePayload");
					if (fw_node && plist_get_node_type(fw_node) == PLIST_BOOLEAN) {
						plist_get_bool_val(fw_node, &is_fw);
					}

					fw_node = plist_access_path(manifest_entry, 2, "Info", "IsLoadedByiBoot");
					if (fw_node && plist_get_node_type(fw_node) == PLIST_BOOLEAN) {
						plist_get_bool_val(fw_node, &loaded_by_iboot);
					}

					fw_node = plist_access_path(manifest_entry, 2, "Info", "IsSecondaryFirmwarePayload");
					if (fw_node && plist_get_node_type(fw_node) == PLIST_BOOLEAN) {
						plist_get_bool_val(fw_node, &is_secondary_fw);
					}

					if (is_fw || (is_secondary_fw && loaded_by_iboot)) {
						plist_t comp_path = plist_access_path(manifest_entry, 2, "Info", "Path");
						if (comp_path) {
							plist_dict_set_item(firmware_files, component, plist_copy(comp_path));
						}
					}
				}
				free(component);
			} while (manifest_entry);
			free(iter);
		}
	}

	if (plist_dict_get_size(firmware_files) == 0) {
		logger(LL_ERROR, "Unable to get list of firmware files.\n");
		return -1;
	}

	const char* component = "LLB";
	void* component_data = NULL;
	size_t component_size = 0;
	int ret = extract_component(client->ipsw, llb_path, &component_data, &component_size);
	free(llb_path);
	if (ret < 0) {
		logger(LL_ERROR, "Unable to extract component: %s\n", component);
		return -1;
	}

	ret = personalize_component(client, component, component_data, component_size, client->tss, &llb_data, &llb_size);
	free(component_data);
	component_data = NULL;
	component_size = 0;
	if (ret < 0) {
		logger(LL_ERROR, "Unable to get personalized component: %s\n", component);
		return -1;
	}

	dict = plist_new_dict();
	plist_dict_set_item(dict, "LlbImageData", plist_new_data((char*)llb_data, llb_size));
	free(llb_data);

	if (flash_version_1) {
		norimage = plist_new_dict();
	} else {
		norimage = plist_new_array();
	}

	plist_dict_iter iter = NULL;
	plist_dict_new_iter(firmware_files, &iter);
	while (iter) {
		char *comp = NULL;
		plist_t pcomp = NULL;
		plist_dict_next_item(firmware_files, iter, &comp, &pcomp);
		if (!comp) {
			break;
		}
		char *comppath = NULL;
		plist_get_string_val(pcomp, &comppath);
		if (!comppath) {
			free(comp);
			continue;
		}

		component = (const char*)comp;
		if (!strcmp(component, "LLB") || !strcmp(component, "RestoreSEP")) {
			// skip LLB, it's already passed in LlbImageData
			// skip RestoreSEP, it's passed in RestoreSEPImageData
			free(comp);
			free(comppath);
			continue;
		}

		component_data = NULL;
		component_size = 0;

		if (extract_component(client->ipsw, comppath, &component_data, &component_size) < 0) {
			free(iter);
			free(comp);
			free(comppath);
			plist_free(firmware_files);
			logger(LL_ERROR, "Unable to extract component: %s\n", component);
			return -1;
		}

		if (personalize_component(client, component, component_data, component_size, client->tss, &nor_data, &nor_size) < 0) {
			free(iter);
			free(comp);
			free(comppath);
			free(component_data);
			plist_free(firmware_files);
			logger(LL_ERROR, "Unable to get personalized component: %s\n", component);
			return -1;
		}
		free(component_data);
		component_data = NULL;
		component_size = 0;

		if (flash_version_1) {
			plist_dict_set_item(norimage, component, plist_new_data((char*)nor_data, nor_size));
		} else {
			/* make sure iBoot is the first entry in the array */
			if (!strncmp("iBoot", component, 5)) {
				plist_array_insert_item(norimage, plist_new_data((char*)nor_data, nor_size), 0);
			} else {
				plist_array_append_item(norimage, plist_new_data((char*)nor_data, nor_size));
			}
		}

		free(comp);
		free(comppath);
		free(nor_data);
		nor_data = NULL;
		nor_size = 0;
	}
	free(iter);
	plist_free(firmware_files);
	plist_dict_set_item(dict, "NorImageData", norimage);

	void* personalized_data = NULL;
	size_t personalized_size = 0;

	if (build_identity_has_component(client->restore->build_identity, "RestoreSEP") &&
	    build_identity_get_component_path(client->restore->build_identity, "RestoreSEP", &restore_sep_path) == 0) {
		component = "RestoreSEP";
		ret = extract_component(client->ipsw, restore_sep_path, &component_data, &component_size);
		free(restore_sep_path);
		if (ret < 0) {
			logger(LL_ERROR, "Unable to extract component: %s\n", component);
			return -1;
		}

		ret = personalize_component(client, component, component_data, component_size, client->tss, &personalized_data, &personalized_size);
		free(component_data);
		component_data = NULL;
		component_size = 0;
		if (ret < 0) {
			logger(LL_ERROR, "Unable to get personalized component: %s\n", component);
			return -1;
		}

		plist_dict_set_item(dict, "RestoreSEPImageData", plist_new_data((char*)personalized_data, personalized_size));
		free(personalized_data);
		personalized_data = NULL;
		personalized_size = 0;
	}

	if (build_identity_has_component(client->restore->build_identity, "SEP") &&
	    build_identity_get_component_path(client->restore->build_identity, "SEP", &sep_path) == 0) {
		component = "SEP";
		ret = extract_component(client->ipsw, sep_path, &component_data, &component_size);
		free(sep_path);
		if (ret < 0) {
			logger(LL_ERROR, "Unable to extract component: %s\n", component);
			return -1;
		}

		ret = personalize_component(client, component, component_data, component_size, client->tss, &personalized_data, &personalized_size);
		free(component_data);
		component_data = NULL;
		component_size = 0;
		if (ret < 0) {
			logger(LL_ERROR, "Unable to get personalized component: %s\n", component);
			return -1;
		}

		plist_dict_set_item(dict, "SEPImageData", plist_new_data((char*)personalized_data, personalized_size));
		free(personalized_data);
		personalized_data = NULL;
		personalized_size = 0;
	}

	if (build_identity_has_component(client->restore->build_identity, "SepStage1") &&
	    build_identity_get_component_path(client->restore->build_identity, "SepStage1", &sep_path) == 0) {
		component = "SepStage1";
		ret = extract_component(client->ipsw, sep_path, &component_data, &component_size);
		free(sep_path);
		if (ret < 0) {
			logger(LL_ERROR, "Unable to extract component: %s\n", component);
			return -1;
		}

		ret = personalize_component(client, component, component_data, component_size, client->tss, &personalized_data, &personalized_size);
		free(component_data);
		component_data = NULL;
		component_size = 0;
		if (ret < 0) {
			logger(LL_ERROR, "Unable to get personalized component: %s\n", component);
			return -1;
		}

		plist_dict_set_item(dict, "SEPPatchImageData", plist_new_data((char*)personalized_data, personalized_size));
		free(personalized_data);
		personalized_data = NULL;
		personalized_size = 0;
	}

	if (client->debug_level > 1)
		logger_dump_plist(LL_DEBUG, dict, 0);

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	logger(LL_INFO, "Sending NORData now...\n");
	restored_error_t restore_error = _restore_service_send(service, dict, 0);
	plist_free(dict);
	_restore_service_free(service);
	if (restore_error != RESTORE_E_SUCCESS) {
		logger(LL_ERROR, "Unable to send NORData\n");
		return -1;
	}

	logger(LL_INFO, "Done sending NORData\n");
	return 0;
}

static const char* restore_get_bbfw_fn_for_element(const char* elem, uint32_t bb_chip_id)
{
	struct bbfw_fn_elem_t {
		const char* element;
		const char* fn;
	};

	struct bbfw_fn_elem_t bbfw_fn_elem[] = {
		// ICE3 firmware files
		{ "RamPSI", "psi_ram.fls" },
		{ "FlashPSI", "psi_flash.fls" },
		// Trek firmware files
		{ "eDBL", "dbl.mbn" },
		{ "RestoreDBL", "restoredbl.mbn" },
		// Phoenix/Mav4 firmware files
		{ "DBL", "dbl.mbn" },
		{ "ENANDPRG", "ENPRG.mbn" },
		// Mav5 firmware files
		{ "RestoreSBL1", "restoresbl1.mbn" },
		{ "SBL1", "sbl1.mbn" },
		// ICE16 firmware files
		{ "RestorePSI", "restorepsi.bin" },
		{ "PSI", "psi_ram.bin" },
		// ICE19 firmware files
		{ "RestorePSI2", "restorepsi2.bin" },
		{ "PSI2", "psi_ram2.bin" },
		// Mav20 Firmware file
		{ "Misc", "multi_image.mbn" },
		{ NULL, NULL }
	};

	struct bbfw_fn_elem_t bbfw_fn_elem_mav25[] = {
		// Mav25 Firmware files
		{ "Misc", "multi_image.mbn" },
		{ "RestoreSBL1", "restorexbl_sc.elf" },
		{ "SBL1", "xbl_sc.elf" },
		{ "TME", "signed_firmware_soc_view.elf" },
		{ NULL, NULL }
	};

	struct bbfw_fn_elem_t* bbfw_fn_elems = (struct bbfw_fn_elem_t*)bbfw_fn_elem;
	if (bb_chip_id == 0x1F30E1) {
		bbfw_fn_elems = (struct bbfw_fn_elem_t*)bbfw_fn_elem_mav25;
	}

	int i;
	for (i = 0; bbfw_fn_elems[i].element != NULL; i++) {
		if (strcmp(bbfw_fn_elems[i].element, elem) == 0) {
			return bbfw_fn_elems[i].fn;
		}
	}
	return NULL;
}

static int restore_sign_bbfw(const char* bbfwtmp, plist_t bbtss, const unsigned char* bb_nonce, uint32_t bb_chip_id)
{
	int res = -1;

	// check for BBTicket in result
	plist_t bbticket = plist_dict_get_item(bbtss, "BBTicket");
	if (!bbticket || plist_get_node_type(bbticket) != PLIST_DATA) {
		logger(LL_ERROR, "Could not find BBTicket in Baseband TSS response\n");
		return -1;
	}

	plist_t bbfw_dict = plist_dict_get_item(bbtss, "BasebandFirmware");
	if (!bbfw_dict || plist_get_node_type(bbfw_dict) != PLIST_DICT) {
		logger(LL_ERROR, "Could not find BasebandFirmware Dictionary node in Baseband TSS response\n");
		return -1;
	}

	unsigned char* buffer = NULL;
	const unsigned char* blob = NULL;
	unsigned char* fdata = NULL;
	uint64_t fsize = 0;
	uint64_t blob_size = 0;
	int zerr = 0;
	int64_t zindex = -1;
	struct zip_stat zstat;
	struct zip_file* zfile = NULL;
	struct zip* za = NULL;
	struct zip_source* zs = NULL;
	fls_file* fls = NULL;

	za = zip_open(bbfwtmp, 0, &zerr);
	if (!za) {
		logger(LL_ERROR, "Could not open ZIP archive '%s': %d\n", bbfwtmp, zerr);
		goto leave;
	}

	plist_dict_iter iter = NULL;
	plist_dict_new_iter(bbfw_dict, &iter);
	if (!iter) {
		logger(LL_ERROR, "Could not create dict iter for BasebandFirmware Dictionary\n");
		return -1;
	}

	int is_fls = 0;
	int64_t signed_file_idxs[16];
	int signed_file_count = 0;
	char* key = NULL;
	plist_t node = NULL;
	while (1) {
		plist_dict_next_item(bbfw_dict, iter, &key, &node);
		if (key == NULL)
			break;
		if (node && (strcmp(key + (strlen(key) - 5), "-Blob") == 0) && (plist_get_node_type(node) == PLIST_DATA)) {
			char *ptr = strchr(key, '-');
			*ptr = '\0';
			const char* signfn = restore_get_bbfw_fn_for_element(key, bb_chip_id);
			if (!signfn) {
				logger(LL_ERROR, "can't match element name '%s' to baseband firmware file name.\n", key);
				goto leave;
			}
			char* ext = strrchr(signfn, '.');
			if (!strcmp(ext, ".fls")) {
				is_fls = 1;
			}

			zindex = zip_name_locate(za, signfn, 0);
			if (zindex < 0) {
				logger(LL_ERROR, "can't locate '%s' in '%s'\n", signfn, bbfwtmp);
				goto leave;
			}

			zip_stat_init(&zstat);
			if (zip_stat_index(za, zindex, 0, &zstat) != 0) {
				logger(LL_ERROR, "zip_stat_index failed for index %" PRIi64 "\n", zindex);
				goto leave;
			}

			zfile = zip_fopen_index(za, zindex, 0);
			if (zfile == NULL) {
				logger(LL_ERROR, "zip_fopen_index failed for index %" PRIi64 "\n", zindex);
				goto leave;
			}

			buffer = (unsigned char*) malloc(zstat.size + 1);
			if (buffer == NULL) {
				logger(LL_ERROR, "Out of memory\n");
				goto leave;
			}

			if (zip_fread(zfile, buffer, zstat.size) != zstat.size) {
				logger(LL_ERROR, "zip_fread: failed\n");
				goto leave;
			}
			buffer[zstat.size] = '\0';

			zip_fclose(zfile);
			zfile = NULL;

			if (is_fls) {
				fls = fls_parse(buffer, zstat.size);
				if (!fls) {
					logger(LL_ERROR, "could not parse fls file\n");
					goto leave;
				}
			}

			blob_size = 0;
			blob = (const unsigned char*)plist_get_data_ptr(node, &blob_size);
			if (!blob) {
				logger(LL_ERROR, "could not get %s-Blob data\n", key);
				goto leave;
			}

			logger(LL_VERBOSE, "Stitching %s\n", signfn);
			if (is_fls) {
				if (fls_update_sig_blob(fls, blob, (size_t)blob_size) != 0) {
					logger(LL_ERROR, "Could not stitch %s\n", signfn);
					goto leave;
				}
				fsize = fls->size;
				fdata = (unsigned char*)malloc(fsize);
				if (fdata == NULL)  {
					logger(LL_ERROR, "out of memory\n");
					goto leave;
				}
				memcpy(fdata, fls->data, fsize);
				fls_free(fls);
				fls = NULL;
			} else if (bb_chip_id == 0x1F30E1) { // Mav25 - Qualcomm Snapdragon X80 5G Modem
				fdata = mbn_mav25_stitch(buffer, zstat.size, blob, (size_t)blob_size);
				fsize = zstat.size;
				if (!fdata) {
					logger(LL_ERROR, "Could not stitch %s\n", signfn);
					goto leave;
				}
			} else {
				fdata = mbn_stitch(buffer, zstat.size, blob, (size_t)blob_size);
				fsize = zstat.size;
				if (!fdata) {
					logger(LL_ERROR, "Could not stitch %s\n", signfn);
					goto leave;
				}
			}
			free(buffer);
			buffer = NULL;

			zs = zip_source_buffer(za, fdata, fsize, 1);
			if (!zs) {
				logger(LL_ERROR, "out of memory\n");
				free(fdata);
				goto leave;
			}

			if (zip_file_replace(za, zindex, zs, 0) == -1) {
				logger(LL_ERROR, "Could not update signed '%s' in archive\n", signfn);
				goto leave;
			}

			if (is_fls && !bb_nonce) {
				if (strcmp(key, "RamPSI") == 0) {
					signed_file_idxs[signed_file_count++] = zindex;
				}
			} else {
				signed_file_idxs[signed_file_count++] = zindex;
			}
		}
		free(key);
	}
	free(iter);

	// remove everything but required files
	int64_t i, numf = zip_get_num_entries(za, 0);
	for (i = 0; i < numf; i++) {
		int j;
		int keep = 0;
		// check for signed file index
		for (j = 0; j < signed_file_count; j++) {
			if (i == signed_file_idxs[j]) {
				keep = 1;
				break;
			}
		}
		// check for anything but .mbn and .fls if bb_nonce is set
		const char* fn = zip_get_name(za, i, 0);
		if (!keep) {
			if (fn) {
				char* ext = strrchr(fn, '.');
				if (ext && (!strcmp(ext, ".fls") || !strcmp(ext, ".mbn") || !strcmp(ext, ".elf") || !strcmp(ext, ".bin"))) {
					keep = 1;
				}
			}
		}
		if (!keep) {
			logger(LL_DEBUG, "%s: removing %s from bbfw\n", __func__, fn);
			zip_delete(za, i);
		} else {
			logger(LL_DEBUG, "%s: keeping %s in bbfw\n", __func__, fn);
		}
	}

	if (bbticket) {
		if (is_fls) {
			// add BBTicket to file ebl.fls
			zindex = zip_name_locate(za, "ebl.fls", 0);
			if (zindex < 0) {
				logger(LL_ERROR, "can't locate 'ebl.fls' in '%s'\n", bbfwtmp);
				goto leave;
			}

			zip_stat_init(&zstat);
			if (zip_stat_index(za, zindex, 0, &zstat) != 0) {
				logger(LL_ERROR, "zip_stat_index failed for index %" PRIi64 "\n", zindex);
				goto leave;
			}

			zfile = zip_fopen_index(za, zindex, 0);
			if (zfile == NULL) {
				logger(LL_ERROR, "zip_fopen_index failed for index %" PRIi64 "\n", zindex);
				goto leave;
			}

			buffer = (unsigned char*) malloc(zstat.size + 1);
			if (buffer == NULL) {
				logger(LL_ERROR, "Out of memory\n");
				goto leave;
			}

			if (zip_fread(zfile, buffer, zstat.size) != zstat.size) {
				logger(LL_ERROR, "zip_fread: failed\n");
				goto leave;
			}
			buffer[zstat.size] = '\0';

			zip_fclose(zfile);
			zfile = NULL;

			fls = fls_parse(buffer, zstat.size);
			free(buffer);
			buffer = NULL;
			if (!fls) {
				logger(LL_ERROR, "could not parse fls file\n");
				goto leave;
			}

			blob_size = 0;
			blob = (const unsigned char*)plist_get_data_ptr(bbticket, &blob_size);
			if (!blob) {
				logger(LL_ERROR, "could not get BBTicket data\n");
				goto leave;
			}

			if (fls_insert_ticket(fls, blob, (unsigned int)blob_size) != 0) {
				logger(LL_ERROR, "could not insert BBTicket to ebl.fls\n");
				goto leave;
			}

			fsize = fls->size;
			fdata = (unsigned char*)malloc(fsize);
			if (!fdata) {
				logger(LL_ERROR, "out of memory\n");
				goto leave;
			}
			memcpy(fdata, fls->data, fsize);
			fls_free(fls);
			fls = NULL;

			zs = zip_source_buffer(za, fdata, fsize, 1);
			if (!zs) {
				logger(LL_ERROR, "out of memory\n");
				free(fdata);
				goto leave;
			}

			if (zip_file_replace(za, zindex, zs, 0) == -1) {
				logger(LL_ERROR, "could not update archive with ticketed ebl.fls\n");
				goto leave;
			}
		} else {
			// add BBTicket as bbticket.der
			blob_size = 0;
			blob = (const unsigned char*)plist_get_data_ptr(bbticket, &blob_size);
			if (!blob) {
				logger(LL_ERROR, "could not get BBTicket data\n");
				goto leave;
			}

			zs = zip_source_buffer(za, blob, blob_size, 0);
			if (!zs) {
				logger(LL_ERROR, "out of memory\n");
				goto leave;
			}

			if (zip_file_add(za, "bbticket.der", zs, ZIP_FL_OVERWRITE) == -1) {
				logger(LL_ERROR, "could not add bbticket.der to archive\n");
				goto leave;
			}
		}
	}

	// this will write out the modified zip
	if (zip_close(za) == -1) {
		logger(LL_ERROR, "could not close and write modified archive: %s\n", zip_strerror(za));
		res = -1;
	} else {
		res = 0;
	}
	za = NULL;
	zs = NULL;

leave:
	if (zfile) {
		zip_fclose(zfile);
	}
	if (zs) {
		zip_source_free(zs);
	}
	if (za) {
		zip_unchange_all(za);
		zip_close(za);
	}
	fls_free(fls);
	free(buffer);

	return res;
}

static int restore_send_baseband_data(struct idevicerestore_client_t* client, plist_t message)
{
	int res = -1;
	uint64_t bb_cert_id = 0;
	unsigned char* bb_snum = NULL;
	uint64_t bb_snum_size = 0;
	unsigned char* bb_nonce = NULL;
	uint64_t bb_nonce_size = 0;
	uint64_t bb_chip_id = 0;
	plist_t response = NULL;
	char* buffer = NULL;
	char* bbfwtmp = NULL;
	plist_t dict = NULL;

	if (!client || !client->restore || !client->restore->build_identity) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return -1;
	}

	logger(LL_INFO, "About to send BasebandData...\n");

	// NOTE: this function is called 2 or 3 times!

	// setup request data
	plist_t arguments = plist_dict_get_item(message, "Arguments");
	if (arguments && plist_get_node_type(arguments) == PLIST_DICT) {
		plist_t bb_chip_id_node = plist_dict_get_item(arguments, "ChipID");
		if (bb_chip_id_node && plist_get_node_type(bb_chip_id_node) == PLIST_UINT) {
			plist_get_uint_val(bb_chip_id_node, &bb_chip_id);
		}
		plist_t bb_cert_id_node = plist_dict_get_item(arguments, "CertID");
		if (bb_cert_id_node && plist_get_node_type(bb_cert_id_node) == PLIST_UINT) {
			plist_get_uint_val(bb_cert_id_node, &bb_cert_id);
		}
		plist_t bb_snum_node = plist_dict_get_item(arguments, "ChipSerialNo");
		if (bb_snum_node && plist_get_node_type(bb_snum_node) == PLIST_DATA) {
			plist_get_data_val(bb_snum_node, (char**)&bb_snum, &bb_snum_size);
		}
		plist_t bb_nonce_node = plist_dict_get_item(arguments, "Nonce");
		if (bb_nonce_node && plist_get_node_type(bb_nonce_node) == PLIST_DATA) {
			plist_get_data_val(bb_nonce_node, (char**)&bb_nonce, &bb_nonce_size);
		}
	}

	if ((bb_nonce == NULL) || (client->restore->bbtss == NULL)) {
		/* populate parameters */
		plist_t parameters = plist_new_dict();
		plist_dict_set_item(parameters, "ApECID", plist_new_uint(client->ecid));
		if (bb_nonce) {
			plist_dict_set_item(parameters, "BbNonce", plist_new_data((const char*)bb_nonce, bb_nonce_size));
		}
		plist_dict_set_item(parameters, "BbChipID", plist_new_uint(bb_chip_id));
		plist_dict_set_item(parameters, "BbGoldCertId", plist_new_uint(bb_cert_id));
		plist_dict_set_item(parameters, "BbSNUM", plist_new_data((const char*)bb_snum, bb_snum_size));

		tss_parameters_add_from_manifest(parameters, client->restore->build_identity, true);

		/* create baseband request */
		plist_t request = tss_request_new(NULL);
		if (request == NULL) {
			logger(LL_ERROR, "Unable to create Baseband TSS request\n");
			plist_free(parameters);
			return -1;
		}

		/* add baseband parameters */
		tss_request_add_common_tags(request, parameters, NULL);
		tss_request_add_baseband_tags(request, parameters, NULL);

		plist_t node = plist_access_path(client->restore->build_identity, 2, "Info", "FDRSupport");
		if (node && plist_get_node_type(node) == PLIST_BOOLEAN) {
			uint8_t b = 0;
			plist_get_bool_val(node, &b);
			if (b) {
				plist_dict_set_item(request, "ApProductionMode", plist_new_bool(1));
				plist_dict_set_item(request, "ApSecurityMode", plist_new_bool(1));
			}
		}
		logger(LL_INFO, "Sending Baseband TSS request...\n");
		logger_dump_plist(LL_DEBUG, request, 0);
		response = tss_request_send(request, client->tss_url);
		plist_free(request);
		plist_free(parameters);
		if (response == NULL) {
			logger(LL_ERROR, "Unable to fetch Baseband TSS\n");
			return -1;
		}
		logger(LL_INFO, "Received Baseband SHSH blobs\n");
		logger_dump_plist(LL_DEBUG, response, 0);
	}

	// get baseband firmware file path from build identity
	plist_t bbfw_path = plist_access_path(client->restore->build_identity, 4, "Manifest", "BasebandFirmware", "Info", "Path");
	if (!bbfw_path || plist_get_node_type(bbfw_path) != PLIST_STRING) {
		logger(LL_ERROR, "Unable to get BasebandFirmware/Info/Path node\n");
		plist_free(response);
		return -1;
	}
	char* bbfwpath = NULL;
	plist_get_string_val(bbfw_path, &bbfwpath);
	if (!bbfwpath) {
		logger(LL_ERROR, "Unable to get baseband path\n");
		plist_free(response);
		return -1;
	}

	// extract baseband firmware to temp file
	bbfwtmp = get_temp_filename("bbfw_");
	if (!bbfwtmp) {
		size_t l = strlen(client->udid);
		bbfwtmp = malloc(l + 10);
		strcpy(bbfwtmp, "bbfw_");
		strncpy(bbfwtmp + 5, client->udid, l);
		strcpy(bbfwtmp + 5 + l, ".tmp");
		logger(LL_WARNING, "Could not generate temporary filename, using %s in current directory\n", bbfwtmp);
	}
	if (ipsw_extract_to_file(client->ipsw, bbfwpath, bbfwtmp) != 0) {
		logger(LL_ERROR, "Unable to extract baseband firmware from ipsw\n");
		goto leave;
	}

	if (bb_nonce && !client->restore->bbtss) {
		// keep the response for later requests
		client->restore->bbtss = response;
		response = NULL;
	}

	res = restore_sign_bbfw(bbfwtmp, (client->restore->bbtss) ? client->restore->bbtss : response, bb_nonce, bb_chip_id);
	if (res != 0) {
		goto leave;
	}

	res = -1;

	size_t sz = 0;
	if (read_file(bbfwtmp, (void**)&buffer, &sz) < 0) {
		logger(LL_ERROR, "could not read updated bbfw archive\n");
		goto leave;
	}

	// send file
	dict = plist_new_dict();
	plist_dict_set_item(dict, "BasebandData", plist_new_data(buffer, sz));
	free(buffer);
	buffer = NULL;

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	logger(LL_INFO, "Sending BasebandData now...\n");
	if (_restore_service_send(service, dict, 0) != RESTORE_E_SUCCESS) {
		logger(LL_ERROR, "Unable to send BasebandData data\n");
		goto leave;
	}

	_restore_service_free(service);

	logger(LL_INFO, "Done sending BasebandData\n");
	res = 0;

leave:
	plist_free(dict);
	free(buffer);
	if (bbfwtmp) {
		if (client->flags & FLAG_KEEP_PERS) {
			const char* bbfwname = path_get_basename(bbfwtmp);
			logger(LL_VERBOSE, "%s: Keeping personalized BBFW as %s\n", __func__, bbfwname);
			rename(bbfwtmp, bbfwname);
		} else {
			remove(bbfwtmp);
		}
		free(bbfwtmp);
	}
	plist_free(response);

	return res;
}

int restore_send_fdr_trust_data(struct idevicerestore_client_t* client, plist_t message)
{
	restored_error_t restore_error;
	plist_t dict;

	logger(LL_INFO, "About to send FDR Trust data...\n");

	// FIXME: What should we send here?
	/* Sending an empty dict makes it continue with FDR
	 * and this is what iTunes seems to be doing too */
	dict = plist_new_dict();

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	logger(LL_INFO, "Sending FDR Trust data now...\n");
	restore_error = _restore_service_send(service, dict, 0);
	plist_free(dict);
	_restore_service_free(service);
	if (restore_error != RESTORE_E_SUCCESS) {
		logger(LL_ERROR, "During sending FDR Trust data (%d)\n", restore_error);
		return -1;
	}

	logger(LL_INFO, "Done sending FDR Trust Data\n");

	return 0;
}

static int restore_send_image_data(struct idevicerestore_client_t *client, plist_t message, const char *image_list_k, const char *image_type_k, const char *image_data_k)
{
	restored_error_t restore_error;
	plist_t arguments;
	plist_t dict;
	plist_t node;
	plist_t matched_images = NULL;
	plist_t data_dict = NULL;
	plist_t build_id_manifest;
	plist_dict_iter iter = NULL;
	char *image_name = NULL;
	int want_image_list = 0;

	if (!client || !client->restore || !client->restore->build_identity) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return -1;
	}

	arguments = plist_dict_get_item(message, "Arguments");
	want_image_list = plist_dict_get_bool(arguments, image_list_k);
	node = plist_dict_get_item(arguments, "ImageName");
	if (node) {
		plist_get_string_val(node, &image_name);
	}
	if (!image_type_k) {
		node = plist_dict_get_item(arguments, "ImageType");
		if (node) {
			image_type_k = plist_get_string_ptr(node, NULL);
		}
	}
	if (!image_type_k) {
		logger(LL_ERROR, "Missing ImageType\n");
		return -1;
	}

	if (!want_image_list && !image_name) {
		logger(LL_INFO, "About to send %s...\n", image_data_k);
	}

	if (want_image_list) {
		matched_images = plist_new_array();
	} else {
		data_dict = plist_new_dict();
	}

	build_id_manifest = plist_dict_get_item(client->restore->build_identity, "Manifest");
	if (build_id_manifest) {
		plist_dict_new_iter(build_id_manifest, &iter);
	}
	if (iter) {
		char *component;
		plist_t manifest_entry;
		do {
			component = NULL;
			manifest_entry = NULL;
			plist_dict_next_item(build_id_manifest, iter, &component, &manifest_entry);
			if (component && manifest_entry && plist_get_node_type(manifest_entry) == PLIST_DICT) {
				uint8_t is_image_type = 0;
				plist_t is_image_type_node = plist_access_path(manifest_entry, 2, "Info", image_type_k);
				if (is_image_type_node && plist_get_node_type(is_image_type_node) == PLIST_BOOLEAN) {
					plist_get_bool_val(is_image_type_node, &is_image_type);
				}
				if (is_image_type) {
					if (want_image_list) {
						logger(LL_INFO, "Found %s component %s\n", image_type_k, component);
						plist_array_append_item(matched_images, plist_new_string(component));
					} else if (!image_name || !strcmp(image_name, component)) {
						char *path = NULL;
						void* data = NULL;
						size_t size = 0;
						void* component_data = NULL;
						size_t component_size = 0;
						int ret = -1;

						if (!image_name) {
							logger(LL_INFO, "Found %s component '%s'\n", image_type_k, component);
						}
						build_identity_get_component_path(client->restore->build_identity, component, &path);
						if (path) {
							ret = extract_component(client->ipsw, path, &component_data, &component_size);
						}
						free(path);
						path = NULL;
						if (ret < 0) {
							logger(LL_ERROR, "Unable to extract component: %s\n", component);
						}

						ret = personalize_component(client, component, component_data, component_size, client->tss, &data, &size);
						free(component_data);
						component_data = NULL;
						if (ret < 0) {
							logger(LL_ERROR, "Unable to get personalized component: %s\n", component);
						}

						plist_dict_set_item(data_dict, component, plist_new_data((const char*)data, size));
						free(data);
					}
				}
				free(component);
			}
		} while (manifest_entry);
		free(iter);
	}

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	dict = plist_new_dict();
	if (want_image_list) {
		plist_dict_set_item(dict, image_list_k, matched_images);
		logger(LL_INFO, "Sending %s image list\n", image_type_k);
	} else {
		if (image_name) {
			node = plist_dict_get_item(data_dict, image_name);
			if (node) {
				plist_dict_set_item(dict, image_data_k, plist_copy(node));
			}
			plist_dict_set_item(dict, "ImageName", plist_new_string(image_name));
			logger(LL_INFO, "Sending %s for %s...\n", image_type_k, image_name);
		} else {
			plist_dict_set_item(dict, image_data_k, data_dict);
			logger(LL_INFO, "Sending %s now...\n", image_type_k);
		}
	}

	restore_error = _restore_service_send(service, dict, 0);
	plist_free(dict);
	_restore_service_free(service);
	if (restore_error != RESTORE_E_SUCCESS) {
		if (want_image_list) {
			logger(LL_ERROR, "Failed to send %s image list (%d)\n", image_type_k, restore_error);
		} else {
			if (image_name) {
				logger(LL_ERROR, "Failed to send %s for %s (%d)\n", image_type_k, image_name, restore_error);
				free(image_name);
			} else {
				logger(LL_ERROR, "Failed to send %s (%d)\n", image_type_k, restore_error);
			}
		}
		return -1;
	}

	if (!want_image_list) {
		if (image_name) {
			free(image_name);
		} else {
			logger(LL_INFO, "Done sending %s\n", image_type_k);
		}
	}

	return 0;
}

static int _wants_firmware_data(plist_t arguments)
{
	int result = 0;
	plist_t tags = plist_access_path(arguments, 2, "DeviceGeneratedTags", "ResponseTags");
	if (tags) {
		plist_array_iter iter = NULL;
		plist_array_new_iter(tags, &iter);
		plist_t node = NULL;
		do {
			plist_array_next_item(tags, iter, &node);
			if (node) {
				const char* tag = plist_get_string_ptr(node, NULL);
				if (tag && (strcmp(tag, "FirmwareData") == 0)) {
					result = 1;
				}
			}
		} while (node);
		plist_mem_free(iter);
	}
	return result;
}

static plist_t restore_get_se_firmware_data(struct idevicerestore_client_t* client, plist_t p_info, plist_t arguments)
{
	const char *comp_name = NULL;
	char *comp_path = NULL;
	void* component_data = NULL;
	size_t component_size = 0;
	plist_t parameters = NULL;
	plist_t request = NULL;
	plist_t response = NULL;
	plist_t p_dgr = NULL;
	int ret;
	uint64_t chip_id = 0;

	if (!client || !client->restore || !client->restore->build_identity) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return NULL;
	}

	plist_t node = plist_dict_get_item(p_info, "SE,ChipID");
	if (node && plist_get_node_type(node) == PLIST_UINT) {
		plist_get_uint_val(node, &chip_id);
	}
	if (chip_id == 0x20211) {
		comp_name = "SE,Firmware";
	} else if (chip_id == 0x73 || chip_id == 0x64 || chip_id == 0xC8 || chip_id == 0xD2 || chip_id == 0x2C || chip_id == 0x36 || chip_id == 0x37) {
		comp_name = "SE,UpdatePayload";
	} else {
		logger(LL_WARNING, "Unknown SE,ChipID 0x%" PRIx64 " detected. Restore might fail.\n", (uint64_t)chip_id);
		if (build_identity_has_component(client->restore->build_identity, "SE,UpdatePayload"))
			comp_name = "SE,UpdatePayload";
		else if (build_identity_has_component(client->restore->build_identity, "SE,Firmware"))
			comp_name = "SE,Firmware";
		else {
			logger(LL_ERROR, "Neither 'SE,Firmware' nor 'SE,UpdatePayload' found in build identity.\n");
			return NULL;
		}
		logger(LL_DEBUG, "%s: using %s\n", __func__, comp_name);
	}

	p_dgr = plist_dict_get_item(arguments, "DeviceGeneratedRequest");
	if (!p_dgr) {
		logger(LL_NOTICE, "%s: No DeviceGeneratedRequest in firmware updater data request. Continuing anyway.\n", __func__);
	} else if (!PLIST_IS_DICT(p_dgr)) {
		logger(LL_ERROR, "%s: DeviceGeneratedRequest has invalid type!\n", __func__);
		return NULL;
	}

	/* create SE request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		logger(LL_ERROR, "Unable to create SE TSS request\n");
		free(component_data);
		return NULL;
	}

	parameters = plist_new_dict();

	/* add manifest for current build_identity to parameters */
	tss_parameters_add_from_manifest(parameters, client->restore->build_identity, true);

	/* add SE,* tags from info dictionary to parameters */
	plist_dict_merge(&parameters, p_info);

	/* add required tags for SE TSS request */
	tss_request_add_se_tags(request, parameters, p_dgr);

	plist_free(parameters);

	logger(LL_INFO, "Sending SE TSS request...\n");
	response = tss_request_send(request, client->tss_url);
	plist_free(request);
	if (response == NULL) {
		logger(LL_ERROR, "Unable to fetch SE ticket\n");
		free(component_data);
		return NULL;
	}

	if (plist_dict_get_item(response, "SE2,Ticket")) {
		logger(LL_INFO, "Received SE2,Ticket\n");
	} else if (plist_dict_get_item(response, "SE,Ticket")) {
		logger(LL_INFO, "Received SE,Ticket\n");
	} else {
		logger(LL_ERROR, "No 'SE ticket' in TSS response, this might not work\n");
	}

	/* don't add FirmwareData if not requested via ResponseTags */
	if (!_wants_firmware_data(arguments)) {
		logger(LL_DEBUG, "Not adding FirmwareData as it was not requested\n");
		return response;
	}

	if (build_identity_get_component_path(client->restore->build_identity, comp_name, &comp_path) < 0) {
		plist_free(response);
		logger(LL_ERROR, "Unable to get path for '%s' component\n", comp_name);
		return NULL;
	}

	ret = extract_component(client->ipsw, comp_path, &component_data, &component_size);
	free(comp_path);
	comp_path = NULL;
	if (ret < 0) {
		plist_free(response);
		logger(LL_ERROR, "Unable to extract '%s' component\n", comp_name);
		return NULL;
	}

	plist_dict_set_item(response, "FirmwareData", plist_new_data((char*)component_data, component_size));
	free(component_data);
	component_data = NULL;
	component_size = 0;

	return response;
}

static plist_t restore_get_savage_firmware_data(struct idevicerestore_client_t* client, plist_t p_info, plist_t arguments)
{
	char *comp_name = NULL;
	char *comp_path = NULL;
	void* component_data = NULL;
	size_t component_size = 0;
	void* component_data_tmp = NULL;
	plist_t parameters = NULL;
	plist_t request = NULL;
	plist_t response = NULL;
	int ret;

	if (!client || !client->restore || !client->restore->build_identity) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return NULL;
	}

	plist_t device_generated_request = plist_dict_get_item(arguments, "DeviceGeneratedRequest");
	if (device_generated_request && !PLIST_IS_DICT(device_generated_request)) {
		logger(LL_ERROR, "%s: DeviceGeneratedRequest has invalid type!\n", __func__);
		return NULL;
	}

	/* create Savage request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		logger(LL_ERROR, "Unable to create Savage TSS request\n");
		return NULL;
	}

	parameters = plist_new_dict();

	/* add manifest for current build_identity to parameters */
	tss_parameters_add_from_manifest(parameters, client->restore->build_identity, true);

	/* add Savage,* tags from info dictionary to parameters */
	plist_dict_merge(&parameters, p_info);

	/* add required tags for Savage TSS request */
	tss_request_add_savage_tags(request, parameters, device_generated_request, &comp_name);

	plist_free(parameters);

	if (!comp_name) {
		logger(LL_ERROR, "Could not determine Savage firmware component\n");
		plist_free(request);
		return NULL;
	}
	logger(LL_DEBUG, "%s: using %s\n", __func__, comp_name);

	logger(LL_INFO, "Sending Savage TSS request...\n");
	response = tss_request_send(request, client->tss_url);
	plist_free(request);
	if (response == NULL) {
		logger(LL_ERROR, "Unable to fetch Savage ticket\n");
		free(comp_name);
		return NULL;
	}

	if (plist_dict_get_item(response, "Savage,Ticket")) {
		logger(LL_INFO, "Received Savage ticket\n");
	} else {
		logger(LL_ERROR, "No 'Savage,Ticket' in TSS response, this might not work\n");
	}

	/* don't add FirmwareData if not requested via ResponseTags */
	if (!_wants_firmware_data(arguments)) {
		logger(LL_DEBUG, "Not adding FirmwareData as it was not requested\n");
		return response;
	}

	/* now get actual component data */
	if (build_identity_get_component_path(client->restore->build_identity, comp_name, &comp_path) < 0) {
		plist_free(response);
		logger(LL_ERROR, "Unable to get path for '%s' component\n", comp_name);
		free(comp_name);
		return NULL;
	}

	ret = extract_component(client->ipsw, comp_path, &component_data, &component_size);
	free(comp_path);
	comp_path = NULL;
	if (ret < 0) {
		plist_free(response);
		logger(LL_ERROR, "Unable to extract '%s' component\n", comp_name);
		free(comp_name);
		return NULL;
	}
	free(comp_name);
	comp_name = NULL;

	component_data_tmp = realloc(component_data, (size_t)component_size+16);
	if (!component_data_tmp) {
		free(component_data);
		plist_free(response);
		return NULL;
	}
	component_data = component_data_tmp;
	memmove(component_data + 16, component_data, (size_t)component_size);
	memset(component_data, '\0', 16);
	*(uint32_t*)(component_data + 4) = htole32((uint32_t)component_size);
	component_size += 16;

	plist_dict_set_item(response, "FirmwareData", plist_new_data((char*)component_data, component_size));
	free(component_data);
	component_data = NULL;
	component_size = 0;

	return response;
}

static plist_t restore_get_yonkers_firmware_data(struct idevicerestore_client_t* client, plist_t p_info, plist_t arguments)
{
	char *comp_name = NULL;
	char *comp_path = NULL;
	void* component_data = NULL;
	size_t component_size = 0;
	plist_t parameters = NULL;
	plist_t request = NULL;
	plist_t response = NULL;
	int ret;

	if (!client || !client->restore || !client->restore->build_identity) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return NULL;
	}

	plist_t device_generated_request = plist_dict_get_item(arguments, "DeviceGeneratedRequest");
	if (device_generated_request && !PLIST_IS_DICT(device_generated_request)) {
		logger(LL_ERROR, "%s: DeviceGeneratedRequest has invalid type!\n", __func__);
		return NULL;
	}

	/* create Yonkers request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		logger(LL_ERROR, "Unable to create Yonkers TSS request\n");
		return NULL;
	}

	parameters = plist_new_dict();

	/* add manifest for current build_identity to parameters */
	tss_parameters_add_from_manifest(parameters, client->restore->build_identity, true);

	/* add Yonkers,* tags from info dictionary to parameters */
	plist_dict_merge(&parameters, p_info);

	/* add required tags for Yonkers TSS request */
	tss_request_add_yonkers_tags(request, parameters, device_generated_request, &comp_name);

	plist_free(parameters);

	if (!comp_name) {
		logger(LL_ERROR, "Could not determine Yonkers firmware component\n");
		plist_free(request);
		return NULL;
	}
	logger(LL_DEBUG, "%s: using %s\n", __func__, comp_name);

	logger(LL_INFO, "Sending Yonkers TSS request...\n");
	response = tss_request_send(request, client->tss_url);
	plist_free(request);
	if (response == NULL) {
		logger(LL_ERROR, "Unable to fetch Yonkers ticket\n");
		free(comp_name);
		return NULL;
	}

	if (plist_dict_get_item(response, "Yonkers,Ticket")) {
		logger(LL_INFO, "Received Yonkers ticket\n");
	} else {
		logger(LL_ERROR, "No 'Yonkers,Ticket' in TSS response, this might not work\n");
	}

	/* don't add FirmwareData if not requested via ResponseTags */
	if (!_wants_firmware_data(arguments)) {
		logger(LL_DEBUG, "Not adding FirmwareData as it was not requested\n");
		free(comp_name);
		return response;
	}

	if (build_identity_get_component_path(client->restore->build_identity, comp_name, &comp_path) < 0) {
		plist_free(response);
		logger(LL_ERROR, "Unable to get path for '%s' component\n", comp_name);
		free(comp_name);
		return NULL;
	}

	/* now get actual component data */
	ret = extract_component(client->ipsw, comp_path, &component_data, &component_size);
	free(comp_path);
	comp_path = NULL;
	if (ret < 0) {
		plist_free(response);
		logger(LL_ERROR, "Unable to extract '%s' component\n", comp_name);
		free(comp_name);
		return NULL;
	}
	free(comp_name);
	comp_name = NULL;

	plist_t firmware_data = plist_new_dict();
	plist_dict_set_item(firmware_data, "YonkersFirmware", plist_new_data((char*)component_data, component_size));
	plist_dict_set_item(response, "FirmwareData", firmware_data);

	free(component_data);
	component_data = NULL;
	component_size = 0;

	return response;
}

static plist_t restore_get_rose_firmware_data(struct idevicerestore_client_t* client, plist_t p_info, plist_t arguments)
{
	char *comp_name = NULL;
	char *comp_path = NULL;
	void* component_data = NULL;
	size_t component_size = 0;
	ftab_t ftab = NULL;
	ftab_t rftab = NULL;
	uint32_t ftag = 0;
	plist_t parameters = NULL;
	plist_t request = NULL;
	plist_t response = NULL;
	int ret;

	if (!client || !client->restore || !client->restore->build_identity) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return NULL;
	}

	/* create Rose request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		logger(LL_ERROR, "Unable to create Rose TSS request\n");
		return NULL;
	}

	parameters = plist_new_dict();

	/* add manifest for current build_identity to parameters */
	tss_parameters_add_from_manifest(parameters, client->restore->build_identity, true);

	plist_dict_set_item(parameters, "ApProductionMode", plist_new_bool(1));
	if (client->image4supported) {
		plist_dict_set_item(parameters, "ApSecurityMode", plist_new_bool(1));
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(1));
	} else {
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(0));
	}

	plist_t device_generated_request = plist_dict_get_item(arguments, "DeviceGeneratedRequest");
	if (device_generated_request) {
		/* use DeviceGeneratedRequest if present */
		plist_dict_merge(&request, device_generated_request);
	} else {
		/* add Rap,* tags from info dictionary to parameters */
		plist_dict_merge(&parameters, p_info);
	}

	/* add required tags for Rose TSS request */
	tss_request_add_rose_tags(request, parameters, NULL);

	plist_free(parameters);

	logger(LL_INFO, "Sending Rose TSS request...\n");
	response = tss_request_send(request, client->tss_url);
	plist_free(request);
	if (response == NULL) {
		logger(LL_ERROR, "Unable to fetch Rose ticket\n");
		return NULL;
	}

	if (plist_dict_get_item(response, "Rap,Ticket")) {
		logger(LL_INFO, "Received Rose ticket\n");
	} else {
		logger(LL_ERROR, "No 'Rap,Ticket' in TSS response, this might not work\n");
	}

	/* don't add FirmwareData if not requested via ResponseTags */
	if (!_wants_firmware_data(arguments)) {
		logger(LL_DEBUG, "Not adding FirmwareData as it was not requested\n");
		return response;
	}

	comp_name = "Rap,RTKitOS";
	if (build_identity_get_component_path(client->restore->build_identity, comp_name, &comp_path) < 0) {
		plist_free(response);
		logger(LL_ERROR, "Unable to get path for '%s' component\n", comp_name);
		return NULL;
	}
	ret = extract_component(client->ipsw, comp_path, &component_data, &component_size);
	free(comp_path);
	comp_path = NULL;
	if (ret < 0) {
		plist_free(response);
		logger(LL_ERROR, "Unable to extract '%s' component\n", comp_name);
		return NULL;
	}
	if (ftab_parse(component_data, component_size, &ftab, &ftag) != 0) {
		plist_free(response);
		free(component_data);
		logger(LL_ERROR, "Failed to parse '%s' component data.\n", comp_name);
		return NULL;
	}
	free(component_data);
	component_data = NULL;
	component_size = 0;
	if (ftag != 'rkos') {
		logger(LL_WARNING, "Unexpected tag 0x%08x, expected 0x%08x; continuing anyway.\n", ftag, 'rkos');
	}

	comp_name = "Rap,RestoreRTKitOS";
	if (build_identity_has_component(client->restore->build_identity, comp_name)) {
		if (build_identity_get_component_path(client->restore->build_identity, comp_name, &comp_path) < 0) {
			ftab_free(ftab);
			plist_free(response);
			logger(LL_ERROR, "Unable to get path for '%s' component\n", comp_name);
			return NULL;
		}
		ret = extract_component(client->ipsw, comp_path, &component_data, &component_size);
		free(comp_path);
		comp_path = NULL;
		if (ret < 0) {
			ftab_free(ftab);
			plist_free(response);
			logger(LL_ERROR, "Unable to extract '%s' component\n", comp_name);
			return NULL;
		}

		ftag = 0;
		if (ftab_parse(component_data, component_size, &rftab, &ftag) != 0) {
			free(component_data);
			ftab_free(ftab);
			plist_free(response);
			logger(LL_ERROR, "Failed to parse '%s' component data.\n", comp_name);
			return NULL;
		}
		free(component_data);
		component_data = NULL;
		component_size = 0;
		if (ftag != 'rkos') {
			logger(LL_WARNING, "Unexpected tag 0x%08x, expected 0x%08x; continuing anyway.\n", ftag, 'rkos');
		}

		if (ftab_get_entry_ptr(rftab, 'rrko', &component_data, &component_size) == 0) {
			ftab_add_entry(ftab, 'rrko', component_data, component_size);
		} else {
			logger(LL_ERROR, "Could not find 'rrko' entry in ftab. This will probably break things.\n");
		}
		ftab_free(rftab);
		component_data = NULL;
		component_size = 0;
	} else {
		logger(LL_NOTICE, "Build identity does not have a '%s' component.\n", comp_name);
	}

	ftab_write(ftab, &component_data, &component_size);
	ftab_free(ftab);

	plist_dict_set_item(response, "FirmwareData", plist_new_data((char*)component_data, component_size));
	free(component_data);
	component_data = NULL;
	component_size = 0;

	return response;
}

static plist_t restore_get_veridian_firmware_data(struct idevicerestore_client_t* client, plist_t p_info, plist_t arguments)
{
	char *comp_name = "BMU,FirmwareMap";
	char *comp_path = NULL;
	void* component_data = NULL;
	size_t component_size = 0;
	plist_t parameters = NULL;
	plist_t request = NULL;
	plist_t response = NULL;
	int ret;

	if (!client || !client->restore || !client->restore->build_identity) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return NULL;
	}

	plist_t device_generated_request = plist_dict_get_item(arguments, "DeviceGeneratedRequest");
	if (device_generated_request && !PLIST_IS_DICT(device_generated_request)) {
		logger(LL_ERROR, "%s: DeviceGeneratedRequest has invalid type!\n", __func__);
		return NULL;
	}

	/* create Veridian request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		logger(LL_ERROR, "Unable to create Veridian TSS request\n");
		free(component_data);
		return NULL;
	}

	parameters = plist_new_dict();

	/* add manifest for current build_identity to parameters */
	tss_parameters_add_from_manifest(parameters, client->restore->build_identity, true);

	/* add BMU,* tags from info dictionary to parameters */
	plist_dict_merge(&parameters, p_info);

	/* add required tags for Veridian TSS request */
	tss_request_add_veridian_tags(request, parameters, device_generated_request);

	plist_free(parameters);

	logger(LL_INFO, "Sending Veridian TSS request...\n");
	response = tss_request_send(request, client->tss_url);
	plist_free(request);
	if (response == NULL) {
		logger(LL_ERROR, "Unable to fetch Veridian ticket\n");
		free(component_data);
		return NULL;
	}

	if (plist_dict_get_item(response, "BMU,Ticket")) {
		logger(LL_INFO, "Received Veridian ticket\n");
	} else {
		logger(LL_ERROR, "No 'BMU,Ticket' in TSS response, this might not work\n");
	}

	/* don't add FirmwareData if not requested via ResponseTags */
	if (!_wants_firmware_data(arguments)) {
		logger(LL_DEBUG, "Not adding FirmwareData as it was not requested\n");
		return response;
	}

	if (build_identity_get_component_path(client->restore->build_identity, comp_name, &comp_path) < 0) {
		plist_free(response);
		logger(LL_ERROR, "Unable to get path for '%s' component\n", comp_name);
		return NULL;
	}

	/* now get actual component data */
	ret = extract_component(client->ipsw, comp_path, &component_data, &component_size);
	free(comp_path);
	comp_path = NULL;
	if (ret < 0) {
		plist_free(response);
		logger(LL_ERROR, "Unable to extract '%s' component\n", comp_name);
		return NULL;
	}

	plist_t fw_map = NULL;
	if (plist_is_binary((const char*)component_data, component_size)) {
		plist_from_bin((const char*)component_data, component_size, &fw_map);
	} else {
		plist_from_xml((const char*)component_data, component_size, &fw_map);
	}
	free(component_data);
	component_data = NULL;
	component_size = 0;

	if (!fw_map) {
		plist_free(response);
		logger(LL_ERROR, "Unable to parse '%s' component data as plist\n", comp_name);
		return NULL;
	}

	plist_t fw_map_digest = plist_access_path(client->restore->build_identity, 3, "Manifest", comp_name, "Digest");
	if (!fw_map_digest) {
		plist_free(fw_map);
		plist_free(response);
		logger(LL_ERROR, "Unable to get Digest for '%s' component\n", comp_name);
		return NULL;
	}

	plist_dict_set_item(fw_map, "fw_map_digest", plist_copy(fw_map_digest));

	char *bin_plist = NULL;
	uint32_t bin_size = 0;
	plist_to_bin(fw_map, &bin_plist, &bin_size);
	plist_free(fw_map);

	plist_dict_set_item(response, "FirmwareData", plist_new_data(bin_plist, bin_size));
	free(bin_plist);

	return response;
}

static plist_t restore_get_generic_firmware_data(struct idevicerestore_client_t* client, plist_t p_info, plist_t arguments)
{
	plist_t request = NULL;
	plist_t response = NULL;

	plist_t p_updater_name = plist_dict_get_item(arguments, "MessageArgUpdaterName");
	const char* s_updater_name = plist_get_string_ptr(p_updater_name, NULL);

	plist_t response_tags = plist_access_path(arguments, 2, "DeviceGeneratedTags", "ResponseTags");
	const char* response_ticket = NULL;
	if (PLIST_IS_ARRAY(response_tags)) {
		plist_t tag0 = plist_array_get_item(response_tags, 0);
		if (tag0) {
			response_ticket = plist_get_string_ptr(tag0, NULL);
		}
	}
	if (response_ticket == NULL) {
		logger(LL_ERROR, "Unable to determine response ticket from device generated tags\n");
		return NULL;
	}

	/* create TSS request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		logger(LL_ERROR, "Unable to create %s TSS request\n", s_updater_name);
		return NULL;
	}

	/* add device generated request data to request */
	plist_t device_generated_request = plist_dict_get_item(arguments, "DeviceGeneratedRequest");
	if (!device_generated_request) {
		logger(LL_ERROR, "Could not find DeviceGeneratedRequest in arguments dictionary\n");
		plist_free(request);
		return NULL;
	}
	plist_dict_merge(&request, device_generated_request);

	logger(LL_INFO, "Sending %s TSS request...\n", s_updater_name);
	logger_dump_plist(LL_DEBUG, request, 0);
	response = tss_request_send(request, client->tss_url);
	plist_free(request);
	if (response == NULL) {
		logger(LL_ERROR, "Unable to fetch %s ticket\n", s_updater_name);
		return NULL;
	}
	logger_dump_plist(LL_DEBUG, response, 0);

	if (plist_dict_get_item(response, response_ticket)) {
		logger(LL_INFO, "Received %s\n", response_ticket);
	} else {
		logger(LL_ERROR, "No '%s' in TSS response, this might not work\n", response_ticket);
		logger_dump_plist(LL_VERBOSE, response, 0);
	}

	return response;
}

static plist_t restore_get_tcon_firmware_data(struct idevicerestore_client_t* client, plist_t p_info, plist_t arguments)
{
	char *comp_name = "Baobab,TCON";
	char *comp_path = NULL;
	void* component_data = NULL;
	size_t component_size = 0;
	plist_t parameters = NULL;
	plist_t request = NULL;
	plist_t response = NULL;
	int ret;

	if (!client || !client->restore || !client->restore->build_identity) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return NULL;
	}

	plist_t device_generated_request = plist_dict_get_item(arguments, "DeviceGeneratedRequest");
	if (device_generated_request && !PLIST_IS_DICT(device_generated_request)) {
		logger(LL_ERROR, "%s: DeviceGeneratedRequest has invalid type!\n", __func__);
		return NULL;
	}

	/* create Baobab request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		logger(LL_ERROR, "Unable to create Baobab TSS request\n");
		free(component_data);
		return NULL;
	}

	parameters = plist_new_dict();

	/* add manifest for current build_identity to parameters */
	tss_parameters_add_from_manifest(parameters, client->restore->build_identity, true);

	/* add Baobab,* tags from info dictionary to parameters */
	plist_dict_merge(&parameters, p_info);

	/* add required tags for Baobab TSS request */
	tss_request_add_tcon_tags(request, parameters, device_generated_request);

	plist_free(parameters);

	logger(LL_INFO, "Sending Baobab TSS request...\n");
	response = tss_request_send(request, client->tss_url);
	plist_free(request);
	if (response == NULL) {
		logger(LL_ERROR, "Unable to fetch Baobab ticket\n");
		free(component_data);
		return NULL;
	}

	if (plist_dict_get_item(response, "Baobab,Ticket")) {
		logger(LL_INFO, "Received Baobab ticket\n");
	} else {
		logger(LL_ERROR, "No 'Baobab,Ticket' in TSS response, this might not work\n");
	}

	/* don't add FirmwareData if not requested via ResponseTags */
	if (!_wants_firmware_data(arguments)) {
		logger(LL_DEBUG, "Not adding FirmwareData as it was not requested\n");
		return response;
	}

	if (build_identity_get_component_path(client->restore->build_identity, comp_name, &comp_path) < 0) {
		logger(LL_ERROR, "Unable to get path for '%s' component\n", comp_name);
		plist_free(response);
		return NULL;
	}

	/* now get actual component data */
	ret = extract_component(client->ipsw, comp_path, &component_data, &component_size);
	free(comp_path);
	comp_path = NULL;
	if (ret < 0) {
		logger(LL_ERROR, "Unable to extract '%s' component\n", comp_name);
		plist_free(response);
		return NULL;
	}

	plist_dict_set_item(response, "FirmwareData", plist_new_data((char*)component_data, component_size));
	free(component_data);
	component_data = NULL;
	component_size = 0;

	return response;
}

static plist_t restore_get_timer_firmware_data(struct idevicerestore_client_t* client, plist_t p_info, plist_t arguments)
{
	char comp_name[64];
	char *comp_path = NULL;
	void* component_data = NULL;
	size_t component_size = 0;
	ftab_t ftab = NULL;
	ftab_t rftab = NULL;
	uint32_t ftag = 0;
	plist_t parameters = NULL;
	plist_t request = NULL;
	plist_t response = NULL;
	const char* ticket_name = NULL;
	uint32_t tag = 0;
	int ret;

	if (!client || !client->restore || !client->restore->build_identity) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return NULL;
	}

	plist_t device_generated_request = plist_dict_get_item(arguments, "DeviceGeneratedRequest");
	if (device_generated_request && !PLIST_IS_DICT(device_generated_request)) {
		logger(LL_ERROR, "%s: DeviceGeneratedRequest has invalid type!\n", __func__);
		return NULL;
	}

	/* create Timer request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		logger(LL_ERROR, "Unable to create Timer TSS request\n");
		return NULL;
	}

	parameters = plist_new_dict();

	/* add manifest for current build_identity to parameters */
	tss_parameters_add_from_manifest(parameters, client->restore->build_identity, true);

	plist_dict_set_item(parameters, "ApProductionMode", plist_new_bool(1));
	if (client->image4supported) {
		plist_dict_set_item(parameters, "ApSecurityMode", plist_new_bool(1));
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(1));
	} else {
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(0));
	}

	/* add Timer,* tags from info dictionary to parameters */
	plist_t info_array = plist_dict_get_item(p_info, "InfoArray");
	if (!info_array) {
		logger(LL_ERROR, "Could not find InfoArray in info dictionary\n");
		plist_free(parameters);
		return NULL;
	} else {
		plist_t info_dict = plist_array_get_item(info_array, 0);
		plist_t hwid = plist_dict_get_item(info_dict, "HardwareID");
		tag = (uint32_t)plist_dict_get_uint(info_dict, "TagNumber");
		char key[64];

		plist_dict_set_item(parameters, "TagNumber", plist_new_uint(tag));
		plist_t node = plist_dict_get_item(info_dict, "TicketName");
		if (node) {
			ticket_name = plist_get_string_ptr(node, NULL);
			plist_dict_set_item(parameters, "TicketName", plist_copy(node));
		}

		snprintf(key, sizeof(key), "Timer,ChipID,%u", tag);
		plist_dict_copy_uint(parameters, hwid, key, "ChipID");

		snprintf(key, sizeof(key), "Timer,BoardID,%u", tag);
		plist_dict_copy_uint(parameters, hwid, key, "BoardID");

		snprintf(key, sizeof(key), "Timer,ECID,%u", tag);
		plist_dict_copy_uint(parameters, hwid, key, "ECID");

		snprintf(key, sizeof(key), "Timer,Nonce,%u", tag);
		plist_dict_copy_data(parameters, hwid, key, "Nonce");

		snprintf(key, sizeof(key), "Timer,SecurityMode,%u", tag);
		plist_dict_copy_bool(parameters, hwid, key, "SecurityMode");

		snprintf(key, sizeof(key), "Timer,SecurityDomain,%u", tag);
		plist_dict_copy_uint(parameters, hwid, key, "SecurityDomain");

		snprintf(key, sizeof(key), "Timer,ProductionMode,%u", tag);
		plist_dict_copy_uint(parameters, hwid, key, "ProductionStatus");
	}
	plist_t ap_info = plist_dict_get_item(p_info, "APInfo");
	if (!ap_info) {
		logger(LL_ERROR, "Could not find APInfo in info dictionary\n");
		plist_free(parameters);
		return NULL;
	} else {
		plist_dict_merge(&parameters, ap_info);
	}

	/* add required tags for Timer TSS request */
	tss_request_add_timer_tags(request, parameters, device_generated_request);

	plist_free(parameters);

	logger(LL_INFO, "Sending %s TSS request...\n", ticket_name);
	response = tss_request_send(request, client->tss_url);
	plist_free(request);
	if (response == NULL) {
		logger(LL_ERROR, "Unable to fetch %s\n", ticket_name);
		return NULL;
	}

	if (plist_dict_get_item(response, ticket_name)) {
		logger(LL_INFO, "Received %s\n", ticket_name);
	} else {
		logger(LL_ERROR, "No '%s' in TSS response, this might not work\n", ticket_name);
	}

	/* don't add FirmwareData if not requested via ResponseTags */
	if (!_wants_firmware_data(arguments)) {
		logger(LL_DEBUG, "Not adding FirmwareData as it was not requested\n");
		return response;
	}

	snprintf(comp_name, sizeof(comp_name), "Timer,RTKitOS,%u", tag);
	if (build_identity_has_component(client->restore->build_identity, comp_name)) {
		if (build_identity_get_component_path(client->restore->build_identity, comp_name, &comp_path) < 0) {
			plist_free(response);
			logger(LL_ERROR, "Unable to get path for '%s' component\n", comp_name);
			return NULL;
		}
		ret = extract_component(client->ipsw, comp_path, &component_data, &component_size);
		free(comp_path);
		comp_path = NULL;
		if (ret < 0) {
			logger(LL_ERROR, "Unable to extract '%s' component\n", comp_name);
			plist_free(response);
			return NULL;
		}
		if (ftab_parse(component_data, component_size, &ftab, &ftag) != 0) {
			free(component_data);
			plist_free(response);
			logger(LL_ERROR, "Failed to parse '%s' component data.\n", comp_name);
			return NULL;
		}
		free(component_data);
		component_data = NULL;
		component_size = 0;
		if (ftag != 'rkos') {
			logger(LL_WARNING, "Unexpected tag 0x%08x, expected 0x%08x; continuing anyway.\n", ftag, 'rkos');
		}
	} else {
		logger(LL_NOTICE, "Build identity does not have a '%s' component.\n", comp_name);
	}

	snprintf(comp_name, sizeof(comp_name), "Timer,RestoreRTKitOS,%u", tag);
	if (build_identity_has_component(client->restore->build_identity, comp_name)) {
		if (build_identity_get_component_path(client->restore->build_identity, comp_name, &comp_path) < 0) {
			ftab_free(ftab);
			plist_free(response);
			logger(LL_ERROR, "Unable to get path for '%s' component\n", comp_name);
			return NULL;
		}
		ret = extract_component(client->ipsw, comp_path, &component_data, &component_size);
		free(comp_path);
		comp_path = NULL;
		if (ret < 0) {
			ftab_free(ftab);
			plist_free(response);
			logger(LL_ERROR, "Unable to extract '%s' component\n", comp_name);
			return NULL;
		}

		ftag = 0;
		if (ftab_parse(component_data, component_size, &rftab, &ftag) != 0) {
			free(component_data);
			ftab_free(ftab);
			plist_free(response);
			logger(LL_ERROR, "Failed to parse '%s' component data.\n", comp_name);
			return NULL;
		}
		free(component_data);
		component_data = NULL;
		component_size = 0;
		if (ftag != 'rkos') {
			logger(LL_WARNING, "Unexpected tag 0x%08x, expected 0x%08x; continuing anyway.\n", ftag, 'rkos');
		}

		if (ftab_get_entry_ptr(rftab, 'rrko', &component_data, &component_size) == 0) {
			ftab_add_entry(ftab, 'rrko', component_data, component_size);
		} else {
			logger(LL_ERROR, "Could not find 'rrko' entry in ftab. This will probably break things.\n");
		}
		ftab_free(rftab);
		component_data = NULL;
		component_size = 0;
	} else {
		logger(LL_NOTICE, "Build identity does not have a '%s' component.\n", comp_name);
	}

	ftab_write(ftab, &component_data, &component_size);
	ftab_free(ftab);

	plist_dict_set_item(response, "FirmwareData", plist_new_data((char*)component_data, component_size));
	free(component_data);
	component_data = NULL;
	component_size = 0;

	return response;
}

static plist_t restore_get_cryptex1_firmware_data(struct idevicerestore_client_t* client, plist_t p_info, plist_t arguments)
{
	plist_t parameters = NULL;
	plist_t request = NULL;
	plist_t response = NULL;

	if (!client || !client->restore || !client->restore->build_identity) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return NULL;
	}

	plist_t p_updater_name = plist_dict_get_item(arguments, "MessageArgUpdaterName");
	const char* s_updater_name = plist_get_string_ptr(p_updater_name, NULL);

	plist_t response_tags = plist_access_path(arguments, 2, "DeviceGeneratedTags", "ResponseTags");
	const char* response_ticket = "Cryptex1,Ticket";
	if (PLIST_IS_ARRAY(response_tags)) {
		plist_t tag0 = plist_array_get_item(response_tags, 0);
		if (tag0) {
			response_ticket = plist_get_string_ptr(tag0, NULL);
		}
	}

	/* create Cryptex1 request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		logger(LL_ERROR, "Unable to create %s TSS request\n", s_updater_name);
		return NULL;
	}

	parameters = plist_new_dict();

	/* merge data from MessageArgInfo */
	plist_dict_merge(&parameters, p_info);

	/* add tags from manifest to parameters */
	plist_t build_identity_tags = plist_access_path(arguments, 2, "DeviceGeneratedTags", "BuildIdentityTags");
	if (PLIST_IS_ARRAY(build_identity_tags)) {
		uint32_t i = 0;
		for (i = 0; i < plist_array_get_size(build_identity_tags); i++) {
			plist_t node = plist_array_get_item(build_identity_tags, i);
			const char* key = plist_get_string_ptr(node, NULL);
			plist_t item = plist_dict_get_item(client->restore->build_identity, key);
			if (item) {
				plist_dict_set_item(parameters, key, plist_copy(item));
			}
		}
	}

	/* make sure we always have these required tags defined */
	if (!plist_dict_get_item(parameters, "ApProductionMode")) {
		plist_dict_set_item(parameters, "ApProductionMode", plist_new_bool(1));
	}
	if (!plist_dict_get_item(parameters, "ApSecurityMode")) {
		plist_dict_set_item(parameters, "ApSecurityMode", plist_new_bool(1));
	}
	if (!plist_dict_get_item(parameters, "ApChipID")) {
		plist_dict_copy_uint(parameters, client->restore->build_identity, "ApChipID", NULL);
	}
	if (!plist_dict_get_item(parameters, "ApBoardID")) {
		plist_dict_copy_uint(parameters, client->restore->build_identity, "ApBoardID", NULL);
	}

	/* add device generated request data to parameters */
	plist_t device_generated_request = plist_dict_get_item(arguments, "DeviceGeneratedRequest");
	if (!device_generated_request) {
		logger(LL_ERROR, "Could not find DeviceGeneratedRequest in arguments dictionary\n");
		plist_free(parameters);
		return NULL;
	}
	plist_dict_merge(&parameters, device_generated_request);

	/* add Cryptex1 tags to request */
	tss_request_add_cryptex_tags(request, parameters, NULL);

	plist_free(parameters);

	logger(LL_INFO, "Sending %s TSS request...\n", s_updater_name);
	response = tss_request_send(request, client->tss_url);
	plist_free(request);
	if (response == NULL) {
		logger(LL_ERROR, "Unable to fetch %s ticket\n", s_updater_name);
		return NULL;
	}

	if (plist_dict_get_item(response, response_ticket)) {
		logger(LL_INFO, "Received %s\n", response_ticket);
	} else {
		logger(LL_ERROR, "No '%s' in TSS response, this might not work\n", response_ticket);
		logger_dump_plist(LL_VERBOSE, response, 0);
	}

	return response;
}

static int restore_send_firmware_updater_preflight(struct idevicerestore_client_t* client, plist_t message)
{
	plist_t dict = NULL;
	int restore_error;

	if (client->debug_level > 1) {
		logger(LL_DEBUG, "%s: Got FirmwareUpdaterPreflight request:\n", __func__);
		logger_dump_plist(LL_DEBUG, message, 1);
	}

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	dict = plist_new_dict();

	logger(LL_INFO, "Sending FirmwareResponsePreflight now...\n");
	restore_error = _restore_service_send(service, dict, 0);
	plist_free(dict);
	_restore_service_free(service);
	if (restore_error != RESTORE_E_SUCCESS) {
		logger(LL_ERROR, "Couldn't send FirmwareResponsePreflight data (%d)\n", restore_error);
		return -1;
	}

	logger(LL_INFO, "Done sending FirmwareUpdaterPreflight response\n");
	return 0;
}

static int restore_send_firmware_updater_data(struct idevicerestore_client_t* client, plist_t message)
{
	plist_t arguments;
	plist_t p_type, p_updater_name, p_loop_count, p_info;
	plist_t loop_count_dict = NULL;
	char *s_type = NULL;
	plist_t dict = NULL;
	plist_t fwdict = NULL;
	char *s_updater_name = NULL;
	int restore_error;

	if (!client || !client->restore || !client->restore->build_identity) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return -1;
	}

	if (client->debug_level > 1) {
		logger(LL_DEBUG, "%s: Got FirmwareUpdaterData request:\n", __func__);
		logger_dump_plist(LL_DEBUG, message, 1);
	}

	arguments = plist_dict_get_item(message, "Arguments");
	if (!arguments || plist_get_node_type(arguments) != PLIST_DICT) {
		logger(LL_ERROR, "%s: Arguments missing or has invalid type!\n", __func__);
		goto error_out;
	}

	p_type = plist_dict_get_item(arguments, "MessageArgType");
	if (!p_type || (plist_get_node_type(p_type) != PLIST_STRING)) {
		logger(LL_ERROR, "%s: MessageArgType missing or has invalid type!\n", __func__);
		goto error_out;
	}

	p_updater_name = plist_dict_get_item(arguments, "MessageArgUpdaterName");
	if (!p_updater_name || (plist_get_node_type(p_updater_name) != PLIST_STRING)) {
		logger(LL_ERROR, "%s: MessageArgUpdaterName missing or has invalid type!\n", __func__);
		goto error_out;
	}

	p_loop_count = plist_dict_get_item(arguments, "MessageArgUpdaterLoopCount");
	if (p_loop_count) {
		loop_count_dict = plist_new_dict();
		plist_dict_set_item(loop_count_dict, "LoopCount", plist_copy(p_loop_count));
	}

	plist_get_string_val(p_type, &s_type);
	if (!s_type || strcmp(s_type, "FirmwareResponseData")) {
		logger(LL_ERROR, "%s: MessageArgType has unexpected value '%s'\n", __func__, s_type);
		goto error_out;
	}
	free(s_type);
	s_type = NULL;

	p_info = plist_dict_get_item(arguments, "MessageArgInfo");
	if (!p_info || (plist_get_node_type(p_info) != PLIST_DICT)) {
		logger(LL_ERROR, "%s: MessageArgInfo missing or has invalid type!\n", __func__);
		goto error_out;
	}

	plist_get_string_val(p_updater_name, &s_updater_name);
	logger_dump_plist(LL_DEBUG, p_info, 1);

	if (strcmp(s_updater_name, "SE") == 0) {
		fwdict = restore_get_se_firmware_data(client, p_info, arguments);
		if (fwdict == NULL) {
			logger(LL_ERROR, "%s: Couldn't get SE firmware data\n", __func__);
			goto error_out;
		}
	} else if (strcmp(s_updater_name, "Savage") == 0) {
		const char *fwtype = "Savage";
		plist_t p_info_yonkers = plist_dict_get_item(p_info, "YonkersDeviceInfo");
		plist_t p_info_jasmine = plist_dict_get_item(p_info, "JasmineIR1DeviceInfo");
		if (PLIST_IS_DICT(p_info_yonkers)) {
			fwtype = "Yonkers";
			fwdict = restore_get_yonkers_firmware_data(client, p_info_yonkers, arguments);
		} else if (PLIST_IS_DICT(p_info_jasmine)) {
			fwtype = "Jasmine";
			fwdict = restore_get_generic_firmware_data(client, p_info_jasmine, arguments);
		} else {
			fwdict = restore_get_savage_firmware_data(client, p_info, arguments);
		}
		if (fwdict == NULL) {
			logger(LL_ERROR, "%s: Couldn't get %s firmware data\n", __func__, fwtype);
			goto error_out;
		}
	} else if (strcmp(s_updater_name, "Rose") == 0) {
		fwdict = restore_get_rose_firmware_data(client, p_info, arguments);
		if (fwdict == NULL) {
			logger(LL_ERROR, "%s: Couldn't get Rose firmware data\n", __func__);
			goto error_out;
		}
	} else if (strcmp(s_updater_name, "T200") == 0) {
		fwdict = restore_get_veridian_firmware_data(client, p_info, arguments);
		if (fwdict == NULL) {
			logger(LL_ERROR, "%s: Couldn't get Veridian firmware data\n", __func__);
			goto error_out;
		}
	} else if (strcmp(s_updater_name, "AppleTCON") == 0) {
		fwdict = restore_get_tcon_firmware_data(client, p_info, arguments);
		if (fwdict == NULL) {
			logger(LL_ERROR, "%s: Couldn't get AppleTCON firmware data\n", __func__);
			goto error_out;
		}
	} else if (strcmp(s_updater_name, "PS190") == 0) {
		fwdict = restore_get_generic_firmware_data(client, p_info, arguments);
		if (fwdict == NULL) {
			logger(LL_ERROR, "%s: Couldn't get PCON1 firmware data\n", __func__);
			goto error_out;
		}
	} else if (strcmp(s_updater_name, "AppleTypeCRetimer") == 0) {
		fwdict = restore_get_timer_firmware_data(client, p_info, arguments);
		if (fwdict == NULL) {
			logger(LL_ERROR, "%s: Couldn't get AppleTypeCRetimer firmware data\n", __func__);
			goto error_out;
		}
	} else if ((strcmp(s_updater_name, "Cryptex1") == 0) || (strcmp(s_updater_name, "Cryptex1LocalPolicy") == 0)) {
		fwdict = restore_get_cryptex1_firmware_data(client, p_info, arguments);
		if (fwdict == NULL) {
			logger(LL_ERROR, "%s: Couldn't get %s firmware data\n", __func__, s_updater_name);
			goto error_out;
		}
	} else if (strcmp(s_updater_name, "Ace3") == 0) {
		fwdict = restore_get_generic_firmware_data(client, p_info, arguments);
		if (fwdict == NULL) {
			logger(LL_ERROR, "%s: Couldn't get %s firmware data\n", __func__, s_updater_name);
			goto error_out;
		}
	} else if (strcmp(s_updater_name, "Centauri") == 0) {
		fwdict = restore_get_generic_firmware_data(client, p_info, arguments);
		if (fwdict == NULL) {
			logger(LL_ERROR, "%s: Couldn't get %s firmware data\n", __func__, s_updater_name);
			goto error_out;
		}
	} else if (strcmp(s_updater_name, "Vinyl") == 0) {
		fwdict = restore_get_generic_firmware_data(client, p_info, arguments);
		if (fwdict == NULL) {
			logger(LL_ERROR, "%s: Couldn't get %s firmware data\n", __func__, s_updater_name);
			goto error_out;
		}
	} else {
		logger(LL_ERROR, "%s: Got unknown updater name '%s', trying to discover from device generated request.\n", __func__, s_updater_name);
		fwdict = restore_get_generic_firmware_data(client, p_info, arguments);
		if (fwdict == NULL) {
			logger(LL_ERROR, "%s: Couldn't get %s firmware data\n", __func__, s_updater_name);
			goto error_out;
		}
	}
	free(s_updater_name);
	s_updater_name = NULL;

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	dict = plist_new_dict();
	plist_dict_set_item(dict, "FirmwareResponseData", fwdict);

	logger(LL_INFO, "Sending FirmwareResponse data now...\n");
	restore_error = _restore_service_send(service, dict, 0);
	plist_free(dict);
	_restore_service_free(service);
	if (restore_error != RESTORE_E_SUCCESS) {
		logger(LL_ERROR, "Couldn't send FirmwareResponse data (%d)\n", restore_error);
		goto error_out;
	}

	logger(LL_INFO, "Done sending FirmwareUpdater data\n");

	return 0;

error_out:
	free(s_type);
	free(s_updater_name);
	plist_free(loop_count_dict);
	return -1;
}

static int restore_send_receipt_manifest(struct idevicerestore_client_t* client, plist_t message)
{
	plist_t dict;
	int restore_error;

	if (!client || !client->restore || !client->restore->build_identity) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return -1;
	}

	plist_t manifest = plist_dict_get_item(client->restore->build_identity, "Manifest");
	if (!manifest) {
		logger(LL_ERROR, "%s: Failed to get Manifest node from build_identity\n", __func__);
		goto error_out;
	}

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	dict = plist_new_dict();
	plist_dict_set_item(dict, "ReceiptManifest", plist_copy(manifest));

	logger(LL_INFO, "Sending ReceiptManifest data now...\n");
	restore_error = _restore_service_send(service, dict, 0);
	plist_free(dict);
	_restore_service_free(service);
	if (restore_error != RESTORE_E_SUCCESS) {
		logger(LL_ERROR, "Couldn't send ReceiptManifest data (%d)\n", restore_error);
		goto error_out;
	}

	logger(LL_INFO, "Done sending ReceiptManifest data\n");

	return 0;

error_out:
	return -1;
}


struct cpio_odc_header {
	char c_magic[6];
	char c_dev[6];
	char c_ino[6];
	char c_mode[6];
	char c_uid[6];
	char c_gid[6];
	char c_nlink[6];
	char c_rdev[6];
	char c_mtime[11];
	char c_namesize[6];
	char c_filesize[11];
};

static void octal(char *p, int width, int v)
{
	char buf[32];
	snprintf(buf, 32, "%0*o", width, v);
	memcpy(p, buf, width);
}

static int cpio_send_file(idevice_connection_t connection, const char *name, struct stat *st, void *data)
{
	struct cpio_odc_header hdr;

	memset(&hdr, '0', sizeof(hdr));
	memcpy(hdr.c_magic, "070707", 6);
	octal(hdr.c_dev, 6, st->st_dev);
	octal(hdr.c_ino, 6, st->st_ino);
	octal(hdr.c_mode, 6, st->st_mode);
	octal(hdr.c_uid, 6, st->st_uid);
	octal(hdr.c_gid, 6, st->st_gid);
	octal(hdr.c_nlink, 6, st->st_nlink);
	octal(hdr.c_rdev, 6, st->st_rdev);
	octal(hdr.c_mtime, 11, st->st_mtime);
	octal(hdr.c_namesize, 6, strlen(name) + 1);
	if (data)
		octal(hdr.c_filesize, 11, st->st_size);

	uint32_t bytes = 0;
	int name_len = strlen(name) + 1;
	idevice_error_t device_error;

	device_error = idevice_connection_send(connection, (void *)&hdr, sizeof(hdr), &bytes);
	if (device_error != IDEVICE_E_SUCCESS || bytes != sizeof(hdr)) {
		logger(LL_ERROR, "BootabilityBundle unable to send header. (%d) Sent %u of %lu bytes.\n", device_error, bytes, (long)sizeof(hdr));
		return -1;
	}

	device_error = idevice_connection_send(connection, (void *)name, name_len, &bytes);
	if (device_error != IDEVICE_E_SUCCESS || bytes != name_len) {
		logger(LL_ERROR, "BootabilityBundle unable to send filename. (%d) Sent %u of %u bytes.\n", device_error, bytes, name_len);
		return -1;
	}

	if (st->st_size && data) {
		device_error = idevice_connection_send(connection, data, st->st_size, &bytes);
		if (device_error != IDEVICE_E_SUCCESS || bytes != st->st_size) {
			logger(LL_ERROR, "BootabilityBundle unable to send data. (%d) Sent %u of %lu bytes.\n", device_error, bytes, (long)st->st_size);
			return -1;
		}
	}

	return 0;
}

static int restore_bootability_send_one(void *ctx, ipsw_archive_t ipsw, const char *name, struct stat *stat)
{
	idevice_connection_t connection = (idevice_connection_t)ctx;
	const char *prefix = "BootabilityBundle/Restore/Bootability/";
	const char *subpath;

	if (!strcmp(name, "BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache")) {
		subpath = "Bootability.trustcache";
	} else if (strncmp(name, prefix, strlen(prefix))) {
		return 0;
	} else {
		subpath = name + strlen(prefix);
	}

	logger(LL_DEBUG, "BootabilityBundle send m=%07o s=%10ld %s\n", stat->st_mode, (long)stat->st_size, subpath);

	void *buf = NULL;
	size_t size = 0;

	if ((S_ISLNK(stat->st_mode) || S_ISREG(stat->st_mode)) && stat->st_size != 0) {
		ipsw_extract_to_memory(ipsw, name, &buf, &size);
		if (size != stat->st_size) {
			logger(LL_ERROR, "expected %zu bytes but got %zu for file %s\n", (size_t)stat->st_size, size, name);
			free(buf);
			return -1;
		}
	}

	stat->st_uid = stat->st_gid = 0;

	int ret = cpio_send_file(connection, subpath, stat, buf);

	free(buf);
	return ret;
}

static int restore_send_bootability_bundle_data(struct idevicerestore_client_t* client, plist_t message)
{
	if (client->debug_level > 1) {
		logger(LL_DEBUG, "%s: Got BootabilityBundle request:\n", __func__);
		logger_dump_plist(LL_DEBUG, message, 1);
	}

	plist_t node = plist_dict_get_item(message, "DataPort");
	uint64_t u64val = 0;
	plist_get_uint_val(node, &u64val);
	uint16_t data_port = (uint16_t)u64val;

	int attempts = 10;
	idevice_connection_t connection = NULL;
	idevice_error_t device_error = IDEVICE_E_SUCCESS;

	if (!client || !client->restore || !client->restore->build_identity || !client->restore->device) {
		logger(LL_ERROR, "%s: idevicerestore client not initialized?!\n", __func__);
		return -1;
	}

	logger(LL_DEBUG, "Connecting to BootabilityBundle data port\n");
	while (--attempts > 0) {
		device_error = idevice_connect(client->restore->device, data_port, &connection);
		if (device_error == IDEVICE_E_SUCCESS) {
			break;
		}
		sleep(1);
		logger(LL_DEBUG, "Retrying connection...\n");
	}
	if (device_error != IDEVICE_E_SUCCESS) {
		logger(LL_ERROR, "Unable to connect to BootabilityBundle data port\n");
		return -1;
	}

	int ret = ipsw_list_contents(client->ipsw, restore_bootability_send_one, connection);

	if (ret < 0) {
		logger(LL_ERROR, "Failed to send BootabilityBundle\n");
		return ret;
	}

	struct stat st = {.st_nlink = 1};
	cpio_send_file(connection, "TRAILER!!!", &st, NULL);

	idevice_disconnect(connection);

    return 0;
}

plist_t restore_get_build_identity(struct idevicerestore_client_t* client, uint8_t is_recovery_os)
{
	const char *variant;

	if (is_recovery_os)
		variant = RESTORE_VARIANT_MACOS_RECOVERY_OS;
	else if (client->flags & FLAG_ERASE)
		variant = RESTORE_VARIANT_ERASE_INSTALL;
	else
		variant = RESTORE_VARIANT_UPGRADE_INSTALL;

	plist_t build_identity = build_manifest_get_build_identity_for_model_with_variant(
			client->build_manifest,
			client->device->hardware_model,
			variant, 0);

	plist_t unique_id_node = plist_dict_get_item(client->build_manifest, "UniqueBuildID");
	if (unique_id_node) {
		logger(LL_INFO, "UniqueBuildID: ");
		plist_write_to_stream(unique_id_node, stdout, PLIST_FORMAT_PRINT, PLIST_OPT_NONE);
	}

	return build_identity;
}

plist_t restore_get_build_identity_from_request(struct idevicerestore_client_t* client, plist_t message)
{
	plist_t args = plist_dict_get_item(message, "Arguments");
	return restore_get_build_identity(client, plist_dict_get_bool(args, "IsRecoveryOS"));
}

int extract_macos_variant(plist_t build_identity, char** output)
{
	plist_t build_info = plist_dict_get_item(build_identity, "Info");
	if (!build_info) {
		logger(LL_ERROR, "build identity does not contain an 'Info' element\n");
		return -1;
	}

	plist_t macos_variant_node = plist_dict_get_item(build_info, "MacOSVariant");
	if (!macos_variant_node) {
		logger(LL_ERROR, "build identity info does not contain a MacOSVariant\n");
		return -1;
	}
	plist_get_string_val(macos_variant_node, output);

	return 0;
}

static char* extract_global_manifest_path(plist_t build_identity, char *variant)
{
	plist_t build_info = plist_dict_get_item(build_identity, "Info");
	if (!build_info) {
		logger(LL_ERROR, "build identity does not contain an 'Info' element\n");
		return NULL;
	}

	plist_t device_class_node = plist_dict_get_item(build_info, "DeviceClass");
	if (!device_class_node) {
		logger(LL_ERROR, "build identity info does not contain a DeviceClass\n");
		return NULL;
	}
	char *device_class = NULL;
	plist_get_string_val(device_class_node, &device_class);

	char *macos_variant = NULL;
	int ret;
	if (variant) {
		macos_variant = variant;
	} else {
		ret = extract_macos_variant(build_identity, &macos_variant);
		if (ret != 0) {
			free(device_class);
			return NULL;
		}
	}

	// The path of the global manifest is hardcoded. There's no pointer to in the build manifest.
	size_t psize = 42+strlen(macos_variant)+strlen(device_class)+1;
	char *ticket_path = malloc(psize);
	snprintf(ticket_path, psize, "Firmware/Manifests/restore/%s/apticket.%s.im4m", macos_variant, device_class);

	free(device_class);
	free(macos_variant);

	return ticket_path;
}

int extract_global_manifest(struct idevicerestore_client_t* client, plist_t build_identity, char *variant, void** pbuffer, size_t* psize)
{
	char* ticket_path = extract_global_manifest_path(build_identity, variant);
	if (!ticket_path) {
		logger(LL_ERROR, "failed to get global manifest path\n");
		return -1;
	}
	int ret = ipsw_extract_to_memory(client->ipsw, ticket_path, pbuffer, psize);
	if (ret != 0) {
		free(ticket_path);
		logger(LL_ERROR, "failed to read global manifest\n");
		return -1;
	}
	free(ticket_path);

	return 0;
}

struct _restore_send_file_data_ctx {
	struct idevicerestore_client_t* client;
	restore_service_client_t service;
	int last_progress;
	uint32_t tag;
};

static int _restore_send_file_data(struct _restore_send_file_data_ctx* rctx, const void* data, size_t size, size_t done, size_t total_size)
{
	plist_t dict = plist_new_dict();
	if (data != NULL) {
		// Send a chunk of file data
		plist_dict_set_item(dict, "FileData", plist_new_data((char*)data, size));
	} else {
		// Send FileDataDone to mark end of transfer
		plist_dict_set_item(dict, "FileDataDone", plist_new_bool(1));
	}
	restored_error_t restore_error = _restore_service_send(rctx->service, dict, 0);
	if (restore_error != RESTORE_E_SUCCESS) {
		plist_free(dict);
		logger(LL_ERROR, "%s: Failed to send data (%d)\n", __func__, restore_error);
		return -1;
	}
	plist_free(dict);

	/* special handling for AEA image format */
	if (done == 0 && (memcmp(data, "AEA1", 4) == 0)) {
		logger(LL_VERBOSE, "Encountered First Chunk in AEA image\n");
		plist_t message = NULL;
		property_list_service_error_t err = _restore_service_recv_timeout(rctx->service, &message, 3000);
		if (err == PROPERTY_LIST_SERVICE_E_RECEIVE_TIMEOUT) {
			logger(LL_VERBOSE, "No URLAsset requested, assuming it is not necessary.\n");
		} else if (err == PROPERTY_LIST_SERVICE_E_SUCCESS) {
			if (PLIST_IS_DICT(message) && plist_dict_get_item(message, "Arguments")) {
				restore_send_url_asset(rctx->client, message);
			} else {
				logger(LL_DEBUG, "%s: Unexpected message received\n", __func__);
				logger_dump_plist(LL_DEBUG, message, 1);
			}
		}
	}

	if (total_size > 0x1000000) {
		double progress = (double)done / (double)total_size;
		set_progress(rctx->tag, progress);
		int progress_int = (int)(progress*100.0);
		if (progress_int > rctx->last_progress) {
			idevicerestore_progress(rctx->client, RESTORE_STEP_UPLOAD_IMG, progress);
			rctx->last_progress = progress_int;
		}
	}
	return 0;
}

int restore_send_personalized_boot_object_v3(struct idevicerestore_client_t* client, plist_t message)
{
	if (client->debug_level > 1) {
		logger(LL_DEBUG, "%s: Got PersonalizedBootObjectV3 request:\n", __func__);
		logger_dump_plist(LL_DEBUG, message, 1);
	}

	char *image_name = NULL;
	plist_t node = plist_access_path(message, 2, "Arguments", "ImageName");
	if (!node || plist_get_node_type(node) != PLIST_STRING) {
		logger(LL_DEBUG, "Failed to parse arguments from PersonalizedBootObjectV3 plist\n");
		return -1;
	}
	plist_get_string_val(node, &image_name);
	if (!image_name) {
		logger(LL_DEBUG, "Failed to parse arguments from PersonalizedBootObjectV3 as string\n");
		return -1;
	}

	char *component = image_name;
	size_t size = 0;
	void *data = NULL;
	char *path = NULL;

	logger(LL_INFO, "About to send %s...\n", component);

	if (strcmp(image_name, "__GlobalManifest__") == 0) {
		int ret = extract_global_manifest(client, client->restore->build_identity, NULL, &data, &size);
		if (ret != 0) {
			return -1;
		}
	} else if (strcmp(image_name, "__RestoreVersion__") == 0) {
		int ret = ipsw_extract_to_memory(client->ipsw, "RestoreVersion.plist", &data, &size);
		if (ret != 0) {
			logger(LL_ERROR, "failed to read global manifest\n");
			return -1;
		}
	} else if (strcmp(image_name, "__SystemVersion__") == 0) {
		int ret = ipsw_extract_to_memory(client->ipsw, "SystemVersion.plist", &data, &size);
		if (ret != 0) {
			logger(LL_ERROR, "failed to read global manifest\n");
			return -1;
		}
	} else {
		// Get component path
		if (client->tss) {
			if (tss_response_get_path_by_entry(client->tss, component, &path) < 0) {
				logger(LL_DEBUG, "No path for component %s in TSS, will fetch from build identity\n", component);
			}
		}
		if (!path) {
			plist_t build_identity = restore_get_build_identity_from_request(client, message);
			if (!build_identity) {
				logger(LL_ERROR, "Unable to find a matching build identity\n");
				return -1;
			}
			if (build_identity_get_component_path(build_identity, component, &path) < 0) {
				logger(LL_ERROR, "Unable to find %s path from build identity\n", component);
				return -1;
			}
		}

		// Extract component
		void *component_data = NULL;
		size_t component_size = 0;
		int ret = extract_component(client->ipsw, path, &component_data, &component_size);
		free(path);
		path = NULL;
		if (ret < 0) {
			logger(LL_ERROR, "Unable to extract component %s\n", component);
			return -1;
		}

		// Personalize IMG4
		ret = personalize_component(client, component, component_data, component_size, client->tss, &data, &size);
		free(component_data);
		component_data = NULL;
		if (ret < 0) {
			logger(LL_ERROR, "Unable to get personalized component %s\n", component);
			return -1;
		}
	}

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	logger(LL_INFO, "Sending %s now (%" PRIu64 " bytes)...\n", component, (uint64_t)size);

	struct _restore_send_file_data_ctx rctx;
	rctx.client = client;
	rctx.service = service;
	rctx.last_progress = 0;
	rctx.tag = progress_get_next_tag();

	if (size > 0x2000000) {
		register_progress(rctx.tag, component);
	}

	int64_t i = size;
	while (i > 0) {
		int blob_size = i > 8192 ? 8192 : i;
		if (_restore_send_file_data(&rctx, ((char*)data + size - i), blob_size, size-i, size) < 0) {
			free(data);
			_restore_service_free(service);
			finalize_progress(rctx.tag);
			logger(LL_ERROR, "Unable to send component %s data\n", component);
			return -1;
		}
		i -= blob_size;
	}
	free(data);

	_restore_send_file_data(&rctx, NULL, 0, size-i, size);
	finalize_progress(rctx.tag);

	_restore_service_free(service);

	logger(LL_INFO, "Done sending %s\n", component);
	return 0;
}

int restore_send_source_boot_object_v4(struct idevicerestore_client_t* client, plist_t message)
{
	if (client->debug_level > 1) {
		logger(LL_DEBUG, "%s: Got SourceBootObjectV4 request:\n", __func__);
		logger_dump_plist(LL_DEBUG, message, 1);
	}

	char *image_name = NULL;
	plist_t node = plist_access_path(message, 2, "Arguments", "ImageName");
	if (!node || plist_get_node_type(node) != PLIST_STRING) {
		logger(LL_DEBUG, "Failed to parse arguments from SourceBootObjectV4 plist\n");
		return -1;
	}
	plist_get_string_val(node, &image_name);
	if (!image_name) {
		logger(LL_DEBUG, "Failed to parse arguments from SourceBootObjectV4 as string\n");
		return -1;
	}

	char *component = image_name;
	// Fork from restore_send_component
	//
	char *path = NULL;

	logger(LL_INFO, "About to send %s...\n", component);

	if (strcmp(image_name, "__GlobalManifest__") == 0) {
		char *variant = NULL;
		plist_t node = plist_access_path(message, 2, "Arguments", "Variant");
		if (!node || plist_get_node_type(node) != PLIST_STRING) {
			logger(LL_DEBUG, "Failed to parse arguments from SourceBootObjectV4 plist\n");
			return -1;
		}
		plist_get_string_val(node, &variant);
		if (!variant) {
			logger(LL_DEBUG, "Failed to parse arguments from SourceBootObjectV4 as string\n");
			return -1;
		}

		path = extract_global_manifest_path(client->restore->build_identity, variant);
	} else if (strcmp(image_name, "__RestoreVersion__") == 0) {
		path = strdup("RestoreVersion.plist");
	} else if (strcmp(image_name, "__SystemVersion__") == 0) {
		path = strdup("SystemVersion.plist");
	} else {
		// Get component path
		if (client->tss) {
			if (tss_response_get_path_by_entry(client->tss, component, &path) < 0) {
				logger(LL_DEBUG, "No path for component %s in TSS, will fetch from build identity\n", component);
			}
		}
		if (!path) {
			plist_t build_identity = restore_get_build_identity_from_request(client, message);
			if (build_identity_get_component_path(build_identity, component, &path) < 0) {
				logger(LL_ERROR, "Unable to find %s path from build identity\n", component);
				return -1;
			}
		}
	}

	if (!path) {
		logger(LL_ERROR, "Failed to get path for component %s\n", component);
		return -1;
	}

	uint64_t fsize = 0;
	ipsw_get_file_size(client->ipsw, path, &fsize);

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	logger(LL_INFO, "Sending %s now (%" PRIu64 " bytes)\n", component, fsize);

	struct _restore_send_file_data_ctx rctx;
	rctx.client = client;
	rctx.service = service;
	rctx.last_progress = 0;
	rctx.tag = progress_get_next_tag();

	register_progress(rctx.tag, component);

	if (ipsw_extract_send(client->ipsw, path, 8192, (ipsw_send_cb)_restore_send_file_data, &rctx) < 0) {
		free(path);
		_restore_service_free(service);
		finalize_progress(rctx.tag);
		logger(LL_ERROR, "Failed to send component %s\n", component);
		return -1;
	}
	free(path);

	_restore_service_free(service);
	finalize_progress(rctx.tag);

	logger(LL_INFO, "Done sending %s\n", component);
	return 0;
}

int restore_send_restore_local_policy(struct idevicerestore_client_t* client, plist_t message)
{
	size_t size = 0;
	void* data = NULL;

	void* component_data = NULL;
	size_t component_size = 0;

	char* component = "Ap,LocalPolicy";

	component_data = malloc(sizeof(lpol_file));
	component_size = sizeof(lpol_file);
	memcpy(component_data, lpol_file, component_size);

	// The Update mode does not have a specific build identity for the recovery os.
	plist_t build_identity = restore_get_build_identity(client, client->flags & FLAG_ERASE ? 1 : 0);

	int ret = get_recovery_os_local_policy_tss_response(client, build_identity, &client->tss_localpolicy, plist_dict_get_item(message, "Arguments"));
	if (ret < 0) {
		logger(LL_ERROR, "Unable to get recovery os local policy tss response\n");
		return -1;
	}

	ret = personalize_component(client, component, component_data, component_size, client->tss_localpolicy, &data, &size);
	free(component_data);
	component_data = NULL;
	if (ret < 0) {
		logger(LL_ERROR, "Unable to get personalized component %s\n", component);
		return -1;
	}

	plist_t dict = plist_new_dict();
	plist_dict_set_item(dict, "Ap,LocalPolicy", plist_new_data((char*)data, size));

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	int restore_error = 0;
	restore_error = _restore_service_send(service, dict, 0);
	_restore_service_free(service);
	if (restore_error != RESTORE_E_SUCCESS) {
		logger(LL_ERROR, "Unable to send component %s data\n", component);
		return -1;
	}

	plist_free(dict);
	free(data);

	return 0;
}

int restore_send_buildidentity(struct idevicerestore_client_t* client, plist_t message)
{
	restored_error_t restore_error;
	plist_t dict;

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	logger(LL_INFO, "About to send BuildIdentity Dict...\n");

	plist_t build_identity = restore_get_build_identity_from_request(client, message);

	dict = plist_new_dict();
	plist_dict_set_item(dict, "BuildIdentityDict", plist_copy(build_identity));

	plist_t node = plist_access_path(message, 2, "Arguments", "Variant");
	if(node) {
		plist_dict_set_item(dict, "Variant", plist_copy(node));
	} else {
		plist_dict_set_item(dict, "Variant", plist_new_string("Erase"));
	}

	logger(LL_INFO, "Sending BuildIdentityDict now...\n");
	restore_error = _restore_service_send(service, dict, 0);
	_restore_service_free(service);
	plist_free(dict);
	if (restore_error != RESTORE_E_SUCCESS) {
		logger(LL_ERROR, "Unable to send BuildIdentityDict (%d)\n", restore_error);
		return -1;
	}

	logger(LL_INFO, "Done sending BuildIdentityDict\n");
	return 0;
}

int restore_send_recovery_os_file_asset_image(struct idevicerestore_client_t* client, plist_t message)
{
	char *fw_override_key = NULL;
	plist_t node = plist_access_path(message, 2, "Arguments", "FWOverrideKey");
	if (PLIST_IS_STRING(node)) {
		plist_get_string_val(node, &fw_override_key);
	}
	if (!fw_override_key) {
		logger(LL_ERROR, "Failed to get FWOverrideKey from arguments. Trying to continue anyway.\n");
		return -1;
	}

	plist_t dict = plist_new_dict();
	if (!client->recovery_variant) {
		logger(LL_ERROR, "no RecoveryOS variant in BuildManifest. Trying to continue anyway.\n");
		plist_dict_set_item(dict, "RecoveryOSNoAssetFound", plist_new_bool(1));
		restored_send(client->restore->client, dict);
		plist_free(dict);
		return 0;
	}

	if (strncmp(fw_override_key, "RecoveryOS", 10) != 0) {
		logger(LL_ERROR, "FWOVerrideKey has unexpected prefix\n");
		plist_dict_set_item(dict, "RecoveryOSNoAssetFound", plist_new_bool(1));
		restored_send(client->restore->client, dict);
		plist_free(dict);
		return 0;
	}

	const char* component = fw_override_key+10;
	char* path = NULL;
	if (build_identity_get_component_path(client->recovery_variant, component, &path) < 0) {
		logger(LL_ERROR, "Unable to find %s path from recovery build identity. Trying to continue anyway.\n", component);
		plist_dict_set_item(dict, "RecoveryOSNoAssetFound", plist_new_bool(1));
		restored_send(client->restore->client, dict);
		plist_free(dict);
		return 0;
	}

	void* component_data = NULL;
	size_t component_size = 0;
	int ret = extract_component(client->ipsw, path, &component_data, &component_size);
	free(path);
	path = NULL;
	if (ret < 0) {
		logger(LL_ERROR, "Unable to extract component %s. Trying to continue anyway.\n", component);
		plist_dict_set_item(dict, "RecoveryOSNoAssetFound", plist_new_bool(1));
		restored_send(client->restore->client, dict);
		plist_free(dict);
		return 0;
	}

	void* data = NULL;
	size_t size = 0;
	ret = personalize_component(client, component, component_data, component_size, client->tss_recoveryos_root_ticket, &data, &size);
	free(component_data);
	component_data = NULL;
	if (ret < 0) {
		logger(LL_ERROR, "Unable to get personalized component %s. Trying to continue anyway.\n", component);
		plist_dict_set_item(dict, "RecoveryOSNoAssetFound", plist_new_bool(1));
		restored_send(client->restore->client, dict);
		plist_free(dict);
		return 0;
	}

	logger(LL_INFO, "Sending %s\n", fw_override_key);

	plist_dict_set_item(dict, "AdditionalBootImages", plist_new_data((char*)data, size));
	free(data);
	restored_send(client->restore->client, dict);
	plist_free(dict);

	return 0;
}

int restore_send_recovery_os_iboot_fw_files_images(struct idevicerestore_client_t* client, plist_t message)
{
	plist_t build_id_manifest = plist_dict_get_item(client->recovery_variant, "Manifest");
	if (!build_id_manifest) {
		logger(LL_ERROR, "Missing Manifest dictionary in build identity?!\n");
		return -1;
	}

	plist_t firmware_files = plist_new_dict();

	plist_dict_iter iter = NULL;
	plist_dict_new_iter(build_id_manifest, &iter);
	if (iter) {
		char *component = NULL;
		plist_t manifest_entry;
		do {
			component = NULL;
			manifest_entry = NULL;
			plist_dict_next_item(build_id_manifest, iter, &component, &manifest_entry);
			if (component && PLIST_IS_DICT(manifest_entry)) {
				uint8_t loaded_by_iboot = 0;
				uint8_t loaded_by_iboot_stage1 = 0;
				plist_t fw_node;

				fw_node = plist_access_path(manifest_entry, 2, "Info", "IsLoadedByiBoot");
				if (fw_node && plist_get_node_type(fw_node) == PLIST_BOOLEAN) {
					plist_get_bool_val(fw_node, &loaded_by_iboot);
				}
				fw_node = plist_access_path(manifest_entry, 2, "Info", "IsLoadedByiBootStage1");
				if (fw_node && plist_get_node_type(fw_node) == PLIST_BOOLEAN) {
					plist_get_bool_val(fw_node, &loaded_by_iboot_stage1);
				}
				if (loaded_by_iboot || loaded_by_iboot_stage1) {
					plist_t comp_path = plist_access_path(manifest_entry, 2, "Info", "Path");
					if (comp_path) {
						const char* path = plist_get_string_ptr(comp_path, NULL);
						void* component_data = NULL;
						size_t component_size = 0;
						int ret = extract_component(client->ipsw, path, &component_data, &component_size);
						if (ret == 0) {
							void* data = NULL;
							size_t size = 0;
							ret = personalize_component(client, component, component_data, component_size, client->tss_recoveryos_root_ticket, &data, &size);
							free(component_data);
							component_data = NULL;
							if (ret == 0) {
								plist_dict_set_item(firmware_files, component, plist_new_data((char*)data, size));
								free(data);
							}
						}
					}
				}
			}
			free(component);
		} while (manifest_entry);
		plist_mem_free(iter);
	}

	plist_t dict = plist_new_dict();

	if (plist_dict_get_size(firmware_files) == 0) {
		plist_free(firmware_files);
		logger(LL_NOTICE, "No iBoot firmware files. Continuing.\n");
		plist_dict_set_item(dict, "RecoveryOSNoAssetFound", plist_new_bool(1));
		restored_send(client->restore->client, dict);
		plist_free(dict);
		return 0;

	}

	logger(LL_INFO, "Sending iBoot additional firmware files\n");

	plist_dict_set_item(dict, "AdditionalBootImages", firmware_files);
	restored_send(client->restore->client, dict);
	plist_free(dict);

	return 0;
}

int restore_send_recovery_os_image(struct idevicerestore_client_t* client, plist_t message)
{
	const char* component = "OS";
	char* path = NULL;
	if (build_identity_get_component_path(client->recovery_variant, component, &path) < 0) {
		logger(LL_ERROR, "Unable to find %s path from build identity\n", component);
		return -1;
	}
	if (!path) {
		logger(LL_ERROR, "Failed to get path for component %s\n", component);
		return -1;
	}

	uint64_t fsize = 0;
	ipsw_get_file_size(client->ipsw, path, &fsize);

	restore_service_client_t service = _restore_get_service_client_for_data_request(client, message);
	if (!service) {
		logger(LL_ERROR, "%s: Unable to connect to service client\n", __func__);
		return -1;
	}

	logger(LL_INFO, "Sending %s now (%" PRIu64 " bytes)\n", component, fsize);

	struct _restore_send_file_data_ctx rctx;
	rctx.client = client;
	rctx.service = service;
	rctx.last_progress = 0;
	rctx.tag = progress_get_next_tag();

	register_progress(rctx.tag, component);

	if (ipsw_extract_send(client->ipsw, path, 8192, (ipsw_send_cb)_restore_send_file_data, &rctx) < 0) {
		free(path);
		_restore_service_free(service);
		finalize_progress(rctx.tag);
		logger(LL_ERROR, "Failed to send component %s\n", component);
		return -1;
	}
	free(path);

	_restore_service_free(service);
	finalize_progress(rctx.tag);

	logger(LL_INFO, "Done sending %s\n", component);

	return 0;
}

int restore_send_recovery_os_version_data(struct idevicerestore_client_t* client, plist_t message)
{
	plist_t build_id_info = plist_dict_get_item(client->recovery_variant, "Info");
	if (!build_id_info) {
		logger(LL_ERROR, "Missing Info dictionary in build identity?!\n");
		return -1;
	}
	plist_t version_data = plist_new_dict();
	plist_dict_copy_item(version_data, build_id_info, "BuildNumber", NULL);
	plist_dict_copy_item(version_data, build_id_info, "Variant", NULL);
	plist_dict_copy_item(version_data, build_id_info, "BuildTrain", NULL);
	plist_dict_copy_item(version_data, build_id_info, "ProductVersion", "ProductMarketingVersion");
	char *xml = NULL;
	uint32_t xml_len = 0;
	plist_to_xml(version_data, &xml, &xml_len);
	plist_free(version_data);

	logger(LL_INFO, "Sending RecoveryOS version data\n");

	plist_t dict = plist_new_dict();
	plist_dict_set_item(dict, "RecoveryOSVersionData", plist_new_data(xml, xml_len));
	plist_mem_free(xml);
	restored_send(client->restore->client, dict);
	plist_free(dict);

	return 0;
}

int restore_handle_data_request_msg(struct idevicerestore_client_t* client, plist_t message)
{
	plist_t node = NULL;

	// checks and see what kind of data restored is requests and pass
	// the request to its own handler
	node = plist_dict_get_item(message, "DataType");
	if (node && PLIST_STRING == plist_get_node_type(node)) {
		const char *type = plist_get_string_ptr(node, NULL);
logger(LL_DEBUG, "%s: type = %s\n", __func__, type);
		// this request is sent when restored is ready to receive the filesystem
		if (!strcmp(type, "SystemImageData")) {
			if (restore_send_filesystem(client, message) < 0) {
				logger(LL_ERROR, "Unable to send filesystem\n");
				return -2;
			}
		}

		else if (!strcmp(type, "BuildIdentityDict")) {
			if (restore_send_buildidentity(client, message) < 0) {
				logger(LL_ERROR, "Unable to send RootTicket\n");
				return -1;
			}
		}

		else if (!strcmp(type, "PersonalizedBootObjectV3")) {
			if (restore_send_personalized_boot_object_v3(client, message) < 0) {
				logger(LL_ERROR, "Unable to send PersonalizedBootObjectV3\n");
				return -1;
			}
		}

		else if (!strcmp(type, "SourceBootObjectV4")) {
			if (restore_send_source_boot_object_v4(client, message) < 0) {
				logger(LL_ERROR, "Unable to send SourceBootObjectV4\n");
				return -1;
			}
		}

		else if (!strcmp(type, "RecoveryOSLocalPolicy")) {
			if (restore_send_restore_local_policy(client, message) < 0) {
				logger(LL_ERROR, "Unable to send RecoveryOSLocalPolicy\n");
				return -1;
			}
		}

		// this request is sent when restored is ready to receive the filesystem
		else if (!strcmp(type, "RecoveryOSASRImage")) {
			if (restore_send_filesystem(client, message) < 0) {
				logger(LL_ERROR, "Unable to send filesystem\n");
				return -2;
			}
		}

		// Send RecoveryOS RTD
		else if(!strcmp(type, "RecoveryOSRootTicketData")) {
			if (restore_send_recovery_os_root_ticket(client, message) < 0) {
				logger(LL_ERROR, "Unable to send RootTicket\n");
				return -1;
			}
		}

		// send RootTicket (== APTicket from the TSS request)
		else if (!strcmp(type, "RootTicket")) {
			if (restore_send_root_ticket(client, message) < 0) {
				logger(LL_ERROR, "Unable to send RootTicket\n");
				return -1;
			}
		}
		// send KernelCache
		else if (!strcmp(type, "KernelCache")) {
			if (restore_send_component(client, message, "KernelCache", NULL) < 0) {
				logger(LL_ERROR, "Unable to send kernelcache\n");
				return -1;
			}
		}

		else if (!strcmp(type, "DeviceTree")) {
			if (restore_send_component(client, message, "DeviceTree", NULL) < 0) {
				logger(LL_ERROR, "Unable to send DeviceTree\n");
				return -1;
			}
		}

		else if (!strcmp(type, "SystemImageRootHash")) {
			if (restore_send_component(client, message, "SystemVolume", type) < 0) {
				logger(LL_ERROR, "Unable to send SystemImageRootHash data\n");
				return -1;
			}
		}

		else if (!strcmp(type, "SystemImageCanonicalMetadata")) {
			if (restore_send_component(client, message, "Ap,SystemVolumeCanonicalMetadata", type) < 0) {
				logger(LL_ERROR, "Unable to send SystemImageCanonicalMetadata data\n");
				return -1;
			}
		}

		else if (!strcmp(type, "NORData")) {
			if((client->flags & FLAG_EXCLUDE) == 0) {
				if(restore_send_nor(client, message) < 0) {
					logger(LL_ERROR, "Unable to send NOR data\n");
					return -1;
				}
			} else {
				logger(LL_INFO, "Not sending NORData... Quitting...\n");
				client->flags |= FLAG_QUIT;
			}
		}

		else if (!strcmp(type, "BasebandData")) {
			if(restore_send_baseband_data(client, message) < 0) {
				logger(LL_ERROR, "Unable to send baseband data\n");
				return -1;
			}
		}

		else if (!strcmp(type, "FDRTrustData")) {
			if(restore_send_fdr_trust_data(client, message) < 0) {
				logger(LL_ERROR, "Unable to send FDR Trust data\n");
				return -1;
			}
		}

		else if (!strcmp(type, "FUDData")) {
			if(restore_send_image_data(client, message, "FUDImageList", "IsFUDFirmware", "FUDImageData") < 0) {
				logger(LL_ERROR, "Unable to send FUD data\n");
				return -1;
			}
		}

		else if (!strcmp(type, "FirmwareUpdaterPreflight")) {
			if(restore_send_firmware_updater_preflight(client, message) < 0) {
				logger(LL_ERROR, "Unable to send FirmwareUpdaterPreflight\n");
				return -1;
			}
		}

		else if (!strcmp(type, "FirmwareUpdaterData")) {
			if(restore_send_firmware_updater_data(client, message) < 0) {
				logger(LL_ERROR, "Unable to send FirmwareUpdater data\n");
				return -1;
			}
		}

		else if (!strcmp(type, "PersonalizedData")) {
			if(restore_send_image_data(client, message, "ImageList", NULL, "ImageData") < 0) {
				logger(LL_ERROR, "Unable to send Personalized data\n");
				return -1;
			}
		}

		else if (!strcmp(type, "EANData")) {
			if(restore_send_image_data(client, message, "EANImageList", "IsEarlyAccessFirmware", "EANData") < 0) {
				logger(LL_ERROR, "Unable to send Personalized data\n");
				return -1;
			}
		}

		else if (!strcmp(type, "BootabilityBundle")) {
			if (restore_send_bootability_bundle_data(client, message) < 0) {
				logger(LL_ERROR, "Unable to send BootabilityBundle data\n");
				return -1;
			}
		}

		else if (!strcmp(type, "ReceiptManifest")) {
			if (restore_send_receipt_manifest(client, message) < 0) {
				logger(LL_ERROR, "Unable to send ReceiptManifest data\n");
				return -1;
			}
		}

		else if (!strcmp(type, "BasebandUpdaterOutputData")) {
			if (restore_handle_baseband_updater_output_data(client, message) < 0) {
				logger(LL_ERROR, "Unable to send BasebandUpdaterOutputData data\n");
				return -1;
			}
		}

		else if (!strcmp(type, "URLAsset")) {
			if (restore_send_url_asset(client, message) < 0) {
				logger(LL_ERROR, "Unable to send URLAsset data\n");
				return -1;
			}
		}

		else if (!strcmp(type, "StreamedImageDecryptionKey")) {
			if (restore_send_streamed_image_decryption_key(client, message) < 0) {
				logger(LL_ERROR, "Unable to send StreamedImageDecryptionKey data\n");
				return -1;
			}
		}

		else if (!strcmp(type, "RecoveryOSFileAssetImage")) {
			if (restore_send_recovery_os_file_asset_image(client, message) < 0) {
				logger(LL_ERROR, "Unable to send RecoveryOSFileImageAssetImage data\n");
				return -1;
			}
		}

		else if (!strcmp(type, "RecoveryOSIBootFWFilesImages")) {
			if (restore_send_recovery_os_iboot_fw_files_images(client, message) < 0) {
				logger(LL_ERROR, "Unable to send RecoveryOSIBootFWFilesImages data\n");
				return -1;
			}
		}

		else if (!strcmp(type, "RecoveryOSImage")) {
			if (restore_send_recovery_os_image(client, message) < 0) {
				logger(LL_ERROR, "Unable to send RecoveryOSImage data\n");
				return -1;
			}
		}

		else if (!strcmp(type, "RecoveryOSVersionData")) {
			if (restore_send_recovery_os_version_data(client, message) < 0) {
				logger(LL_ERROR, "Unable to send RecoveryOSVersionData data\n");
				return -1;
			}
		}

		else {
			// Unknown DataType!!
			logger(LL_ERROR, "Unknown data request '%s' received\n", type);
			logger_dump_plist(LL_VERBOSE, message, 1);
		}
	}
	return 0;
}

struct _restore_async_args {
	struct idevicerestore_client_t* client;
	plist_t message;
};

static void* _restore_handle_async_data_request(void* args)
{
	struct _restore_async_args* async_args = (struct _restore_async_args*)args;
	struct idevicerestore_client_t* client = async_args->client;
	plist_t message = async_args->message;
	free(async_args);

	int err = restore_handle_data_request_msg(client, message);
	if (err < 0) {
		client->async_err = err;
		client->flags |= FLAG_QUIT;
	}

	plist_free(message);
	return NULL;
}

static int restore_handle_restored_crash(struct idevicerestore_client_t* client, plist_t message)
{
	plist_t backtrace = plist_dict_get_item(message, "RestoredBacktrace");
	logger(LL_INFO, "*** restored crashed, backtrace following ***\n");
	if (PLIST_IS_STRING(backtrace)) {
		logger(LL_INFO, "%s\n", plist_get_string_ptr(backtrace, NULL));
	} else if (PLIST_IS_ARRAY(backtrace)) {
		uint32_t i = 0;
		for (i = 0; i < plist_array_get_size(backtrace); i++) {
			plist_t line = plist_array_get_item(backtrace, i);
			logger(LL_INFO, "\t%s\n", plist_get_string_ptr(line, NULL));
		}
	} else {
		logger_dump_plist(LL_VERBOSE, message, 1);
	}
	return 0;
}

static int restore_handle_async_wait(struct idevicerestore_client_t* client, plist_t message)
{
	logger(LL_DEBUG, "AsyncWait\n");
	logger_dump_plist(LL_DEBUG, message, 1);
	return 0;
}

static int restore_handle_restore_attestation(struct idevicerestore_client_t* client, plist_t message)
{
	logger_dump_plist(LL_DEBUG, message, 1);
	logger(LL_DEBUG, "Sending RestoreShouldAttest: false\n");
	plist_t dict = plist_new_dict();
	plist_dict_set_item(dict, "RestoreShouldAttest", plist_new_bool(0));
	restored_error_t restore_error = restored_send(client->restore->client, dict);
	plist_free(dict);	
	if (restore_error != RESTORE_E_SUCCESS) {
		logger(LL_ERROR, "Unable to send RestoreShouldAttest (%d)\n", restore_error);
		return -1;
	}
	return 0;
}

static void _restore_calculate_recovery_os_partition_size(struct idevicerestore_client_t* client, uint64_t* min_size, uint64_t* max_size)
{
	const char* asset_list[] = { "OS", "KernelCache", "DeviceTree", "iBEC", "AppleLogo", "StaticTrustCache", "iBootData", "Diags", "Ap,SystemVolumeCanonicalMetadata", "SystemVolume", "BaseSystemVolume", "Ap,BaseSystemTrustCache", "AVISP1,RTKitOS", NULL };

	if (min_size) *min_size = 356;
	if (max_size) *max_size = 420;

	double total_size = 0;
	plist_t firmware_items = plist_new_dict();
	plist_t build_id_manifest = plist_dict_get_item(client->recovery_variant, "Manifest");
	plist_dict_iter iter = NULL;
	plist_dict_new_iter(build_id_manifest, &iter);
	if (iter) {
		char *component = NULL;
		plist_t manifest_entry;
		do {
			component = NULL;
			manifest_entry = NULL;
			plist_dict_next_item(build_id_manifest, iter, &component, &manifest_entry);
			if (component && PLIST_IS_DICT(manifest_entry) && plist_dict_get_item(firmware_items, component) == NULL) {
				int add_image = 0;
				int i = 0;
				while (asset_list[i]) {
					if (!strcmp(asset_list[i], component)) {
						add_image = 1;
						break;
					}
					i++;
				}
				plist_t fw_node;
				fw_node = plist_access_path(manifest_entry, 2, "Info", "IsLoadedByiBoot");
				if (fw_node && plist_get_node_type(fw_node) == PLIST_BOOLEAN) {
					uint8_t loaded_by_iboot = 0;
					plist_get_bool_val(fw_node, &loaded_by_iboot);
					if (loaded_by_iboot) {
						add_image = 1;
					}
				}
				if (add_image) {
					plist_t p_path = plist_access_path(manifest_entry, 2, "Info", "Path");
					if (p_path) {
						const char* path = plist_get_string_ptr(p_path, NULL);
						uint64_t fsize = 0;
						if (ipsw_get_file_size(client->ipsw, path, &fsize) == 0) {
							logger(LL_DEBUG, "%s: Adding %s (%s, %" PRIu64 " bytes)\n", __func__, component, path, fsize);
							total_size += (double)fsize / 0x100000;
						}
					}
				}
			}
			free(component);
		} while (manifest_entry);
		plist_mem_free(iter);
	}
	total_size = ceil(total_size);
	if (min_size) *min_size = total_size * 1.05 + 25;
	if (max_size) *max_size = total_size * 1.25 + 25;
}

// Extracted from ac2
plist_t restore_supported_data_types()
{
	plist_t dict = plist_new_dict();
	plist_dict_set_item(dict, "AuthInstallCACert", plist_new_bool(1));
	plist_dict_set_item(dict, "BasebandBootData", plist_new_bool(0));
	plist_dict_set_item(dict, "BasebandData", plist_new_bool(0));
	plist_dict_set_item(dict, "BasebandStackData", plist_new_bool(0));
	plist_dict_set_item(dict, "BasebandUpdaterOutputData", plist_new_bool(0));
	plist_dict_set_item(dict, "BootabilityBundle", plist_new_bool(0));
	plist_dict_set_item(dict, "BuildIdentityDict", plist_new_bool(0));
	plist_dict_set_item(dict, "BuildIdentityDictV2", plist_new_bool(0));
	plist_dict_set_item(dict, "Cryptex1LocalPolicy", plist_new_bool(1));
	plist_dict_set_item(dict, "DataType", plist_new_bool(0));
	plist_dict_set_item(dict, "DiagData", plist_new_bool(0));
	plist_dict_set_item(dict, "EANData", plist_new_bool(0));
	plist_dict_set_item(dict, "FDRMemoryCommit", plist_new_bool(0));
	plist_dict_set_item(dict, "FDRTrustData", plist_new_bool(0));
	plist_dict_set_item(dict, "FUDData", plist_new_bool(0));
	plist_dict_set_item(dict, "FileData", plist_new_bool(0));
	plist_dict_set_item(dict, "FileDataDone", plist_new_bool(0));
	plist_dict_set_item(dict, "FirmwareUpdaterData", plist_new_bool(0));
	plist_dict_set_item(dict, "FirmwareUpdaterDataV2", plist_new_bool(0));
	plist_dict_set_item(dict, "FirmwareUpdaterDataV3", plist_new_bool(1));
	plist_dict_set_item(dict, "FirmwareUpdaterPreflight", plist_new_bool(1));
	plist_dict_set_item(dict, "GrapeFWData", plist_new_bool(0));
	plist_dict_set_item(dict, "HPMFWData", plist_new_bool(0));
	plist_dict_set_item(dict, "HostSystemTime", plist_new_bool(1));
	plist_dict_set_item(dict, "KernelCache", plist_new_bool(0));
	plist_dict_set_item(dict, "MessageUseStreamedImageFile", plist_new_bool(1));
	plist_dict_set_item(dict, "NORData", plist_new_bool(0));
	plist_dict_set_item(dict, "NitrogenFWData", plist_new_bool(1));
	plist_dict_set_item(dict, "OpalFWData", plist_new_bool(0));
	plist_dict_set_item(dict, "OverlayRootDataCount", plist_new_bool(0));
	plist_dict_set_item(dict, "OverlayRootDataForKey", plist_new_bool(1));
	plist_dict_set_item(dict, "OverlayRootDataForKeyIndex", plist_new_bool(1));
	plist_dict_set_item(dict, "PeppyFWData", plist_new_bool(1));
	plist_dict_set_item(dict, "PersonalizedBootObjectV3", plist_new_bool(0));
	plist_dict_set_item(dict, "PersonalizedData", plist_new_bool(1));
	plist_dict_set_item(dict, "ProvisioningData", plist_new_bool(0));
	plist_dict_set_item(dict, "RamdiskFWData", plist_new_bool(1));
	plist_dict_set_item(dict, "ReceiptManifest", plist_new_bool(1));
	plist_dict_set_item(dict, "RecoveryOSASRImage", plist_new_bool(1));
	plist_dict_set_item(dict, "RecoveryOSAppleLogo", plist_new_bool(1));
	plist_dict_set_item(dict, "RecoveryOSDeviceTree", plist_new_bool(1));
	plist_dict_set_item(dict, "RecoveryOSFileAssetImage", plist_new_bool(1));
	plist_dict_set_item(dict, "RecoveryOSIBEC", plist_new_bool(1));
	plist_dict_set_item(dict, "RecoveryOSIBootFWFilesImages", plist_new_bool(1));
	plist_dict_set_item(dict, "RecoveryOSImage", plist_new_bool(1));
	plist_dict_set_item(dict, "RecoveryOSKernelCache", plist_new_bool(1));
	plist_dict_set_item(dict, "RecoveryOSLocalPolicy", plist_new_bool(1));
	plist_dict_set_item(dict, "RecoveryOSOverlayRootDataCount", plist_new_bool(0));
	plist_dict_set_item(dict, "RecoveryOSRootTicketData", plist_new_bool(1));
	plist_dict_set_item(dict, "RecoveryOSStaticTrustCache", plist_new_bool(1));
	plist_dict_set_item(dict, "RecoveryOSVersionData", plist_new_bool(1));
	plist_dict_set_item(dict, "RestoreLocalPolicy", plist_new_bool(1));
	plist_dict_set_item(dict, "RootData", plist_new_bool(0));
	plist_dict_set_item(dict, "RootTicket", plist_new_bool(0));
	plist_dict_set_item(dict, "S3EOverride", plist_new_bool(0));
	plist_dict_set_item(dict, "SourceBootObjectV3", plist_new_bool(0));
	plist_dict_set_item(dict, "SourceBootObjectV4", plist_new_bool(0));
	plist_dict_set_item(dict, "SsoServiceTicket", plist_new_bool(0));
	plist_dict_set_item(dict, "StockholmPostflight", plist_new_bool(0));
	plist_dict_set_item(dict, "SystemImageCanonicalMetadata", plist_new_bool(0));
	plist_dict_set_item(dict, "SystemImageData", plist_new_bool(0));
	plist_dict_set_item(dict, "SystemImageRootHash", plist_new_bool(0));
	plist_dict_set_item(dict, "URLAsset", plist_new_bool(1));
	plist_dict_set_item(dict, "USBCFWData", plist_new_bool(0));
	plist_dict_set_item(dict, "USBCOverride", plist_new_bool(0));
	plist_dict_set_item(dict, "UpdateVolumeOverlayRootDataCount", plist_new_bool(1));
	return dict;
}

// Extracted from ac2
plist_t restore_supported_message_types()
{
	plist_t dict = plist_new_dict();
	plist_dict_set_item(dict, "AsyncDataRequestMsg", plist_new_bool(1));
	plist_dict_set_item(dict, "AsyncWait", plist_new_bool(1));
	plist_dict_set_item(dict, "BBUpdateStatusMsg", plist_new_bool(0));
	plist_dict_set_item(dict, "CheckpointMsg", plist_new_bool(1));
	plist_dict_set_item(dict, "CrashLog", plist_new_bool(1));
	plist_dict_set_item(dict, "DataRequestMsg", plist_new_bool(0));
	plist_dict_set_item(dict, "FDRSubmit", plist_new_bool(1));
	plist_dict_set_item(dict, "MsgType", plist_new_bool(0));
	plist_dict_set_item(dict, "PreviousRestoreLogMsg", plist_new_bool(0));
	plist_dict_set_item(dict, "ProgressMsg", plist_new_bool(0));
	plist_dict_set_item(dict, "ProvisioningAck", plist_new_bool(0));
	plist_dict_set_item(dict, "ProvisioningInfo", plist_new_bool(0));
	plist_dict_set_item(dict, "ProvisioningStatusMsg", plist_new_bool(0));
	plist_dict_set_item(dict, "ReceivedFinalStatusMsg", plist_new_bool(0));
	plist_dict_set_item(dict, "RestoreAttestation", plist_new_bool(1));
	plist_dict_set_item(dict, "RestoredCrash", plist_new_bool(1));
	plist_dict_set_item(dict, "StatusMsg", plist_new_bool(0));
	return dict;
}

#ifdef HAVE_REVERSE_PROXY
static void rp_log_cb(reverse_proxy_client_t client, const char* log_msg, void* user_data)
{
	logger(LL_VERBOSE, "ReverseProxy[%s]: %s\n", (reverse_proxy_get_type(client) == RP_TYPE_CTRL) ? "Ctrl" : "Conn", log_msg);
}

static void rp_status_cb(reverse_proxy_client_t client, reverse_proxy_status_t status, const char* status_msg, void* user_data)
{
	logger(LL_VERBOSE, "ReverseProxy[%s]: (status=%d) %s\n", (reverse_proxy_get_type(client) == RP_TYPE_CTRL) ? "Ctrl" : "Conn", status, status_msg);
}
#endif

int restore_device(struct idevicerestore_client_t* client, plist_t build_identity)
{
	int err = 0;
	char* type = NULL;
	plist_t node = NULL;
	plist_t message = NULL;
	plist_t hwinfo = NULL;
	idevice_t device = NULL;
	restored_client_t restore = NULL;
	restored_error_t restore_error = RESTORE_E_SUCCESS;
#ifndef HAVE_REVERSE_PROXY
	THREAD_T fdr_thread = THREAD_T_NULL;
#endif

	restore_finished = 0;

	// open our connection to the device and verify we're in restore mode
	err = restore_open_with_timeout(client);
	if (err < 0) {
		logger(LL_ERROR, "Unable to open device in restore mode\n");
		return (err == -2) ? -1: -2;
	}
	logger(LL_INFO, "Device %s has successfully entered restore mode\n", client->udid);

	client->restore->build_identity = build_identity;
	restore = client->restore->client;
	device = client->restore->device;

	restore_error = restored_query_value(restore, "HardwareInfo", &hwinfo);
	if (restore_error == RESTORE_E_SUCCESS) {
		uint64_t i = 0;
		uint8_t b = 0;
		logger(LL_INFO, "Hardware Information:\n");

		node = plist_dict_get_item(hwinfo, "BoardID");
		if (node && plist_get_node_type(node) == PLIST_UINT) {
			plist_get_uint_val(node, &i);
			logger(LL_INFO, "BoardID: %d\n", (int)i);
		}

		node = plist_dict_get_item(hwinfo, "ChipID");
		if (node && plist_get_node_type(node) == PLIST_UINT) {
			plist_get_uint_val(node, &i);
			logger(LL_INFO, "ChipID: %d\n", (int)i);
		}

		node = plist_dict_get_item(hwinfo, "UniqueChipID");
		if (node && plist_get_node_type(node) == PLIST_UINT) {
			plist_get_uint_val(node, &i);
			logger(LL_INFO, "UniqueChipID: %" PRIu64 "\n", i);
		}

		node = plist_dict_get_item(hwinfo, "ProductionMode");
		if (node && plist_get_node_type(node) == PLIST_BOOLEAN) {
			plist_get_bool_val(node, &b);
			logger(LL_INFO, "ProductionMode: %s\n", (b==1) ? "true":"false");
		}
		plist_free(hwinfo);
	}

	restore_error = restored_query_value(restore, "SavedDebugInfo", &hwinfo);
	if (restore_error == RESTORE_E_SUCCESS) {
		char* sval = NULL;

		node = plist_dict_get_item(hwinfo, "PreviousExitStatus");
		if (node && plist_get_node_type(node) == PLIST_STRING) {
			plist_get_string_val(node, &sval);
			logger(LL_INFO, "Previous restore exit status: %s\n", sval);
			free(sval);
			sval = NULL;
		}

		node = plist_dict_get_item(hwinfo, "USBLog");
		if (node && plist_get_node_type(node) == PLIST_STRING) {
			plist_get_string_val(node, &sval);
			logger(LL_INFO, "USB log is available:\n%s\n", sval);
			free(sval);
			sval = NULL;
		}

		node = plist_dict_get_item(hwinfo, "PanicLog");
		if (node && plist_get_node_type(node) == PLIST_STRING) {
			plist_get_string_val(node, &sval);
			logger(LL_INFO, "Panic log is available:\n%s\n", sval);
			free(sval);
			sval = NULL;
		}
		plist_free(hwinfo);
	}

	if (plist_dict_get_item(client->tss, "BBTicket")) {
		client->restore->bbtss = plist_copy(client->tss);
	}

#ifdef HAVE_REVERSE_PROXY
	logger(LL_INFO, "Starting Reverse Proxy\n");
	reverse_proxy_client_t rproxy = NULL;
	if (reverse_proxy_client_create_with_port(device, &rproxy, REVERSE_PROXY_DEFAULT_PORT) != REVERSE_PROXY_E_SUCCESS) {
		logger(LL_ERROR, "Could not create Reverse Proxy\n");
	} else {
		if (client->flags & FLAG_DEBUG) {
			reverse_proxy_client_set_log_callback(rproxy, rp_log_cb, NULL);
		}
		reverse_proxy_client_set_status_callback(rproxy, rp_status_cb, NULL);
		if (reverse_proxy_client_start_proxy(rproxy, 2) != REVERSE_PROXY_E_SUCCESS) {
			logger(LL_ERROR, "Device didn't accept new reverse proxy protocol, trying to use old one\n");
			reverse_proxy_client_free(rproxy);
			rproxy = NULL;
			if (reverse_proxy_client_create_with_port(device, &rproxy, REVERSE_PROXY_DEFAULT_PORT) != REVERSE_PROXY_E_SUCCESS) {
				logger(LL_ERROR, "Could not create Reverse Proxy\n");
			} else {
				if (client->flags & FLAG_DEBUG) {
					reverse_proxy_client_set_log_callback(rproxy, rp_log_cb, NULL);
				}
				reverse_proxy_client_set_status_callback(rproxy, rp_status_cb, NULL);
				if (reverse_proxy_client_start_proxy(rproxy, 1) != REVERSE_PROXY_E_SUCCESS) {
					logger(LL_ERROR, "ReverseProxy: Device didn't accept old protocol, giving up\n");
				}
			}
		}
	}
#else
	fdr_client_t fdr_control_channel = NULL;
	logger(LL_INFO, "Starting FDR listener thread\n");
	if (!fdr_connect(device, FDR_CTRL, &fdr_control_channel)) {
		if(thread_new(&fdr_thread, fdr_listener_thread, fdr_control_channel)) {
			logger(LL_ERROR, "Failed to start FDR listener thread\n");
			fdr_thread = THREAD_T_NULL; /* undefined after failure */
		}
	} else {
		logger(LL_ERROR, "Failed to start FDR Ctrl channel\n");
		// FIXME: We might want to return failure here as it will likely fail
	}
#endif

	plist_t opts = plist_new_dict();
	// FIXME: required?
	//plist_dict_set_item(opts, "AuthInstallRestoreBehavior", plist_new_string("Erase"));
	plist_dict_set_item(opts, "AutoBootDelay", plist_new_uint(0));

	if (client->firmware_preflight_info) {
		plist_t bbus = plist_copy(client->firmware_preflight_info);

		plist_dict_remove_item(bbus, "FusingStatus");
		plist_dict_remove_item(bbus, "PkHash");

		plist_dict_set_item(opts, "BBUpdaterState", bbus);

		plist_dict_copy_data(opts, client->firmware_preflight_info, "BasebandNonce", "Nonce");
	}

	plist_dict_set_item(opts, "SupportedDataTypes", restore_supported_data_types());
	plist_dict_set_item(opts, "SupportedMessageTypes", restore_supported_message_types());

	// FIXME: Should be adjusted for update behaviors
	if (client->macos_variant) {
		plist_dict_set_item(opts, "AddSystemPartitionPadding", plist_new_bool(1));
		plist_dict_set_item(opts, "AllowUntetheredRestore", plist_new_bool(0));
		plist_dict_set_item(opts, "AuthInstallEnableSso", plist_new_bool(0));
		char *macos_variant = NULL;
		int ret = extract_macos_variant(build_identity, &macos_variant);
		if (ret == 0) {
			plist_dict_set_item(opts, "AuthInstallRecoveryOSVariant", plist_new_string(macos_variant));
			free(macos_variant);
		}
		plist_dict_set_item(opts, "AuthInstallRestoreBehavior", plist_new_string(client->flags & FLAG_ERASE ? "Erase": "Update"));
		plist_dict_set_item(opts, "AutoBootDelay", plist_new_uint(0));
		plist_dict_set_item(opts, "BasebandUpdaterOutputPath", plist_new_bool(1));
		plist_dict_set_item(opts, "DisableUserAuthentication", plist_new_bool(1));
		plist_dict_set_item(opts, "FitSystemPartitionToContent", plist_new_bool(1));
		plist_dict_set_item(opts, "FlashNOR", plist_new_bool(1));
		plist_dict_set_item(opts, "FormatForAPFS", plist_new_bool(1));
		plist_dict_set_item(opts, "FormatForLwVM", plist_new_bool(0));
		plist_dict_set_item(opts, "InstallDiags", plist_new_bool(0));
		plist_dict_set_item(opts, "InstallRecoveryOS", plist_new_bool(1));
		plist_dict_set_item(opts, "MacOSSwapPerformed", plist_new_bool(1));
		plist_dict_set_item(opts, "MacOSVariantPresent", plist_new_bool(1));
		plist_dict_set_item(opts, "MinimumBatteryVoltage", plist_new_uint(0)); // FIXME: Should be adjusted for M1 macbooks (if needed)
		plist_dict_set_item(opts, "RecoveryOSUnpack", plist_new_bool(1));
		plist_dict_set_item(opts, "ShouldRestoreSystemImage", plist_new_bool(1));
		plist_dict_set_item(opts, "SkipPreflightPersonalization", plist_new_bool(0));
		plist_dict_set_item(opts, "UpdateBaseband", plist_new_bool(1));
		// FIXME: I don't know where this number comes from yet. It seems like it matches this part of the build identity:
		// 	<key>OSVarContentSize</key>
		// 	<integer>573751296</integer>
		//  But i can't seem to find a plausible formula
		// It did work with multiple macOS versions
		plist_dict_set_item(opts, "recoveryOSPartitionSize", plist_new_uint(58201));
		plist_t msp = plist_access_path(build_identity, 2, "Info", "MinimumSystemPartition");
		if (msp) {
			plist_dict_set_item(opts, "SystemPartitionSize", plist_copy(msp));
		}
	} else {
		// FIXME: new on iOS 5 ?
		plist_dict_set_item(opts, "BootImageType", plist_new_string("User"));
		// FIXME: required?
		//plist_dict_set_item(opts, "BootImageFile", plist_new_string("018-7923-347.dmg"));
		plist_dict_set_item(opts, "DFUFileType", plist_new_string("RELEASE"));
		plist_dict_set_item(opts, "DataImage", plist_new_bool(0));
		// FIXME: not required for iOS 5?
		//plist_dict_set_item(opts, "DeviceTreeFile", plist_new_string("DeviceTree.k48ap.img3"));
		plist_dict_set_item(opts, "FirmwareDirectory", plist_new_string("."));
		// FIXME: usable if false? (-x parameter)
		plist_dict_set_item(opts, "FlashNOR", plist_new_bool(1));
		// FIXME: not required for iOS 5?
		//plist_dict_set_item(opts, "KernelCacheFile", plist_new_string("kernelcache.release.k48"));
		// FIXME: new on iOS 5 ?
		plist_dict_set_item(opts, "KernelCacheType", plist_new_string("Release"));
		// FIXME: not required for iOS 5?
		//plist_dict_set_item(opts, "NORImagePath", plist_new_string("."));
		// FIXME: new on iOS 5 ?
		plist_dict_set_item(opts, "NORImageType", plist_new_string("production"));
		// FIXME: not required for iOS 5?
		//plist_dict_set_item(opts, "PersonalizedRestoreBundlePath", plist_new_string("/tmp/Per2.tmp"));
		plist_dict_set_item(opts, "RestoreBundlePath", plist_new_string("/tmp/Per2.tmp"));
		// FIXME: not required for iOS 5?
		//plist_dict_set_item(opts, "SourceRestoreBundlePath", plist_new_string("/tmp"));
		// FIXME: new on iOS 5 ?
		plist_dict_set_item(opts, "SystemImageType", plist_new_string("User"));
		// FIXME: does this have any effect actually?
		plist_dict_set_item(opts, "UpdateBaseband", plist_new_bool(1));
		plist_dict_set_item(opts, "InstallDiags", plist_new_bool(0));
		if (client->recovery_variant) {
			plist_dict_set_item(opts, "InstallRecoveryOS", plist_new_bool(1));
			plist_dict_set_item(opts, "RecoveryOSBundlePath", plist_new_string("/tmp/Per2.tmp"));
			plist_t recovery_variant = plist_access_path(client->recovery_variant, 2, "Info", "Variant");
			plist_dict_set_item(opts, "AuthInstallRecoveryOSVariant", plist_copy(recovery_variant));
			uint64_t max_size = 0;
			uint64_t min_size = 0;
			_restore_calculate_recovery_os_partition_size(client, &min_size, &max_size);
			logger(LL_INFO, "Calculated recoveryOSPartitionSize as %" PRIu64 " MB\n", min_size);
			logger(LL_INFO, "Calculated recoveryOSMaxPartitionSize as %" PRIu64 " MB\n", max_size);
			plist_dict_set_item(opts, "recoveryOSMaxPartitionSize", plist_new_uint(max_size));
			plist_dict_set_item(opts, "recoveryOSPartitionSize", plist_new_uint(min_size));
		}

		if (plist_dict_get_bool(client->parameters, "RequiresNonceSlot")) {
			logger(LL_INFO, "Device will use nonce slots.\n");
		} else {
			logger(LL_INFO, "Device will not use nonce slots.\n");
		}

		// Added for iOS 18.0 beta 1
		plist_dict_set_item(opts, "HostHasFixFor99053849", plist_new_bool(1));
		plist_dict_set_item(opts, "SystemImageFormat", plist_new_string("AEAWrappedDiskImage"));
		plist_dict_set_item(opts, "WaitForDeviceConnectionToFinishStateMachine", plist_new_bool(0));

		plist_t sep = plist_access_path(build_identity, 3, "Manifest", "SEP", "Info");
		if (sep) {
			node = plist_dict_get_item(sep, "RequiredCapacity");
			if (node && plist_get_node_type(node) == PLIST_STRING) {
				char* sval = NULL;
				plist_get_string_val(node, &sval);
				logger(LL_DEBUG, "TZ0RequiredCapacity: %s\n", sval);
				plist_dict_set_item(opts, "TZ0RequiredCapacity", plist_copy(node));
				free(sval);
				sval = NULL;
			}
		}
		// FIXME: not required for iOS 5?
		//plist_dict_set_item(opts, "UserLocale", plist_new_string("en_US"));
		/* this is mandatory on iOS 7+ to allow restore from normal mode */
		plist_dict_set_item(opts, "PersonalizedDuringPreflight", plist_new_bool(1));
	}

	// Added for iOS 18.0 and macOS 15.0
	plist_t async_data_types = plist_new_dict();
	plist_dict_set_item(async_data_types, "BasebandData", plist_new_bool(0));
	plist_dict_set_item(async_data_types, "RecoveryOSASRImage", plist_new_bool(0));
	plist_dict_set_item(async_data_types, "StreamedImageDecryptionKey", plist_new_bool(0));
	plist_dict_set_item(async_data_types, "SystemImageData", plist_new_bool(0));
	plist_dict_set_item(async_data_types, "URLAsset", plist_new_bool(1));
	plist_dict_set_item(opts, "SupportedAsyncDataTypes", async_data_types);

	plist_dict_set_item(opts, "RootToInstall", plist_new_bool(0));
	char* guid = generate_guid();
	if (guid) {
		plist_dict_set_item(opts, "UUID", plist_new_string(guid));
		free(guid);
	}
	plist_dict_set_item(opts, "CreateFilesystemPartitions", plist_new_bool(1));
	plist_dict_set_item(opts, "SystemImage", plist_new_bool(1));
	if (client->restore_boot_args) {
		plist_dict_set_item(opts, "RestoreBootArgs", plist_new_string(client->restore_boot_args));
	}
	plist_t spp = plist_access_path(build_identity, 2, "Info", "SystemPartitionPadding");
	if (spp) {
		spp = plist_copy(spp);
	} else {
		spp = plist_new_dict();
		plist_dict_set_item(spp, "1024", plist_new_uint(1280));
		plist_dict_set_item(spp, "128", plist_new_uint(1280));
		plist_dict_set_item(spp, "16", plist_new_uint(160));
		plist_dict_set_item(spp, "256", plist_new_uint(1280));
		plist_dict_set_item(spp, "32", plist_new_uint(320));
		plist_dict_set_item(spp, "512", plist_new_uint(1280));
		plist_dict_set_item(spp, "64", plist_new_uint(640));
		plist_dict_set_item(spp, "768", plist_new_uint(1280));
		plist_dict_set_item(spp, "8", plist_new_uint(80));
	}
	plist_dict_set_item(opts, "SystemPartitionPadding", spp);

	// start the restore process
	restore_error = restored_start_restore(restore, opts, client->restore->protocol_version);
	if (restore_error != RESTORE_E_SUCCESS) {
		logger(LL_ERROR, "Unable to start the restore process\n");
		plist_free(opts);
		restore_client_free(client);
		return -1;
	}
	plist_free(opts);
	idevicerestore_progress(client, RESTORE_STEP_PREPARE, 1.0);

	// this is the restore process loop, it reads each message in from
	// restored and passes that data on to it's specific handler
	while (!(client->flags & FLAG_QUIT)) {
		if (err != 0 && client->flags & FLAG_IGNORE_ERRORS) {
			logger(LL_WARNING, "Attempting to continue after critical error, restore might fail...\n");
			err = 0;
		}
		// finally, if any of these message handlers returned -1 then we encountered
		// an unrecoverable error, so we need to bail.
		if (err < 0) {
			logger(LL_ERROR, "Unable to successfully restore device\n");
			client->flags |= FLAG_QUIT;
		}

		restore_error = restored_receive(restore, &message);
#ifdef HAVE_RESTORE_E_RECEIVE_TIMEOUT
		if (restore_error == RESTORE_E_RECEIVE_TIMEOUT) {
			logger(LL_DEBUG, "No data to read (timeout)\n");
			message = NULL;
			continue;
		} else if (restore_error != RESTORE_E_SUCCESS) {
			logger(LL_ERROR, "Could not read data (%d). Aborting.\n", restore_error);
			err = -11;
			break;
		}
#else
		if (restore_error != RESTORE_E_SUCCESS) {
			logger(LL_DEBUG, "No data to read\n");
			message = NULL;
			continue;
		}
#endif

		// discover what kind of message has been received
		node = plist_dict_get_item(message, "MsgType");
		if (!node || plist_get_node_type(node) != PLIST_STRING) {
			logger(LL_DEBUG, "Unknown message received:\n");
			logger_dump_plist(LL_DEBUG, message, 1);
			plist_free(message);
			message = NULL;
			continue;
		}
		plist_get_string_val(node, &type);

		// data request messages are sent by restored whenever it requires
		// files sent to the server by the client. these data requests include
		// SystemImageData, RootTicket, KernelCache, NORData and BasebandData requests
		if (!strcmp(type, "DataRequestMsg")) {
			err = restore_handle_data_request_msg(client, message);
		}

		// async data request message
		else if (!strcmp(type, "AsyncDataRequestMsg")) {
			THREAD_T t = THREAD_T_NULL;
			struct _restore_async_args* args = (struct _restore_async_args*)malloc(sizeof(struct _restore_async_args));
			args->client = client;
			args->message = plist_copy(message);
			if (thread_new(&t, _restore_handle_async_data_request, args) < 0) {
				free(args);
				logger(LL_ERROR, "Failed to start async data request handler thread!\n");
				err = -1;
				if (client->flags & FLAG_IGNORE_ERRORS) {
					client->flags &= ~FLAG_IGNORE_ERRORS;
				}
			} else {
				thread_detach(t);
			}
		}

		// restore logs are available if a previous restore failed
		else if (!strcmp(type, "PreviousRestoreLogMsg")) {
			err = restore_handle_previous_restore_log_msg(restore, message);
		}

		// progress notification messages sent by the restored inform the client
		// of it's current operation and sometimes percent of progress is complete
		else if (!strcmp(type, "ProgressMsg")) {
			err = restore_handle_progress_msg(client, message);
		}

		// status messages usually indicate the current state of the restored
		// process or often to signal an error has been encountered
		else if (!strcmp(type, "StatusMsg")) {
			err = restore_handle_status_msg(client, message);
			if (restore_finished) {
				plist_t dict = plist_new_dict();
				plist_dict_set_item(dict, "MsgType", plist_new_string("ReceivedFinalStatusMsg"));
				restored_send(restore, dict);
				plist_free(dict);
				client->flags |= FLAG_QUIT;
			}
		}

		else if (!strcmp(type, "CheckpointMsg")) {
			uint64_t ckpt_id;
			int64_t ckpt_res;
			uint8_t ckpt_complete = 0;
			const char* ckpt_name = NULL;
			// Get checkpoint id
			node = plist_dict_get_item(message, "CHECKPOINT_ID");
			if (!node || plist_get_node_type(node) != PLIST_INT) {
				logger(LL_DEBUG, "Failed to parse checkpoint id from checkpoint plist\n");
				err = -1;
				break;
			}
			plist_get_uint_val(node, &ckpt_id);
			// Get checkpoint_name
			node = plist_dict_get_item(message, "CHECKPOINT_NAME");
			ckpt_name = (node) ? plist_get_string_ptr(node, NULL) : "unknown";
			// Get checkpoint result
			node = plist_dict_get_item(message, "CHECKPOINT_RESULT");
			if (!node || plist_get_node_type(node) != PLIST_INT) {
				logger(LL_DEBUG, "Failed to parse checkpoint result from checkpoint plist\n");
				err = -1;
				break;
			}
			plist_get_int_val(node, &ckpt_res);
			// Get checkpoint complete
			node = plist_dict_get_item(message, "CHECKPOINT_COMPLETE");
			if (PLIST_IS_BOOLEAN(node)) {
				plist_get_bool_val(node, &ckpt_complete);
			}

			if (ckpt_complete) {
				logger(LL_VERBOSE, "Checkpoint completed id: 0x%" PRIX64 " (%s) result=%" PRIi64 "\n", ckpt_id, ckpt_name, ckpt_res);
			} else {
				logger(LL_VERBOSE, "Checkpoint started   id: 0x%" PRIX64 " (%s)\n", ckpt_id, ckpt_name);
			}
			node = plist_dict_get_item(message, "CHECKPOINT_WARNING");
			if (node) {
				logger(LL_VERBOSE, "Checkpoint WARNING id: 0x%" PRIX64 " result=%" PRIi64 ": %s\n", ckpt_id, ckpt_res, plist_get_string_ptr(node, NULL));
			}
			node = plist_dict_get_item(message, "CHECKPOINT_ERROR");
			if (node) {
				logger(LL_VERBOSE, "Checkpoint FAILURE id: 0x%" PRIX64 " result=%" PRIi64 ": %s\n", ckpt_id, ckpt_res, plist_get_string_ptr(node, NULL));
			}
		}

		// baseband update message
		else if (!strcmp(type, "BBUpdateStatusMsg")) {
			err = restore_handle_bb_update_status_msg(client, message);
		}

		// baseband updater output data request
		else if (!strcmp(type, "BasebandUpdaterOutputData")) {
			err = restore_handle_baseband_updater_output_data(client, message);
		}

		// handle restored crash, print backtrace
		else if (!strcmp(type, "RestoredCrash")) {
			err = restore_handle_restored_crash(client, message);
		}

		// handle async wait
		else if (!strcmp(type, "AsyncWait")) {
			err = restore_handle_async_wait(client, message);
		}

		else if (!strcmp(type, "RestoreAttestation")) {
			err = restore_handle_restore_attestation(client, message);
		}

		// there might be some other message types i'm not aware of, but I think
		// at least the "previous error logs" messages usually end up here
		else {
			logger(LL_DEBUG, "Unknown message type received\n");
			logger_dump_plist(LL_DEBUG, message, 1);
		}

		free(type);
		plist_free(message);
		message = NULL;
	}
	if (client->async_err != 0) {
		err = client->async_err;
	}

#ifdef HAVE_REVERSE_PROXY
	reverse_proxy_client_free(rproxy);
#else
	if (thread_alive(fdr_thread)) {
		if (fdr_control_channel) {
			fdr_disconnect(fdr_control_channel);
			thread_join(fdr_thread);
			fdr_control_channel = NULL;
		}
	}
#endif

	restore_client_free(client);
	return err;
}
