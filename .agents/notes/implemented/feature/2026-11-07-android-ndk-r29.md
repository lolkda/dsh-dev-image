# Agent Note: 将默认 NDK 降级到 r29

Status: implemented

## Problem

用户要求把镜像默认 NDK 从 r30 降级到 r29。r30 是当前默认，但部分项目需要 r29 的工具链/行为；同时 Android SDK 仍保留 Platform 37.2，不能把 r29 的平台能力误认为和 r30 相同。

## Decision

- [Dockerfile](../../../../Dockerfile) 的 `ANDROID_NDK_VERSION` 默认值改为 `29.0.14206865`（r29）；amd64 的 `sdkmanager` 安装、`source.properties` 校验、`ndk-build` 和 CMake toolchain 检查继续复用同一套逻辑。
- [NDK 环境测试](../../../../tests/android-ndk.test.mjs) 的版本 fixture 同步改为 `29.0.14206865`。
- [README](../../../../README.md) 和维护者文档的默认 NDK 版本、`ANDROID_NDK_HOME`、`ndkVersion` 示例同步改为 r29，并明确 r29 的平台上限是 API 35：`compileSdk = 37` 的 Java/Kotlin 构建不受影响，但 native 代码不能使用 API 36/37 的新接口，此类项目需要改用 r30。
- 不保留双 NDK 安装：镜像只安装一个默认 NDK，避免把 r29 和 r30 同时塞进镜像造成体积和选择歧义。需要其他 NDK 的项目通过显式 `ANDROID_NDK_HOME` 或外部安装覆盖。

## Alternatives considered

- 保留 r30 并额外安装 r29：可同时支持两套 native 平台，但镜像体积会增加约一套 NDK，且默认版本仍不明确；用户要求的是降级，不是双版本。
- 只改 README 不改镜像：文档看似满足，但实际镜像仍是 r30，Gradle `ndkVersion` 和 CI 校验会不一致，不能采用。
- 继续用 r30 并声称兼容 r29：r30 的编译器版本和 sysroot 与 r29 不同，不能满足需要 r29 的项目；同时会误导 API 35 上限的判断。

## Testing

- 已在当前 amd64 环境通过 `sdkmanager` 安装 `ndk;29.0.14206865`，`source.properties` 显示 `Pkg.ReleaseName = r29`，`meta/platforms.json` 的 `max` 为 `35`。
- 使用 r29 实际运行 [NDK 冒烟](../../../../tests/android-ndk-smoke.sh)：C++20 / Android arm64 / API 28 JNI 共享库编译成功，`llvm-readelf` 验证 DYN、AArch64 和 `JNI_OnLoad` 通过。
- 本地 Node、Shell、ShellCheck 和笔记门禁通过；真实 Docker 构建和双架构容器验收由 GitHub Actions 完成。

## Consequences

- 默认 NDK 从 r30 变为 r29，使用 r30 专有工具链行为或 native API 36/37 接口的项目需要显式切换到 r30。
- r29 只支持到 API 35；镜像仍保留 Android Platform 37.2，Java/Kotlin 的 `compileSdk 37` 不受影响，但 native 目标不能使用 API 36/37 的新接口。
- 已有容器不会自动降级，必须重新拉取镜像并重建容器。

## Related notes audit

[Android NDK 初始决定](../feature/2026-11-04-android-ndk.md) 的 r30 默认值由本决定取代；其 amd64-only、PATH/入口一致性、`source.properties` 校验和 NDK 冒烟约束继续保留。
