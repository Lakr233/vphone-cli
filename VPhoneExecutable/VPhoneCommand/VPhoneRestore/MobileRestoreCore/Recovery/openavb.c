/*
 * openavb.c
 * The stage-0 image identity OpenAVB needs before it takes an iBSS over DFU.
 *
 * Not part of upstream idevicerestore. New vphone machines boot OpenAVB
 * (https://github.com/owngoal-dev/OpenAVB) instead of Apple's AVPBooter.
 * OpenAVB carries no description of any iBoot build: it refuses a DFU iBSS
 * unless the host first tells it what that image is -- the size and SHA-256
 * of the IM4P payload, the size and SHA-256 of the decompressed image, its
 * load address and entry exception level. This file builds that description
 * from the personalized iBSS and uploads it with the ROM's vendor requests on
 * the default control pipe:
 *
 *   0x41 0x70  wValue=stage                     open the stage's slot
 *   0x41 0x71  wValue=stage wIndex=chunk  data  append, chunks in order
 *   0x41 0x72  wValue=stage wIndex=rows         seal; writes the magic
 *   0xc0 0x73                             48 B  report {count, received, sealed}
 *
 * The slot holds a 112-byte header (OpenAVB's AVPPatchStageHeader) followed
 * by `rows` {offset, instruction} words. vphone's iBSS is already patched by
 * `fw patch`, so the slot carries the identity and no rows.
 *
 * Apple's ROM stalls the report request, which is how this tells the two
 * apart: the request only reads, and nothing is written to a ROM that does
 * not answer it. The contract is OpenAVB's docs/external-contract.md;
 * vphone's side of it is Research/Firmware/openavb_boot_rom.md.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <compression.h>
#include <CommonCrypto/CommonDigest.h>

#include "openavb.h"
#include "common.h"
#include "vphone_restore_bridge.h"

enum {
	OPENAVB_REQUEST_OPEN = 0x70,
	OPENAVB_REQUEST_APPEND = 0x71,
	OPENAVB_REQUEST_SEAL = 0x72,
	OPENAVB_REQUEST_REPORT = 0x73,
	OPENAVB_STAGE_IBSS = 0,
	OPENAVB_STAGE_COUNT = 4,
	OPENAVB_REPORT_SIZE = OPENAVB_STAGE_COUNT * 12,
	OPENAVB_MAGIC = 0x48435450, /* 'PTCH' */
	OPENAVB_VERSION = 1,
	OPENAVB_FLAG_IDENTITY = 1,
	OPENAVB_PROBE_TIMEOUT_MS = 1000,
	OPENAVB_TIMEOUT_MS = 5000,
	/* iBoot's start loads its link address with `ldr x1, =base`, the third
	 * instruction; the literal sat at 0x300 up to iOS 26 and at 0x380 from 27
	 * on, where 0x300 holds the version string. 0x300 is the fallback. */
	IBOOT_LINK_BASE_LOAD = 0x8,
	IBOOT_LINK_BASE_OFFSET = 0x300,
	/* An iBSS runs at EL2 where the CPU offers it; the ROM keeps EL1 on its
	 * own when it was entered at EL1, as it is under Virtualization.framework. */
	IBOOT_ENTRY_EXCEPTION_LEVEL = 2,
	/* Far beyond any iBoot; only bounds the decode buffer. */
	IBOOT_MAX_RAW_SIZE = 64 << 20,
};

_Static_assert(VPHONE_OPENAVB_IDENTITY_SIZE == 112, "AVPPatchStageHeader is 112 bytes");

/* --- DER ----------------------------------------------------------------- */

/* One element at `*at`, ending no later than `end`: its tag and body.
 * Advances `*at` past it. */
static int der_next(const uint8_t *data, size_t end, size_t *at, uint8_t *tag, size_t *body, size_t *body_end)
{
	size_t i = *at;
	if (i > end || end - i < 2) {
		return -1;
	}
	*tag = data[i];
	size_t length = data[i + 1];
	i += 2;
	if (length & 0x80) {
		size_t count = length & 0x7f;
		if (count == 0 || count > 4 || end - i < count) {
			return -1;
		}
		length = 0;
		for (size_t k = 0; k < count; k++) {
			length = (length << 8) | data[i + k];
		}
		i += count;
	}
	if (length > end - i) {
		return -1;
	}
	*body = i;
	*body_end = i + length;
	*at = *body_end;
	return 0;
}

static int der_is_string(const uint8_t *data, size_t body, size_t body_end, const char *text)
{
	size_t length = strlen(text);
	return body_end - body == length && memcmp(data + body, text, length) == 0;
}

