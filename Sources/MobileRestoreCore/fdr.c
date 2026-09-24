/*
 * fdr.c
 * Connection proxy service used by FDR
 *
 * Copyright (c) 2014 BALATON Zoltan. All Rights Reserved.
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

#include <sys/types.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice-glue/socket.h>

#include "common.h"
#include "idevicerestore.h"
#include "fdr.h"
#include <endianness.h> /* from libimobiledevice */

#define CTRL_PORT 0x43a /*1082*/
#define CTRLCMD  "BeginCtrl"
#define HELLOCTRLCMD "HelloCtrl"
#define HELLOCMD "HelloConn"

#define FDR_SYNC_MSG  0x1
#define FDR_PROXY_MSG 0x105
#define FDR_PLIST_MSG 0xbbaa

static uint64_t conn_port;
static int ctrlprotoversion = 2;
static int serial;

static int fdr_receive_plist(fdr_client_t fdr, plist_t* data);
static int fdr_send_plist(fdr_client_t fdr, plist_t data);
static int fdr_ctrl_handshake(fdr_client_t fdr);
static int fdr_sync_handshake(fdr_client_t fdr);
static int fdr_handle_sync_cmd(fdr_client_t fdr);
static int fdr_handle_plist_cmd(fdr_client_t fdr);
static int fdr_handle_proxy_cmd(fdr_client_t fdr);

int fdr_connect(idevice_t device, fdr_type_t type, fdr_client_t* fdr)
{
	int res = -1, i = 0;
	int attempts = 10;
	idevice_connection_t connection = NULL;
	idevice_error_t device_error = IDEVICE_E_SUCCESS;
	uint16_t port = (type == FDR_CONN ? conn_port : CTRL_PORT);

	*fdr = NULL;

	logger(LL_DEBUG, "Connecting to FDR client at port %u\n", port);

	for (i = 1; i <= attempts; i++) {
		device_error = idevice_connect(device, port, &connection);
		if (device_error == IDEVICE_E_SUCCESS) {
			break;
		}

		if (i >= attempts) {
			logger(LL_ERROR, "Unable to connect to FDR client (%d)\n", device_error);
			return -1;
		}

		sleep(2);
		logger(LL_DEBUG, "Retrying connection...\n");
	}

	fdr_client_t fdr_loc = calloc(1, sizeof(struct fdr_client));
	if (!fdr_loc) {
		logger(LL_ERROR, "Unable to allocate memory\n");
		return -1;
	}
	fdr_loc->connection = connection;
	fdr_loc->device = device;
	fdr_loc->type = type;

	/* Do handshake */
	if (type == FDR_CTRL)
		res = fdr_ctrl_handshake(fdr_loc);
	else if (type == FDR_CONN)
		res = fdr_sync_handshake(fdr_loc);

	if (res) {
		fdr_free(fdr_loc);
		return -1;
	}

	*fdr = fdr_loc;

	return 0;
}

void fdr_disconnect(fdr_client_t fdr)
{
	if (!fdr)
		return;

	if (fdr->connection) {
		idevice_connection_t conn = fdr->connection;
		fdr->connection = NULL;
		idevice_disconnect(conn);
	}
}

void fdr_free(fdr_client_t fdr)
{
	if (!fdr)
		return;

	fdr_disconnect(fdr);

	free(fdr);
	fdr = NULL;
}

int fdr_poll_and_handle_message(fdr_client_t fdr)
{
	idevice_error_t device_error = IDEVICE_E_SUCCESS;
	uint32_t bytes = 0;
	uint16_t cmd;

	if (!fdr) {
		logger(LL_ERROR, "Invalid FDR client\n");
		return -1;
	}

	device_error = idevice_connection_receive_timeout(fdr->connection, (char *)&cmd, sizeof(cmd), &bytes, 20000);
#ifdef HAVE_IDEVICE_E_TIMEOUT
	if (device_error == IDEVICE_E_TIMEOUT || (device_error == IDEVICE_E_SUCCESS && bytes != sizeof(cmd)))
#else
	if (device_error == IDEVICE_E_SUCCESS && bytes != sizeof(cmd))
#endif
	{
		logger(LL_DEBUG, "FDR %p timeout waiting for command\n", fdr);
		return 0;
	}
	else if (device_error != IDEVICE_E_SUCCESS) {
		if (fdr->connection) {
			logger(LL_ERROR, "Unable to receive message from FDR %p (%d). %u/%u bytes\n", fdr, device_error, bytes, (uint32_t)sizeof(cmd));
		}
		return -1;
	}

	if (cmd == FDR_SYNC_MSG) {
		logger(LL_DEBUG, "FDR %p got sync message\n", fdr);
		return fdr_handle_sync_cmd(fdr);
	}

	if (cmd == FDR_PROXY_MSG) {
		logger(LL_DEBUG, "FDR %p got proxy message\n", fdr);
		return fdr_handle_proxy_cmd(fdr);
	}

	if (cmd == FDR_PLIST_MSG) {
		logger(LL_DEBUG, "FDR %p got plist message\n", fdr);
		return fdr_handle_plist_cmd(fdr);
	}

	logger(LL_WARNING, "FDR %p received unknown packet %#x of size %u\n", fdr, cmd, bytes);
	return 0;
}

