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

#ifndef IDEVICERESTORE_NORMAL_H
#define IDEVICERESTORE_NORMAL_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/libimobiledevice.h>

int normal_check_mode(struct idevicerestore_client_t* client);
irecv_device_t normal_get_irecv_device(struct idevicerestore_client_t* client);
int normal_enter_recovery(struct idevicerestore_client_t* client);
int normal_is_image4_supported(struct idevicerestore_client_t* client);
int normal_get_ap_nonce(struct idevicerestore_client_t* client, unsigned char** nonce, unsigned int* nonce_size);
int normal_get_sep_nonce(struct idevicerestore_client_t* client, unsigned char** nonce, unsigned int* nonce_size);
int normal_get_firmware_preflight_info(struct idevicerestore_client_t* client, plist_t *preflight_info);
int normal_get_preflight_info(struct idevicerestore_client_t* client, plist_t *preflight_info);
plist_t normal_get_lockdown_value(struct idevicerestore_client_t* client, const char* domain, const char* key);
int normal_handle_create_stashbag(struct idevicerestore_client_t* client, plist_t manifest);
int normal_handle_commit_stashbag(struct idevicerestore_client_t* client, plist_t manifest);

#ifdef __cplusplus
}
#endif

#endif
