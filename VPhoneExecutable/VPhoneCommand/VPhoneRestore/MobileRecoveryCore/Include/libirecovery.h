/*
 * libirecovery.h
 * Communication to iBoot/iBSS on Apple iOS devices via USB
 *
 * Copyright (c) 2012-2023 Nikias Bassen <nikias@gmx.li>
 * Copyright (c) 2012-2013 Martin Szulecki <m.szulecki@libimobiledevice.org>
 * Copyright (c) 2010 Chronic-Dev Team
 * Copyright (c) 2010 Joshua Hill
 *
 * All rights reserved. This program and the accompanying materials
 * are made available under the terms of the GNU Lesser General Public License
 * (LGPL) version 2.1 which accompanies this distribution, and is available at
 * http://www.gnu.org/licenses/lgpl-2.1.html
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * Lesser General Public License for more details.
 */

#ifndef LIBIRECOVERY_H
#define LIBIRECOVERY_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

#ifndef IRECV_API
  #ifdef IRECV_STATIC
    #define IRECV_API
  #elif defined(_WIN32)
    #define IRECV_API __declspec(dllimport)
  #else
    #define IRECV_API
  #endif
#endif

enum irecv_mode {
	IRECV_K_RECOVERY_MODE_1   = 0x1280,
	IRECV_K_RECOVERY_MODE_2   = 0x1281,
	IRECV_K_RECOVERY_MODE_3   = 0x1282,
	IRECV_K_RECOVERY_MODE_4   = 0x1283,
	IRECV_K_WTF_MODE          = 0x1222,
	IRECV_K_DFU_MODE          = 0x1227,
	IRECV_K_PORT_DFU_MODE     = 0xf014
};

typedef enum {
	IRECV_E_SUCCESS           =  0,
	IRECV_E_NO_DEVICE         = -1,
	IRECV_E_OUT_OF_MEMORY     = -2,
	IRECV_E_UNABLE_TO_CONNECT = -3,
	IRECV_E_INVALID_INPUT     = -4,
	IRECV_E_FILE_NOT_FOUND    = -5,
	IRECV_E_USB_UPLOAD        = -6,
	IRECV_E_USB_STATUS        = -7,
	IRECV_E_USB_INTERFACE     = -8,
	IRECV_E_USB_CONFIGURATION = -9,
	IRECV_E_PIPE              = -10,
	IRECV_E_TIMEOUT           = -11,
	IRECV_E_UNSUPPORTED       = -254,
	IRECV_E_UNKNOWN_ERROR     = -255
} irecv_error_t;

typedef enum {
	IRECV_RECEIVED            = 1,
	IRECV_PRECOMMAND          = 2,
	IRECV_POSTCOMMAND         = 3,
	IRECV_CONNECTED           = 4,
	IRECV_DISCONNECTED        = 5,
	IRECV_PROGRESS            = 6
} irecv_event_type;

typedef struct {
	int size;
	const char* data;
	double progress;
	irecv_event_type type;
} irecv_event_t;

struct irecv_device {
	const char* product_type;
	const char* hardware_model;
	unsigned int board_id;
	unsigned int chip_id;
	const char* display_name;
};
typedef struct irecv_device* irecv_device_t;

struct irecv_device_info {
	unsigned int cpid;
	unsigned int cprv;
	unsigned int cpfm;
	unsigned int scep;
	unsigned int bdid;
	uint64_t ecid;
	unsigned int ibfl;
	char* srnm;
	char* imei;
	char* srtg;
	char* serial_string;
	unsigned char* ap_nonce;
	unsigned int ap_nonce_size;
	unsigned char* sep_nonce;
	unsigned int sep_nonce_size;
	uint16_t pid;
	unsigned int have_cpid : 1;
	unsigned int have_cprv : 1;
	unsigned int have_cpfm : 1;
	unsigned int have_scep : 1;
	unsigned int have_bdid : 1;
	unsigned int have_ecid : 1;
	unsigned int have_ibfl : 1;
};

typedef enum {
	IRECV_DEVICE_ADD     = 1,
	IRECV_DEVICE_REMOVE  = 2
} irecv_device_event_type;

typedef struct {
	irecv_device_event_type type;
	enum irecv_mode mode;
	struct irecv_device_info *device_info;
} irecv_device_event_t;

typedef struct irecv_client_private irecv_client_private;
typedef irecv_client_private* irecv_client_t;

enum {
	IRECV_SEND_OPT_NONE              = 0,
	IRECV_SEND_OPT_DFU_NOTIFY_FINISH = (1 << 0),
	IRECV_SEND_OPT_DFU_FORCE_ZLP     = (1 << 1),
	IRECV_SEND_OPT_DFU_SMALL_PKT     = (1 << 2)
};

/* library */
IRECV_API void irecv_set_debug_level(int level);
IRECV_API const char* irecv_strerror(irecv_error_t error);

IRECV_API const char* irecv_version();

