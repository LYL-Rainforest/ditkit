/*
 * DitKit xxHash128 流式包装层实现。
 *
 * 仅依赖官方 xxhash.h / xxhash.c（v0.8.2，BSD 2-Clause，vendored 于同目录）。
 * xxhash.c 已用 XXH_IMPLEMENTATION 实例化全部函数体；本文件只声明并封装
 * 一个简洁、ABI 安全的流式接口给 Swift 调用，避免直接暴露庞大的官方头。
 */

#include "xxhash.h"
#include "xxhash_wrapper.h"
#include <stdlib.h>

void* DitKit_xxh128_create(void) {
    return XXH3_createState();
}

int DitKit_xxh128_reset(void* state) {
    if (state == NULL) return -1;
    return XXH3_128bits_reset((XXH3_state_t*)state);
}

int DitKit_xxh128_update(void* state, const void* data, size_t length) {
    if (state == NULL) return -1;
    return XXH3_128bits_update((XXH3_state_t*)state, data, length);
}

void DitKit_xxh128_digest(void* state, uint64_t* low, uint64_t* high) {
    if (state == NULL) { if (low) *low = 0; if (high) *high = 0; return; }
    XXH128_hash_t h = XXH3_128bits_digest((XXH3_state_t*)state);
    if (low)  *low  = (uint64_t)h.low64;
    if (high) *high = (uint64_t)h.high64;
}

void DitKit_xxh128_free(void* state) {
    if (state == NULL) return;
    XXH3_freeState((XXH3_state_t*)state);
}
