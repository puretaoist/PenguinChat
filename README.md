# PenguinChat

Flutter / Android 客户端。

## 构建

编译交给 GitHub Actions，本机不需要配 Android SDK：

- 推送到 `main` 自动构建
- 或在 Actions 页面手动触发（可选 `debug` / `release`）
- 产物在该次 run 页面的 **Artifacts** 区域下载

## 本地开发

```bash
flutter pub get
flutter analyze
flutter test
```

单模块自测（纯 Dart，不需要设备）：

```bash
dart run tool/selftest.dart
```

## 文档

- [`AGENTS.md`](AGENTS.md) —— 项目结构、工程约定、当前状态

## 许可

专有许可，保留所有权利。完整条款见 [`LICENSE`](LICENSE)。