void *fdr_listener_thread(void *cdata)
{
	fdr_client_t fdr = cdata;
	int res = 0;

	while (fdr && fdr->connection) {
		logger(LL_DEBUG, "FDR %p waiting for message...\n", fdr);
		res = fdr_poll_and_handle_message(fdr);
		if (fdr->type == FDR_CTRL && res >= 0)
			continue; // main thread should always retry
		if (res != 0)
			break;
	}
	logger(LL_DEBUG, "FDR %p terminating...\n", fdr);
	fdr_free(fdr);
	return (void *)(intptr_t)res;
}

static int fdr_receive_plist(fdr_client_t fdr, plist_t* data)
{
	idevice_error_t device_error = IDEVICE_E_SUCCESS;
	uint32_t len, bytes = 0;
	char* buf = NULL;

	device_error = idevice_connection_receive(fdr->connection, (char*)&len, sizeof(len), &bytes);
	if (device_error != IDEVICE_E_SUCCESS) {
		logger(LL_ERROR, "Unable to receive packet length from FDR (%d)\n", device_error);
		return -1;
	}

	buf = calloc(1, len);
	if (!buf) {
		logger(LL_ERROR, "Unable to allocate memory for FDR receive buffer\n");
		return -1;
	}

	device_error = idevice_connection_receive(fdr->connection, buf, len, &bytes);
	if (device_error != IDEVICE_E_SUCCESS) {
		logger(LL_ERROR, "Unable to receive data from FDR\n");
		free(buf);
		return -1;
	}
	plist_from_bin(buf, bytes, data);
	free(buf);

	logger(LL_DEBUG, "FDR Received %d bytes\n", bytes);

	return 0;
}

static int fdr_send_plist(fdr_client_t fdr, plist_t data)
{
	idevice_error_t device_error = IDEVICE_E_SUCCESS;
	char *buf = NULL;
	uint32_t len = 0, bytes = 0;

	if (!data)
		return -1;

	plist_to_bin(data, &buf, &len);
	if (!buf)
		return -1;

	logger(LL_DEBUG, "FDR sending %d bytes:\n", len);
	logger_dump_plist(LL_DEBUG, data, 1);
	device_error = idevice_connection_send(fdr->connection, (char *)&len, sizeof(len), &bytes);
	if (device_error != IDEVICE_E_SUCCESS || bytes != sizeof(len)) {
		logger(LL_ERROR, "FDR unable to send data length. (%d) Sent %u of %u bytes.\n",
		      device_error, bytes, (uint32_t)sizeof(len));
		free(buf);
		return -1;
	}
	device_error = idevice_connection_send(fdr->connection, buf, len, &bytes);
	free(buf);
	if (device_error != IDEVICE_E_SUCCESS || bytes != len) {
		logger(LL_ERROR, "FDR unable to send data (%d). Sent %u of %u bytes.\n",
		      device_error, bytes, len);
		return -1;
	}

	logger(LL_DEBUG, "FDR Sent %d bytes\n", bytes);
	return 0;
}

