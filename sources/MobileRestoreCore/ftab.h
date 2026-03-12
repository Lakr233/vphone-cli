/*
 * ftab.h
 * Functions for handling the ftab format
 *
 * Copyright (c) 2019 Nikias Bassen. All Rights Reserved.
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

#ifndef IDEVICERESTORE_FTAB_H
#define IDEVICERESTORE_FTAB_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

struct ftab_header {
	uint32_t always_01; // 1
	uint32_t always_ff; // 0xFFFFFFFF
	uint32_t unk_0x08;  // 0
	uint32_t unk_0x0C;  // 0
	uint32_t unk_0x10;  // 0
	uint32_t unk_0x14;  // 0
	uint32_t unk_0x18;  // 0
	uint32_t unk_0x1C;  // 0
	uint32_t tag;       // e.g. 'rkos'
	uint32_t magic;     // 'ftab' magic
	uint32_t num_entries;
	uint32_t pad_0x2C;
};

struct ftab_entry {
	uint32_t tag;
	uint32_t offset;
	uint32_t size;
	uint32_t pad_0x0C;
};

struct ftab_fmt {
	struct ftab_header header;
	struct ftab_entry *entries;
	unsigned char **storage;
};

typedef struct ftab_fmt *ftab_t;

int ftab_parse(const void *data, size_t data_size, ftab_t *ftab, uint32_t *tag);
int ftab_get_entry_ptr(ftab_t ftab, uint32_t tag, void **data, size_t *data_size);
int ftab_add_entry(ftab_t ftab, uint32_t tag, const void *data, size_t data_size);
int ftab_write(ftab_t ftab, void **data, size_t *data_size);
int ftab_free(ftab_t ftab);

#ifdef __cplusplus
}
#endif

#endif
