/*
 * mbn.c
 * support for Qualcomm MBN (Modem Binary) formats
 *
 * Copyright (c) 2012 Martin Szulecki. All Rights Reserved.
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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mbn.h"
#include "common.h"

#define MBN_V1_MAGIC "\x0A\x00\x00\x00"
#define MBN_V1_MAGIC_SIZE 4

#pragma pack(push, 1)
typedef struct {
	uint32_t type;           // the signed .mbn files have 0xA as value.
	uint32_t unk_0x04;
	uint32_t unk_0x08;
	uint32_t unk_0x0c;
	uint32_t data_size;       // data_size = total_size - sizeof(mbn_header)
	uint32_t sig_offset; // real offset = enc_sig_offset & 0xFFFFFF00
	uint32_t unk_0x18;
	uint32_t unk_0x1c;
	uint32_t unk_0x20;
	uint32_t unk_0x24;
} mbn_header_v1;

#define MBN_V2_MAGIC "\xD1\xDC\x4B\x84\x34\x10\xD7\x73"
#define MBN_V2_MAGIC_SIZE 8

typedef struct {
	unsigned char magic1[8];
	uint32_t unk_0x08;
	uint32_t unk_0x0c; // 0xFFFFFFFF
	uint32_t unk_0x10; // 0xFFFFFFFF
	uint32_t header_size;
	uint32_t unk_0x18;
	uint32_t data_size;  // data_size = total_size - sizeof(mbn_header_v2)
	uint32_t sig_offset;
	uint32_t unk_0x24;
	uint32_t unk_0x28;
	uint32_t unk_0x2c;
	uint32_t unk_0x30;
	uint32_t unk_0x34; // 0x1
	uint32_t unk_0x38; // 0x1
	uint32_t unk_0x3c; // 0xFFFFFFFF
	uint32_t unk_0x40; // 0xFFFFFFFF
	uint32_t unk_0x44; // 0xFFFFFFFF
	uint32_t unk_0x48; // 0xFFFFFFFF
	uint32_t unk_0x4c; // 0xFFFFFFFF
} mbn_header_v2;

#define MBN_BIN_MAGIC "\x04\x00\xEA\x6C\x69\x48\x55"
#define MBN_BIN_MAGIC_SIZE 7
#define MBN_BIN_MAGIC_OFFSET 1 // we ignore the first byte

typedef struct {
	unsigned char magic[8];
	uint32_t unk_0x08;
	uint32_t version;
	uint32_t total_size; // size including header
	uint32_t unk_0x14; // some offset
} mbn_bin_header;

typedef struct
{
	uint32_t reserved;
	uint32_t version;
	uint32_t common_metadata_size;
	uint32_t qti_metadata_size;
	uint32_t oem_metadata_size;
	uint32_t hash_table_size;
	uint32_t qti_signature_size;
	uint32_t qti_certificate_chain_size;
	uint32_t oem_signature_size;
	uint32_t oem_certificate_chain_size;
} mbn_v7_header;

#define EI_MAG0 0
#define EI_MAG1 1
#define EI_MAG2 2
#define EI_MAG3 3
#define EI_CLASS 4
#define EI_DATA 5
#define EI_VERSION 6
#define EI_OSABI 7
#define EI_ABIVERSION 8
#define EI_PAD 9
#define EI_NIDENT 16

#define ELFMAG0 0x7F
#define ELFMAG1 'E'
#define ELFMAG2 'L'
#define ELFMAG3 'F'
#define ELFCLASSNONE 0
#define ELFCLASS32 1
#define ELFCLASS64 2

typedef struct
{
	uint8_t e_ident[EI_NIDENT];
	uint16_t e_type;
	uint16_t e_machine;
	uint32_t e_version;
	uint32_t e_entry;
	uint32_t e_phoff;
	uint32_t e_shoff;
	uint32_t e_flags;
	uint16_t e_ehsize;
	uint16_t e_phentsize;
	uint16_t e_phnum;
	uint16_t e_shentsize;
	uint16_t e_shnum;
	uint16_t e_shstrndx;
} elf32_header;

typedef struct
{
	uint8_t e_ident[EI_NIDENT];
	uint16_t e_type;
	uint16_t e_machine;
	uint32_t e_version;
	uint64_t e_entry;
	uint64_t e_phoff;
	uint64_t e_shoff;
	uint32_t e_flags;
	uint16_t e_ehsize;
	uint16_t e_phentsize;
	uint16_t e_phnum;
	uint16_t e_shentsize;
	uint16_t e_shnum;
	uint16_t e_shstrndx;
} elf64_header;

typedef struct
{
	uint32_t p_type;
	uint32_t p_offset;
	uint32_t p_vaddr;
	uint32_t p_paddr;
	uint32_t p_filesz;
	uint32_t p_memsz;
	uint32_t p_flags;
	uint32_t p_align;
} elf32_pheader;

typedef struct
{
	uint32_t p_type;
	uint32_t p_flags;
	uint64_t p_offset;
	uint64_t p_vaddr;
	uint64_t p_paddr;
	uint64_t p_filesz;
	uint64_t p_memsz;
	uint64_t p_align;
} elf64_pheader;
#pragma pack(pop)

static int mbn_is_valid_elf(const uint8_t* e_ident, size_t size)
{
	return size >= EI_NIDENT && e_ident[EI_MAG0] == ELFMAG0 &&
	       e_ident[EI_MAG1] == ELFMAG1 && e_ident[EI_MAG2] == ELFMAG2 &&
	       e_ident[EI_MAG3] == ELFMAG3 && e_ident[EI_CLASS] != ELFCLASSNONE;
}

static int mbn_is_64bit_elf(const uint8_t* e_ident)
{
	return e_ident[EI_CLASS] == ELFCLASS64;
}

void* mbn_stitch(const void* data, size_t data_size, const void* blob, size_t blob_size)
{
	if (!data) {
		logger(LL_ERROR, "%s: data is NULL\n", __func__);
		return NULL;
	}

	if (!data_size) {
		logger(LL_ERROR, "%s: data size is 0\n", __func__);
		return NULL;
	}

	if (!blob) {
		logger(LL_ERROR, "%s: blob is NULL\n", __func__);
		return NULL;
	}

	if (!blob_size) {
		logger(LL_ERROR, "%s: blob size is 0\n", __func__);
		return NULL;
	}

	size_t parsed_size = 0;
	if (data_size > MBN_V2_MAGIC_SIZE && memcmp(data, MBN_V2_MAGIC, MBN_V2_MAGIC_SIZE) == 0) {
		parsed_size = ((mbn_header_v2*)data)->data_size + sizeof(mbn_header_v2);
		logger(LL_DEBUG, "%s: encountered MBN v2 image, parsed_size = 0x%zx\n", __func__, parsed_size);
	} else if (data_size > MBN_V1_MAGIC_SIZE && memcmp(data, MBN_V1_MAGIC, MBN_V1_MAGIC_SIZE) == 0) {
		parsed_size = ((mbn_header_v1*)data)->data_size + sizeof(mbn_header_v1);
		logger(LL_DEBUG, "%s: encountered MBN v1 image, parsed_size = 0x%zx\n", __func__, parsed_size);
	} else if (data_size > MBN_BIN_MAGIC_SIZE+MBN_BIN_MAGIC_OFFSET && memcmp((uint8_t*)data+MBN_BIN_MAGIC_OFFSET, (uint8_t*)MBN_BIN_MAGIC, MBN_BIN_MAGIC_SIZE) == 0) {
		parsed_size = ((mbn_bin_header*)data)->total_size;
		logger(LL_DEBUG, "%s: encountered MBN BIN image, parsed_size = 0x%zx\n", __func__, parsed_size);
	} else if (mbn_is_valid_elf(data, data_size)) {
		if (mbn_is_64bit_elf(data)) {
			const elf64_header* ehdr = data;
			const elf64_pheader* phdr = data + ehdr->e_phoff;
			if (ehdr->e_phnum == 0) {
				logger(LL_ERROR, "%s: ELF has no program sections\n", __func__);
				return NULL;
			}
			uint64_t last_off = 0;
			uint16_t last_index = 0;
			for (uint16_t i = 0; i < ehdr->e_phnum; i++) {
				if (phdr[i].p_offset > last_off) {
					last_off = phdr[i].p_offset;
					last_index = i;
				}
			}
			parsed_size = last_off + phdr[last_index].p_filesz;
		} else {
			const elf32_header* ehdr = data;
			const elf32_pheader* phdr = data + ehdr->e_phoff;
			if (ehdr->e_phnum == 0) {
				logger(LL_ERROR, "%s: ELF has no program sections\n", __func__);
				return NULL;
			}
			uint32_t last_off = 0;
			uint16_t last_index = 0;
			for (uint16_t i = 0; i < ehdr->e_phnum; i++) {
				if (phdr[i].p_offset > last_off) {
					last_off = phdr[i].p_offset;
					last_index = i;
				}
			}
			parsed_size = last_off + phdr[last_index].p_filesz;
		}
		logger(LL_DEBUG, "%s: encountered ELF image, parsed_size = 0x%zx\n", __func__, parsed_size);
	} else {
		logger(LL_WARNING, "Unknown file format passed to %s\n", __func__);
	}
	if (parsed_size != data_size) {
		logger(LL_WARNING, "%s: size mismatch for MBN data, expected 0x%zx, input size 0x%zx\n", __func__, parsed_size, data_size);
	}

	off_t stitch_offset = data_size - blob_size;
	if (stitch_offset + blob_size > data_size) {
		logger(LL_ERROR, "%s: stitch offset (0x%lx) + size (0x%zx) is larger than the destination (0x%zx)\n", __func__, (unsigned long)stitch_offset, blob_size, data_size);
		return NULL;
	}

	unsigned char* buf = malloc(data_size);
	if (buf == NULL)	{
		logger(LL_ERROR, "out of memory\n");
		return NULL;
	}

	memcpy(buf, data, data_size);
	logger(LL_DEBUG, "%s: stitching mbn at 0x%llx, size 0x%zx\n", __func__, stitch_offset, blob_size);
	memcpy(buf + stitch_offset, blob, blob_size);

	return buf;
}

// the sum of header size and all sizes inside it must fit within the size of
// the data
static int mbn_v7_header_sizes_valid(const mbn_v7_header* header, size_t size)
{
	return (sizeof(*header) + header->common_metadata_size +
	       header->qti_metadata_size + header->oem_metadata_size +
	       header->hash_table_size + header->qti_signature_size +
	       header->qti_certificate_chain_size + header->oem_signature_size +
	       header->oem_certificate_chain_size) <= size;
}

// 0xE0 == sizeof(mav25_authority_meta_field_t), 0x68 ==
// kExpectedOEMSignatureSize, 0xD20 == kExpectedOEMCertChainSize
static int mbn_v7_header_sizes_expected(const mbn_v7_header* header)
{
	return (header->qti_metadata_size == 0 || header->qti_metadata_size == 0xE0) &&
	       (header->oem_metadata_size == 0 || header->oem_metadata_size == 0xE0) &&
	       (header->oem_signature_size == 0 || header->oem_signature_size == 0x68) &&
	       (header->oem_certificate_chain_size == 0 || header->oem_certificate_chain_size == 0xD20);
}

static void mbn_v7_log_header(const mbn_v7_header* header, const char* func, const char* prefix)
{
	logger(LL_DEBUG,
		"%s: %s header {version=0x%x, common_metadata_size=0x%x, "
		"qti_metadata_size=0x%x, oem_metadata_size=0x%x, hash_table_size=0x%x, "
		"qti_signature_size=0x%x, qti_certificate_chain_size=0x%x, "
		"oem_signature_size=0x%x, oem_certificate_chain_size=0x%x}\n",
		func,
		prefix,
		header->version,
		header->common_metadata_size,
		header->qti_metadata_size,
		header->oem_metadata_size,
		header->hash_table_size,
		header->qti_signature_size,
		header->qti_certificate_chain_size,
		header->oem_signature_size,
		header->oem_certificate_chain_size
	);
}

void* mbn_mav25_stitch(const void* data, size_t data_size, const void* blob, size_t blob_size)
{
	if (!data) {
		logger(LL_ERROR, "%s: data is NULL\n", __func__);
		return NULL;
	}

	if (!data_size) {
		logger(LL_ERROR, "%s: data size is 0\n", __func__);
		return NULL;
	}

	if (!blob) {
		logger(LL_ERROR, "%s: blob is NULL\n", __func__);
		return NULL;
	}

	if (!blob_size) {
		logger(LL_ERROR, "%s: blob size is 0\n", __func__);
		return NULL;
	}

	if (!mbn_is_valid_elf(data, data_size)) {
		logger(LL_ERROR, "%s: data is not a valid ELF\n", __func__);
		return NULL;
	}

	if (sizeof(mbn_v7_header) > blob_size) {
		logger(LL_ERROR, "%s: header is bigger than blob\n", __func__);
		return NULL;
	}

	const mbn_v7_header* src_header = blob;
	mbn_v7_log_header(src_header, __func__, "src");

	if (src_header->version != 7) {
		logger(LL_ERROR, "%s: src header version (0x%x) is incorrect\n", __func__, src_header->version);
		return NULL;
	}

	// NOTE: Apple does weird stuff, in this case blob is smaller than
	// the sizes the header reports, so we can't check their validity.
	if (!mbn_v7_header_sizes_expected(src_header)) {
		logger(LL_WARNING, "%s: header sizes in header are unexpected (qti_metadata_size=0x%x, oem_metadata_size=0x%x, oem_signature_size=0x%x, oem_certificate_chain_size=0x%x)\n", __func__, src_header->qti_metadata_size, src_header->oem_metadata_size, src_header->oem_signature_size, src_header->oem_certificate_chain_size);
	}

	off_t sect_off;
	size_t sect_size;
	if (mbn_is_64bit_elf(data)) {
		const elf64_header* ehdr = data;
		const elf64_pheader* phdr = data + ehdr->e_phoff;
		if (ehdr->e_phnum == 0) {
			logger(LL_ERROR, "%s: ELF has no program sections\n", __func__);
			return NULL;
		}
		if ((ehdr->e_phoff + ehdr->e_phnum * sizeof(elf32_pheader)) > data_size) {
			logger(LL_ERROR, "%s: Last ELF program section is out of bounds\n", __func__);
			return NULL;
		}
		sect_off = phdr[ehdr->e_phnum-1].p_offset;
		sect_size = phdr[ehdr->e_phnum-1].p_filesz;
	} else {
		const elf32_header* ehdr = data;
		const elf32_pheader* phdr = data + ehdr->e_phoff;
		if (ehdr->e_phnum == 0) {
			logger(LL_ERROR, "%s: ELF has no program sections\n", __func__);
			return NULL;
		}
		if ((ehdr->e_phoff + ehdr->e_phnum * sizeof(elf64_pheader)) > data_size) {
			logger(LL_ERROR, "%s: Last ELF program section is out of bounds\n", __func__);
			return NULL;
		}
		sect_off = phdr[ehdr->e_phnum-1].p_offset;
		sect_size = phdr[ehdr->e_phnum-1].p_filesz;
	}

	if (sect_off == 0) {
		logger(LL_ERROR, "%s: section has 0 offset\n", __func__);
		return NULL;
	}

	if (sect_size == 0) {
		logger(LL_ERROR, "%s: section has 0 size\n", __func__);
		return NULL;
	}

	if (sect_off + sect_size > data_size) {
		logger(LL_ERROR, "%s: section (0x%lx+0x%zx) is bigger than the data\n", __func__, (unsigned long)sect_off, sect_size);
		return NULL;
	}

	if (sizeof(mbn_v7_header) > sect_size) {
		logger(LL_ERROR, "%s: dest header is bigger than the section (0x%zx)\n", __func__, sect_size);
		return NULL;
	}

	const mbn_v7_header* header = data + sect_off;
	mbn_v7_log_header(header, __func__, "dest");
	if (header->version != 7) {
		logger(LL_ERROR, "%s: dest header version (0x%x) is incorrect\n", __func__, header->version);
		return NULL;
	}

	if (!mbn_v7_header_sizes_valid(header, sect_size)) {
		logger(LL_ERROR, "%s: sizes in dest header are invalid (common_metadata_size=0x%x, qti_metadata_size=0x%x, oem_metadata_size=0x%x, hash_table_size=0x%x, qti_signature_size=0x%x, qti_certificate_chain_size=0x%x, oem_signature_size=0x%x, oem_certificate_chain_size=0x%x)\n", __func__, header->common_metadata_size, header->qti_metadata_size, header->oem_metadata_size, header->hash_table_size, header->qti_signature_size, header->qti_certificate_chain_size, header->oem_signature_size, header->oem_certificate_chain_size);
		return NULL;
	}

	if (!mbn_v7_header_sizes_expected(header)) {
		logger(LL_WARNING, "%s: header sizes in dest header are unexpected (qti_metadata_size=0x%x, oem_metadata_size=0x%x, oem_signature_size=0x%x, oem_certificate_chain_size=0x%x)\n", __func__, header->qti_metadata_size, header->oem_metadata_size, header->oem_signature_size, header->oem_certificate_chain_size);
	}

	size_t new_metadata_size =
		sizeof(*src_header) + src_header->common_metadata_size +
		src_header->qti_metadata_size + src_header->oem_metadata_size;
	size_t new_metadata_and_hash_table_size =
		new_metadata_size + src_header->hash_table_size;
	size_t new_oem_sig_and_cert_chain_size =
		src_header->oem_signature_size + src_header->oem_certificate_chain_size;
	off_t new_oem_sig_and_cert_chain_off = new_metadata_and_hash_table_size +
		header->qti_signature_size + header->qti_certificate_chain_size;

	if (new_metadata_and_hash_table_size > blob_size) {
		logger(LL_ERROR, "%s: new metadata (0x%zx) and hash table (0x%x) are bigger than the source (0x%zx)\n", __func__, new_metadata_size, src_header->hash_table_size, blob_size);
		return NULL;
	}

	if (new_metadata_and_hash_table_size > sect_size) {
		logger(LL_ERROR, "%s: new metadata (0x%zx) and hash table (0x%x) are bigger than the destination (0x%zx)\n", __func__, new_metadata_size, src_header->hash_table_size, sect_size);
		return NULL;
	}

	if (new_metadata_and_hash_table_size + new_oem_sig_and_cert_chain_size > blob_size) {
		logger(LL_ERROR, "%s: new OEM signature and certificate chain are bigger than the source\n", __func__);
		return NULL;
	}

	if (new_oem_sig_and_cert_chain_off + new_oem_sig_and_cert_chain_size > sect_size) {
		logger(LL_ERROR, "%s: new OEM signature and certificate chain are outside the bounds of the destination\n", __func__);
		return NULL;
	}

	unsigned char* buf = malloc(data_size);
	if (buf == NULL)	{
		logger(LL_ERROR, "out of memory\n");
		return NULL;
	}

	memcpy(buf, data, data_size);
	logger(LL_DEBUG, "%s: stitching mbn at 0x%lx (0x%zx bytes)\n", __func__, (unsigned long)sect_off, new_metadata_and_hash_table_size);
	memcpy(buf + sect_off, blob, new_metadata_and_hash_table_size);
	logger(LL_DEBUG, "%s: stitching mbn at 0x%lx (0x%zx bytes)\n", __func__, (unsigned long)(sect_off + new_oem_sig_and_cert_chain_off), new_oem_sig_and_cert_chain_size);
	memcpy(buf + sect_off + new_oem_sig_and_cert_chain_off, blob + new_metadata_and_hash_table_size, new_oem_sig_and_cert_chain_size);

	return buf;
}
