#ifndef ENDIANNESS_H
#define ENDIANNESS_H

#ifndef __LITTLE_ENDIAN
#define __LITTLE_ENDIAN 1234
#endif

#ifndef __BIG_ENDIAN
#define __BIG_ENDIAN 4321
#endif

#ifndef __BYTE_ORDER
#ifdef __LITTLE_ENDIAN__
#define __BYTE_ORDER __LITTLE_ENDIAN
#else
#ifdef __BIG_ENDIAN__
#define __BYTE_ORDER __BIG_ENDIAN
#endif
#endif
#endif

#ifndef __BYTE_ORDER
#ifndef _WIN32
#warning __BYTE_ORDER is not defined, assuming little endian
#endif
#define __BYTE_ORDER __LITTLE_ENDIAN
#endif

#ifndef be16toh
#if __BYTE_ORDER == __BIG_ENDIAN
#define be16toh(x) (x)
#else
#define be16toh(x) ((((x) & 0xFF00) >> 8) | (((x) & 0x00FF) << 8))
#endif
#endif

#ifndef htobe16
#define htobe16 be16toh
#endif

#ifndef le16toh
#if __BYTE_ORDER == __BIG_ENDIAN
#define le16toh(x) ((((x) & 0xFF00) >> 8) | (((x) & 0x00FF) << 8))
#else
#define le16toh(x) (x)
#endif
#endif

#ifndef htole16
#define htole16 le16toh
#endif

#ifndef __bswap_32
#define __bswap_32(x) ((((x) & 0xFF000000) >> 24) \
                    | (((x) & 0x00FF0000) >> 8) \
                    | (((x) & 0x0000FF00) << 8) \
                    | (((x) & 0x000000FF) << 24))
#endif

#ifndef be32toh
#if __BYTE_ORDER == __BIG_ENDIAN
#define be32toh(x) (x)
#else
#define be32toh(x) __bswap_32(x)
#endif
#endif

#ifndef htobe32
#define htobe32 be32toh
#endif

#ifndef le32toh
#if __BYTE_ORDER == __BIG_ENDIAN
#define le32toh(x) __bswap_32(x)
#else
#define le32toh(x) (x)
#endif
#endif

#ifndef htole32
#define htole32 le32toh
#endif

#ifndef __bswap_64
#define __bswap_64(x) ((((x) & 0xFF00000000000000ull) >> 56) \
                    | (((x) & 0x00FF000000000000ull) >> 40) \
                    | (((x) & 0x0000FF0000000000ull) >> 24) \
                    | (((x) & 0x000000FF00000000ull) >> 8) \
                    | (((x) & 0x00000000FF000000ull) << 8) \
                    | (((x) & 0x0000000000FF0000ull) << 24) \
                    | (((x) & 0x000000000000FF00ull) << 40) \
                    | (((x) & 0x00000000000000FFull) << 56))
#endif

#ifndef htobe64
#if __BYTE_ORDER == __BIG_ENDIAN
#define htobe64(x) (x)
#else
#define htobe64(x) __bswap_64(x)
#endif
#endif

#ifndef be64toh
#define be64toh htobe64
#endif

#ifndef le64toh
#if __BYTE_ORDER == __LITTLE_ENDIAN
#define le64toh(x) (x)
#else
#define le64toh(x) __bswap_64(x)
#endif
#endif

#ifndef htole64
#define htole64 le64toh
#endif

#if (defined(__BIG_ENDIAN__) \
     && !defined(__FLOAT_WORD_ORDER__)) \
 || (defined(__FLOAT_WORD_ORDER__) \
     && __FLOAT_WORD_ORDER__ == __ORDER_BIG_ENDIAN__)
#define float_bswap64(x) __bswap_64(x)
#define float_bswap32(x) __bswap_32(x)
#else
#define float_bswap64(x) (x)
#define float_bswap32(x) (x)
#endif

#endif /* ENDIANNESS_H */
