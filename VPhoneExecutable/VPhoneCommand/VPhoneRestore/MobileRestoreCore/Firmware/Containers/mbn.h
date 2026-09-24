/*
 * mbn.h
 * support for Qualcomm MBN (Modem Binary) formats
 *
 * Copyright (c) 2012 Nikias Bassen. All Rights Reserved.
 * Copyright (c) 2025 Visual Ehrmanntraut <visual@chefkiss.dev>. All Rights Reserved.
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
#ifndef MBN_H
#define MBN_H

#include <stdint.h>

void* mbn_stitch(const void* data, size_t data_size, const void* blob, size_t blob_size);
void* mbn_mav25_stitch(const void* data, size_t data_size, const void* blob, size_t blob_size);

#endif
