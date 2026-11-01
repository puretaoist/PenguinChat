# vendor/silk — Skype SILK SDK v3（编解码底座）

来源：https://github.com/kn007/silk-v3-decoder （分支 master）
只取其中的 `silk/` 子目录（`interface/` + `src/`，即 Skype SILK SDK v3 源码），
未引入该仓库的 `converter/` 转换工具、`test/` 示例与任何预编译大二进制。

- `interface/`：公开 C API（`SKP_Silk_SDK_API.h`、`SKP_Silk_control.h`、`SKP_Silk_typedef.h`、`SKP_Silk_errors.h`）
- `src/`：`SKP_Silk_*.c` 固定点实现（110 个 .c）。`*.S` 为 ARM 汇编优化，未参与构建
  （构建统一加 `NO_ASM=1`，走纯 C 路径，跨 ABI 行为一致；否则 32 位 ARM 目标会被
  头文件按 `__ARM_ARCH_7A__` 拉进 ARM 汇编宏，而对应函数只存在于未编译的 `*.S`）。
- `LICENSE`：仓库根 LICENSE（MIT，Copyright (c) 2020 Karl Chen）已一并保留；
  各源文件头部的 Skype Limited 原始 BSD 版权声明也全部保留。

SDK 版本字符串：`SKP_Silk_SDK_get_version()` 返回 `1.0.9.6`（见 `src/SKP_Silk_dec_API.c`）。

构建方式见：
- Android：`android/app/src/main/cpp/CMakeLists.txt` → `libsilkcodec.so`
- Windows 宿主：`tool/build_silk_host.sh` → `build/host/silkcodec.dll`
