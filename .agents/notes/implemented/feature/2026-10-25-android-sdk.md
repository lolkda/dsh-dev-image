# Agent Note: 安装完整 Android SDK 编译工具链

Status: implemented

## Problem

镜像原先只在 Debian apt 中安装 `adb`，没有 `platforms`、`build-tools` 或可用的 `sdkmanager`，因此无法从源码编译 APK。用户要求把 Google 官方 Android SDK 的 Platform、Build-Tools、Platform-Tools 三块都装上，取当前最新稳定版，并保证普通 Shell、登录 Shell 和裸 `docker exec` 都能通过 PATH 调用。

## Decision

- 在 [Dockerfile](../../../../Dockerfile) 的 Java 之后、Apktool 之前安装 Google 官方 `cmdline-tools` 23.0（build `16111833`，SHA-256 固定），再用它安装：
  - `platforms;android-37.2`
  - `build-tools;37.0.0`
  - `platform-tools`（构建期校验 `37.0.1`）
- SDK 根目录固定为 `/opt/android-sdk`，`ANDROID_HOME` 与 `ANDROID_SDK_ROOT` 都指向它。`build-tools`、`platform-tools`、`cmdline-tools/latest/bin` 同时写入镜像 `ENV PATH` 和 `/etc/profile.d/00-dsh-path.sh`，避免登录 Shell 的 `/etc/profile` 覆盖 PATH 后命令丢失。
- 所有版本使用 `ARG` 固定，并在构建期读取各组件的 `source.properties` 校验精确版本。不使用 sdkmanager 的隐式 latest，避免重建时随上游漂移。
- amd64 不再安装 Debian 的 `adb`，防止 `/usr/bin/adb` 抢先命中旧版本；构建期从 `/tmp` 调用 `adb`、`fastboot`、`aapt2`、`apksigner`，并在两条 Shell 路径上重复验证。
- Google 的 Linux `build-tools` / `platform-tools` 归档只有 x86_64 二进制。完整 SDK 只在 amd64 安装；arm64 保留 Debian `adb` 作为调试兜底，不承诺 APK 编译，也不伪装安装成功。
- 不安装 NDK、CMake 的 Android 工具链、模拟器或 system-image；真机 USB 透传仍由使用者显式配置，默认 compose 不扩大权限。

## Alternatives considered

- 挂载宿主机的 Android SDK：镜像更小，也避免 SDK license 和架构问题；但用户要求镜像内开箱即用，且宿主机路径不可控，不能保证 `docker exec` 直接可用。
- 只安装 Debian 的 `adb`、`aapt`、`apksigner`：体积小，但版本旧、组件不全，无法满足编译 APK 和“最新”的要求。
- 在 arm64 上强行安装 x86_64 归档并用 QEMU/binfmt 运行：理论上能跑，但需要宿主级 binfmt、额外权限和明显的性能损失，不应成为默认开发镜像的隐式依赖。
- 不固定版本、只装 latest：升级最省事，但可复现性差，构建可能因上游发布而突然失败；因此改为固定版本并在升级时显式修改 ARG、PATH 和文档。

## Verification contract

1. 最终镜像在 amd64 上包含 `cmdline-tools`、`platform-tools`、`build-tools;37.0.0`、`platforms;android-37.2`，`source.properties` 版本与 ARG 一致。
2. `sdkmanager`、`adb`、`fastboot`、`aapt2`、`apksigner`、`zipalign` 在普通 Shell 和登录 Shell 中都解析到 `/opt/android-sdk` 下的路径，且 `adb` 不解析到 Debian 的 `/usr/bin/adb`。
3. 构建期在两种 Shell 中执行 SDK 命令；任一组件缺失或版本错误必须让构建失败，而不是拖到运行时。
4. arm64 构建不安装原生 SDK，保留 Debian `adb`；镜像冒烟跳过 amd64 专属的 SDK 断言，但仍验证 `adb` 可用。
5. 验证不启动 ADB daemon，不修改默认 compose 的 USB 权限，也不安装 NDK、模拟器或 system-image。

## Verification results

- 本地已从 Google 官方仓库实际下载 `commandlinetools-linux-16111833_latest.zip`，SHA-256 与 Dockerfile 一致；在临时 SDK 根目录安装 `platforms;android-37.2`、`build-tools;37.0.0`、`platform-tools` 后，确认 `sdkmanager`、`adb 37.0.1`、`fastboot 37.0.1`、`aapt2`、`apksigner`、`d8` 均可执行；解压后 SDK 约 513 MB。
- 新增 [Android SDK 配置回归](../../../../tests/android-sdk.test.mjs)，覆盖版本固定、官方归档 SHA-256、`source.properties`、amd64/arm64 分支、`ENV` 与登录 Shell PATH、构建期命令和禁止 daemon。
- [完整镜像冒烟](../../../../tests/image-smoke.sh) 已加入 amd64 的 SDK PATH 与命令执行断言，并保留 arm64 的 `adb` 兜底检查；[README](../../../../README.md) 已记录版本、编译配置和架构限制。
- 本地 `node --test tests/*.test.mjs`、`bash -n tests/image-smoke.sh`、`shellcheck tests/image-smoke.sh` 通过。当前环境没有 Docker CLI，未实际构建镜像；真实 Docker 构建、两种 Shell 和 arm64 分支仍需由 CI 验证，不能用静态测试代替。

## Consequences

- amd64 镜像增加约 500 MB 解压后的 SDK，压缩镜像预计增大数百 MB；需要更小体积时应使用外部挂载的 SDK 而不是删除版本校验。
- 项目可以编译 `compileSdk = 37`、`compileSdkMinor = 2` 的 APK；但最新 AGP 默认 Build-Tools 仍是 36.0.0，项目应显式固定 `buildToolsVersion` 或安装对应版本。
- arm64 镜像没有完整 SDK，不能用于 APK 编译；这是 Google 未提供原生 Linux arm64 build-tools 的硬限制，不是 PATH 配置问题。
- SDK 组件位于镜像层，升级后必须重建镜像并重建容器；只 restart 不会生效。