/*
 * The payload of the IM4P in `data`, which is an IM4P or an IMG4 wrapping
 * one: SEQUENCE { "IMG4", IM4P, [0] IM4M } and SEQUENCE { "IM4P", type,
 * description, payload, ... }. The payload is the first OCTET STRING after
 * the "IM4P" marker. This is what OpenAVB measures as the compressed image.
 */
static int im4p_payload(const uint8_t *data, size_t size, const uint8_t **payload, size_t *payload_size)
{
	size_t at = 0, body, body_end;
	uint8_t tag;
	if (der_next(data, size, &at, &tag, &body, &body_end) < 0 || tag != 0x30) {
		return -1;
	}
	const size_t end = body_end;
	at = body;
	if (der_next(data, end, &at, &tag, &body, &body_end) < 0 || tag != 0x16) {
		return -1;
	}
	if (der_is_string(data, body, body_end, "IMG4")) {
		const size_t inner = at;
		if (der_next(data, end, &at, &tag, &body, &body_end) < 0 || tag != 0x30) {
			return -1;
		}
		return im4p_payload(data + inner, body_end - inner, payload, payload_size);
	}
	if (!der_is_string(data, body, body_end, "IM4P")) {
		return -1;
	}
	while (at < end) {
		if (der_next(data, end, &at, &tag, &body, &body_end) < 0) {
			return -1;
		}
		if (tag == 0x04) {
			*payload = data + body;
			*payload_size = body_end - body;
			return 0;
		}
	}
	return -1;
}

/* --- Identity ------------------------------------------------------------ */

static void put_u32(uint8_t *at, uint32_t value)
{
	for (int i = 0; i < 4; i++) {
		at[i] = (uint8_t)(value >> (8 * i));
	}
}

static void put_u64(uint8_t *at, uint64_t value)
{
	for (int i = 0; i < 8; i++) {
		at[i] = (uint8_t)(value >> (8 * i));
	}
}

static uint32_t get_u32(const uint8_t *at)
{
	return (uint32_t)at[0] | (uint32_t)at[1] << 8 | (uint32_t)at[2] << 16 | (uint32_t)at[3] << 24;
}

static uint64_t get_u64(const uint8_t *at)
{
	uint64_t value = 0;
	for (int i = 7; i >= 0; i--) {
		value = (value << 8) | at[i];
	}
	return value;
}

/*
 * The whole LZFSE stream decoded. An LZFSE stream is a chain of blocks, each
 * naming only its own size, so the output size is not known up front: the
 * buffer doubles until the decoder returns less than it was offered.
 */
static uint8_t *lzfse_decode(const uint8_t *payload, size_t size, size_t *decoded)
{
	size_t capacity = size * 4 > (1u << 20) ? size * 4 : (1u << 20);
	while (capacity <= IBOOT_MAX_RAW_SIZE) {
		uint8_t *buffer = malloc(capacity);
		if (buffer == NULL) {
			return NULL;
		}
		size_t got = compression_decode_buffer(buffer, capacity, payload, size, NULL, COMPRESSION_LZFSE);
		if (got == 0) {
			free(buffer);
			return NULL;
		}
		if (got < capacity) {
			*decoded = got;
			return buffer;
		}
		free(buffer);
		capacity *= 2;
	}
	return NULL;
}

/* Where iBoot keeps its link address: the literal its start code loads, or
 * IBOOT_LINK_BASE_OFFSET for an image that does not start that way. */
static size_t iboot_link_base_offset(const uint8_t *raw, size_t size)
{
	const uint32_t insn = get_u32(raw + IBOOT_LINK_BASE_LOAD);
	/* LDR (literal), 64-bit: 0x58000000 | imm19 << 5 | Rt. */
	if ((insn & 0xff000000) == 0x58000000 && (insn & 0x00800000) == 0) {
		const size_t literal = IBOOT_LINK_BASE_LOAD + (size_t)((insn >> 5) & 0x7ffff) * 4;
		if (literal + 8 <= size) {
			return literal;
		}
	}
	return IBOOT_LINK_BASE_OFFSET;
}

