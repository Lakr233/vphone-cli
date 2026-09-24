/*
 * img4.c
 * Functions for handling the IMG4 format
 *
 * Copyright (c) 2013-2019 Nikias Bassen. All Rights Reserved.
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

#include <stdlib.h>
#include <string.h>

#include <libtatsu/tss.h>

#include "common.h"
#include "img4.h"
#include "endianness.h"

#define ASN1_PRIVATE 0xc0
#define ASN1_PRIMITIVE_TAG 0x1f
#define ASN1_CONSTRUCTED 0x20
#define ASN1_SEQUENCE 0x10
#define ASN1_SET 0x11
#define ASN1_CONTEXT_SPECIFIC 0x80
#define ASN1_IA5_STRING 0x16
#define ASN1_OCTET_STRING 0x04
#define ASN1_INTEGER 0x02
#define ASN1_BOOLEAN 0x01

#define IMG4_MAGIC "IMG4"
#define IMG4_MAGIC_SIZE 4

static int asn1_calc_int_size(uint64_t value)
{
	int i = 1;
	while ((value >>= 7) != 0) i++;
	return i;
}

static void asn1_write_int_value(unsigned char **p, uint64_t value, int size)
{
	int value_size = (size > 0) ? size : asn1_calc_int_size(value);
	int i = 0;
	for (i = 1; i <= value_size; i++) {
		(*p)[value_size-i] = value & 0xFF;
		value >>= 8;
	}
	*p += value_size;
}

static void asn1_write_size(unsigned int size, unsigned char** data, unsigned int *data_size)
{
	unsigned int off = 0;

	// first, calculate the size
	if (size >= 0x1000000) {
		// 1+4 bytes length
		(*data)[off++] = 0x84;
		(*data)[off++] = (size >> 24) & 0xFF;
		(*data)[off++] = (size >> 16) & 0xFF;
		(*data)[off++] = (size >> 8) & 0xFF;
		(*data)[off++] = size & 0xFF;
	} else if (size >= 0x10000) {
		// 1+3 bytes length
		(*data)[off++] = 0x83;
		(*data)[off++] = (size >> 16) & 0xFF;
		(*data)[off++] = (size >> 8) & 0xFF;
		(*data)[off++] = size & 0xFF;
	} else if (size >= 0x100) {
		// 1+2 bytes length
		(*data)[off++] = 0x82;
		(*data)[off++] = (size >> 8) & 0xFF;
		(*data)[off++] = (size & 0xFF);
	} else if (size >= 0x80) {
		// 1+1 byte length
		(*data)[off++] = 0x81;
		(*data)[off++] = (size & 0xFF);
	} else {
		// 1 byte length
		(*data)[off++] = size & 0xFF;
	}

	*data += off;
	*data_size += off;
}

static void asn1_write_element_header(unsigned char type, unsigned int size, unsigned char** data, unsigned int *data_size)
{
	unsigned int off = 0;

	if (!type || size == 0 || !data || !data_size) {
		return;
	}

	(*data)[off++] = type;
	*data += off;

	asn1_write_size(size, data, &off);

	*data_size += off;
}

static unsigned char* asn1_create_element_header(unsigned char type, unsigned int size, unsigned char** data, unsigned int *data_size)
{
	unsigned char buf[6];
	unsigned int off = 0;

	if (!type || size == 0 || !data || !data_size) {
		return NULL;
	}

	buf[off++] = type;

	unsigned char* p = &buf[off];
	asn1_write_size(size, &p, &off);

	*data = malloc(off);
	memcpy(*data, buf, off);
	*data_size = off;

	return *data;
}

static void asn1_write_priv_element(unsigned char **p, unsigned int *length, unsigned int value)
{
	int i = 0;
	int ttag = 0;
	int tag = value;

	i = ASN1_CONSTRUCTED;
	i |= (0xFF & ASN1_PRIVATE);

	(*p)[0] = i | ASN1_PRIMITIVE_TAG;
	*p += 1;
	*length += 1;

	for (i = 0, ttag = tag; ttag > 0; i++)
            ttag >>= 7;
        ttag = i;
        while (i-- > 0) {
            (*p)[i] = tag & 0x7f;
            if (i != (ttag - 1))
                (*p)[i] |= 0x80;
            tag >>= 7;
        }
        *p += ttag;
	*length += ttag;
}

static void asn1_write_element(unsigned char **p, unsigned int *length, unsigned char type, void *data, int data_len)
{
	unsigned int this_len = 0;
	switch (type) {
	case ASN1_IA5_STRING: {
		char *str = (char*)data;
		size_t len = (data_len < 0) ? strlen(str) : data_len;
		asn1_write_element_header(type, len, p, &this_len);
		*length += this_len;
		memcpy(*p, str, len);
		*p += len;
		*length += len;
	}	break;
	case ASN1_OCTET_STRING: {
		asn1_write_element_header(type, data_len, p, &this_len);
		*length += this_len;
		memcpy(*p, data, data_len);
		*p += data_len;
		*length += data_len;
	}	break;
	case ASN1_INTEGER: {
		uint64_t value = *(uint64_t*)data;
		int value_size = asn1_calc_int_size(value);
		asn1_write_element_header(type, value_size, p, &this_len);
		*length += this_len;
		asn1_write_int_value(p, value, value_size);
		*length += value_size;
	}	break;
	case ASN1_BOOLEAN: {
		unsigned int value = *(unsigned int*)data;
		asn1_write_element_header(type, 1, p, &this_len);
		*length += this_len;
		asn1_write_int_value(p, value ? 0xFF : 0x00, 1);
		*length += 1;
	}	break;
	case (ASN1_SET | ASN1_CONSTRUCTED): {
		asn1_write_element_header(type, data_len, p, &this_len);
		*length += this_len;
		if (data && data_len > 0) {
			memcpy(*p, data, data_len);
			*p += data_len;
			*length += data_len;
		}
	}	break;
	default:
		logger(LL_ERROR, "%s: type %02x is not implemented\n", __func__, type);
		return;
	}
}

static unsigned int asn1_get_element(const unsigned char* data, unsigned char* type, unsigned char* size)
{
	unsigned int off = 0;

	if (!data)
		return 0;

	if (type)
		*type = data[off++];
	if (size)
		*size = data[off++];

	return off;
}

static const unsigned char *asn1_find_element(unsigned int index, unsigned char type, const unsigned char* data)
{
	unsigned char el_type = 0;
	unsigned char el_size = 0;
	unsigned int off = 0;
	int i;

	// verify data integrity
	if (data[off++] != (ASN1_CONSTRUCTED | ASN1_SEQUENCE))
		return NULL;

	// check data size
	switch (data[off++]) {
	case 0x84:
		off += 4;
		break;
	case 0x83:
		off += 3;
		break;
	case 0x82:
		off += 2;
		break;
	case 0x81:
		off += 1;
		break;
	default:
		break;
	}

	// find the element we are searching
	for (i = 0; i <= index; i++) {
		off += asn1_get_element(&data[off], &el_type, &el_size);
		if (i == index)
			break;
		off += el_size;
	}

	// check element type
	if (el_type != type)
		return NULL;

	return &data[off];
}

static const char *_img4_get_component_tag(const char *compname)
{
	struct comp_tags {
		const char *comp;
		const char *tag;
	};
	const struct comp_tags component_tags[] = {
		{ "ACIBT", "acib" },
		{ "ACIBTLPEM", "lpbt" },
		{ "ACIWIFI", "aciw" },
		{ "ANE", "anef" },
		{ "ANS", "ansf" },
		{ "AOP", "aopf" },
		{ "AVE", "avef" },
		{ "Alamo", "almo" },
		{ "Ap,ANE1", "ane1" },
		{ "Ap,ANE2", "ane2" },
		{ "Ap,ANE3", "ane3" },
		{ "Ap,AudioAccessibilityBootChime", "auac" },
		{ "Ap,AudioBootChime", "aubt" },
		{ "Ap,AudioPowerAttachChime", "aupr" },
		{ "Ap,BootabilityBrainTrustCache", "trbb" },
		{ "Ap,CIO", "ciof" },
		{ "Ap,DCP2", "dcp2" },
		{ "Ap,HapticAssets", "hpas" },
		{ "Ap,LocalBoot", "lobo" },
		{ "Ap,LocalPolicy", "lpol" },
		{ "Ap,NextStageIM4MHash", "nsih" },
		{ "Ap,RecoveryOSPolicyNonceHash", "ronh" },
		{ "Ap,RestoreANE1", "ran1" },
		{ "Ap,RestoreANE2", "ran2" },
		{ "Ap,RestoreANE3", "ran3" },
		{ "Ap,RestoreCIO", "rcio" },
		{ "Ap,RestoreDCP2", "rdc2", },
		{ "Ap,RestoreTMU", "rtmu" },
		{ "Ap,Scorpius", "scpf" },
		{ "Ap,RestoreSecureM3Firmware", "rsm3" },
		{ "Ap,RestoreSecurePageTableMonitor", "rspt" },
		{ "Ap,RestoreTrustedExecutionMonitor", "rtrx" },
		{ "Ap,RestorecL4", "rxcl" },
		{ "Ap,SystemVolumeCanonicalMetadata", "msys" },
		{ "Ap,TMU", "tmuf" },
		{ "Ap,VolumeUUID", "vuid" },
		{ "Ap,rOSLogo1", "rlg1" },
		{ "Ap,rOSLogo2", "rlg2" },
		{ "AppleLogo", "logo" },
		{ "AudioCodecFirmware", "acfw" },
		{ "BatteryCharging", "glyC" },
		{ "BatteryCharging0", "chg0" },
		{ "BatteryCharging1", "chg1" },
		{ "BatteryFull", "batF" },
		{ "BatteryLow0", "bat0" },
		{ "BatteryLow1", "bat1" },
		{ "BatteryPlugin", "glyP" },
		{ "CFELoader", "cfel" },
		{ "CrownFirmware", "crwn" },
		{ "DCP", "dcpf" },
		{ "Dali", "dali" },
		{ "DeviceTree", "dtre" },
		{ "Diags", "diag" },
		{ "EngineeringTrustCache", "dtrs" },
		{ "ExtDCP", "edcp" },
		{ "GFX", "gfxf" },
		{ "Hamm", "hamf" },
		{ "Homer", "homr" },
		{ "ISP", "ispf" },
		{ "InputDevice", "ipdf" },
		{ "KernelCache", "krnl" },
		{ "LLB", "illb" },
		{ "LeapHaptics", "lphp" },
		{ "Liquid", "liqd" },
		{ "LoadableTrustCache", "ltrs" },
		{ "LowPowerWallet0", "lpw0" },
		{ "LowPowerWallet1", "lpw1" },
		{ "LowPowerWallet2", "lpw2" },
		{ "MacEFI", "mefi" },
		{ "MtpFirmware", "mtpf" },
		{ "Multitouch", "mtfw" },
		{ "NeedService", "nsrv" },
		{ "OS", "OS\0\0" },
		{ "OSRamdisk", "osrd" },
		{ "PEHammer", "hmmr" },
		{ "PERTOS", "pert" },
		{ "PHLEET", "phlt" },
		{ "PMP", "pmpf" },
		{ "PersonalizedDMG", "pdmg" },
		{ "RBM", "rmbt" },
		{ "RTP", "rtpf" },
		{ "Rap,SoftwareBinaryDsp1", "sbd1" },
		{ "Rap,RTKitOS", "rkos" },
		{ "Rap,RestoreRTKitOS", "rrko" },
		{ "RecoveryMode", "recm" },
		{ "RestoreANS", "rans" },
		{ "RestoreDCP", "rdcp" },
		{ "RestoreDeviceTree", "rdtr" },
		{ "RestoreExtDCP", "recp" },
		{ "RestoreKernelCache", "rkrn" },
		{ "RestoreLogo", "rlgo" },
		{ "RestoreRTP", "rrtp" },
		{ "RestoreRamDisk", "rdsk" },
		{ "RestoreSEP", "rsep" },
		{ "RestoreTrustCache", "rtsc" },
		{ "SCE", "scef" },
		{ "SCE1Firmware", "sc1f" },
		{ "SEP", "sepi" },
		{ "SIO", "siof" },
		{ "StaticTrustCache", "trst" },
		{ "SystemLocker", "lckr" },
		{ "SystemVolume", "isys" },
		{ "WCHFirmwareUpdater", "wchf" },
		{ "ftap", "ftap" },
		{ "ftsp", "ftsp" },
		{ "iBEC", "ibec" },
		{ "iBSS", "ibss" },
		{ "iBoot", "ibot" },
		{ "iBootData", "ibdt" },
		{ "iBootDataStage1", "ibd1" },
		{ "iBootTest", "itst" },
		{ "rfta", "rfta" },
		{ "rfts", "rfts" },
		{ NULL, NULL }
	};
	int i = 0;

	while (component_tags[i].comp) {
		if (!strcmp(component_tags[i].comp, compname)) {
			return component_tags[i].tag;
		}
		i++;
	}

	return NULL;
}

int img4_stitch_component(const char* component_name, const void* component_data, size_t component_size, plist_t parameters, plist_t tss_response, void** img4_data, size_t *img4_size)
{
	unsigned char* magic_header = NULL;
	unsigned int magic_header_size = 0;
	unsigned char* blob_header = NULL;
	unsigned int blob_header_size = 0;
	unsigned char* img4header = NULL;
	unsigned int img4header_size = 0;
	unsigned int content_size;
	unsigned char* outbuf;
	unsigned char* p;
	unsigned char* blob = NULL;
	unsigned int blob_size = 0;

	if (!component_name || !component_data || component_size == 0 || !tss_response || !img4_data || !img4_size) {
		return -1;
	}

	if (tss_response_get_ap_img4_ticket(tss_response, &blob, &blob_size) != 0) {
		logger(LL_ERROR, "%s: Failed to get ApImg4Ticket from TSS response\n", __func__);
		return -1;
	}

	logger(LL_INFO, "Personalizing IMG4 component %s...\n", component_name);
	/* first we need check if we have to change the tag for the given component */
	const void *tag = asn1_find_element(1, ASN1_IA5_STRING, component_data);
	if (tag) {
		logger(LL_DEBUG, "Tag found\n");
		const char* matches[] = {
			"RestoreKernelCache",
			"RestoreDeviceTree",
			"RestoreSEP",
			"RestoreLogo",
			"RestoreTrustCache",
			"RestoreDCP",
			"Ap,RestoreDCP2",
			"Ap,RestoreTMU",
			"Ap,RestoreCIO",
			"Ap,DCP2",
			"Ap,RestoreSecureM3Firmware",
			"Ap,RestoreSecurePageTableMonitor",
			"Ap,RestoreTrustedExecutionMonitor",
			"Ap,RestorecL4",
			NULL
		};
		int i = 0;
		while (matches[i]) {
			if (!strcmp(matches[i], component_name)) {
				const char* comptag = _img4_get_component_tag(component_name);
				if (comptag) {
					memcpy((void*)tag, comptag, 4);
				} else {
					logger(LL_WARNING, "Cannot find tag for component '%s'\n", component_name);
				}
				break;
			}
			i++;
		}
	} else {
		logger(LL_ERROR, "Personalization failed for component '%s': Tag not found\n", component_name);
		return -1;
	}

	// check if we have a *-TBM entry for the given component
	unsigned char *additional_data = NULL;
	unsigned int additional_size = 0;
	char *tbm_key = malloc(strlen(component_name) + 5);
	snprintf(tbm_key, strlen(component_name)+5, "%s-TBM", component_name);
	plist_t tbm_dict = plist_dict_get_item(tss_response, tbm_key);
	free(tbm_key);
	uint64_t ucon_size = 0;
	const char* ucon_data = NULL;
	uint64_t ucer_size = 0;
	const char* ucer_data = NULL;
	if (tbm_dict) {
		plist_t dt = plist_dict_get_item(tbm_dict, "ucon");
		if (!dt) {
			logger(LL_ERROR, "%s: Missing ucon node in %s-TBM dictionary\n", __func__, component_name);
			return -1;
		}
		ucon_data = plist_get_data_ptr(dt, &ucon_size);
		if (!ucon_data) {
			logger(LL_ERROR, "%s: Missing ucon data in %s-TBM dictionary\n", __func__, component_name);
			return -1;
		}
		dt = plist_dict_get_item(tbm_dict, "ucer");
		if (!dt) {
			logger(LL_ERROR, "%s: Missing ucer data node in %s-TBM dictionary\n", __func__, component_name);
			return -1;
		}
		ucer_data = plist_get_data_ptr(dt, &ucer_size);
		if (!ucer_data) {
			logger(LL_ERROR, "%s: Missing ucer data in %s-TBM dictionary\n", __func__, component_name);
			return -1;
		}
	}

	int nonce_slot_required = plist_dict_get_bool(parameters, "RequiresNonceSlot") && (!strcmp(component_name, "SEP") || !strcmp(component_name, "SepStage1") || !strcmp(component_name, "LLB"));

	if (ucon_data || ucer_data || nonce_slot_required) {
		size_t im4r_size = 16;
		if (ucon_data) {
			im4r_size += 8 + 8 + ucon_size + 16;
		}
		if (ucer_data) {
			im4r_size += 8 + 8 + ucer_size + 16;
		}
		if (nonce_slot_required) {
			im4r_size += 16;
		}
		unsigned char *im4rset = (unsigned char*)malloc(im4r_size);
		unsigned char *p_im4rset = im4rset;
		unsigned int im4rlen = 0;

		// ----------- anid/snid -------
		if (nonce_slot_required) {
			const char* tag_name = NULL;
			uint64_t tag_value = 0;
			if (!strcmp(component_name, "SEP") || !strcmp(component_name, "SepStage1")) {
				tag_name = "snid";
				tag_value = 2;
				if (plist_dict_get_item(parameters, "SepNonceSlotID")) {
					tag_value = plist_dict_get_uint(parameters, "SepNonceSlotID");
				}
			} else {
				tag_name = "anid";
				tag_value = 0;
				if (plist_dict_get_item(parameters, "ApNonceSlotID")) {
					tag_value = plist_dict_get_uint(parameters, "ApNonceSlotID");
				}
			}
			// write priv anid/snid element
			asn1_write_priv_element(&p_im4rset, &im4rlen, __bswap_32(*(uint32_t*)tag_name));
			// write anid/snid IA5STRING and anid/snid value
			unsigned char inner_seq[16];
			unsigned char *p_inner_seq = &inner_seq[0];
			unsigned int inner_seq_hdr_len = 0;
			asn1_write_element(&p_inner_seq, &inner_seq_hdr_len, ASN1_IA5_STRING, (void*)tag_name, -1);
			asn1_write_element(&p_inner_seq, &inner_seq_hdr_len, ASN1_INTEGER, (void*)&tag_value, -1);

			// write anid/snid sequence
			unsigned char elem_seq[8];
			unsigned char *p = &elem_seq[0];
			unsigned int seq_hdr_len = 0;
			asn1_write_element_header(ASN1_SEQUENCE | ASN1_CONSTRUCTED, inner_seq_hdr_len, &p, &seq_hdr_len);

			// add size to priv anid/snid element
			asn1_write_size(inner_seq_hdr_len + seq_hdr_len, &p_im4rset, &im4rlen);

			// put it together
			memcpy(p_im4rset, elem_seq, seq_hdr_len);
			p_im4rset += seq_hdr_len;
			im4rlen += seq_hdr_len;
			memcpy(p_im4rset, inner_seq, inner_seq_hdr_len);
			p_im4rset += inner_seq_hdr_len;
			im4rlen += inner_seq_hdr_len;
		}

		// ----------- ucon ------------
		if (ucon_data) {
			// write priv ucon element
			asn1_write_priv_element(&p_im4rset, &im4rlen, *(uint32_t*)"nocu");

			// write ucon IA5STRING and ucon data header
			unsigned char inner_seq[16];
			unsigned char *p_inner_seq = &inner_seq[0];
			unsigned int inner_seq_hdr_len = 0;
			asn1_write_element(&p_inner_seq, &inner_seq_hdr_len, ASN1_IA5_STRING, (void*)"ucon", -1);
			asn1_write_element_header(ASN1_OCTET_STRING, ucon_size, &p_inner_seq, &inner_seq_hdr_len);

			// write ucon sequence
			unsigned char elem_seq[8];
			unsigned char *p = &elem_seq[0];
			unsigned int seq_hdr_len = 0;
			asn1_write_element_header(ASN1_SEQUENCE | ASN1_CONSTRUCTED, inner_seq_hdr_len + ucon_size, &p, &seq_hdr_len);

			// add size to priv ucon element
			asn1_write_size(inner_seq_hdr_len + ucon_size + seq_hdr_len, &p_im4rset, &im4rlen);

			// put it together
			memcpy(p_im4rset, elem_seq, seq_hdr_len);
			p_im4rset += seq_hdr_len;
			im4rlen += seq_hdr_len;
			memcpy(p_im4rset, inner_seq, inner_seq_hdr_len);
			p_im4rset += inner_seq_hdr_len;
			im4rlen += inner_seq_hdr_len;
			// write ucon data
			memcpy(p_im4rset, ucon_data, ucon_size);
			p_im4rset += ucon_size;
			im4rlen += ucon_size;
		}

		// ----------- ucer ------------
		if (ucer_data) {
			// write priv ucer element
			asn1_write_priv_element(&p_im4rset, &im4rlen, *(uint32_t*)"recu");

			// write ucer IA5STRING and ucer data header
			unsigned char inner_seq[16];
			unsigned char *p_inner_seq = &inner_seq[0];
			unsigned int inner_seq_hdr_len = 0;
			asn1_write_element(&p_inner_seq, &inner_seq_hdr_len, ASN1_IA5_STRING, (void*)"ucer", -1);
			asn1_write_element_header(ASN1_OCTET_STRING, ucer_size, &p_inner_seq, &inner_seq_hdr_len);

			// write ucer sequence
			unsigned char elem_seq[8];
			unsigned char *p = &elem_seq[0];
			unsigned int seq_hdr_len = 0;
			asn1_write_element_header(ASN1_SEQUENCE | ASN1_CONSTRUCTED, inner_seq_hdr_len + ucer_size, &p, &seq_hdr_len);

			// add size to priv ucer element
			asn1_write_size(inner_seq_hdr_len + ucer_size + seq_hdr_len, &p_im4rset, &im4rlen);

			// put it together
			memcpy(p_im4rset, elem_seq, seq_hdr_len);
			p_im4rset += seq_hdr_len;
			im4rlen += seq_hdr_len;
			memcpy(p_im4rset, inner_seq, inner_seq_hdr_len);
			p_im4rset += inner_seq_hdr_len;
			im4rlen += inner_seq_hdr_len;
			// write ucer data
			memcpy(p_im4rset, ucer_data, ucer_size);
			p_im4rset += ucer_size;
			im4rlen += ucer_size;
		}

		// now construct IM4R

		/* write inner set */
		unsigned char inner_set_[8];
		unsigned char *inner_set = &inner_set_[0];
		unsigned int inner_set_len = 0;
		asn1_write_element_header(ASN1_SET | ASN1_CONSTRUCTED, im4rlen, &inner_set, &inner_set_len);

		/* write header values */
		unsigned char hdrdata_[16];
		unsigned char *hdrdata = &hdrdata_[0];
		unsigned int hdrdata_len = 0;
		asn1_write_element(&hdrdata, &hdrdata_len, ASN1_IA5_STRING, (void*)"IM4R", -1);

		/* write sequence now that we know the entire size */
		unsigned char seq_[8];
		unsigned char *seq = &seq_[0];
		unsigned int seq_len = 0;
		asn1_write_element_header(ASN1_SEQUENCE | ASN1_CONSTRUCTED, im4rlen + inner_set_len + hdrdata_len, &seq, &seq_len);

		/* write outer cont[1] */
		unsigned char cont_[8];
		unsigned char *cont = &cont_[0];
		unsigned int cont_len = 0;
		asn1_write_element_header(ASN1_CONTEXT_SPECIFIC | ASN1_CONSTRUCTED | 1, im4rlen + inner_set_len + hdrdata_len + seq_len, &cont, &cont_len);

		// now put everything together
		additional_data = malloc(im4rlen + inner_set_len + hdrdata_len + seq_len + cont_len);
		p = additional_data;
		memcpy(p, cont_, cont_len);
		p += cont_len;
		memcpy(p, seq_, seq_len);
		p += seq_len;
		memcpy(p, hdrdata_, hdrdata_len);
		p += hdrdata_len;
		memcpy(p, inner_set_, inner_set_len);
		p += inner_set_len;
		memcpy(p, im4rset, im4rlen);
		p += im4rlen;
		additional_size = (unsigned int)(p - additional_data);

		free(im4rset);
	}

	// create element header for the "IMG4" magic
	asn1_create_element_header(ASN1_IA5_STRING, IMG4_MAGIC_SIZE, &magic_header, &magic_header_size);
	// create element header for the blob (ApImg4Ticket)
	asn1_create_element_header(ASN1_CONTEXT_SPECIFIC|ASN1_CONSTRUCTED, blob_size, &blob_header, &blob_header_size);

	// calculate the size for the final IMG4 file (asn1 sequence)
	content_size = magic_header_size + IMG4_MAGIC_SIZE + component_size + blob_header_size + blob_size + additional_size;

	// create element header for the final IMG4 asn1 blob
	asn1_create_element_header(ASN1_SEQUENCE|ASN1_CONSTRUCTED, content_size, &img4header, &img4header_size);

	outbuf = (unsigned char*)malloc(img4header_size + content_size);
	if (!outbuf) {
		if (magic_header) {
			free(magic_header);
		}
		if (blob_header) {
			free(blob_header);
		}
		if (img4header) {
			free(img4header);
		}
		free(additional_data);
		logger(LL_ERROR, "out of memory when personalizing IMG4 component %s\n", component_name);
		return -1;
	}
	p = outbuf;

	// now put everything together
	memcpy(p, img4header, img4header_size);
	p += img4header_size;
	memcpy(p, magic_header, magic_header_size);
	p += magic_header_size;
	memcpy(p, IMG4_MAGIC, IMG4_MAGIC_SIZE);
	p += IMG4_MAGIC_SIZE;
	memcpy(p, component_data, component_size);
	p += component_size;
	memcpy(p, blob_header, blob_header_size);
	p += blob_header_size;
	memcpy(p, blob, blob_size);
	p += blob_size;
	if (additional_size) {
		memcpy(p, additional_data, additional_size);
		p += additional_size;
	}

	*img4_data = outbuf;
	*img4_size = (p - outbuf);

	if (magic_header) {
		free(magic_header);
	}
	if (blob_header) {
		free(blob_header);
	}
	if (img4header) {
		free(img4header);
	}
	free(additional_data);

	return 0;
}

