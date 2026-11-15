/*
 * DitKit xxHash128 流式包装层接口（供 Swift 调用）。
 *
 * 底层算法来自官方 xxHash v0.8.2（同目录的 xxhash.h / xxhash.c，BSD 2-Clause）。
 * 哈希值按官方约定输出：高 64 位在前、低 64 位在后，拼接成 32 位十六进制，
 * 与 `xxhsum -H2` 逐字节一致。
 */
#ifndef DitKit_xxhash_wrapper_h
#define DitKit_xxhash_wrapper_h

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void* DitKit_xxh128_create(void);
int   DitKit_xxh128_reset(void* state);
int   DitKit_xxh128_update(void* state, const void* data, size_t length);
void  DitKit_xxh128_digest(void* state, uint64_t* low, uint64_t* high);
void  DitKit_xxh128_free(void* state);

#ifdef __cplusplus
}
#endif

#endif /* DitKit_xxhash_wrapper_h */
