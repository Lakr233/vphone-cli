/*
 * fdr.h
 * Functions for handling FDR connections
 *
 * Copyright (c) 2014 BALATON Zoltan. All Rights Reserved.
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

#ifndef IDEVICERESTORE_FDR_H
#define IDEVICERESTORE_FDR_H

#ifdef __cplusplus
extern "C" {
#endif

#include <libimobiledevice/libimobiledevice.h>

typedef enum {
	FDR_CTRL,
	FDR_CONN
} fdr_type_t;

struct fdr_client {
	idevice_connection_t connection;
	idevice_t device;
	fdr_type_t type;
};
typedef struct fdr_client *fdr_client_t;

int fdr_connect(idevice_t device, fdr_type_t type, fdr_client_t *fdr);
void fdr_disconnect(fdr_client_t fdr);
void fdr_free(fdr_client_t fdr);
int fdr_poll_and_handle_message(fdr_client_t fdr);
void *fdr_listener_thread(void *cdata);

#ifdef __cplusplus
}
#endif

#endif
