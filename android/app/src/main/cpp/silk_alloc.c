/*
 * silk_alloc.c —— 仅供 Dart FFI 使用的跨平台堆分配垫片。
 *
 * 为什么需要：Dart 侧不引 package:ffi（避免新增 pubspec 依赖），
 * 因此拿不到 calloc/free。这里在 SILK 同一动态库里导出两个极小的
 * malloc/free 包装，Dart 用 DynamicLibrary 查符号后即可分配原生态缓冲。
 *
 * 注意：不是 SILK SDK 本体，只做内存分配，不涉及编解码逻辑。
 */
#include <stdlib.h>

void *silk_malloc(int size) {
    if (size <= 0) {
        return 0;
    }
    return malloc((size_t) size);
}

void silk_free(void *ptr) {
    free(ptr);
}
