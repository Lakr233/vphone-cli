/*
 * fls.c
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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fls.h"
#include "common.h"

#ifndef offsetof
#define offsetof(type, member)  __builtin_offsetof (type, member)
#endif

static void fls_parse_elements(fls_file* fls)
{
	/* FIXME: the following code is not big endian safe */
	if (!fls || !fls->data) {
		return;
	}
	uint32_t offset = 0;
	fls->max_elements = 32;
	fls->elements = (fls_element**)malloc(sizeof(fls_element*) * fls->max_elements);

	fls_element* cur = NULL;
	do {
		void* p = fls->data + offset;
		uint32_t hdrsize = 0;
		cur = (fls_element*)p;
		if ((offset + cur->size) > fls->size) {
			break;
		}
		fls_element* ne;
		switch (cur->type) {
		case 0x0c:
			{
			hdrsize = offsetof(fls_0c_element, data);
			fls_0c_element* xe = (fls_0c_element*)malloc(sizeof(fls_0c_element));
			memset(xe, '\0', sizeof(fls_0c_element));
			memcpy((void*)xe, p, hdrsize);
			xe->data = (xe->size > hdrsize) ? p + hdrsize : NULL;
			ne = (fls_element*)xe;
			fls->c_element = xe;
			}
			break;
		case 0x10:
			{
			hdrsize = offsetof(fls_10_element, data);
			fls_10_element* xe = (fls_10_element*)malloc(sizeof(fls_10_element));
			memset(xe, '\0', sizeof(fls_10_element));
			memcpy((void*)xe, p, hdrsize);
			xe->data = (xe->size > hdrsize) ? p + hdrsize : NULL;
			ne = (fls_element*)xe;
			}
			break;
		case 0x14:
			{
			hdrsize = offsetof(fls_14_element, data);
			fls_14_element* xe = (fls_14_element*)malloc(sizeof(fls_14_element));
			memset(xe, '\0', sizeof(fls_14_element));
			memcpy((void*)xe, p, hdrsize);
			xe->data = (xe->size > hdrsize) ? p + hdrsize : NULL;
			ne = (fls_element*)xe;
			}
			break;
		default:
			hdrsize = offsetof(fls_element, data);
			ne = (fls_element*)malloc(sizeof(fls_element));
			memset(ne, '\0', sizeof(fls_element));
			ne->type = cur->type;
			ne->size = cur->size;
			ne->data = (ne->size > hdrsize) ? p + hdrsize : NULL;
			break;
		}
		if ((fls->num_elements + 1) > fls->max_elements) {
			fls->max_elements += 10;
			fls->elements = (fls_element**)realloc(fls->elements, sizeof(fls_element*) * fls->max_elements);
		}
		fls->elements[fls->num_elements++] = ne;
		offset += cur->size;
	} while (offset < fls->size);
	if (offset != fls->size) {
		logger(LL_ERROR, "%s: error parsing elements\n", __func__);
		return;
	}
}

fls_file* fls_parse(const void* data, size_t size)
{
	fls_file* fls = (fls_file*)malloc(sizeof(fls_file));
	if (!fls) {
		return NULL;
	}
	memset(fls, '\0', sizeof(fls_file));
	fls->data = malloc(size);
	fls->size = size;
	memcpy(fls->data, data, size);
	fls_parse_elements(fls);
	return fls;
}

void fls_free(fls_file* fls)
{
	if (fls) {
		if (fls->num_elements > 0) {
			int i;
			for (i = fls->num_elements-1; i >=0; i--) {
				free(fls->elements[i]);
			}
			free(fls->elements);
		}
		if (fls->data) {
			free(fls->data);
		}
		free(fls);
	}
}

