/*
 * fls.h
 * support for .fls file format (found in .bbfw files)
 *
 * Copyright (c) 2012 Nikias Bassen. All Rights Reserved.
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
#ifndef FLS_H
#define FLS_H

#include <stdint.h>

struct _fls_element {
	uint32_t type;
	uint32_t size;
	uint32_t empty;
	const unsigned char* data;
} __attribute__((packed));
typedef struct _fls_element fls_element;

struct _fls_0c_element {
	uint32_t type;
	uint32_t size;
	uint32_t empty;
	uint32_t off_0x0c;
	uint32_t off_0x10;
	uint32_t off_0x14;
	uint32_t off_0x18;
	uint32_t data_size; // size without header
	uint32_t off_0x20;
	uint32_t offset; // absolute offset of data in file
	const unsigned char* data; // data+0x14 contains offset to sig blob
} __attribute__((packed));
typedef struct _fls_0c_element fls_0c_element;

struct _fls_10_element {
	uint32_t type;
	uint32_t size;
	uint32_t empty;
	uint32_t data_size; // size without header
	uint32_t off_0x10;
	uint32_t offset;
	const unsigned char* data;
} __attribute__((packed));
typedef struct _fls_10_element fls_10_element;

struct _fls_14_element {
	uint32_t type;
	uint32_t size;
	uint32_t empty;
	uint32_t data_size; // size without header
	uint32_t off_0x10;
	uint32_t offset;
	const unsigned char* data;
} __attribute__((packed));
typedef struct _fls_14_element fls_14_element;

typedef struct {
	unsigned int num_elements;
	unsigned int max_elements;
	fls_element** elements;
	const fls_0c_element* c_element;
	void* data;
	size_t size;
} fls_file;

fls_file* fls_parse(const void* data, size_t size);
void fls_free(fls_file* fls);
int fls_update_sig_blob(fls_file* fls, const void* data, size_t size);
int fls_insert_ticket(fls_file* fls, const void* data, size_t size);

#endif
