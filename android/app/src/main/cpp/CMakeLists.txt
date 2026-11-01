# ============================================================
# SILK v3 编解码底座（Skype SILK SDK）-> libsilkcodec.so
#
# 供 Dart FFI 直接调用标准 C API，不写 JNI 壳：
#   SKP_Silk_SDK_Get_Encoder_Size / InitEncoder / Encode / QueryEncoder
#   SKP_Silk_SDK_Get_Decoder_Size / InitDecoder / Decode
#   SKP_Silk_SDK_get_TOC / SKP_Silk_SDK_get_version
#
# 由 android/app/build.gradle.kts 的 externalNativeBuild 驱动，
# 单一 CMakeLists 同时服务 arm64-v8a / armeabi-v7a（ABI 由 NDK toolchain 决定）。
# ============================================================
cmake_minimum_required(VERSION 3.22)
project(silkcodec LANGUAGES C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)

# 仓库根目录：本文件位于 <root>/android/app/src/main/cpp/CMakeLists.txt
if(NOT DEFINED SILK_ROOT)
  set(SILK_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../vendor/silk")
endif()
get_filename_component(SILK_ROOT "${SILK_ROOT}" ABSOLUTE)
message(STATUS "[silkcodec] SILK_ROOT = ${SILK_ROOT}")

file(GLOB SILK_SOURCES CONFIGURE_DEPENDS "${SILK_ROOT}/src/*.c")
list(LENGTH SILK_SOURCES _n)
message(STATUS "[silkcodec] SILK C sources = ${_n}")

add_library(silkcodec SHARED
  ${SILK_SOURCES}
  "${CMAKE_CURRENT_SOURCE_DIR}/silk_alloc.c"
)

target_include_directories(silkcodec PRIVATE
  "${SILK_ROOT}/interface"
  "${SILK_ROOT}/src"
)

# NO_ASM：强制走纯 C 实现，不包含 SKP_Silk_macros_arm.h、不引用 ARM 汇编函数。
# 否则 32 位 ARM 编译器会按 __ARM_ARCH_7A__ 自动把 EMBEDDED_ARM 设成 6/7，
# 而这些数学/重采样函数只存在于未编译的 *_arm.S 中，链接必报 undefined symbol。
target_compile_definitions(silkcodec PRIVATE NO_ASM=1 EMBEDDED_ARM=0)

set_target_properties(silkcodec PROPERTIES
  OUTPUT_NAME silkcodec
  POSITION_INDEPENDENT_CODE ON
  C_VISIBILITY_PRESET default
)

# 老代码（2012）在现代 GCC/Clang 下会有一批 unused 警告，只压噪音，不关错误。
target_compile_options(silkcodec PRIVATE
  -O3
  -fvisibility=default
  -Wno-unused-variable
  -Wno-unused-but-set-variable
  -Wno-unused-function
  -Wno-sign-compare
)