#ifndef __bswap_32
#define __bswap_32(x) ((((x) & 0xFF000000) >> 24) \
                    | (((x) & 0x00FF0000) >> 8) \
                    | (((x) & 0x0000FF00) << 8) \
                    | (((x) & 0x000000FF) << 24))
#endif

static void _manifest_write_key_value(unsigned char **p, unsigned int *length, const char *tag, int type, void *value, int size)
{
	uint32_t utag = __bswap_32(*(uint32_t*)tag);
	asn1_write_priv_element(p, length, utag);

	unsigned char *start = *p;
	unsigned char *outer_start = *p + 5;
	unsigned char *inner_start = *p + 5 + 6;
	unsigned int inner_length = 0;
	asn1_write_element(&inner_start, &inner_length, ASN1_IA5_STRING, (void*)tag, -1);
	asn1_write_element(&inner_start, &inner_length, type, value, size);

	unsigned int outer_length = 0;
	unsigned int this_length = 0;
	if (!value && size > 0) {
		asn1_write_element_header(ASN1_SEQUENCE | ASN1_CONSTRUCTED, inner_length + size, &outer_start, &outer_length);
		asn1_write_size(outer_length + inner_length + size, &start, &this_length);
	} else {
		asn1_write_element_header(ASN1_SEQUENCE | ASN1_CONSTRUCTED, inner_length, &outer_start, &outer_length);
		asn1_write_size(outer_length + inner_length, &start, &this_length);
	}

	memmove(start, outer_start - outer_length, outer_length);
	outer_start = start + outer_length;
	*length += this_length;
	*length += outer_length;

	memmove(outer_start, inner_start - inner_length, inner_length);
	*length += inner_length;

	*p += this_length + outer_length + inner_length;
}

