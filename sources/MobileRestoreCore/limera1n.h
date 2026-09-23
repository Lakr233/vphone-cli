/*
 * limera1n.h
 * Helper code for limera1n exploit based on discovery by geohot
 *
 * Copyright (c) 2012-2013 Nikias Bassen. All Rights Reserved.
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

#ifndef __LIMERA1N_H
#define __LIMERA1N_H
#include <libirecovery.h>

int limera1n_is_supported(struct irecv_device *device);
int limera1n_exploit(struct irecv_device *device, irecv_client_t *client);

#endif /* __LIMERA1N_H */
