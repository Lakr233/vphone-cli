/*
 * locking.c
 * locking extras
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
#ifdef WIN32
#include <windows.h>
#else
#include <errno.h>
#endif

#include "locking.h"
#include "common.h"

int lock_file(const char* filename, lock_info_t* lockinfo)
{
	if (!lockinfo) {
		return -1;
	}
#ifdef WIN32
	lockinfo->fp = CreateFile(filename, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
	if (lockinfo->fp == INVALID_HANDLE_VALUE) {
		logger(LL_DEBUG, "ERROR: could not open or create lockfile '%s'\n", filename);
		return -1;
	}

	lockinfo->ldata.Offset = 0;
	lockinfo->ldata.OffsetHigh = 0;

	if (!LockFileEx(lockinfo->fp, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &lockinfo->ldata)) {
		logger(LL_DEBUG, "ERROR: can't lock file, error %d\n", GetLastError());
		CloseHandle(lockinfo->fp);
		lockinfo->fp = INVALID_HANDLE_VALUE;
		return -1;
	}
#else
	lockinfo->fp = fopen(filename, "a+");

	if (!lockinfo->fp) {
		logger(LL_DEBUG, "ERROR: could not open or create lockfile '%s'\n", filename);
		return -1;
	}

	lockinfo->ldata.l_type = F_WRLCK;
	lockinfo->ldata.l_whence = SEEK_SET;
	lockinfo->ldata.l_start = 0;
	lockinfo->ldata.l_len = 0;

	if (fcntl(fileno(lockinfo->fp), F_SETLKW, &lockinfo->ldata) < 0) {
		logger(LL_DEBUG, "ERROR: can't lock file, error %d\n", errno);
		fclose(lockinfo->fp);
		lockinfo->fp = NULL;
		return -1;
	}
#endif
	return 0;
}

int unlock_file(lock_info_t* lockinfo)
{
	if (!lockinfo) {
		return -1;
	}
#ifdef WIN32
	if (lockinfo->fp == INVALID_HANDLE_VALUE) {
		return -1;
	}

	lockinfo->ldata.Offset = 0;
	lockinfo->ldata.OffsetHigh = 0;

	if (!UnlockFileEx(lockinfo->fp, 0, 1, 0, &lockinfo->ldata)) {
		logger(LL_DEBUG, "ERROR: can't unlock file, error %d\n", GetLastError());
		CloseHandle(lockinfo->fp);
		lockinfo->fp = INVALID_HANDLE_VALUE;
		return -1;
	}
	CloseHandle(lockinfo->fp);
	lockinfo->fp = INVALID_HANDLE_VALUE;
#else
	if (!lockinfo->fp) {
		return -1;
	}

	lockinfo->ldata.l_type = F_UNLCK;
	lockinfo->ldata.l_whence = SEEK_SET;
	lockinfo->ldata.l_start = 0;
	lockinfo->ldata.l_len = 0;

	if (fcntl(fileno(lockinfo->fp), F_SETLK, &lockinfo->ldata) < 0) {
		logger(LL_DEBUG, "ERROR: can't unlock file, error %d\n", errno);
		fclose(lockinfo->fp);
		lockinfo->fp = NULL;
		return -1;
	}
	fclose(lockinfo->fp);
	lockinfo->fp = NULL;
#endif
	return 0;
}

