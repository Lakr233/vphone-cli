/*
 * asr.h
 * Functions for handling asr connections
 *
 * Copyright (c) 2012 Martin Szulecki. All Rights Reserved.
 * Copyright (c) 2012 Nikias Bassen. All Rights Reserved.
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

#ifndef IDEVICERESTORE_ASR_H
#define IDEVICERESTORE_ASR_H

#ifdef __cplusplus
extern "C" {
#endif

#include <libimobiledevice/libimobiledevice.h>

#define ASR_DEFAULT_PORT 12345

typedef void (*asr_progress_cb_t)(double, void*);

struct asr_client {
	idevice_connection_t connection;
	uint8_t checksum_chunks;
	int lastprogress;
	asr_progress_cb_t progress_cb;
	void* progress_cb_data;
};
typedef struct asr_client *asr_client_t;

struct ipsw_file_handle;
typedef struct ipsw_file_handle* ipsw_file_handle_t;

int asr_open_with_timeout(idevice_t device, asr_client_t* asr, uint16_t port);
void asr_set_progress_callback(asr_client_t asr, asr_progress_cb_t, void* userdata);
int asr_send(asr_client_t asr, plist_t data);
int asr_receive(asr_client_t asr, plist_t* data);
int asr_send_buffer(asr_client_t asr, const void* data, size_t size);
void asr_free(asr_client_t asr);
int asr_perform_validation(asr_client_t asr, ipsw_file_handle_t file);
int asr_send_payload(asr_client_t asr, ipsw_file_handle_t file);
int asr_handle_oob_data_request(asr_client_t asr, plist_t packet, ipsw_file_handle_t file);


#ifdef __cplusplus
}
#endif

#endif