static int fdr_ctrl_handshake(fdr_client_t fdr)
{
	idevice_error_t device_error = IDEVICE_E_SUCCESS;
	uint32_t bytes = 0, len = sizeof(CTRLCMD);
	plist_t dict, node;
	int res;

	logger(LL_DEBUG, "About to do ctrl handshake\n");

	ctrlprotoversion = 2;

	device_error = idevice_connection_send(fdr->connection, CTRLCMD, len, &bytes);
	if (device_error != IDEVICE_E_SUCCESS || bytes != len) {
		logger(LL_DEBUG, "Hmm... looks like the device doesn't like the newer protocol, using the old one\n");
		ctrlprotoversion = 1;
		len = sizeof(HELLOCTRLCMD);
		device_error = idevice_connection_send(fdr->connection, HELLOCTRLCMD, len, &bytes);
		if (device_error != IDEVICE_E_SUCCESS || bytes != len) {
			logger(LL_ERROR, "FDR unable to send BeginCtrl. Sent %u of %u bytes.\n", bytes, len);
			return -1;
		}
	}

	if (ctrlprotoversion == 2) {
		dict = plist_new_dict();
		plist_dict_set_item(dict, "Command", plist_new_string(CTRLCMD));
		plist_dict_set_item(dict, "CtrlProtoVersion", plist_new_uint(ctrlprotoversion));
		res = fdr_send_plist(fdr, dict);
		plist_free(dict);
		if (res) {
			logger(LL_ERROR, "FDR could not send Begin command.\n");
			return -1;
		}

		if (fdr_receive_plist(fdr, &dict)) {
			logger(LL_ERROR, "FDR did not get Begin command reply.\n");
			return -1;
		}
		logger_dump_plist(LL_DEBUG, dict, 1);
		node = plist_dict_get_item(dict, "ConnPort");
		if (node && plist_get_node_type(node) == PLIST_UINT) {
			plist_get_uint_val(node, &conn_port);
		} else {
			logger(LL_ERROR, "Could not get FDR ConnPort value\n");
			return -1;
		}

		plist_free(dict);
	} else {
		char buf[16];
		uint16_t cport = 0;

		memset(buf, '\0', sizeof(buf));

		bytes = 0;
		device_error = idevice_connection_receive(fdr->connection, buf, 10, &bytes);
		if (device_error != IDEVICE_E_SUCCESS) {
			logger(LL_ERROR, "Could not receive reply to HelloCtrl command\n");
			return -1;
		}
		if (memcmp(buf, "HelloCtrl", 10) != 0) {
			buf[9] = '\0';
			logger(LL_ERROR, "Did not receive HelloCtrl as reply, but %s\n", buf);
			return -1;
		}

		bytes = 0;
		device_error = idevice_connection_receive(fdr->connection, (char*)&cport, 2, &bytes);
		if (device_error != IDEVICE_E_SUCCESS) {
			logger(LL_ERROR, "Failed to receive conn port\n");
			return -1;
		}

		conn_port = le16toh(cport);
	}

	logger(LL_DEBUG, "Ctrl handshake done (ConnPort = %" PRIu64 ")\n", (uint64_t)conn_port);

	return 0;
}

static int fdr_sync_handshake(fdr_client_t fdr)
{
	idevice_error_t device_error = IDEVICE_E_SUCCESS;
	uint32_t bytes = 0, len = sizeof(HELLOCMD);
	plist_t reply;

	device_error = idevice_connection_send(fdr->connection, HELLOCMD, len, &bytes);
	if (device_error != IDEVICE_E_SUCCESS || bytes != len) {
		logger(LL_ERROR, "FDR unable to send Hello. Sent %u of %u bytes.\n", bytes, len);
		return -1;
	}

	if (ctrlprotoversion == 2) {
		if (fdr_receive_plist(fdr, &reply)) {
			logger(LL_ERROR, "FDR did not get HelloConn reply.\n");
			return -1;
		}
		char* identifier = NULL;
		char* cmd = NULL;
		plist_t node = NULL;
		node = plist_dict_get_item(reply, "Command");
		if (node) {
			plist_get_string_val(node, &cmd);
		}
		node = plist_dict_get_item(reply, "Identifier");
		if (node) {
			plist_get_string_val(node, &identifier);
		}
		plist_free(reply);

		if (!cmd || (strcmp(cmd, "HelloConn") != 0)) {
			if (cmd) {
				free(cmd);
			}
			if (identifier) {
				free(identifier);
			}
			logger(LL_ERROR, "Did not receive HelloConn reply...\n");
			return -1;
		}
		free(cmd);

		if (identifier) {
			logger(LL_DEBUG, "Got device identifier %s\n", identifier);
			free(identifier);
		}

	} else {
		char buf[16];
		memset(buf, '\0', sizeof(buf));
		bytes = 0;
		device_error = idevice_connection_receive(fdr->connection, buf, 10, &bytes);
		if (device_error != IDEVICE_E_SUCCESS) {
			logger(LL_ERROR, "Could not receive reply to HelloConn command\n");
			return -1;
		}
		if (memcmp(buf, "HelloConn", 10) != 0) {
			buf[9] = '\0';
			logger(LL_ERROR, "Did not receive HelloConn as reply, but %s\n", buf);
			return -1;
		}
	}

	return 0;
}

