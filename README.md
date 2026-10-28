# dsh-dev-image

通用开发镜像：Python / Node / TypeScript / Java / Rust / Go / Android SDK / DSH 预装在 Debian 容器里。宿主机只需要 Docker，挂载一个工作目录，浏览器打开 `3080` 就能用。

镜像地址：`chikennice/dsh-dev-image:latest`，支持 `linux/amd64` 和 `linux/arm64`。

## 快速开始

直接运行：

```bash
mkdir -p /srv/agent
docker run -d --name dsh-agent --restart unless-stopped --network host \
  -v /srv/agent:/app \
  chikennice/dsh-dev-image:latest
```

打开 `http://<宿主机IP>:3080`。首次启动会安装默认插件，等几秒即可。

- `--network host` 下不要再加 `-p`。
- host 模式会监听所有网卡；有公网 IP 的机器必须用防火墙限制 `3080`。
- `/srv/agent` 是唯一持久化目录，备份它即可。

用 Compose：

```bash
git clone https://github.com/lolkda/dsh-dev-image.git
cd dsh-dev-image

mkdir -p /srv/agent
docker compose up -d
docker compose logs -f
```

`AGENT_HOME` 可以修改宿主挂载目录，默认 `/srv/agent`。Compose 额外提供 CPU / 内存 / PID 限制和日志上限。

容器默认执行 `dsh web`，不需要手动启动。日常 shell 和一次性任务：

```bash
docker compose exec agent bash
docker compose run --rm agent dsh headless "跑一下测试"
docker compose run --rm agent dsh tui
```

修改本仓库后必须重建容器：`docker compose up -d --build --force-recreate`。只 `restart` 不会更新入口。

## 镜像内容

| 类别 | 内容 |
|---|---|
| 基础 | Debian 12 bookworm，glibc 2.36 |
| Python | 3.13.17 |
| Node | 24.22.1，含 npm、Yarn Classic、corepack |
| pnpm | 12.4.2 |
| TypeScript | `tsc` 7.0.2，`tsx` 4.23.15 |
| Rust | 1.98.1，含 `clippy` / `rustfmt` |
| Go | 1.27.1 |
| Java | Temurin 25.0.5+8（LTS），Maven 3.9.16，Gradle 9.7.1 |
| DSH | 0.2.1-rc.2 |
| Android SDK | 仅 amd64：Platform 37.2，Build-Tools 37.0.0，Platform-Tools 37.0.1；arm64 只有 Debian `adb` |
| APK / 插桩 | `apktool` 2.12.1，`frida` 17.23.1，`frida-tools` 14.11.0 |
| 常用 CLI | git、git-lfs、gh、rg、jq、yq 4.53.6、sqlite3、file、xxd、less、tmux、cmake、ninja、gdb、strace、shellcheck |

没有预装：`nmap` / `tcpdump` / `binwalk` 等安全工具，`gopls` / `dlv` / `rust-analyzer` 等语言服务器，Android NDK / 模拟器 / system-image，以及 Docker CLI / socket。

## 常用用法

TypeScript：

```bash
tsc --noEmit -p tsconfig.json   # 只做类型检查
tsc -p tsconfig.json            # 按项目配置编译
tsx src/index.ts                # 直接运行，也支持 .tsx
```

`tsx` 只转译并运行，不做类型检查；项目应在自己的依赖中锁定 `typescript`、`tsx` 和 `@types/node`。

Android SDK：

```bash
sdkmanager --list_installed
adb version
fastboot --version
aapt2 version
apksigner version
```

完整 SDK 只在 amd64 镜像中安装。arm64 镜像保留 Debian `adb` 作为调试兜底，不能编译 APK。项目需使用 `compileSdk = 37`、`compileSdkMinor = 2`、`buildToolsVersion = "37.0.0"`。

不包含 NDK、模拟器或 system-image；默认 Compose 也没有映射宿主 USB 设备。SDK 在镜像层，升级后必须重建容器。

APK 分析与 Frida：

```bash
apktool d app.apk -o decoded
apktool b decoded -o rebuilt.apk

frida --version
frida-ps --help
frida-trace --help
```