int vphone_restore_openavb_ibss_identity(const void *image, size_t size, uint8_t header[VPHONE_OPENAVB_IDENTITY_SIZE], const char **reason)
{
	const char *ignored;
	if (reason == NULL) {
		reason = &ignored;
	}
	const uint8_t *payload = NULL;
	size_t payload_size = 0;
	if (image == NULL || header == NULL || im4p_payload(image, size, &payload, &payload_size) < 0) {
		*reason = "the iBSS is not an IMG4 or IM4P container";
		return -1;
	}
	if (payload_size < 4 || memcmp(payload, "bvx2", 4) != 0) {
		/* OpenAVB decodes LZFSE only; `fw patch` writes iBSS back that way. */
		*reason = "the iBSS payload is not LZFSE-compressed; run fw patch with this bundle again";
		return -1;
	}
	if (payload_size > UINT32_MAX) {
		*reason = "the iBSS payload is too large";
		return -1;
	}
	size_t raw_size = 0;
	uint8_t *raw = lzfse_decode(payload, payload_size, &raw_size);
	if (raw == NULL) {
		*reason = "the iBSS payload does not decode as LZFSE";
		return -1;
	}
	if (raw_size < IBOOT_LINK_BASE_OFFSET + 8) {
		free(raw);
		*reason = "the decoded iBSS is too small to be iBoot";
		return -1;
	}
	const uint64_t load_base = get_u64(raw + iboot_link_base_offset(raw, raw_size));
	if (load_base == 0 || (load_base & 0x3fff) != 0) {
		free(raw);
		*reason = "the decoded iBSS names no page-aligned link address";
		return -1;
	}

	memset(header, 0, VPHONE_OPENAVB_IDENTITY_SIZE);
	put_u32(header + 0x00, OPENAVB_MAGIC);
	put_u32(header + 0x04, OPENAVB_VERSION);
	put_u32(header + 0x08, 0);                    /* rows */
	put_u32(header + 0x0c, OPENAVB_FLAG_IDENTITY);
	/* 0x10 received, 0x14 next_chunk: the ROM keeps those. */
	put_u32(header + 0x18, (uint32_t)payload_size);
	put_u32(header + 0x1c, (uint32_t)raw_size);
	put_u64(header + 0x20, load_base);
	put_u32(header + 0x28, IBOOT_ENTRY_EXCEPTION_LEVEL);
	CC_SHA256(payload, (CC_LONG)payload_size, header + 0x30);
	CC_SHA256(raw, (CC_LONG)raw_size, header + 0x50);
	free(raw);
	*reason = NULL;
	return 0;
}

/* --- Upload -------------------------------------------------------------- */

/* One of the three words the report gives for a stage: count, received, sealed. */
static uint32_t report_word(const unsigned char *report, int stage, int field)
{
	return get_u32(report + stage * 12 + field * 4);
}

int openavb_describe_ibss(irecv_client_t client, const void *image, size_t size)
{
	unsigned char report[OPENAVB_REPORT_SIZE];
	int got = irecv_usb_control_transfer(client, 0xc0, OPENAVB_REQUEST_REPORT, 0, 0,
		report, sizeof(report), OPENAVB_PROBE_TIMEOUT_MS);
	if (got != (int)sizeof(report)) {
		logger(LL_DEBUG, "The boot ROM does not answer OpenAVB's patch-store report (%d); sending iBSS as is.\n", got);
		return 0;
	}

	uint8_t header[VPHONE_OPENAVB_IDENTITY_SIZE];
	const char *reason = NULL;
	if (vphone_restore_openavb_ibss_identity(image, size, header, &reason) < 0) {
		logger(LL_ERROR, "OpenAVB needs the iBSS identity, but %s.\n", reason);
		return -1;
	}
	logger(LL_INFO, "Describing iBSS to OpenAVB (payload %u bytes, image %u bytes at 0x%llx)...\n",
		get_u32(header + 0x18), get_u32(header + 0x1c), (unsigned long long)get_u64(header + 0x20));

	if (irecv_usb_control_transfer(client, 0x41, OPENAVB_REQUEST_OPEN, OPENAVB_STAGE_IBSS, 0,
			NULL, 0, OPENAVB_TIMEOUT_MS) < 0
		|| irecv_usb_control_transfer(client, 0x41, OPENAVB_REQUEST_APPEND, OPENAVB_STAGE_IBSS, 0,
			header, sizeof(header), OPENAVB_TIMEOUT_MS) != (int)sizeof(header)
		|| irecv_usb_control_transfer(client, 0x41, OPENAVB_REQUEST_SEAL, OPENAVB_STAGE_IBSS, 0,
			NULL, 0, OPENAVB_TIMEOUT_MS) < 0) {
		logger(LL_ERROR, "OpenAVB refused the iBSS identity.\n");
		return -1;
	}

	got = irecv_usb_control_transfer(client, 0xc0, OPENAVB_REQUEST_REPORT, 0, 0,
		report, sizeof(report), OPENAVB_TIMEOUT_MS);
	if (got != (int)sizeof(report)
		|| report_word(report, OPENAVB_STAGE_IBSS, 0) != 0
		|| report_word(report, OPENAVB_STAGE_IBSS, 1) != sizeof(header)
		|| report_word(report, OPENAVB_STAGE_IBSS, 2) != 1) {
		logger(LL_ERROR, "OpenAVB did not seal the iBSS identity.\n");
		return -1;
	}
	return 0;
}
