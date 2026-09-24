/*-
 * Copyright (c) 2003-2010 Tim Kientzle
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * Minimal vendored header — only the API surface used by unarchive.m.
 * Linked against iOS system libarchive (-larchive).
 */

#ifndef ARCHIVE_H_INCLUDED
#define ARCHIVE_H_INCLUDED

#include <sys/types.h>
#include <stddef.h>
#include <stdint.h>
#include <unistd.h>

typedef int64_t la_int64_t;
typedef ssize_t la_ssize_t;

struct archive;
struct archive_entry;

/* Status codes */
#define ARCHIVE_EOF      1
#define ARCHIVE_OK       0
#define ARCHIVE_WARN    (-20)

/* Extract flags */
#define ARCHIVE_EXTRACT_TIME                  0x0004
#define ARCHIVE_EXTRACT_PERM                  0x0002
#define ARCHIVE_EXTRACT_ACL                   0x0020
#define ARCHIVE_EXTRACT_FFLAGS                0x0040
#define ARCHIVE_EXTRACT_SECURE_SYMLINKS       0x0100
#define ARCHIVE_EXTRACT_SECURE_NODOTDOT       0x0200
#define ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS 0x10000

/* Error string */
const char *archive_error_string(struct archive *);

/* Read API */
struct archive *archive_read_new(void);
int archive_read_support_format_all(struct archive *);
int archive_read_support_filter_all(struct archive *);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_block(struct archive *, const void **buf, size_t *size, la_int64_t *offset);
int archive_read_close(struct archive *);
int archive_read_free(struct archive *);

/* Write-to-disk API */
struct archive *archive_write_disk_new(void);
int archive_write_disk_set_options(struct archive *, int flags);
int archive_write_disk_set_standard_lookup(struct archive *);
int archive_write_header(struct archive *, struct archive_entry *);
int archive_write_data_block(struct archive *, const void *buf, size_t size, la_int64_t offset);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);

#endif /* !ARCHIVE_H_INCLUDED */