static int fdr_handle_sync_cmd(fdr_client_t fdr_ctrl)
{
	idevice_error_t device_error = IDEVICE_E_SUCCESS;
	fdr_client_t fdr;
	THREAD_T fdr_thread = THREAD_T_NULL;
	int res = 0;
	uint32_t bytes = 0;
	char buf[4096];

	device_error = idevice_connection_receive(fdr_ctrl->connection, buf, sizeof(buf), &bytes);
	if (device_error != IDEVICE_E_SUCCESS || bytes != 2) {
		logger(LL_ERROR, "Unexpected data from FDR\n");
		return -1;
	}
	/* Open a new connection and wait for messages on it */
	if (fdr_connect(fdr_ctrl->device, FDR_CONN, &fdr)) {
		logger(LL_ERROR, "Failed to connect to FDR port\n");
		return -1;
	}
	logger(LL_DEBUG, "FDR connected in reply to sync message, starting command thread\n");
	res = thread_new(&fdr_thread, fdr_listener_thread, fdr);
	if(res) {
		logger(LL_ERROR, "Failed to start FDR command thread\n");
		fdr_free(fdr);
	}
	return res;
}

static int fdr_handle_plist_cmd(fdr_client_t fdr)
{
	int res = 0;
	plist_t dict;

	if (fdr_receive_plist(fdr, &dict)) {
		logger(LL_ERROR, "FDR %p could not receive plist command.\n", fdr);
		return -1;
	}
	plist_t node = plist_dict_get_item(dict, "Command");
	if (!node || (plist_get_node_type(node) != PLIST_STRING)) {
		logger(LL_ERROR, "FDR %p Could not find Command in plist command\n", fdr);
		plist_free(dict);
		return -1;
	}
	char *command = NULL;
	plist_get_string_val(node, &command);
	plist_free(dict);

	if (!command) {
		logger(LL_INFO, "FDR %p received empty plist command\n", fdr);
		return -1;
	}

	if (!strcmp(command, "Ping")) {
		dict = plist_new_dict();
		plist_dict_set_item(dict, "Pong", plist_new_bool(1));
		res = fdr_send_plist(fdr, dict);
		plist_free(dict);
		if (res) {
			logger(LL_ERROR, "FDR %p could not send Ping command reply.\n", fdr);
			free(command);
			return -1;
		}
	} else {
		logger(LL_WARNING, "FDR %p received unknown plist command: %s\n", fdr, command);
		free(command);
		return -1;
	}

	free(command);
	/* FDR connection will be terminated remotely. Next receive will get nothing, error and terminate this worker thread. */
	return 0;
}