int fls_update_sig_blob(fls_file* fls, const void* sigdata, size_t siglen)
{
	/* FIXME: the code in this function is not big endian safe */
	if (!fls || !fls->num_elements) {
		logger(LL_ERROR, "%s: no data\n", __func__);
		return -1;
	}
	if (!fls->c_element) {
		logger(LL_ERROR, "%s: no fls_0c_element in fls data\n", __func__);
		return -1;
	}

	uint32_t datasize = *(uint32_t*)(fls->c_element->data + 0x10);
	if (datasize != fls->c_element->data_size) {
		logger(LL_ERROR, "%s: data size mismatch (0x%x != 0x%x)\n", __func__, datasize, fls->c_element->data_size);
		return -1;
	}
	uint32_t sigoffset = *(uint32_t*)(fls->c_element->data + 0x14);
	if (sigoffset > datasize) {
		logger(LL_ERROR, "%s: signature offset greater than data size (0x%x > 0x%x)\n", __func__, sigoffset, datasize);
		return -1;
	}

	size_t oldsiglen = datasize - sigoffset;
	size_t newsize = fls->size - oldsiglen + siglen;

	unsigned int i;
	uint32_t offset = 0;
	void* newdata = malloc(newsize);
	if (!newdata) {
		logger(LL_ERROR, "%s: out of memory\n", __func__);
		return -1;
	}
	uint32_t hdrsize = 0;
	uint32_t firstpartlen = 0;
	for (i = 0; i < fls->num_elements; i++) {
		switch (fls->elements[i]->type) {
		case 0x0c:
			hdrsize = offsetof(fls_0c_element, data);
			// update offset
			((fls_0c_element*)fls->elements[i])->offset = offset+hdrsize;
			// copy first part of data
			firstpartlen = fls->elements[i]->size - hdrsize - oldsiglen;
			memcpy(newdata+offset+hdrsize, ((fls_0c_element*)fls->elements[i])->data, firstpartlen);
			// copy new signature data
			memcpy(newdata+offset+hdrsize+firstpartlen, sigdata, siglen);
			((fls_0c_element*)fls->elements[i])->data = newdata+offset+hdrsize;
			fls->elements[i]->size -= oldsiglen;
			fls->elements[i]->size += siglen;
			((fls_0c_element*)fls->elements[i])->data_size -= oldsiglen;
			((fls_0c_element*)fls->elements[i])->data_size += siglen;
			memcpy(newdata+offset+hdrsize+0x10, &(((fls_0c_element*)fls->elements[i])->data_size), 4);
			// copy header
			memcpy(newdata+offset, fls->elements[i], hdrsize);
			break;
		case 0x10:
			hdrsize = offsetof(fls_10_element, data);
			// update offset
			((fls_10_element*)fls->elements[i])->offset = offset+hdrsize;
			// copy header
			memcpy(newdata+offset, fls->elements[i], hdrsize);
			// copy data
			if (fls->elements[i]->size > hdrsize) {
				memcpy(newdata+offset+hdrsize, ((fls_10_element*)fls->elements[i])->data, fls->elements[i]->size - hdrsize);
				((fls_10_element*)fls->elements[i])->data = newdata+offset+hdrsize;
			} else {
				((fls_10_element*)fls->elements[i])->data = NULL;
			}
			break;
		case 0x14:
			hdrsize = offsetof(fls_14_element, data);
			// update offset
			((fls_14_element*)fls->elements[i])->offset = offset+hdrsize;
			// copy header
			memcpy(newdata+offset, fls->elements[i], hdrsize);
			// copy data
			if (fls->elements[i]->size > hdrsize) {
				memcpy(newdata+offset+hdrsize, ((fls_14_element*)fls->elements[i])->data, fls->elements[i]->size - hdrsize);
				((fls_14_element*)fls->elements[i])->data = newdata+offset+hdrsize;
			} else {
				((fls_14_element*)fls->elements[i])->data = NULL;
			}
			break;
		default:
			hdrsize = offsetof(fls_element, data);
			// copy header
			memcpy(newdata+offset, fls->elements[i], hdrsize);
			// copy data
			if (fls->elements[i]->size > hdrsize) {
				memcpy(newdata+offset+hdrsize, fls->elements[i]->data, fls->elements[i]->size - hdrsize);
				fls->elements[i]->data = newdata+offset+hdrsize;
			} else {
				fls->elements[i]->data = NULL;
			}
			break;
		}
		offset += fls->elements[i]->size;
	}
	if (fls->data) {
		free(fls->data);
	}
	fls->data = newdata;
	fls->size = newsize;

	return 0;
}

