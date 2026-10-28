# 构建、发版与回归

面向修改镜像的人。日常使用看 [README](../README.md)。

## 构建参数

版本号只在 [Dockerfile](../Dockerfile) 的 `ARG` 默认值里维护，Compose 和 CI 不重复声明。

| 参数 | 默认值 | 说明 |
|---|---|---|
| `GO_VERSION` | `1.27.1` | 官方 tarball；sha256 从 go.dev API 现取 |
| `JDK_VERSION` | `25` | Adoptium feature version |
| `DSH_VERSION` | `0.2.1-rc.2` | npm 版本号或 dist-tag |
| `PNPM_VERSION` | `12.4.2` | 全局安装 |
| `TYPESCRIPT_VERSION` | `7.0.2` | 全局 `tsc` |
| `TSX_VERSION` | `4.23.15` | 全局 `tsx` |
| `MAVEN_VERSION` | `3.9.16` | 官方 tarball |
| `GRADLE_VERSION` | `9.7.1` | 官方 distribution |
| `UV_VERSION` | `0.12.17` | PyPI 安装 |
| `YQ_VERSION` | `4.53.6` | mikefarah v4 官方二进制 |
| `FRIDA_VERSION` | `17.23.1` | 独立 venv |
| `FRIDA_TOOLS_VERSION` | `14.11.0` | 需与核心版本兼容 |
| `APKTOOL_VERSION` | `2.12.1` | 官方 JAR |
| `APKTOOL_SHA256` | 见 Dockerfile | 与 `APKTOOL_VERSION` 配套 |
| `ANDROID_CMDLINE_TOOLS_VERSION` | `23.0` | 构建期校验 `source.properties` |
| `ANDROID_CMDLINE_TOOLS_BUILD` | `16111833` | Google 归档编号 |
| `ANDROID_CMDLINE_TOOLS_SHA256` | 见 Dockerfile | 与 build 编号配套 |
| `ANDROID_SDK_PLATFORM` | `37.2` | 安装为 `platforms;android-37.2` |
| `ANDROID_BUILD_TOOLS_VERSION` | `37.0.0` | PATH 中也写死了这个目录 |
| `ANDROID_PLATFORM_TOOLS_VERSION` | `37.0.1` | 构建期校验 |

升级 Android 组件时，除了改 ARG，还要同步 `ENV PATH`、`/etc/profile.d/00-dsh-path.sh` 和文档中的路径；构建期的 `source.properties` 校验会兜底。

Node / Rust 更换版本时必须继续使用 bookworm 变体（glibc 2.36）。Python base 固定到精确补丁版本，避免 `3.13-slim` 漂移。Java 和 Go 使用官方 tarball，不跨阶段 COPY，原因见下文。

## 构建与发布

```bash
docker compose build
docker compose up -d --force-recreate
```

构建期会逐条验证 COPY 进来的工具链，最后再跑一次 `bash -c` 和 `bash -lc` 的全链路冒烟；任何一条路径不对，构建当场失败。

发布只使用 Docker Hub：

```bash
docker pull chikennice/dsh-dev-image:latest
```

| 标签 | 触发条件 |
|---|---|
| `:latest` | 默认分支最新 |
| `:main` | push 到 `main` |
| `:1.2.3` / `:1.2` | push `v1.2.3` tag |

[build.yml](../.github/workflows/build.yml) 的流程：

1. 先调用 [verify-layout.yml](../.github/workflows/verify-layout.yml)，测试当前 checkout 的入口、配置和真实 Linux 权限，而不是拉旧 `latest`。
2. amd64 和 arm64 在各自原生 runner 上构建、加载到本机 Docker，执行启动权限、工具链、缓存位置和默认 Web HTTP 验收。
3. 不重新构建，直接推送已测镜像；通过 digest 合并多架构 manifest 后才更新公开标签。

PR 只测试 amd64、不推送；发布时两个架构都必须通过。`ci-<run>-<attempt>-<arch>` 是本次构建的中间标签，不要用于部署。

发布前在 GitHub 仓库 **Settings → Secrets and variables → Actions** 配置：

- `DOCKERHUB_USERNAME`：有目标仓库写权限的 Docker Hub 用户名。
- `DOCKERHUB_TOKEN`：有目标仓库写权限的 Access Token。

非 PR 发布缺少任一 secret 会失败；PR 不需要这些凭据。token 是否存在由前置检查验证，token 是否有效只能靠实际登录和推送验证。

单平台构建上限 90 分钟。Android SDK 解压后约 500 MB，加上 Gradle、Go、JDK 和 apt 层，压缩镜像预计 1.6–1.7 GB。

## 回归测试

不需要安装 npm 测试依赖：

