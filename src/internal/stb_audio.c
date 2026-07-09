#include <stddef.h>
#include <stdlib.h>

extern void* c_alloc(size_t len);
extern void* c_realloc(void* ptr, size_t len);
extern void c_free(void* ptr);

#define malloc(len) c_alloc(len)
#define realloc(ptr, len) c_realloc(ptr, len)
#define free(ptr) c_free(ptr)

#define STB_VORBIS_NO_PUSHDATA_API
#define STB_VORBIS_NO_INTEGER_CONVERSION
#define STB_VORBIS_NO_STDIO

#include "stb_vorbis.c"
