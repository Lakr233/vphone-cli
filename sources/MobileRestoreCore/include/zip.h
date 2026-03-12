#ifndef VPHONE_ZIP_STUB_H
#define VPHONE_ZIP_STUB_H

#include <stdint.h>

typedef int64_t zip_int64_t;
typedef uint64_t zip_uint64_t;

struct zip;
struct zip_file;
struct zip_source;

typedef struct zip zip_t;
typedef struct zip_file zip_file_t;
typedef struct zip_source zip_source_t;

typedef struct zip_stat {
	const char* name;
	zip_uint64_t size;
	int comp_method;
} zip_stat_t;

#define ZIP_OPSYS_UNIX 3
#define ZIP_CM_STORE 0
#define ZIP_FL_OVERWRITE 0

zip_t* zip_open(const char* path, int flags, int* errorp);
int zip_close(zip_t* archive);
int zip_unchange_all(zip_t* archive);
zip_int64_t zip_name_locate(zip_t* archive, const char* name, int flags);
void zip_stat_init(zip_stat_t* st);
int zip_stat_index(zip_t* archive, zip_uint64_t index, int flags, zip_stat_t* st);
int zip_stat(zip_t* archive, const char* name, int flags, zip_stat_t* st);
zip_file_t* zip_fopen_index(zip_t* archive, zip_uint64_t index, int flags);
zip_int64_t zip_fread(zip_file_t* file, void* buffer, zip_uint64_t size);
int zip_fclose(zip_file_t* file);
void zip_file_error_get(zip_file_t* file, int* ze, int* se);
zip_int64_t zip_get_num_entries(zip_t* archive, int flags);
int zip_file_get_external_attributes(zip_t* archive, zip_uint64_t index, int flags, uint8_t* opsys, uint32_t* attributes);
zip_int64_t zip_ftell(zip_file_t* file);
int zip_fseek(zip_file_t* file, zip_int64_t offset, int whence);
zip_source_t* zip_source_buffer(zip_t* archive, const void* data, zip_uint64_t length, int freep);
int zip_file_replace(zip_t* archive, zip_uint64_t index, zip_source_t* source, int flags);
const char* zip_get_name(zip_t* archive, zip_uint64_t index, int flags);
int zip_delete(zip_t* archive, zip_uint64_t index);
zip_int64_t zip_file_add(zip_t* archive, const char* name, zip_source_t* source, int flags);
void zip_source_free(zip_source_t* source);
const char* zip_strerror(zip_t* archive);

#endif
