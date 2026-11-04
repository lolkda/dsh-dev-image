# Agent Note: 安装 Android NDK 并支持所有 Shell 路径

Status: implemented

## Problem

镜像已有 SDK Platform 37.2、Build Tools 37.0.0 和主机 C++ 工具，但此前明确没有安装 Android NDK。用户需要落地 JNI/native 开发，确认在镜像中补齐 NDK、PATH 和验证，并要求修改后提交 push 触发现有 CI。只装 NDK 而未同步 ENV、登录 Shell 和入口会造成不同调用方式找不到工具。

## Scope and delegation

沿用用户已确认的实现方案；内部脚本组织及测试细节由模型处理。只修改本镜像项目，不修改 WeCom 源码、不升级其他工具、不安装模拟器、不扩大默认 Docker/USB 权限、不重建当前运行容器。用户明确授权提交并正常 push 到当前 main 分支，触发既有 build-and-publish；不强推。

## Decision

- [Dockerfile](<../../../../Dockerfile>) 使用唯一版本参数 ANDROID_NDK_VERSION=30.0.16248370（r30），在既有 amd64 SDK 安装分支通过 sdkmanager 安装 ndk 包，并核对 source.properties、ndk-build 和 CMake toolchain。
- NDK_HOME 位于 /opt/android-sdk/ndk/版本，实际导出名为 ANDROID_NDK_HOME。ENV PATH 追加 NDK 根目录与 linux-x86_64 LLVM bin，支持不经过 shell/entrypoint 的 docker exec，同时不抢占既有主机工具优先级。
- [ndk-env.sh](<../../../../ndk-env.sh>) 为入口和登录 Shell 共用的 POSIX 辅助脚本；仅加入存在的目录，幂等，支持空格/引号路径，拒绝相对路径与冒号。显式 ANDROID_NDK_HOME 优先；未设置时可根据 ANDROID_HOME 和 ANDROID_NDK_VERSION 计算。
- 保留架构边界：amd64 镜像可以交叉编译 Android arm64；arm64 镜像不安装不可执行的 Linux x86_64 NDK，不宣称支持 Android 编译。
- [NDK 冒烟](<../../../../tests/android-ndk-smoke.sh>) 在构建期两种 Shell 和完整镜像运行测试中实际链接 C++20 / Android API 28 / arm64 的 JNI so，并检查 ELF DYN、AArch64 与 JNI_OnLoad。测试只编译/读取产物，不在 Android 设备执行或启动 ADB daemon。
- 裸 docker exec 直接调用 ndk-build、目标 Clang，再运行同一冒烟脚本；目录恢复不能仅依赖 entrypoint。轻量入口测试镜像也包含辅助脚本，但不下载 NDK。

## Alternatives considered

- 仅临时装进当前容器：重建后丢失且无法由 CI 验证，不符合用户要求。
- 只修改 entrypoint PATH：裸 docker exec 不执行入口，仍会缺工具。
- 在三个位置分别复制 PATH 处理代码：容易漂移；运行时与登录 Shell 共用辅助脚本，ENV仍保留容器元数据所需路径。
- 将 NDK LLVM 放到 PATH 最前：可能覆盖用户/主机 clang 等工具，改为追加。
- arm64 镜像安装 x86_64 NDK 并假定可运行：不采用，不引入隐式仿真或改变已有架构承诺。

## Behavior and verification

- 新测试先得到7项失败，缺失安装声明、ENV/helper及真实编译冒烟；非法路径用例随后补充错误原因断言，避免把脚本不存在当成正确拒绝。
- 只读审查发现受限.dockerignore会排除新增COPY源；先增加失败用例，再仅放行ndk-env.sh和tests/android-ndk-smoke.sh，不放开整个tests目录。另增加“继承镜像PATH时自定义NDK_HOME真正替换旧NDK”的失败回归后修复。
- 最终本地检查：Node共177项，175通过、0失败、2个既有环境用例跳过（未设置FRIDA_TEST_BIN及root进程无法直接跑非root用例）；新增10项NDK测试全部通过。真实root入口25项通过，notes18项通过，Bash/POSIX语法、ShellCheck与git diff --check通过。不把配置断言算作真实NDK编译。
- [配置/PATH 回归](<../../../../tests/android-ndk.test.mjs>)验证版本、三处接线、幂等、空格/引号、缺目录、显式覆盖及编译脚本内容；[入口回归](<../../../../tests/entrypoint.test.sh>)实际验证运行时 PATH 恢复。
- 当前容器没有 Docker，未在本地构建新镜像或运行真实 NDK 交叉编译。真实镜像/NDK冒烟由[既有CI](<../../../../.github/workflows/build.yml>)在发布前执行；仅触发CI不能算镜像已发布。
- 版本来源为[Android官方NDK下载页](https://developer.android.com/ndk/downloads)在2026-11-04列出的r30 LTS；没有在当前容器另行下载完整NDK。

## Consequences

增加amd64镜像的下载量与体积，NDK工具链位于镜像层。用户需拉取新镜像并重建容器，单纯restart旧容器不会生效。项目应固定选定ndkVersion，CMake可使用ANDROID_NDK_HOME下的toolchain；平台库仍需为Android目标单独构建，不能链接主机Linux库。

本决定仅取代[此前SDK记录](<2026-10-25-android-sdk.md>)中“不安装NDK”的范围；SDK/Build Tools版本、amd64/arm64边界、模拟器与USB限制保持。不得将NDK版本冒烟或最小so测试当作具体WeCom业务或真机验证。