```bash
node --test tests/*.test.mjs
npm run verify-notes
for script in entrypoint.sh cli-env.sh tests/*.sh; do bash -n "$script"; done
shellcheck entrypoint.sh cli-env.sh tests/*.sh
sh -n cli-env.sh
node --check home-init.mjs
```

入口成功路径必须用真实 root 运行；普通用户跑 Node 测试时，相关用例会明确跳过，不能算通过：

```bash
sudo env PATH="$PATH" bash tests/entrypoint.test.sh
sudo env PATH="$PATH" node --test tests/*.test.mjs
```

真实 Docker 权限验收：

```bash
docker build -f tests/Dockerfile -t dsh-entrypoint-test .
bash tests/container-runtime.sh dsh-entrypoint-test
```

完整镜像验收（需要网络安装默认插件）：

```bash
docker build -t dsh-dev-image:verify .
bash tests/container-runtime.sh dsh-dev-image:verify
bash tests/image-smoke.sh dsh-dev-image:verify
```

重点测试文件：

- [entrypoint.test.sh](../tests/entrypoint.test.sh)：真实执行 root 入口，只替换外部插件安装命令。
- [config.test.mjs](../tests/config.test.mjs)：空值展开、版本默认值、失败传播和发布约束。
- [container-runtime.sh](../tests/container-runtime.sh)：root 启动、旧 UID 的 `0700` 工作区、混合属主、只读挂载、符号链接和能力边界。
- [image-smoke.sh](../tests/image-smoke.sh)：两种 Shell、TypeScript / Rust 实际编译、Maven / pnpm 缓存位置、默认 Web 登录流程。
- [android-sdk.test.mjs](../tests/android-sdk.test.mjs)：Android 版本、SHA-256、`source.properties`、PATH 和架构差异。
- [web-ready.test.mjs](../tests/web-ready.test.mjs)：真实 HTTP 登录流程及失败分支。

DSH 对匿名 `/` 返回 `401` 是正常鉴权行为，不能用匿名 `curl --fail` 判断服务是否启动。验收从启动日志取 token，跟随登录重定向并保留 cookie，最终必须获得 `200`。

CI 在发布前执行这些步骤；没有实际运行 Docker 的本地检查不能标记为容器验收通过。

## 设计取舍

**base 用 `python:3.13.17-slim-bookworm`，不用裸 Debian。** 官方 Python 镜像会把 Python 实际依赖的 `.so` 所属 apt 包标记为 manual，并跑过 `ldconfig`。换成裸 Debian 再 COPY Python 的 `/usr/local`，`sqlite3` / `ssl` / `ctypes` 等模块会 ImportError。

**Java 不走 COPY。** eclipse-temurin 的 Debian 变体跟随发行版；JDK 24 时期只有 noble 变体（glibc 2.39 > base 的 2.36）。Adoptium tarball 面向 glibc 2.17+，换 JDK 版本不用动 base。

**Go 也不走 COPY。** golang 官方镜像的 `/usr/local/go` 是指向 `/target/usr/local/go` 的符号链接，跨阶段 COPY 对符号链接的处理依赖构建器，不可靠。

**Node 的 `/opt` 必须一起 COPY。** node 镜像把 Yarn 装在 `/opt/yarn-<ver>/`，`/usr/local/bin/yarn` 只是符号链接；只拷 `/usr/local/bin` 会留下断链。

**不能用 alpine。** musl 与 manylinux wheel、原生 Node 模块、JVM 不兼容，等于逼所有项目从源码构建。

**`dsh` 不用 `@latest`。** dist-tag 会变化，且不保证指向需要的预发布版本；镜像通过 `DSH_VERSION` 固定。

**rust / go 需要 `build-essential`。** 不只是编译 C 扩展：`rustc` 需要 cc 链接产物，Node、rustc、`libjvm.so` 还都动态链接 `libstdc++6` 和 `libgcc_s`。

**root-only + Docker 默认 capabilities。** 不写 `cap_drop`，仅额外添加 `SYS_PTRACE`；保留 `no-new-privileges`，不使用 privileged，也不挂 Docker socket。

## 升级检查清单

- Node / Rust 来源镜像仍是 bookworm 变体。
- Python base 仍是精确的 3.13 补丁版本。
- Android 的 ARG、PATH、`profile.d` 和文档版本一致。
- `APKTOOL_VERSION` 与 `APKTOOL_SHA256` 配套。
- 默认插件仍为 `@lolkda/dsh-web-lan@latest`，不要改成固定版本作为默认值。
- 旧部署中的非 root `user`、`AGENT_UID/GID`、`USER_UID/GID` 和 `cap_drop: ALL` 已移除。
- 用 `docker compose up -d --build --force-recreate` 重建，不只 `restart`。