static int fdr_handle_proxy_cmd(fdr_client_t fdr)
{
	idevice_error_t device_error = IDEVICE_E_SUCCESS;
	char *buf = NULL;
	size_t bufsize = 1048576;
	uint32_t sent = 0, bytes = 0;
	char *host = NULL;
	uint16_t port = 0;

	buf = malloc(bufsize);
	if (!buf) {
		logger(LL_ERROR, "%s: malloc failed\n", __func__);
		return -1;
	}

	device_error = idevice_connection_receive(fdr->connection, buf, bufsize, &bytes);
	if (device_error != IDEVICE_E_SUCCESS) {
		free(buf);
		logger(LL_ERROR, "FDR %p failed to read data for proxy command\n", fdr);
		return -1;
	}
	logger(LL_DEBUG, "Got proxy command with %u bytes\n", bytes);

	/* Just return success here unconditionally because we don't know
	 * anything else and we will eventually abort on failure anyway */
	uint16_t ack = 5;
	device_error = idevice_connection_send(fdr->connection, (char *)&ack, sizeof(ack), &sent);
	if (device_error != IDEVICE_E_SUCCESS || sent != sizeof(ack)) {
		free(buf);
		logger(LL_ERROR, "FDR %p unable to send ack. Sent %u of %u bytes.\n",
		      fdr, sent, (uint32_t)sizeof(ack));
		return -1;
	}

	if (bytes < 3) {
		logger(LL_DEBUG, "FDR %p proxy command data too short, retrying\n", fdr);
		return fdr_poll_and_handle_message(fdr);
	}

	/* ack command data too */
	device_error = idevice_connection_send(fdr->connection, buf, bytes, &sent);
	if (device_error != IDEVICE_E_SUCCESS || sent != bytes) {
		free(buf);
		logger(LL_ERROR, "FDR %p unable to send data. Sent %u of %u bytes.\n",
		      fdr, sent, bytes);
		return -1;
	}

	/* Now try to handle actual messages */
	/* Connect: 0 3 hostlen <host> <port> */
	if (buf[0] == 0 && buf[1] == 3) {
		uint16_t *p = (uint16_t *)&buf[bytes - 2];
		port = be16toh(*p);
		buf[bytes - 2] = '\0';
		host = strdup(&buf[3]);
		logger(LL_DEBUG, "FDR %p Proxy connect request to %s:%u\n", fdr, host, port);
	}

	if (!host || !buf[2]) {
		/* missing or zero length host name */
		free(buf);
		return 0;
	}

	/* else wait for messages and forward them */
	int sockfd = socket_connect(host, port);
	free(host);
	if (sockfd < 0) {
		free(buf);
		logger(LL_ERROR, "Failed to connect socket: %s\n", strerror(errno));
		return -1;
	}

	int res = 0, bytes_ret;
	while (1) {
		bytes = 0;
		device_error = idevice_connection_receive_timeout(fdr->connection, buf, bufsize, &bytes, 100);
#ifdef HAVE_IDEVICE_E_TIMEOUT
		if (device_error == IDEVICE_E_TIMEOUT || (device_error == IDEVICE_E_SUCCESS && !bytes))
#else
		if (device_error == IDEVICE_E_SUCCESS && !bytes)
#endif
		{
			//logger(LL_DEBUG, "Timeout waiting for proxy payload. %p\n", fdr);
		}
		else if (device_error != IDEVICE_E_SUCCESS) {
			logger(LL_ERROR, "FDR %p Unable to receive proxy payload (%d)\n", fdr, device_error);
			res = -1;
			break;
		}
		if (bytes) {
			logger(LL_DEBUG, "FDR %p got payload of %u bytes, now trying to proxy it\n", fdr, bytes);
			logger(LL_DEBUG, "Sending %u bytes of data\n", bytes);
			sent = 0;
			while (sent < bytes) {
				int s = socket_send(sockfd, buf + sent, bytes - sent);
				if (s < 0) {
					break;
				}
				sent += s;
			}
			if (sent != bytes) {
				logger(LL_ERROR, "Sending proxy payload failed: %s. Sent %u of %u bytes. \n", strerror(errno), sent, bytes);
				socket_close(sockfd);
				res = -1;
				break;
			}
		}
		bytes_ret = socket_receive_timeout(sockfd, buf, bufsize, 0, 100);
		if (bytes_ret == -ETIMEDOUT) {
			bytes_ret = 0;
		} else if (bytes_ret == -ECONNRESET) {
			res = 1;
			break;
		} else if (bytes_ret < 0) {
			logger(LL_ERROR, "FDR %p receiving proxy payload failed: %d (%s)\n",
			      fdr, bytes_ret, strerror(-bytes_ret));
			break;
		}

		bytes = bytes_ret;
		if (bytes) {
			logger(LL_DEBUG, "FDR %p Received %u bytes reply data,%s sending to device\n",
			      fdr, bytes, (bytes ? "" : " not"));

			sent = 0;
			while (sent < bytes) {
				uint32_t s;
				device_error = idevice_connection_send(fdr->connection, buf + sent, bytes - sent, &s);
				if (device_error != IDEVICE_E_SUCCESS) {
					break;
				}
				sent += s;
			}
			if (device_error != IDEVICE_E_SUCCESS || bytes != sent) {
				logger(LL_ERROR, "FDR %p unable to send data (%d). Sent %u of %u bytes.\n", fdr, device_error, sent, bytes);
				res = -1;
				break;
			}
		} else serial++;
	}
	socket_close(sockfd);
	free(buf);
	return res;
}