static void _manifest_write_component(unsigned char **p, unsigned int *length, const char *tag, plist_t comp)
{
	uint32_t utag = __bswap_32(*(uint32_t*)tag);
	asn1_write_priv_element(p, length, utag);

	unsigned char *start = *p;
	unsigned char *outer_start = *p + 5;
	unsigned char *inner_start = *p + 5 + 6;
	unsigned int inner_length = 0;
	asn1_write_element(&inner_start, &inner_length, ASN1_IA5_STRING, (void*)tag, -1);

	unsigned char tmp_[512] = { 0, };
	unsigned int tmp_len = 0;
	unsigned char *tmp = &tmp_[0];

	plist_t node = NULL;
	uint8_t boolval = 0;

	node = plist_dict_get_item(comp, "Digest");
	if (node) {
		uint64_t digest_len = 0;
		const char *digest = plist_get_data_ptr(node, &digest_len);
		if (digest_len > 0) {
			_manifest_write_key_value(&tmp, &tmp_len, "DGST", ASN1_OCTET_STRING, (void*)digest, digest_len);
		}
	}

	node = plist_dict_get_item(comp, "Trusted");
	if (node) {
		boolval = 0;
		plist_get_bool_val(node, &boolval);
		unsigned int int_bool_val = boolval;
		_manifest_write_key_value(&tmp, &tmp_len, "EKEY", ASN1_BOOLEAN, &int_bool_val, -1);
	}

	node = plist_dict_get_item(comp, "EPRO");
	if (node) {
		boolval = 0;
		plist_get_bool_val(node, &boolval);
		unsigned int int_bool_val = boolval;
		_manifest_write_key_value(&tmp, &tmp_len, "EPRO", ASN1_BOOLEAN, &int_bool_val, -1);
	}

	node = plist_dict_get_item(comp, "ESEC");
	if (node) {
		boolval = 0;
		plist_get_bool_val(node, &boolval);
		unsigned int int_bool_val = boolval;
		_manifest_write_key_value(&tmp, &tmp_len, "ESEC", ASN1_BOOLEAN, &int_bool_val, -1);
	}

	node = plist_dict_get_item(comp, "TBMDigests");
	if (node) {
		uint64_t datalen = 0;
		const char *data = plist_get_data_ptr(node, &datalen);
		const char *tbmtag = NULL;
		if (!strcmp(tag, "sepi")) {
			tbmtag = "tbms";
		} else if (!strcmp(tag, "rsep")) {
			tbmtag = "tbmr";
		}
		if (!tbmtag) {
			logger(LL_ERROR, "Unexpected TMBDigests for comp '%s'\n", tag);
		} else {
			_manifest_write_key_value(&tmp, &tmp_len, tbmtag, ASN1_OCTET_STRING, (void*)data, datalen);
		}
	}

	asn1_write_element_header(ASN1_SET | ASN1_CONSTRUCTED, tmp_len, &inner_start, &inner_length);
	memcpy(inner_start, tmp_, tmp_len);
	inner_start += tmp_len;
	inner_length += tmp_len;

	unsigned int outer_length = 0;
	asn1_write_element_header(ASN1_SEQUENCE | ASN1_CONSTRUCTED, inner_length, &outer_start, &outer_length);

	unsigned int this_length = 0;
	asn1_write_size(outer_length + inner_length, &start, &this_length);

	memmove(start, outer_start - outer_length, outer_length);

	outer_start = start + outer_length;
	*length += this_length;
	*length += outer_length;

	memmove(outer_start, inner_start - inner_length, inner_length);

	*length += inner_length;

	*p += this_length + outer_length + inner_length;
}