`frida` 只内置客户端，不安装、不启动 `frida-server`。连接设备时需要自行部署与核心版本、目标架构匹配的 server。

## 数据与持久化

只有 `/app` 一个挂载点：

```text
/app
├── ...     代码与工作区
├── .dsh/   DSH profile、插件、凭证、日志
├── .home/  root HOME、Git/SSH/gh 配置、用户级 CLI
└── .cache/ cargo/go/pip/npm/maven/gradle/uv/pnpm store
```

- `/app` 之外仍可写，但属于容器可写层，重建容器后丢弃。
- 备份 = 打包 `/srv/agent`；清缓存 = 停容器后删除 `/srv/agent/.cache`。
- 容器统一使用 root（`0:0`），`HOME=/app/.home`，不递归修改宿主文件属主；新文件在宿主上可能需要 sudo 编辑。
- `npm install -g`、`pnpm add -g`、`pip install --user`、`uv tool install`、`cargo install`、`go install` 默认落到 `/app/.home/.local`，随 `/app` 持久化。

## 常用配置

| 变量 | 默认 | 说明 |
|---|---|---|
| `AGENT_HOME` | `/srv/agent` | Compose 的宿主挂载目录 |
| `DSH_PROFILE` | `web` | DSH profile |
| `DSH_PLUGINS` | `@lolkda/dsh-web-lan@latest` | 启动时安装的插件，空格分隔 |
| `DSH_PLUGINS_REQUIRED` | `1` | 插件装不上时是否退出 |
| `DSH_PLUGIN_REGISTRY` | `https://registry.npmjs.org` | 插件专用 npm 源 |
| `DSH_WEB_TRUSTED_HOSTS` | 空 | 额外信任的访问域名 |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm / pnpm / Yarn 源 |
| `PYPI_INDEX_URL` | `https://mirrors.aliyun.com/pypi/simple/` | pip / uv 源 |

显式写 `DSH_PLUGINS=` 会跳过插件安装，但不会卸载已有 profile 里的插件。离线环境用 `DSH_PLUGINS_REQUIRED=0`。

`NPM_REGISTRY` / `PYPI_INDEX_URL` 是 Compose 的整组开关；直接 `docker run` 时改用镜像里的 `npm_config_registry`、`PIP_INDEX_URL` 等原生变量。

需要容器网络隔离时改用 bridge：

```bash
DSH_HOST=192.168.1.5 docker compose -f compose.bridge.yml up -d
```

`DSH_HOST` 同时决定端口绑定到哪张网卡、以及 Web 信任哪个 Host；不填就只能从宿主本机访问。`DSH_PORT` 只改宿主端口，默认 `3080`。

## 验证

```bash
docker compose exec agent bash -lc \
  'python -V && node -v && pnpm -v && tsc --version && go version && \
   rustc -V && java -version && dsh --help >/dev/null && echo ALL-OK'
```

完整镜像冒烟、root 权限回归和 Android / TypeScript / 用户 CLI 验收见 [维护者文档](docs/maintainer.md)。

## 已知限制

- Android 编译只在 amd64 提供；arm64 只有 `adb`，不能构建 APK。
- 默认没有 Docker socket，容器内不能 `docker build` / `docker compose up`。
- 默认不映射 USB，Android 真机调试需要显式加 `--device` / `devices:`。
- 容器里的 profile 是新的空 profile；宿主 `~/.dsh/profiles/web` 和 MCP 服务器不会自动迁移，只会安装 `DSH_PLUGINS` 中列出的插件。
- 默认插件写 `@latest`，首次启动需要联网，且不同时间启动可能装到不同版本；要可复现就在 `DSH_PLUGINS` 里写死版本。
- 只支持 `amd64` / `arm64`，其他架构会在 Java / Go 构建阶段报错退出。
- host 模式 + root 容器适合受控的开发机；公网部署必须自己加防火墙和访问控制。

## 维护

- [构建、发版与回归测试](docs/maintainer.md)
- [Web 访问与插件机制](docs/internals.md)
