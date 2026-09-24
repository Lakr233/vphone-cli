/*
 * ace3.c
 * Functions to handle Ace3/uarp firmware format
 *
 * Copyright (c) 2024 Nikias Bassen, All Rights Reserved.
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

#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <libimobiledevice-glue/nskeyedarchive.h>

#include "common.h"
#include "ace3.h"
#include "endianness.h"

static uint32_t crc_buffer(const unsigned char* buffer, unsigned int bufsize, unsigned int salt)
{
	uint32_t result;
	unsigned int i;
	unsigned int j;

	if ( !buffer )
		return 0xFFFFFFFF;
	result = salt;
	for (i = 0; i < bufsize; ++i) {
		for (j = 0; j != 8; ++j) {
			unsigned int tmp0 = 2 * result;
			unsigned int tmp1 = *(unsigned char*)(buffer + i);
			unsigned int tmp2 = ((unsigned int)result >> 31) ^ ((tmp1 >> j) & 1);
			result = (tmp2 + 2 * result) ^ 0x4C11DB6;
			if (!tmp2)
				result = tmp0;
		}
	}
	return result;
}

static int uarp_version_convert(uint32_t* version_data, uint32_t* version_out)
{
	if (version_out) *version_out = 0;
	if (!version_data) {
		return -1;
	}
	uint32_t part1 = (version_data[0] < 0xE00) ? version_data[0] : version_data[0] - 0xE00;
	if (part1 > 0x63) {
		return 0;
	}
	uint32_t part2 = (version_data[0] < 0xE00) ? 0 : 0xE00;
	uint32_t part3 = version_data[1];
	if (part3 > 0x3E7) {
		return 0;
	}
	uint32_t part4 = version_data[2];
	if (part4 > 0x63) {
		return 0;
	}
	if (version_out) {
		*version_out = (((((0x147B * (unsigned int)((uint16_t)part3 >> 2)) >> 9) & 0x3FF00) | (0x10 * (((uint8_t)((uint16_t)part3 / 0xA) % 0xA) & 0xF)) | ((uint16_t)part3 % 0xA)) << 8)
		  | ((((uint8_t)part1 % 0xA) | (0x10 * ((uint8_t)part1 / 0xA)) | part2) << 20)
		  | ((uint8_t)part4 % 0xA)
		  | (((0xCD * (unsigned int)(uint8_t)part4) >> 7) & 0xF0);
	}
	return 0;
}

int ace3_create_binary(const void* uarp_fw, size_t uarp_size, uint64_t bdid, unsigned int prev, plist_t tss, void** bin_out, size_t* bin_size)
{
	struct ace3bin_header {
		uint32_t magic;        // 0xACE00003
		uint32_t version;      // ace3 version, e.g. 0x00203400
		uint32_t unk8;         // 0x00002800
		uint32_t header_size;  // 0x00000040
		uint32_t data1_size;
		uint32_t data2_size;
		uint32_t im4m_offset;
		uint32_t im4m_dl_size;
		uint32_t content_size;
		uint32_t crc;
		uint64_t fill1;        // 0xFFFFFFFFFFFFFFFF
		uint64_t fill2;        // 0xFFFFFFFFFFFFFFFF
		uint64_t fill3;        // 0xFFFFFFFFFFFFFFFF
	};

	struct uarp_header {
		uint32_t unk_00;        // BE 0x00000002
		uint32_t header_size;   // BE usually 0x0000002C
		uint32_t plist_offset;  // BE
		uint32_t unk_0c;        // 0
		uint32_t unk_10;        // 0
		uint32_t unk_14;        // 0
		uint32_t unk_18;        // 0
		uint32_t c_offset;      // BE
		uint32_t unk_20;        // 0
		uint32_t toc_offset;    // BE usually 0x0000002c
		uint32_t toc_size;      // BE
	};
	struct uarp_toc_entry {
		uint32_t this_size;    // BE usually 0x28
		uint32_t fourcc;        // 'PT01' or similar
		uint32_t version[4];    // BE values
		uint32_t unk_18;        // BE other offset, not sure
		uint32_t unk_1c;        // BE usually 0
		uint32_t offset;        // BE
		uint32_t size;          //
	};

	plist_t p_im4m = plist_dict_get_item(tss, "USBPortController1,Ticket");
	uint64_t im4m_size = 0;
	const char* im4m = plist_get_data_ptr(p_im4m, &im4m_size);

	struct uarp_header* uarp_hdr = (struct uarp_header*)uarp_fw;
	uint32_t uarp_hdr_size = be32toh(uarp_hdr->header_size);
	uint32_t plist_offset = be32toh(uarp_hdr->plist_offset);
	uint32_t plist_size = uarp_size - plist_offset;
	nskeyedarchive_t ka = nskeyedarchive_new_from_data(uarp_fw + plist_offset, plist_size);
	if (!ka) {
		return -1;
	}
	plist_t uarp_dict = nskeyedarchive_to_plist(ka);
	nskeyedarchive_free(ka);

	// find the corresponding entries for given BoardID+PREV

	char* payload_4cc = NULL;
	char* data_payload_4ccs = NULL;

	plist_t sb_payloads = plist_dict_get_item(uarp_dict, "SuperBinary Payloads");
	if (PLIST_IS_ARRAY(sb_payloads)) {
		plist_array_iter iter = NULL;
		plist_array_new_iter(sb_payloads, &iter);
		plist_t payload = NULL;
		do {
			plist_array_next_item(sb_payloads, iter, &payload);
			if (!payload) {
				break;
			}
			plist_t meta = plist_dict_get_item(payload, "Payload MetaData");
			if (!PLIST_IS_DICT(meta)) {
				continue;
			}
			plist_t prefix = plist_dict_get_item(meta, "Personalization Manifest Prefix");
			if (!PLIST_IS_STRING(prefix)) {	
				continue;
			}
			if (strcmp(plist_get_string_ptr(prefix, NULL), "USBPortController") != 0) {
				continue;
			}
			plist_t p_boardid = plist_dict_get_item(meta, "Personalization Board ID (64 bits)");
			if (!PLIST_IS_INT(p_boardid)) {
				continue;
			}
			uint64_t boardid = 0;
			plist_get_uint_val(p_boardid, &boardid);
			if (boardid == bdid) {
				logger(LL_DEBUG, "%s: Found Board ID 0x%" PRIx64 "\n", __func__, bdid);
				plist_t p4cc = plist_dict_get_item(payload, "Payload 4CC");
				plist_get_string_val(p4cc, &payload_4cc);
				plist_t matching = plist_dict_get_item(meta, "Personalization Matching Data");
				if (PLIST_IS_ARRAY(matching)) {
					plist_array_iter iter2 = NULL;
					plist_array_new_iter(matching, &iter2);
					plist_t match = NULL;
					do {
						plist_array_next_item(matching, iter2, &match);
						if (!PLIST_IS_DICT(match)) {
							break;
						}
						uint64_t minrev = 0;
						plist_t p_min = plist_dict_get_item(match, "Personalization Matching Data Product Revision Minimum");
						plist_get_uint_val(p_min, &minrev);
						uint64_t maxrev = 0;
						plist_t p_max = plist_dict_get_item(match, "Personalization Matching Data Product Revision Maximum");
						plist_get_uint_val(p_max, &maxrev);
						if (prev >= minrev && prev <= maxrev) {
							plist_t tags = plist_dict_get_item(match, "Personalization Matching Data Payload Tags");
							plist_get_string_val(tags, &data_payload_4ccs);
							logger(LL_DEBUG, "%s: Found matching tags %s\n", __func__, data_payload_4ccs);
							break;
						}
					} while (match);
					plist_mem_free(iter2);
				}
				break;
			}
		} while (payload);
		plist_mem_free(iter);
	}
	if (!payload_4cc) {
		logger(LL_ERROR, "Failed to get payload 4cc\n");
		return -1;
	}
	if (!data_payload_4ccs) {
		logger(LL_ERROR, "Failed to get data payload 4ccs\n");
		return -1;
	}

	// now find the blobs in UARP data
	uint32_t dl_offset = 0;
	uint32_t dl_size = 0;
	uint32_t data1_offset = 0;
	uint32_t data1_size = 0;
	uint32_t data1_version = 0;
	uint32_t data2_offset = 0;
	uint32_t data2_size = 0;
	uint32_t toc_size = be32toh(uarp_hdr->toc_size);
	const unsigned char* p = uarp_fw + uarp_hdr_size;
	while (p < (const unsigned char*)uarp_fw + toc_size) {
		struct uarp_toc_entry* entry = (struct uarp_toc_entry*)p;
		uint32_t te_size = be32toh(entry->this_size);
		if (strncmp((char*)&(entry->fourcc), payload_4cc, 4) == 0) {
			dl_offset = be32toh(entry->offset);
			dl_size = be32toh(entry->size);
		} else if (strncmp((char*)&(entry->fourcc), data_payload_4ccs, 4) == 0) {
			uint32_t version_data[4];
			version_data[0] = be32toh(entry->version[0]);
			version_data[1] = be32toh(entry->version[1]);
			version_data[2] = be32toh(entry->version[2]);
			version_data[3] = be32toh(entry->version[3]);
			data1_offset = be32toh(entry->offset);
			data1_size = be32toh(entry->size);
			uarp_version_convert(version_data, &data1_version);
		} else if (strncmp((char*)&(entry->fourcc), data_payload_4ccs+5, 4) == 0) {
			data2_offset = be32toh(entry->offset);
			data2_size = be32toh(entry->size);
		}
		p += te_size;
	}

	uint32_t content_size = data1_size + data2_size + im4m_size + dl_size;

	*bin_out = malloc(0x40 + content_size);
	struct ace3bin_header* hdr = (struct ace3bin_header*)(*bin_out);
	hdr->magic = htole32(0xACE00003);
	hdr->version = htole32(data1_version);
	hdr->unk8 = htole32(0x00002800);
	hdr->header_size = htole32(0x40);
	hdr->data1_size = htole32(data1_size);
	hdr->data2_size = htole32(data2_size);;
	hdr->im4m_offset = htole32(0x40 + data1_size + data2_size);
	hdr->im4m_dl_size = htole32(im4m_size + dl_size);
	hdr->content_size = htole32(content_size);
	hdr->crc = 0;
	hdr->fill1 = 0xFFFFFFFFFFFFFFFFLL;
	hdr->fill2 = 0xFFFFFFFFFFFFFFFFLL;
	hdr->fill3 = 0xFFFFFFFFFFFFFFFFLL;

	// write data1 payload
	memcpy(*bin_out + 0x40, uarp_fw + data1_offset, data1_size);
	// write data2 payload
	memcpy(*bin_out + 0x40 + data1_size, uarp_fw + data2_offset, data2_size);
	// write IM4M
	memcpy(*bin_out + 0x40 + data1_size + data2_size, im4m, im4m_size);
	// write dl payload
	memcpy(*bin_out + 0x40 + data1_size + data2_size + im4m_size, uarp_fw + dl_offset, dl_size);

	// calculate CRC and update header
	hdr->crc = htole32(crc_buffer(*bin_out + 0x40, content_size, 0xFFFFFFFF));

	*bin_size = 0x40 + content_size;

	return 0;
}
