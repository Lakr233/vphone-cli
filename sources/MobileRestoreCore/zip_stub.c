#include "zip.h"

#include <errno.h>

struct zip {
	int unused;
};

struct zip_file {
	int unused;
};

struct zip_source {
	int unused;
};

zip_t* zip_open(const char* path, int flags, int* errorp)
{
	(void)path;
	(void)flags;
	if (errorp) {
		*errorp = ENOTSUP;
	}
	return NULL;
}

int zip_close(zip_t* archive)
{
	(void)archive;
	return 0;
}

int zip_unchange_all(zip_t* archive)
{
	(void)archive;
	return 0;
}

zip_int64_t zip_name_locate(zip_t* archive, const char* name, int flags)
{
	(void)archive;
	(void)name;
	(void)flags;
	return -1;
}

void zip_stat_init(zip_stat_t* st)
{
	if (!st) {
		return;
	}
	st->name = NULL;
	st->size = 0;
	st->comp_method = 0;
}

int zip_stat_index(zip_t* archive, zip_uint64_t index, int flags, zip_stat_t* st)
{
	(void)archive;
	(void)index;
	(void)flags;
	zip_stat_init(st);
	return -1;
}

int zip_stat(zip_t* archive, const char* name, int flags, zip_stat_t* st)
{
	(void)archive;
	(void)name;
	(void)flags;
	zip_stat_init(st);
	return -1;
}

zip_file_t* zip_fopen_index(zip_t* archive, zip_uint64_t index, int flags)
{
	(void)archive;
	(void)index;
	(void)flags;
	return NULL;
}

zip_int64_t zip_fread(zip_file_t* file, void* buffer, zip_uint64_t size)
{
	(void)file;
	(void)buffer;
	(void)size;
	return -1;
}

int zip_fclose(zip_file_t* file)
{
	(void)file;
	return 0;
}

void zip_file_error_get(zip_file_t* file, int* ze, int* se)
{
	(void)file;
	if (ze) {
		*ze = ENOTSUP;
	}
	if (se) {
		*se = ENOTSUP;
	}
}

zip_int64_t zip_get_num_entries(zip_t* archive, int flags)
{
	(void)archive;
	(void)flags;
	return 0;
}

int zip_file_get_external_attributes(zip_t* archive, zip_uint64_t index, int flags, uint8_t* opsys, uint32_t* attributes)
{
	(void)archive;
	(void)index;
	(void)flags;
	if (opsys) {
		*opsys = ZIP_OPSYS_UNIX;
	}
	if (attributes) {
		*attributes = 0;
	}
	return -1;
}

zip_int64_t zip_ftell(zip_file_t* file)
{
	(void)file;
	return -1;
}

int zip_fseek(zip_file_t* file, zip_int64_t offset, int whence)
{
	(void)file;
	(void)offset;
	(void)whence;
	return -1;
}

zip_source_t* zip_source_buffer(zip_t* archive, const void* data, zip_uint64_t length, int freep)
{
	(void)archive;
	(void)data;
	(void)length;
	(void)freep;
	return NULL;
}

int zip_file_replace(zip_t* archive, zip_uint64_t index, zip_source_t* source, int flags)
{
	(void)archive;
	(void)index;
	(void)source;
	(void)flags;
	return -1;
}

const char* zip_get_name(zip_t* archive, zip_uint64_t index, int flags)
{
	(void)archive;
	(void)index;
	(void)flags;
	return NULL;
}

int zip_delete(zip_t* archive, zip_uint64_t index)
{
	(void)archive;
	(void)index;
	return -1;
}

zip_int64_t zip_file_add(zip_t* archive, const char* name, zip_source_t* source, int flags)
{
	(void)archive;
	(void)name;
	(void)source;
	(void)flags;
	return -1;
}

void zip_source_free(zip_source_t* source)
{
	(void)source;
}

const char* zip_strerror(zip_t* archive)
{
	(void)archive;
	return "zip support unavailable in vphone-cli directory-only restore mode";
}
