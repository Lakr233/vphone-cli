/*
 * img3.c
 * Functions for handling with Apple's IMG3 format
 *
 * Copyright (c) 2012-2013 Nikias Bassen. All Rights Reserved.
 * Copyright (c) 2010 Martin Szulecki. All Rights Reserved.
 * Copyright (c) 2010 Joshua Hill. All Rights Reserved.
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

#include "img3.h"
#include "common.h"
#include "idevicerestore.h"

static void img3_free(img3_file* image);
static img3_element* img3_parse_element(const unsigned char* data);
static void img3_free_element(img3_element* element);

static img3_file* img3_parse_file(const unsigned char* data, unsigned int size) {
	unsigned int data_offset = 0;
	img3_element* element;
	img3_header* header = (img3_header*) data;
	if (header->signature != kImg3Container) {
		logger(LL_ERROR, "Invalid IMG3 file\n");
		return NULL;
	}

	img3_file* image = (img3_file*) malloc(sizeof(img3_file));
	if (image == NULL) {
		logger(LL_ERROR, "Unable to allocate memory for IMG3 file\n");
		return NULL;
	}
	memset(image, '\0', sizeof(img3_file));
	image->idx_ecid_element = -1;
	image->idx_shsh_element = -1;
	image->idx_cert_element = -1;

	image->header = (img3_header*) malloc(sizeof(img3_header));
	if (image->header == NULL) {
		logger(LL_ERROR, "Unable to allocate memory for IMG3 header\n");
		img3_free(image);
		return NULL;
	}
	memcpy(image->header, data, sizeof(img3_header));
	data_offset += sizeof(img3_header);

	img3_element_header* current = NULL;
	while (data_offset < size) {
		current = (img3_element_header*) &data[data_offset];
		switch (current->signature) {
		case kTypeElement:
			element = img3_parse_element(&data[data_offset]);
			if (element == NULL) {
				logger(LL_ERROR, "Unable to parse TYPE element\n");
				img3_free(image);
				return NULL;
			}
			image->elements[image->num_elements++] = element;
			logger(LL_DEBUG, "Parsed TYPE element\n");
			break;

		case kDataElement:
			element = img3_parse_element(&data[data_offset]);
			if (element == NULL) {
				logger(LL_ERROR, "Unable to parse DATA element\n");
				img3_free(image);
				return NULL;
			}
			image->elements[image->num_elements++] = element;
			logger(LL_DEBUG, "Parsed DATA element\n");
			break;

		case kVersElement:
			element = img3_parse_element(&data[data_offset]);
			if (element == NULL) {
				logger(LL_ERROR, "Unable to parse VERS element\n");
				img3_free(image);
				return NULL;
			}
			image->elements[image->num_elements++] = element;
			logger(LL_DEBUG, "Parsed VERS element\n");
			break;

		case kSepoElement:
			element = img3_parse_element(&data[data_offset]);
			if (element == NULL) {
				logger(LL_ERROR, "Unable to parse SEPO element\n");
				img3_free(image);
				return NULL;
			}
			image->elements[image->num_elements++] = element;
			logger(LL_DEBUG, "Parsed SEPO element\n");
			break;

		case kBordElement:
			element = img3_parse_element(&data[data_offset]);
			if (element == NULL) {
				logger(LL_ERROR, "Unable to parse BORD element\n");
				img3_free(image);
				return NULL;
			}
			image->elements[image->num_elements++] = element;
			logger(LL_DEBUG, "Parsed BORD element\n");
			break;

		case kChipElement:
			element = img3_parse_element(&data[data_offset]);
			if (element == NULL) {
				logger(LL_ERROR, "Unable to parse CHIP element\n");
				img3_free(image);
				return NULL;
			}
			image->elements[image->num_elements++] = element;
			logger(LL_DEBUG, "Parsed CHIP element\n");
			break;

		case kKbagElement:
			element = img3_parse_element(&data[data_offset]);
			if (element == NULL) {
				logger(LL_ERROR, "Unable to parse first KBAG element\n");
				img3_free(image);
				return NULL;
			}
			image->elements[image->num_elements++] = element;
			logger(LL_DEBUG, "Parsed KBAG element\n");
			break;

		case kEcidElement:
			element = img3_parse_element(&data[data_offset]);
			if (element == NULL) {
				logger(LL_ERROR, "Unable to parse ECID element\n");
				img3_free(image);
				return NULL;
			}
			image->idx_ecid_element = image->num_elements;
			image->elements[image->num_elements++] = element;
			logger(LL_DEBUG, "Parsed ECID element\n");
			break;

		case kShshElement:
			element = img3_parse_element(&data[data_offset]);
			if (element == NULL) {
				logger(LL_ERROR, "Unable to parse SHSH element\n");
				img3_free(image);
				return NULL;
			}
			image->idx_shsh_element = image->num_elements;
			image->elements[image->num_elements++] = element;
			logger(LL_DEBUG, "Parsed SHSH element\n");
			break;

		case kCertElement:
			element = img3_parse_element(&data[data_offset]);
			if (element == NULL) {
				logger(LL_ERROR, "Unable to parse CERT element\n");
				img3_free(image);
				return NULL;
			}
			image->idx_cert_element = image->num_elements;
			image->elements[image->num_elements++] = element;
			logger(LL_DEBUG, "Parsed CERT element\n");
			break;

		case kUnknElement:
			element = img3_parse_element(&data[data_offset]);
			if (element == NULL) {
				logger(LL_ERROR, "Unable to parse UNKN element\n");
				img3_free(image);
				return NULL;
			}
			image->elements[image->num_elements++] = element;
			logger(LL_DEBUG, "Parsed UNKN element\n");
			break;

		default:
			logger(LL_ERROR, "Unknown IMG3 element type %08x\n", current->signature);
			img3_free(image);
			return NULL;
		}
		data_offset += current->full_size;
	}

	return image;
}

static img3_element* img3_parse_element(const unsigned char* data) {
	img3_element_header* element_header = (img3_element_header*) data;
	img3_element* element = (img3_element*) malloc(sizeof(img3_element));
	if (element == NULL) {
		logger(LL_ERROR, "Unable to allocate memory for IMG3 element\n");
		return NULL;
	}
	memset(element, '\0', sizeof(img3_element));

	element->data = (unsigned char*) malloc(element_header->full_size);
	if (element->data == NULL) {
		logger(LL_ERROR, "Unable to allocate memory for IMG3 element data\n");
		free(element);
		return NULL;
	}
	memcpy(element->data, data, element_header->full_size);
	element->header = (img3_element_header*) element->data;
	element->type = (img3_element_type) element->header->signature;

	return element;
}

static void img3_free(img3_file* image) {
	if (image != NULL) {
		if (image->header != NULL) {
			free(image->header);
		}

		int i;
		for (i = 0; i < image->num_elements; i++) {
			img3_free_element(image->elements[i]);
			image->elements[i] = NULL;
		}
		free(image);
		image = NULL;
	}
}

static void img3_free_element(img3_element* element) {
	if (element != NULL) {
		if (element->data != NULL) {
			free(element->data);
			element->data = NULL;
		}
		free(element);
		element = NULL;
	}
}

static int img3_replace_signature(img3_file* image, const unsigned char* signature) {
	int i, oldidx;
	int offset = 0;
	img3_element* ecid = img3_parse_element(&signature[offset]);
	if (ecid == NULL || ecid->type != kEcidElement) {
		logger(LL_ERROR, "Unable to find ECID element in signature\n");
		return -1;
	}
	offset += ecid->header->full_size;

	img3_element* shsh = img3_parse_element(&signature[offset]);
	if (shsh == NULL || shsh->type != kShshElement) {
		logger(LL_ERROR, "Unable to find SHSH element in signature\n");
		return -1;
	}
	offset += shsh->header->full_size;

	img3_element* cert = img3_parse_element(&signature[offset]);
	if (cert == NULL || cert->type != kCertElement) {
		logger(LL_ERROR, "Unable to find CERT element in signature\n");
		return -1;
	}
	offset += cert->header->full_size;

	if (image->idx_ecid_element >= 0) {
		img3_free_element(image->elements[image->idx_ecid_element]);
		image->elements[image->idx_ecid_element] = ecid;
	} else {
		if (image->idx_shsh_element >= 0) {
			// move elements by 1
			oldidx = image->idx_shsh_element;
			for (i = image->num_elements-1; i >= oldidx; i--) {
				image->elements[i+1] = image->elements[i];
				switch (image->elements[i+1]->type) {
				case kShshElement:
					image->idx_shsh_element = i+1;
					break;
				case kCertElement:
					image->idx_cert_element = i+1;
					break;
				case kEcidElement:
					image->idx_ecid_element = i+1;
					break;
				default:
					break;
				}
			}
			image->elements[oldidx] = ecid;
			image->idx_ecid_element = oldidx;
			image->num_elements++;
		} else {
			// append if not found
			image->elements[image->num_elements] = ecid;
			image->idx_ecid_element = image->num_elements;
			image->num_elements++;
		}
	}

	if (image->idx_shsh_element >= 0) {
		img3_free_element(image->elements[image->idx_shsh_element]);
		image->elements[image->idx_shsh_element] = shsh;
	} else {
		if (image->idx_cert_element >= 0) {
			// move elements by 1
			oldidx = image->idx_cert_element;
			for (i = image->num_elements-1; i >= oldidx; i--) {
				image->elements[i+1] = image->elements[i];
				switch (image->elements[i+1]->type) {
				case kShshElement:
					image->idx_shsh_element = i+1;
					break;
				case kCertElement:
					image->idx_cert_element = i+1;
					break;
				case kEcidElement:
					image->idx_ecid_element = i+1;
					break;
				default:
					break;
				}
			}
			image->elements[oldidx] = shsh;
			image->idx_shsh_element = oldidx;
			image->num_elements++;
		} else {
			// append if not found
			image->elements[image->num_elements] = shsh;
			image->idx_shsh_element = image->num_elements;
			image->num_elements++;
		}
	}

	if (image->idx_cert_element >= 0) {
		img3_free_element(image->elements[image->idx_cert_element]);
		image->elements[image->idx_cert_element] = cert;
	} else {
		// append if not found
		image->elements[image->num_elements] = cert;
		image->idx_cert_element = image->num_elements;
		image->num_elements++;
	}

	return 0;
}

static int img3_get_data(img3_file* image, unsigned char** pdata, unsigned int* psize) {
	int i;
	int offset = 0;
	int size = sizeof(img3_header);

	// Add up the size of the image first so we can allocate our memory
	for (i = 0; i < image->num_elements; i++) {
		size += image->elements[i]->header->full_size;
	}

	logger(LL_INFO, "reconstructed size: %d\n", size);

	unsigned char* data = (unsigned char*) malloc(size);
	if (data == NULL) {
		logger(LL_ERROR, "Unable to allocate memory for IMG3 data\n");
		return -1;
	}

	// Add data to our new header (except shsh_offset)
	img3_header* header = (img3_header*) data;
	header->full_size = size;
	header->signature = image->header->signature;
	header->data_size = size - sizeof(img3_header);
	header->image_type = image->header->image_type;
	offset += sizeof(img3_header);

	// Copy each section over to the new buffer
	for (i = 0; i < image->num_elements; i++) {
		memcpy(&data[offset], image->elements[i]->data, image->elements[i]->header->full_size);
		if (image->elements[i]->type == kShshElement) {
			header->shsh_offset = offset - sizeof(img3_header);
		}
		offset += image->elements[i]->header->full_size;
	}

	if (offset != size) {
		logger(LL_ERROR, "Incorrectly sized image data\n");
		free(data);
		*pdata = 0;
		*psize = 0;
		return -1;
	}

	*pdata = data;
	*psize = size;
	return 0;
}

int img3_stitch_component(const char* component_name, const void* component_data, size_t component_size, const void* blob, size_t blob_size, void** img3_data, size_t *img3_size)
{
	img3_file *img3 = NULL;
	unsigned char* outbuf = NULL;
	unsigned int outsize = 0;

	if (!component_name || !component_data || component_size == 0 || !blob || blob_size == 0 || !img3_data || !img3_size) {
		return -1;
	}

	logger(LL_INFO, "Personalizing IMG3 component %s...\n", component_name);

	/* parse current component as img3 */
	img3 = img3_parse_file(component_data, component_size);
	if (img3 == NULL) {
		logger(LL_ERROR, "Unable to parse %s IMG3 file\n", component_name);
		return -1;
	}

	if (((img3_element_header*)blob)->full_size != blob_size) {
		logger(LL_ERROR, "Invalid blob passed for %s IMG3: The size %d embedded in the blob does not match the passed size of %zu\n", component_name, ((img3_element_header*)blob)->full_size, blob_size);
		img3_free(img3);
		return -1;
	}

	/* personalize the component using the blob */
	if (img3_replace_signature(img3, blob) < 0) {
		logger(LL_ERROR, "Unable to replace %s IMG3 signature\n", component_name);
		img3_free(img3);
		return -1;
	}

	/* get the img3 file as data */
	if (img3_get_data(img3, &outbuf, &outsize) < 0) {
		logger(LL_ERROR, "Unable to reconstruct %s IMG3\n", component_name);
		img3_free(img3);
		return -1;
	}

	/* cleanup */
	img3_free(img3);

	*img3_data = outbuf;
	*img3_size = outsize;

	return 0;
}