int img4_create_local_manifest(plist_t request, plist_t build_identity, plist_t* manifest)
{
	if (!request || !manifest) {
		return -1;
	}

	unsigned char *buf = calloc(1, 65536);
	unsigned char *p = buf;
	unsigned int length = 0;
	uint64_t uintval = 0;
	unsigned int boolval = 0;

	unsigned char tmp_[1024];
	unsigned char *tmp = &tmp_[0];
	unsigned int tmp_len = 0;

	/* write manifest properties */
	uintval = plist_dict_get_uint(request, "ApBoardID");
	_manifest_write_key_value(&tmp, &tmp_len, "BORD", ASN1_INTEGER, &uintval, -1);

	uintval = 0;
	_manifest_write_key_value(&tmp, &tmp_len, "CEPO", ASN1_INTEGER, &uintval, -1);

	uintval = plist_dict_get_uint(request, "ApChipID");
	_manifest_write_key_value(&tmp, &tmp_len, "CHIP", ASN1_INTEGER, &uintval, -1);

	boolval = plist_dict_get_bool(request, "ApProductionMode");
	_manifest_write_key_value(&tmp, &tmp_len, "CPRO", ASN1_BOOLEAN, &boolval, -1);

	boolval = 0;
	_manifest_write_key_value(&tmp, &tmp_len, "CSEC", ASN1_BOOLEAN, &boolval, -1);

	uintval = plist_dict_get_uint(request, "ApSecurityDomain");
	_manifest_write_key_value(&tmp, &tmp_len, "SDOM", ASN1_INTEGER, &uintval, -1);

	/* create manifest properties set */
	_manifest_write_key_value(&p, &length, "MANP", ASN1_SET | ASN1_CONSTRUCTED, tmp_, tmp_len);

	plist_t component_manifest = NULL;
	if (build_identity) {
		component_manifest = plist_dict_get_item(build_identity, "Manifest");
	}

	/* now write the components */
	plist_dict_iter iter = NULL;
	plist_dict_new_iter(request, &iter);
	char *key = NULL;
	plist_t val = NULL;
	do {
		plist_dict_next_item(request, iter, &key, &val);
		if (val && plist_get_node_type(val) == PLIST_DICT) {
			const char *comp = NULL;
			/* check if component has Img4PayloadType */
			if (component_manifest) {
				plist_t img4_comp = plist_access_path(component_manifest, 3, key, "Info", "Img4PayloadType");
				if (img4_comp) {
					comp = plist_get_string_ptr(img4_comp, NULL);
				}
			}
			if (!comp) {
				comp = _img4_get_component_tag(key);
			}
			if (!comp) {
				logger(LL_DEBUG, "%s: Unhandled component '%s'\n", __func__, key);
				_manifest_write_component(&p, &length, key, val);
			} else {
				logger(LL_DEBUG, "found component %s (%s)\n", comp, key);
				_manifest_write_component(&p, &length, comp, val);
			}
		}
		free(key);
	} while (val);
	free(iter);

	/* write manifest body header */
	unsigned char manb_[32];
	unsigned char *manb = &manb_[0];
	unsigned int manb_len = 0;
	_manifest_write_key_value(&manb, &manb_len, "MANB", ASN1_SET | ASN1_CONSTRUCTED, NULL, length);

	/* write inner set */
	unsigned char inner_set_[8];
	unsigned char *inner_set = &inner_set_[0];
	unsigned int inner_set_len = 0;
	asn1_write_element_header(ASN1_SET | ASN1_CONSTRUCTED, length + manb_len, &inner_set, &inner_set_len);

	/* write header values */
	unsigned char hdrdata_[16];
	unsigned char *hdrdata = &hdrdata_[0];
	unsigned int hdrdata_len = 0;
	asn1_write_element(&hdrdata, &hdrdata_len, ASN1_IA5_STRING, (void*)"IM4M", -1);
	uint64_t intval = 0;
	asn1_write_element(&hdrdata, &hdrdata_len, ASN1_INTEGER, &intval, -1);

	/* write outer sequence now that we know the entire size */
	unsigned char seq_[8];
	unsigned char *seq = &seq_[0];
	unsigned int seq_len = 0;
	asn1_write_element_header(ASN1_SEQUENCE | ASN1_CONSTRUCTED, inner_set_len + length + manb_len + hdrdata_len, &seq, &seq_len);

	unsigned int header_len = seq_len + hdrdata_len + inner_set_len + manb_len;

	/* now put everything together */
	memmove(buf + header_len, buf, length);

	unsigned char *hdr = buf;
	unsigned int hdr_len = 0;

	memcpy(hdr, seq_, seq_len);
	hdr += seq_len;
	hdr_len += seq_len;

	memcpy(hdr, hdrdata_, hdrdata_len);
	hdr += hdrdata_len;
	hdr_len += hdrdata_len;

	memcpy(hdr, inner_set_, inner_set_len);
	hdr += inner_set_len;
	hdr_len += inner_set_len;

	memcpy(hdr, manb_, manb_len);
	hdr += manb_len;
	hdr_len += manb_len;

	length += hdr_len;

	*manifest = plist_new_data((char*)buf, length);

	free(buf);

	return 0;
}
