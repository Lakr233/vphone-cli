/*
 * ftab.c
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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "ftab.h"
#include "common.h"
#include "endianness.h"

int ftab_parse(const void *data, size_t data_size, ftab_t *ftab, uint32_t *tag)
{
	if (!data || !data_size || !ftab) {
		return -1;
	}

	if (data_size < sizeof(struct ftab_header)) {
		logger(LL_ERROR, "%s: Buffer too small for ftab data\n", __func__);
		return -1;
	}

	struct ftab_header *hdr_ptr = (struct ftab_header*)data;
	if (be32toh(hdr_ptr->magic) != 'ftab') {
		logger(LL_ERROR, "%s: Unexpected magic value 0x%08x\n", __func__, le32toh(hdr_ptr->magic));
		return -1;
	}

	/* copy header */
	ftab_t ftab_new = (ftab_t)calloc(1, sizeof(struct ftab_fmt));
	memcpy(&ftab_new->header, data, sizeof(struct ftab_header));

	ftab_new->header.always_01 = le32toh(ftab_new->header.always_01);
	ftab_new->header.always_ff = le32toh(ftab_new->header.always_ff);
	ftab_new->header.tag = be32toh(ftab_new->header.tag);
	if (tag) {
		*tag = ftab_new->header.tag;
	}
	ftab_new->header.magic = be32toh(ftab_new->header.magic);
	ftab_new->header.num_entries = le32toh(ftab_new->header.num_entries);

	/* copy entries */
	ftab_new->entries = (struct ftab_entry*)malloc(sizeof(struct ftab_entry) * ftab_new->header.num_entries);
	memcpy(ftab_new->entries, data + sizeof(struct ftab_header), sizeof(struct ftab_entry) * ftab_new->header.num_entries);

	/* create data storage */
	ftab_new->storage = (unsigned char**)calloc(ftab_new->header.num_entries, sizeof(unsigned char*));

	/* fill data storage */
	uint32_t i = 0;
	for (i = 0; i < ftab_new->header.num_entries; i++) {
		ftab_new->entries[i].tag = be32toh(ftab_new->entries[i].tag);
		ftab_new->entries[i].offset = le32toh(ftab_new->entries[i].offset);
		ftab_new->entries[i].size = le32toh(ftab_new->entries[i].size);

		ftab_new->storage[i] = malloc(ftab_new->entries[i].size);
		memcpy(ftab_new->storage[i], data + ftab_new->entries[i].offset, ftab_new->entries[i].size);
	}

	*ftab = ftab_new;

	return 0;
}

int ftab_get_entry_ptr(ftab_t ftab, uint32_t tag, void **data, size_t *data_size)
{
	if (!ftab || !tag || !data || !data_size) {
		return -1;
	}

	uint32_t i;
	int res = -1;
	for (i = 0; i < ftab->header.num_entries; i++) {
		if (ftab->entries[i].tag == tag) {
			*data = ftab->storage[i];
			*data_size = ftab->entries[i].size;
			res = 0;
		}
	}
	return res;
}

int ftab_add_entry(ftab_t ftab, uint32_t tag, const void *data, size_t data_size)
{
	if (!ftab || !tag || !data || !data_size) {
		return -1;
	}

	uint32_t new_index = ftab->header.num_entries;
	struct ftab_entry *new_entries = realloc(ftab->entries, sizeof(struct ftab_entry) * (ftab->header.num_entries + 1));
	if (!new_entries) {
		logger(LL_ERROR, "%s: realloc failed!\n", __func__);
		return -1;
	}
	ftab->entries = new_entries;
	unsigned char **new_storage = realloc(ftab->storage, sizeof(unsigned char*) * (ftab->header.num_entries + 1));
	if (!new_storage) {
		logger(LL_ERROR, "%s: realloc failed!\n", __func__);
		return -1;
	}
	ftab->storage = new_storage;

	unsigned char *data_copy = (unsigned char*)malloc(data_size);
	if (!data_copy) {
		return -1;
	}
	memcpy(data_copy, data, data_size);

	ftab->storage[new_index] = data_copy;
	ftab->entries[new_index].tag = tag;
	ftab->entries[new_index].size = data_size;
	ftab->header.num_entries++;

	uint32_t off = sizeof(struct ftab_header) + sizeof(struct ftab_entry) * ftab->header.num_entries;
	uint32_t i;
	for (i = 0; i < ftab->header.num_entries; i++) {
		ftab->entries[i].offset = off;
		off += ftab->entries[i].size;
	}

	return 0;
}

int ftab_write(ftab_t ftab, void **data, size_t *data_size)
{
	uint32_t i;
	unsigned int total_size = sizeof(struct ftab_header);
	total_size += ftab->header.num_entries * sizeof(struct ftab_entry);
	for (i = 0; i < ftab->header.num_entries; i++) {
		total_size += ftab->entries[i].size;
	}

	unsigned char *data_out = (unsigned char*)malloc(total_size);
	if (!data_out) {
		logger(LL_ERROR, "%s: Out of memory?!\n", __func__);
		return -1;
	}

	struct ftab_header *ftab_header = (struct ftab_header*)data_out;
	memset(ftab_header, '\0', sizeof(struct ftab_header));
	ftab_header->always_01 = htole32(ftab->header.always_01);
	ftab_header->always_ff = htole32(ftab->header.always_ff);
	ftab_header->tag = htobe32(ftab->header.tag);
	ftab_header->magic = htobe32(ftab->header.magic);
	ftab_header->num_entries = htole32(ftab->header.num_entries);

	for (i = 0; i < ftab->header.num_entries; i++) {
		struct ftab_entry* entry = (struct ftab_entry*)(data_out + sizeof(struct ftab_header) + (sizeof(struct ftab_entry) * i));
		entry->tag = htobe32(ftab->entries[i].tag);
		entry->offset = htole32(ftab->entries[i].offset);
		entry->size = htole32(ftab->entries[i].size);
		entry->pad_0x0C = 0;
	}

	unsigned char *p = data_out + sizeof(struct ftab_header) + (sizeof(struct ftab_entry) * ftab->header.num_entries);
	for (i = 0; i < ftab->header.num_entries; i++) {
		memcpy(p, ftab->storage[i], ftab->entries[i].size);
		p += ftab->entries[i].size;
	}

	*data = data_out;
	*data_size = total_size;

	return 0;
}

int ftab_free(ftab_t ftab)
{
	if (!ftab) return -1;
	uint32_t i = 0;
	for (i = 0; i < ftab->header.num_entries; i++) {
		free(ftab->storage[i]);
	}
	free(ftab->storage);
	free(ftab->entries);
	free(ftab);
	return 0;
}
