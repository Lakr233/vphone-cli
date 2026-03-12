#include "vphone_restore_bridge.h"

#include <libirecovery.h>
#include <unistd.h>

static int vphone_irecv_mode_matches(int expected_mode, int actual_mode)
{
	switch (expected_mode) {
	case VPHONE_IRECV_MODE_ANY:
		return 1;
	case VPHONE_IRECV_MODE_DFU:
		return (actual_mode == IRECV_K_DFU_MODE) || (actual_mode == IRECV_K_PORT_DFU_MODE);
	case VPHONE_IRECV_MODE_RECOVERY:
		return (actual_mode == IRECV_K_RECOVERY_MODE_1) ||
			(actual_mode == IRECV_K_RECOVERY_MODE_2) ||
			(actual_mode == IRECV_K_RECOVERY_MODE_3) ||
			(actual_mode == IRECV_K_RECOVERY_MODE_4);
	default:
		return 0;
	}
}

static irecv_error_t vphone_irecv_open_checked(irecv_client_t* client, uint64_t ecid, int has_ecid, int expected_mode, int attempts)
{
	irecv_error_t error = irecv_open_with_ecid_and_attempts(client, has_ecid ? ecid : 0, attempts);
	if (error != IRECV_E_SUCCESS) {
		return error;
	}

	int actual_mode = 0;
	error = irecv_get_mode(*client, &actual_mode);
	if (error != IRECV_E_SUCCESS) {
		irecv_close(*client);
		*client = NULL;
		return error;
	}
	if (!vphone_irecv_mode_matches(expected_mode, actual_mode)) {
		irecv_close(*client);
		*client = NULL;
		return IRECV_E_UNSUPPORTED;
	}

	return IRECV_E_SUCCESS;
}

const char* vphone_irecv_error_string(int error)
{
	return irecv_strerror((irecv_error_t)error);
}

int vphone_irecv_send_file(const char* path, uint64_t ecid, int has_ecid, int mode, uint32_t options)
{
	if (!path || !path[0]) {
		return IRECV_E_INVALID_INPUT;
	}

	irecv_client_t client = NULL;
	irecv_error_t error = vphone_irecv_open_checked(&client, ecid, has_ecid, mode, 10);
	if (error != IRECV_E_SUCCESS) {
		return error;
	}

	error = irecv_send_file(client, path, options);
	irecv_close(client);
	return error;
}

int vphone_irecv_send_command(const char* command, uint64_t ecid, int has_ecid, int mode)
{
	if (!command || !command[0]) {
		return IRECV_E_INVALID_INPUT;
	}

	irecv_client_t client = NULL;
	irecv_error_t error = vphone_irecv_open_checked(&client, ecid, has_ecid, mode, 10);
	if (error != IRECV_E_SUCCESS) {
		return error;
	}

	error = irecv_send_command(client, command);
	irecv_close(client);
	return error;
}

int vphone_irecv_wait_for_mode(uint64_t ecid, int has_ecid, int mode, int timeout_ms)
{
	const useconds_t interval_us = 250000;
	int remaining_ms = timeout_ms;

	while (remaining_ms >= 0) {
		irecv_client_t client = NULL;
		irecv_error_t error = vphone_irecv_open_checked(&client, ecid, has_ecid, mode, 1);
		if (error == IRECV_E_SUCCESS) {
			irecv_close(client);
			return IRECV_E_SUCCESS;
		}
		if (client) {
			irecv_close(client);
		}
		if (remaining_ms == 0) {
			break;
		}
		usleep(interval_us);
		if (remaining_ms < 250) {
			remaining_ms = 0;
		} else {
			remaining_ms -= 250;
		}
	}

	return IRECV_E_TIMEOUT;
}