int fls_insert_ticket(fls_file* fls, const void* data, size_t size)
{
	/* FIXME: the code in this function is not big endian safe */
	if (!fls || !fls->num_elements) {
		logger(LL_ERROR, "%s: no data\n", __func__);
		return -1;
	}
	if (!fls->c_element) {
		logger(LL_ERROR, "%s: no fls_0c_element in fls data\n", __func__);
		return -1;
	}

	uint32_t padding = 0;
	if (size%4 != 0) {
		padding = 4-(size%4);
	}
	size_t newsize = fls->size + size + padding;
	unsigned int i;
	uint32_t offset = 0;
	void* newdata = malloc(newsize);
	if (!newdata) {
		logger(LL_ERROR, "%s: out of memory\n", __func__);
		return -1;
	}
	uint32_t hdrsize = 0;
	for (i = 0; i < fls->num_elements; i++) {
		switch (fls->elements[i]->type) {
		case 0x0c:
			hdrsize = offsetof(fls_0c_element, data);
			// update offset
			((fls_0c_element*)fls->elements[i])->offset = offset+hdrsize;
			// copy ticket data
			memcpy(newdata+offset+hdrsize, data, size);
			if (padding > 0) {
				// padding
				memset(newdata+offset+hdrsize+size, '\xFF', padding);
			}
			// copy remaining data
			memcpy(newdata+offset+hdrsize+size+padding, ((fls_0c_element*)fls->elements[i])->data, fls->elements[i]->size);
			((fls_0c_element*)fls->elements[i])->data = newdata+offset+hdrsize;
			fls->elements[i]->size += (size + padding);
			((fls_0c_element*)fls->elements[i])->data_size += (size + padding);
			// copy header
			memcpy(newdata+offset, fls->elements[i], hdrsize);
			break;
		case 0x10:
			hdrsize = offsetof(fls_10_element, data);
			// update offset
			((fls_10_element*)fls->elements[i])->offset = offset+hdrsize;
			// copy header
			memcpy(newdata+offset, fls->elements[i], hdrsize);
			// copy data
			if (fls->elements[i]->size > hdrsize) {
				memcpy(newdata+offset+hdrsize, ((fls_10_element*)fls->elements[i])->data, fls->elements[i]->size - hdrsize);
				((fls_10_element*)fls->elements[i])->data = newdata+offset+hdrsize;
			} else {
				((fls_10_element*)fls->elements[i])->data = NULL;
			}
			break;
		case 0x14:
			hdrsize = offsetof(fls_14_element, data);
			// update offset
			((fls_14_element*)fls->elements[i])->offset = offset+hdrsize;
			// copy header
			memcpy(newdata+offset, fls->elements[i], hdrsize);
			// copy data
			if (fls->elements[i]->size > hdrsize) {
				memcpy(newdata+offset+hdrsize, ((fls_14_element*)fls->elements[i])->data, fls->elements[i]->size - hdrsize);
				((fls_14_element*)fls->elements[i])->data = newdata+offset+hdrsize;
			} else {
				((fls_14_element*)fls->elements[i])->data = NULL;
			}
			break;
		default:
			hdrsize = offsetof(fls_element, data);
			// copy header
			memcpy(newdata+offset, fls->elements[i], hdrsize);
			// copy data
			if (fls->elements[i]->size > hdrsize) {
				memcpy(newdata+offset+hdrsize, fls->elements[i]->data, fls->elements[i]->size - hdrsize);
				fls->elements[i]->data = newdata+offset+hdrsize;
			} else {
				fls->elements[i]->data = NULL;
			}
			break;
		}
		offset += fls->elements[i]->size;
	}
	if (fls->data) {
		free(fls->data);
	}
	fls->data = newdata;
	fls->size = newsize;

	return 0;
}

