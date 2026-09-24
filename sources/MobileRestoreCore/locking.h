/*
 * locking.h
 * locking extras header file
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
#ifndef LOCKING_H
#define LOCKING_H
#include <stdio.h>
#ifdef WIN32
#include <windows.h>
#else
#include <fcntl.h>
#endif

typedef struct {
#ifdef WIN32
	HANDLE fp;
	OVERLAPPED ldata;
#else
	FILE* fp;
	struct flock ldata;
#endif
} lock_info_t;

int lock_file(const char* filename, lock_info_t* lockp);
int unlock_file(lock_info_t* lockp);

#endif