/* device connectivity */
IRECV_API irecv_error_t irecv_open_with_ecid(irecv_client_t* client, uint64_t ecid);
IRECV_API irecv_error_t irecv_open_with_ecid_and_attempts(irecv_client_t* pclient, uint64_t ecid, int attempts);
IRECV_API irecv_error_t irecv_reset(irecv_client_t client);
IRECV_API irecv_error_t irecv_close(irecv_client_t client);
IRECV_API irecv_client_t irecv_reconnect(irecv_client_t client, int initial_pause);

/* misc */
IRECV_API irecv_error_t irecv_receive(irecv_client_t client);
IRECV_API irecv_error_t irecv_execute_script(irecv_client_t client, const char* script);
IRECV_API irecv_error_t irecv_reset_counters(irecv_client_t client);
IRECV_API irecv_error_t irecv_finish_transfer(irecv_client_t client);
IRECV_API irecv_error_t irecv_trigger_limera1n_exploit(irecv_client_t client);

/* usb helpers */
IRECV_API irecv_error_t irecv_usb_set_configuration(irecv_client_t client, int configuration);
IRECV_API irecv_error_t irecv_usb_set_interface(irecv_client_t client, int usb_interface, int usb_alt_interface);
IRECV_API int irecv_usb_control_transfer(irecv_client_t client, uint8_t bm_request_type, uint8_t b_request, uint16_t w_value, uint16_t w_index, unsigned char *data, uint16_t w_length, unsigned int timeout);
IRECV_API int irecv_async_usb_control_transfer(irecv_client_t client, uint8_t bm_request_type, uint8_t b_request, uint16_t w_value, uint16_t w_index, unsigned char *data, uint16_t w_length);
IRECV_API int irecv_async_usb_control_transfer_with_cancel(irecv_client_t client, uint8_t bm_request_type, uint8_t b_request, uint16_t w_value, uint16_t w_index, unsigned char *data, uint16_t w_length, unsigned int u_time);
IRECV_API int irecv_usb_bulk_transfer(irecv_client_t client, unsigned char endpoint, unsigned char *data, int length, int *transferred, unsigned int timeout);
IRECV_API int irecv_usb_interrupt_transfer(irecv_client_t client, unsigned char endpoint, unsigned char *data, int length, int *transferred, unsigned int timeout);

/* events */
typedef void(*irecv_device_event_cb_t)(const irecv_device_event_t* event, void *user_data);
typedef struct irecv_device_event_context* irecv_device_event_context_t;
IRECV_API irecv_error_t irecv_device_event_subscribe(irecv_device_event_context_t *context, irecv_device_event_cb_t callback, void *user_data);
IRECV_API irecv_error_t irecv_device_event_unsubscribe(irecv_device_event_context_t context);
typedef int(*irecv_event_cb_t)(irecv_client_t client, const irecv_event_t* event);
IRECV_API irecv_error_t irecv_event_subscribe(irecv_client_t client, irecv_event_type type, irecv_event_cb_t callback, void *user_data);
IRECV_API irecv_error_t irecv_event_unsubscribe(irecv_client_t client, irecv_event_type type);

/* I/O */
IRECV_API irecv_error_t irecv_send_file(irecv_client_t client, const char* filename, unsigned int options);
IRECV_API irecv_error_t irecv_send_command(irecv_client_t client, const char* command);
IRECV_API irecv_error_t irecv_send_command_breq(irecv_client_t client, const char* command, uint8_t b_request);
IRECV_API irecv_error_t irecv_send_buffer(irecv_client_t client, unsigned char* buffer, unsigned long length, unsigned int options);
IRECV_API irecv_error_t irecv_recv_buffer(irecv_client_t client, char* buffer, unsigned long length);

/* commands */
IRECV_API irecv_error_t irecv_saveenv(irecv_client_t client);
IRECV_API irecv_error_t irecv_getenv(irecv_client_t client, const char* variable, char** value);
IRECV_API irecv_error_t irecv_setenv(irecv_client_t client, const char* variable, const char* value);
IRECV_API irecv_error_t irecv_setenv_np(irecv_client_t client, const char* variable, const char* value);
IRECV_API irecv_error_t irecv_reboot(irecv_client_t client);
IRECV_API irecv_error_t irecv_getret(irecv_client_t client, unsigned int* value);

/* device information */
IRECV_API irecv_error_t irecv_get_mode(irecv_client_t client, int* mode);
IRECV_API const struct irecv_device_info* irecv_get_device_info(irecv_client_t client);

/* device database queries */
IRECV_API irecv_device_t irecv_devices_get_all(void);
IRECV_API irecv_error_t irecv_devices_get_device_by_client(irecv_client_t client, irecv_device_t* device);
IRECV_API irecv_error_t irecv_devices_get_device_by_product_type(const char* product_type, irecv_device_t* device);
IRECV_API irecv_error_t irecv_devices_get_device_by_hardware_model(const char* hardware_model, irecv_device_t* device);

#ifdef __cplusplus
}
#endif

#endif
