# ZhuYu

任何 AI 未经用户明确许可，不得修改 README 文档。

ZhuYu 是一个用 Zig 编写的 2D 游戏开发库，基于 Sokol。
名字取自[《山海经·南山经》](https://zh.wikisource.org/zh-hans/山海經/南山經)中的祝余草：形似韭菜，开青色花，传说食之不饥。

## 功能概览

- 窗口管理、缩放，以及键盘、鼠标和最多 8 点触摸输入。
- 2D 批量绘制、相机、图集、动画和渲染目标。
- 图片与音频资源加载。
- 文字绘制、界面控件和 Tiled 地图支持。

## 构建要求

使用 Zig 0.17.0。

### 最低系统版本

| 平台 | 最低版本 | 依据 |
| --- | --- | --- |
| Windows | 10 | 当前 Zig 标准库最低支持 Windows 10。 |
| Linux x86_64 | 内核 5.10、glibc 2.31 | 内核按 Zig 支持下限。 |
| macOS | 14.0 | 当前 Sokol 的 Metal 窗口使用 `CADisplayLink`，从 macOS 14 提供。 |
| iOS | 15.0 | 当前 Sokol 使用的 `preferredFrameRateRange` 从 iOS 15 提供。 |
| Android | 8.0（API 26） | Sokol 音频使用 AAudio，从 API 26 提供。 |

Windows 和 Linux 内核的依据见 [Zig 系统版本要求]，macOS 的依据见 [Sokol 窗口实现]，
Android 的依据见 [AAudio 系统要求]。

Linux 默认使用 X11、OpenGL 4.3 和 ALSA；Wayland 桌面需要 XWayland。

[Zig 系统版本要求]: https://ziglang.org/learn/platform-support/#version-requirements
[Sokol 窗口实现]: https://github.com/floooh/sokol/blob/master/sokol_app.h
[AAudio 系统要求]: https://developer.android.com/ndk/guides/stable_apis#audio

构建时必须显式指定最低版本，不能依赖 Zig 的默认值：

| 构建目标 | `-Dtarget` |
| --- | --- |
| Windows x86_64 | `x86_64-windows.win10-gnu` |
| Linux x86_64 | `x86_64-linux.5.10-gnu.2.31` |
| macOS Apple Silicon | `aarch64-macos.14.0` |
| macOS Intel | `x86_64-macos.14.0` |
| iOS 真机 | `aarch64-ios.15.0` |
| iOS Apple Silicon 模拟器 | `aarch64-ios.15.0-simulator` |
| Android ARM64 | `aarch64-linux-android.26` |

构建 Linux 发行包时，头文件和链接库也应来自匹配基线的环境，例如 Debian 11。
仅指定 `-Dtarget` 不能降低链接库自身的 glibc 要求。

其他 Android 架构同样使用 API 26。APK 的 `minSdkVersion` 从编译目标的 API
版本取得；`targetSdkVersion` 从已安装的 SDK Platform 取得，两者不要混淆。

最低系统版本不随 Zig、SDK 或流水线的系统版本自动提高，更改前需明确确认。

### 运行测试

```sh
zig build test
zig build test -Doptimize=safe
```

## 开发状态

**警告：本项目仍在开发中，不保证任何兼容性。**
接口、资源格式和运行行为可能变化；问题修复也可能改变现有行为。
