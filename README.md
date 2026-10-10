# dev-agent

通用开发镜像：Python / Node / TypeScript / Java / Rust / Go / git / DeepSeek Harness，跑在 Linux 服务器的 Docker 里，本地零安装。

## 包含什么

版本均已核实存在（2026-09 实测 Docker Hub / Adoptium API / go.dev API / npm registry）。

| 组件 | 版本 | 来源 |
|---|---|---|
| base | Debian 12 bookworm, glibc 2.36 | `python:3.12-slim-bookworm` |
| Python | 3.12.x | base 自带 |
| Node | 24（24.21.0，含 npm / yarn / corepack） | `node:24-bookworm-slim` |
| TypeScript（`tsc`） | 7.0.2 | npm（原生编译器，按架构安装） |
| `tsx` | 4.23.15 | npm（直接运行 TS / TSX） |
| Rust | 1.98.1 | `rust:1.98.1-slim-bookworm` |
| Go | 1.27.1 | go.dev 官方 tarball |
| Java | Temurin 24.0.2+12 | Adoptium API tarball |
| git | bookworm apt | — |
| DSH | 0.2.1-alpha.2 | npm |
| pnpm | 12.4.2 | npm（`dsh plugin` 依赖它） |

Node / Rust 来自 **Debian bookworm 系**（glibc 2.36），和 base 一致，所以 COPY 安全。Go 和 Java 不走 COPY，原因见下。

### 开发工具（配合 agent 用）

挑选原则：agent 在 shell 里最常敲的命令，以及语言工具链里"缺了等于半残"的那几个。

| 类别 | 工具 | 用途 |
|---|---|---|
| 代码搜索 | `rg`（ripgrep） | agent 搜代码的主力 |
| 找文件 | `fd` | Debian 的二进制叫 `fdfind`，镜像里建了 `fd` 别名 |
| 检视 | `file` `tree` `xxd` `less` `vim` `man` | 类型、结构、十六进制 |
| 数据处理 | `sqlite3` `jq` `yq`(v4) | 查库、JSON / YAML |
| 网络诊断 | `ip` / `ss` `dig` `nc` `lsof` | 端口占用、连通性、DNS |
| 进程 / 会话 | `ps` / `top` `tmux` | 长任务挂 tmux，断线不丢 |
| 构建 | `cmake` `ninja` `autoconf` `automake` `libtool` | C / C++ 项目 |
| 调试 | `gdb` `strace` | 需要 `cap_add: SYS_PTRACE`，compose 里已配好 |
| Android 调试 | `adb` | 设备调试 CLI，来自 Debian 归档包而非完整 SDK；[用法与边界见下](#adbandroid-调试桥) |
| APK 分析 | `apktool` 3.0.3 | 官方 JAR + SHA-256 校验，复用镜像 Java；支持任意目录直接调用 |
| 动态插桩 | `frida` 17.23.1 / `frida-tools` 14.11.0 | 独立 Python 环境，系统 PATH 提供 `frida`、`frida-ps`、`frida-trace` 等 CLI |
| 版本控制 | `git` `git-lfs` `gh` | |
| 其他 | `shellcheck` `bc` `rsync` `zip` / `unzip` | |

`apktool` 已安装到系统 `PATH`，普通 shell、登录 shell 和裸 `docker exec` 均可调用，不需要进入安装目录：

```bash
apktool --version
apktool d /path/to/app.apk -o /path/to/decoded
apktool b /path/to/decoded -o /path/to/rebuilt.apk
docker exec --workdir /tmp dsh-agent apktool --version
```

新增工具需要重建镜像并重建容器，已运行的旧容器不会自动获得 apktool。构建参数 `APKTOOL_VERSION` 与 `APKTOOL_SHA256` 必须配套更新。

Frida CLI 同样支持任意目录调用，无需激活 Python 环境：

```bash
frida --version
frida-ps --help
frida-trace --help
frida-ls-devices
docker exec --workdir /tmp dsh-agent frida --version
```

`frida-tools` 安装在隔离环境 `/opt/frida`，其 `frida*` 命令链接到 `/usr/local/bin`；不会向系统 Python 注入这些依赖。`frida --version` 显示的是核心 `FRIDA_VERSION`，而不是 `FRIDA_TOOLS_VERSION`。两项构建参数固定且需保持兼容。只内置客户端，不安装或启动 `frida-server`；连接设备时自行部署与核心版本、目标架构匹配的 server。新增 Frida 同样需要重建镜像和容器。

**语言工具链补全**（apt 给不了、或给的版本不能用）：

| 工具 | 版本 | 为什么不用 apt |
|---|---|---|
| `cargo clippy` / `cargo fmt` | — | rust 官方 slim 镜像只有 minimal profile，没这两个。已 `rustup component add` |
| `gradle` | 9.7.1 | Debian 的是 **4.4.1**（2017 年的），现代项目根本用不了 → 官方 distribution + sha256 |
| `yq` | 4.53.6 | Debian 的是 **3.1.0**，那是 Python 版、语法和 mikefarah v4 完全不同（`yq -y` vs `yq -o=yaml`），装错比不装更坑 → 官方二进制 + 校验和 |
| `uv` | 0.12.17 | 不在 Debian → `pip install`（会校验 PyPI 哈希，比 `curl \| sh` 干净） |
| `maven` | 3.9.16 | Debian 的 maven 包硬依赖 `default-jre-headless`，会拖进整套 openjdk-17（约 150MB）并把 `/usr/bin/java` 指向它 → 官方 tarball |
| `gh` | 2.23.0 | Debian 版本够用，直接 apt（旧但能用） |

Maven 仓库和 Gradle 缓存分别落在 `/app/.cache/m2/repository` 与 `/app/.cache/gradle`，随 `/app` 持久化。Maven 通过镜像内的 `localRepository` 设置读取 `MAVEN_CONFIG`，并非只声明一个不会生效的环境变量。

**没装的**：`nmap` / `tcpdump` / `binwalk` 这类安全工具，以及 `gopls` / `dlv` / `rust-analyzer` 这类语言服务器。它们体积不小，前者还需要额外 capability（`NET_RAW`）。要加就在 apt 列表里补，或让 agent 自己 `go install` / `rustup component add`。

> 加上这些之后镜像大概 1.5–2 GB。想瘦身：删掉 `gradle`（约 200MB 解压后）、`gdb`、`maven` 里用不到的。

## 部署

### 最短路径：直接跑镜像

```bash
mkdir -p /srv/agent
docker run -d --name dsh-agent --restart unless-stopped --network host \
  -v /srv/agent:/app \
  ghcr.io/lolkda/dsh-dev-image:latest
```

然后浏览器开 `http://<宿主机IP>:3080`。

`DSH_PLUGINS` 默认值和 `CMD` 都已经烤进镜像，所以**不需要 `-e`，也不用写 `dsh web`**。

> `--network host` 不能加 `-p`（会警告且无效）。
> 普通本地可写挂载**不需要**预先 chown；容器统一使用 root（边界见下面「权限」一节）。

### 用 compose：多了资源限制和日志上限

服务器上还跑着别的服务时建议用这个（`cpus` / `mem_limit` / `pids_limit` / 日志上限）。

```bash
git clone https://github.com/lolkda/dsh-dev-image.git
cd dsh-dev-image

mkdir -p /srv/agent   # 默认挂这里，可用 AGENT_HOME 改

docker compose up -d
docker compose logs -f          # 第一次会装插件，等几秒
```

### 单挂载点：只有 `/app` 一个出入口

只有 `/app` 持久化。其他路径仍可写，但属于容器可写层，重建容器后丢弃（不是只读文件系统）：

```
/app          ← 宿主目录，唯一出入口
  ├── ...     ← 你的代码（工作区）
  ├── .dsh/   ← DSH profile、插件、凭证、日志
  ├── .home/  ← root HOME：Git/gh/SSH 配置、用户级工具
  └── .cache/ ← cargo/go/pip/npm/maven/gradle/uv 缓存
```

- **备份** = 打包这一个目录
- **清缓存** = 停容器后清理 `/srv/agent/.cache`（不动代码和新安装的用户 CLI；旧版 Cargo/Go 工具须先迁移，见下文）
- **删容器** = 镜像层全部还原，你的东西一个不动

工具链本体（rustup 工具链、JDK、Go、Maven、Gradle）留在镜像内的 `/usr/local` 和 `/opt`，不占用挂载点 —— 它们不需要持久化，重建镜像本来就该换新的。

### 权限：统一 root，不再切换用户

镜像、入口、插件安装、DSH 主程序及默认 `docker exec` 都使用 **root（UID/GID `0:0`）**，不是通过 sudo 提权；不再创建 agent 系统用户，也不再自动跟随挂载目录的 UID/GID。Compose 服务名仍叫 `agent`，它不是 Linux 用户名。

`/app` 仍为唯一挂载点，`HOME` 和 root 的账户家目录仍为 `/app/.home`，不会切到 `/root` 导致原配置不可见。启动流程为：

```text
校验 root 身份与配置 → 创建并验证状态/CLI 目录 → 安装插件 → exec 主命令
```

- **不递归 chown**：工程、`.git`、旧 HOME、插件和缓存文件保留原属主。新文件通常属于 root；宿主普通用户直接编辑这些文件可能需要 sudo。
- **旧 UID 数据可继续访问**：两份 Compose 使用 Docker 默认 capabilities，仅额外添加调试用的 `SYS_PTRACE`，不再维护极窄的能力白名单，也不启用 privileged。默认能力包括 `CHOWN/DAC_OVERRIDE/FOWNER`，允许手动调整归属、访问旧 UID 文件和收紧 HOME 权限；`SETUID/SETGID` 等常用能力也恢复。入口仍不会自动归权或降权。
- **仍有明确边界**：root 不绕过只读挂载、NFS root-squash、用户命名空间映射或工具自身的校验。HOME、状态和 CLI 目录被文件/符号链接占用，或不可写时，会在插件和主命令前失败；`DSH_PLUGINS_REQUIRED=0` 不跳过权限错误。
- **配置与凭据不被覆盖**：仅补缺失的 Shell 默认文件。某些工具（例如 OpenSSH）会检查配置属主，旧 UID 配置即使能读取也可能被工具拒绝；这类文件可在容器内按实际报错单独调整归属，不自动接管整个 HOME。

**从 agent 版本升级：** 使用新版 Compose，并移除部署面板中的非 root `user`、`AGENT_UID/AGENT_GID` 环境覆盖及 `USER_UID/USER_GID` 构建参数。非 root 入口或直接传入非空旧身份变量会明确报错。已有 `/app/.home` 不需要为了入口检查而更换属主，也不要重新导入或删除它。旧 Compose 中的 `cap_drop: ALL` 应一并删除，只保留额外的 `SYS_PTRACE`；只改 `user: root` 不会恢复被丢弃的能力。

> 镜像支持的部署布局固定为 `/app`。入口的 `APP_DIR` 仅用于隔离测试等底层调用；仅修改它不会同步镜像 ENV、账户 HOME 与登录 PATH，不应用它改变部署布局。

然后浏览器直接开：

```
http://<宿主机IP>:3080
```

**不需要填任何 IP，没有别的步骤。**

容器起来就直接跑 `dsh web`，不用再 exec 进去手动启动。要 shell 就另开一个终端：

```bash
docker compose exec agent bash
```

想跑别的：

```bash
docker compose run --rm agent dsh headless "跑一下测试"   # 一次性任务
docker compose run --rm agent dsh tui                     # 终端界面
```

**修改了本仓库后，必须重新构建并重建容器；`restart` 不会更新旧容器中的入口。** 推荐在 Linux 部署机上执行：

```bash
docker compose up -d --build --force-recreate
docker compose logs --tail=100 agent
docker compose exec agent sh -c 'id; printf "HOME=%s\n" "$HOME"; test -w /app/.dsh'
```

如果改用 CI 已经发布的修正版，而不是本地源码：

```bash
docker compose pull
docker compose up -d --force-recreate
```

本地修改尚未发布时，拉现有 `latest` 不会带上这些修改。以上操作不会删除 `/app` 的 bind mount 数据，不需要 `down -v`。

### 发布镜像

支持 `linux/amd64` 和 `linux/arm64`。

```bash
docker pull ghcr.io/lolkda/dsh-dev-image:latest
```

| 标签 | 触发条件 |
|---|---|
| `:latest` | 默认分支最新 |
| `:main` | push 到 main |
| `:1.2.3` / `:1.2` | push `v1.2.3` tag |

构建由 [build.yml](.github/workflows/build.yml) 驱动：

1. 先调用 [verify-layout.yml](.github/workflows/verify-layout.yml)，测试当前 checkout 的入口、配置和真实 Linux 权限，而不是拉旧 `latest`。
2. 每个平台构建并 `load` 到本机 Docker，执行启动权限、工具链、缓存位置和默认 Web HTTP 验收。
3. **不重新构建**，直接推送已测镜像；通过 digest 合并多架构 manifest 后才更新公开标签。

PR 只测试 amd64、不推送；发布时 amd64 和 arm64 都必须通过。`ci-<run>-<attempt>-<arch>` 是隔离本次产物的中间标签，不建议用于部署。

**版本号只写在 Dockerfile 的 ARG 默认值里**，CI 不重复声明 —— 改版本改那一行就够了。

> **已实测**：公开仓库推的 GHCR 包默认可匿名拉取，不需要手动改 visibility。
> 匿名请求 `ghcr.io/v2/lolkda/dsh-dev-image/manifests/latest` 返回 200。
>
> 两个平台在独立原生 runner 上并行构建与验收：amd64 使用 `ubuntu-latest`，arm64 使用 `ubuntu-24.04-arm`，不再通过 QEMU 模拟运行。缓存仍按架构隔离，完整启动、工具链和 Web 验收全部保留；单个平台上限仍为 90 分钟。
>
> 镜像不小：amd64 压缩后约 1.4 GB，arm64 约 1.3 GB。大头是 gradle（解压后约 200MB）、
> Go 工具链、JDK，以及 apt 那一层。想瘦身就删 gradle 或 gdb。

## 进去干活

```bash
docker compose exec agent bash
```

冒烟测试：

```bash
docker run --rm -e DSH_PLUGINS= ghcr.io/lolkda/dsh-dev-image:latest bash -lc \
  'python -V && node -v && pnpm -v && tsc --version && tsx --version && go version && rustc -V && java -version && git --version && adb version >/dev/null && dsh --help >/dev/null && echo ALL-OK'
```

镜像构建过程本身有两道检查：每条 COPY 后面立刻验证该工具链，最后再跑一次全链路冒烟。任何一条路径不对，`docker compose build` 当场失败，不会拖到运行时。

### TypeScript：检查、编译与直接运行

预装的 `tsc` 和 `tsx` 位于镜像层的 `/usr/local`，不需要启动时再安装，也不会被 `/app` 挂载遮蔽。普通 Shell 和登录 Shell 都可使用：

```bash
tsc --version
tsx --version

# 在有 tsconfig.json 的项目根目录中：
tsc --noEmit -p tsconfig.json   # 只做类型检查
tsc -p tsconfig.json            # 按项目配置编译
tsx src/index.ts               # 直接运行；同样支持 .tsx
```

`tsx` 只转译并运行，**不做类型检查**，请配合 `tsc --noEmit`。Node 24 自带的类型擦除也不能替代编译器，`enum` 等需要转译的语法可交给 `tsx`。

默认 TypeScript 7 使用原生编译器，不再附带旧版 `tsserver`。依赖旧版 TypeScript 工具链的项目应在自己的依赖中锁定兼容版本；可用 `TYPESCRIPT_VERSION` 构建参数调整镜像默认版本。

全局工具用于开箱即用，不替代项目依赖：项目应按需声明 `typescript`、`tsx` 和 `@types/node`，通过 npm scripts 使用项目锁定的版本。镜像不全局安装框架或项目类型声明。

### ADB（Android 调试桥）

`adb` 装的是 **Debian 12 bookworm 官方归档**的 [`adb`](https://packages.debian.org/bookworm/adb) 二进制包（源码包 `android-platform-tools`，bookworm 里是 `1:29.0.6-28`，`amd64` / `arm64` 都有），由 `apt-get install --no-install-recommends` 装成 `/usr/bin/adb`（真实二进制在 `/usr/lib/android-sdk/platform-tools/adb`）。系统 `PATH` 本来就含 `/usr/bin`，所以没有 alias、wrapper 或额外 PATH 编排，任意目录、普通/登录 Shell，以及不经 Shell 的 `docker exec` 都能直接用：

```bash
adb version
docker compose exec --workdir /tmp agent adb version
```

**范围。** 只有 adb 命令行本身：不含完整 Android SDK，不含 `fastboot`。Debian 维护的版本不是 Google 官方最新 Platform Tools。

**重建后生效。** `adb` 在镜像层，不在 `/app` 卷里，所以要重建镜像并重建容器：

```bash
docker compose up -d --build --force-recreate
```

`docker build` 之后只 `restart` 旧容器不会换镜像（`docker compose restart` 同理）；上面的命令显式重建容器以使用新镜像。构建时会用 `adb version` 在两条 PATH 路径上各检查一次，装不上就当场失败。

**CLI 可用 ≠ 真机可调试。** 默认 compose 不映射宿主 USB 设备，也不加 `--privileged` 或额外权限；`--no-install-recommends` 同时**没有**装 udev 规则推荐包（`android-sdk-platform-tools-common`）。要让容器直连 USB 真机，仍须把设备显式映射进来（`--device` / `devices:`，由使用者按需决定）。设备端的「USB 调试」开关和 adb 的「允许此电脑调试」授权同样在容器之外。

**不启动 daemon。** 构建期和冒烟只调用 `adb version`：它在客户端本地打印版本，不需要设备，也不会拉起 ADB server。

---

## Web 访问是怎么通的

### 默认就是零配置

[compose.yml](compose.yml) 用的是 `network_mode: host`。容器共享宿主网络栈后，dsh 的 `/api` Host 围栏在自动派生信任列表时看到的就是宿主真实网卡：

```js
// dsh-web-app/lib/index.js:83
Object.values(networkInterfaces()).flat()
  .filter(i => i.family === "IPv4" && !i.internal).map(i => i.address)
```

→ LAN / Tailscale / ZeroTier / VPN **全部自动可信**，DHCP 变了重启就跟着变。这就是为什么不需要填 IP。

> ⚠️ **唯一要注意的**：host 模式下 dsh 绑 `0.0.0.0`，会在**所有**宿主网卡上监听。这台机器只要有公网 IP，防火墙就不是可选项：
>
> ```bash
> ufw allow from 192.168.1.0/24 to any port 3080 proto tcp
> ufw allow in on tailscale0 to any port 3080 proto tcp   # 用 Tailscale 的话
> ufw deny 3080/tcp
> ```

### 为什么 `--host 0.0.0.0` 不能用命令行给

不是配置问题，是**硬拒**：

```js
// dsh-web-app/lib/startup.js:40
if (options.host === "0.0.0.0") program.error(
  "error: --host 0.0.0.0 is intentionally not supported yet for safety: " +
  "it would expose remote code execution to the network; use 127.0.0.1 instead");
```

而 schema 只接受两个值：

```js
// dsh-host-webserver/lib/index.js:141
host: z.union([z.const("127.0.0.1"), z.const("0.0.0.0")]).required(),
```

**容器里这是死结**：dsh 绑 `127.0.0.1` 的话，Docker 端口映射转发不到（`-p` 转发到容器 IP，不是容器 loopback）。所以容器内必须绑 `0.0.0.0` —— 唯一的路是 patch 层，也就是 `@lolkda/dsh-web-lan`，已默认装在 `DSH_PLUGINS` 里。

### `/api` 围栏拦什么

`/api` 上有个防 DNS rebinding 的 Host 校验：

```js
// dsh-client-connection/lib/index.js:552
if (!isTrustedApiRequest(request, this.trustedHosts)) return 403;
```

只放行 **loopback** 或命中 `trustedHosts` 的 Host，而且是**精确匹配、不支持通配**：

```js
// dsh-client-connection/lib/index.js:188
return canonicalAuthority(entry, entryUrl) === entryUrl.hostname
  ? entryUrl.hostname === hostUrl.hostname      // 精确相等
  : entryUrl.host === hostUrl.host;
```

`*` 会被 WHATWG 解析成字面量主机名，永远不匹配。

**注意 Web GUI 本身就是 `/api` 的客户端** —— 页面本身是静态资源（不过围栏），但你在页面上做的一切（会话列表、发消息、看文件）全是浏览器往 `/api` 发请求。所以 Host 对不上时，症状是**页面能打开、然后一片空白**。

### 想要容器网络隔离：`compose.bridge.yml`

```bash
DSH_HOST=192.168.1.5 docker compose -f compose.bridge.yml up -d
```

保留容器的独立网络（容器无法访问宿主 loopback 上的服务），代价是**必须填一次 `DSH_HOST`**：

| 变量 | 作用 |
|---|---|
| `DSH_HOST` | 你浏览器里输入的宿主机 IP。同时决定端口发布到哪张网卡 + 围栏信任哪个 Host |
| `DSH_PORT` | 宿主机端口，默认 3080。改它不影响围栏（信任项是 port-less 的，匹配任意端口） |

映射关系是 `${DSH_HOST}:${DSH_PORT}:3080` —— 右边固定 3080，是容器内 dsh 的默认监听端口。

为什么躲不掉这个值：bridge 下容器看到的网卡是 `172.x`，浏览器发来的 Host 是宿主地址，两者对不上 → 403。**这是 dsh 的设计，不是配置缺失。**

---

## DSH 插件

### 机制

一个 DSH 插件就是一个普通 npm 包，在 `package.json` 里声明：

```json
"dsh": { "bundle": { "patch": "./cordis.patch.yml" } }
```

`dsh plugin --profile <p> add <spec>` 做两件事：

1. **在 profile 目录里跑 pnpm**（CLI 原话："forwarding the remaining arguments to pnpm in the profile directory"）；
2. `reconcilePlugins` 把包名追加进 profile `package.json` 的 `dsh.profile.bundles`。

于是这一层成为**每次启动的一部分**，不再需要 `--patch`。

profile 目录结构（`$DSH_HOME/profiles/web/`）：

```
package.json          # dependencies + dsh.profile.bundles（插件名单）
pnpm-lock.yaml
pnpm-workspace.yaml   # nodeLinker: hoisted
cordis.yml            # profile 根，空数组 —— 别改它
cordis.patch.yml      # 你自己的 patch 层，在每个 bundle 层之后应用
node_modules/
```

### 为什么必须在启动时登记，不能在 build 期

profile 位于 `$DSH_HOME/profiles/<name>/`，而 `$DSH_HOME` 是**挂载卷**。构建期写进镜像的 profile 内容会被（首次启动时还是空的）卷整个遮蔽，症状是"插件装了但没生效"，而且完全静默。

所以登记放在 [entrypoint.sh](entrypoint.sh) 里，卷挂好并完成 root 状态初始化后才执行。每次启动仍会执行 `pnpm add`：缓存可以复用，但带版本范围的包仍可能查询 registry，**不保证完全离线或永远解析成同一版本**。

`DSH_PROFILE` 同时用于插件安装和默认 Web 启动。`dsh web` 会转换为 `dsh --profile <所选 profile>`，其余启动参数保留；非默认 profile 仍需要具备相应的 Web 配置。

`DSH_PLUGINS` 未设置时使用镜像/Compose 默认插件；显式置空会跳过安装。注意：跳过安装**不会卸载已有 profile 内的插件**；新 profile 若没有 LAN 插件，也不会按默认方案对外监听。

### 默认插件与升级

镜像和两份 Compose 的默认列表是：

| 插件 | 版本 | 用途 |
|---|---|---|
| `@lolkda/dsh-web-lan` | 不锁定：每次启动装 registry 最新发布 | Web 局域网访问与相关设置 |
| [`dsh-auto-thinking-levels`](https://github.com/lolkda/dsh-auto-thinking-levels) | 不锁定：每次启动装 registry 最新发布 | 为 `llm-pi-ai` 路由补充缺失的思考等级，不覆盖已有档位或 `reasoningEfforts: false` |

两个默认插件都刻意不写版本号。它们独立于镜像发版（写这份说明时 registry 上 web-lan 是 `0.2.0`、auto-thinking-levels 是 `0.1.2`，而镜像过去锁的是 `0.1.1` / `0.1.0`）：锁死版本意味着插件发新版后，只拉镜像、只重启容器都不会更新，只能改 `DSH_PLUGINS` 重建镜像。不写版本时，每次启动都由 `pnpm add <包名>` 解析 registry 当前的 latest，镜像不必为了插件升级重新发布。

**入口会关掉 pnpm 的新版本成熟期**（[entrypoint.sh](entrypoint.sh) 里 `PNPM_CONFIG_MINIMUM_RELEASE_AGE=0`）。pnpm 12 自带 24 小时 `minimumReleaseAge`（默认 1440 分钟），会把"刚发布、还不够成熟"的版本回退到上一个成熟版本 —— 实测 web-lan `0.2.0` 发布 3 小时时，裸装解析到的仍是 `0.1.1`。要求"装最新"就得绕开它，否则"不指定版本"实际等价于"装一天前的最新版"。这个覆盖只作用于 `DSH_PLUGINS` 的安装命令，容器里用户项目的 pnpm 安装仍走 pnpm 自己的默认策略。

代价说清楚：**同一个镜像在不同时间启动可能装到不同版本**，上游发大版本（含破坏性改动）也会被直接吃进来；registry 不可达时按 `DSH_PLUGINS_REQUIRED` 处理（默认直接退出）。要可复现就在 `DSH_PLUGINS` 里写死版本。

这里的“内置”沿用启动时自动安装并登记到 profile 的方式，不代表首次启动无需联网。自动思考等级插件只处理 `llm-pi-ai`，不保证其他 adapter 或上游模型支持所有等级。

### 加 / 换插件

在 [compose.yml](compose.yml) 中覆盖 `DSH_PLUGINS`（空格分隔，需要额外插件时追加到末尾；版本号可写可不写）：

```yaml
DSH_PLUGINS: "@lolkda/dsh-web-lan dsh-auto-thinking-levels"
```

升级旧容器时必须重新创建容器。若部署面板或旧配置保留了原来的 `DSH_PLUGINS` 环境变量，请清除覆盖值或改为上面的新列表；只拉取镜像、只重启旧容器不会更新已经保存的环境变量。启动用户固定为 `0:0`，入口和主程序全程使用 root，不再降权。

离线环境设 `DSH_PLUGINS_REQUIRED=0`，装不上也继续启动（默认 `1`，装不上直接退出，不静默降级）。

### `link:` 装法注意

本地 checkout 的插件（`dsh plugin add link:/path`）需要那个路径**在容器里存在**。宿主的 `F:/project/...` 在 Linux 容器里没有意义。要么用 registry 版本，要么先把 checkout 拷进镜像。

---

## 改版本

```bash
docker compose build --build-arg JDK_VERSION=25
```

| arg | 默认 | 说明 |
|---|---|---|
| `GO_VERSION` | `1.27.1` | 校验和从 go.dev API 现取，改版本不用手改 sha |
| `JDK_VERSION` | `24` | Adoptium 的 feature version |
| `DSH_VERSION` | `0.2.1-alpha.2` | npm 版本号或 dist-tag |
| `PNPM_VERSION` | `12.4.2` | — |
| `TYPESCRIPT_VERSION` | `7.0.2` | TypeScript 编译器 `tsc` |
| `TSX_VERSION` | `4.23.15` | TS / TSX 脚本运行器 |

> **Java 版本建议**：24 是 non-LTS，早已 EOL。当前 LTS 是 **25**，最新 feature release 是 26。走 Adoptium 路线换版本**不需要动 base**，改 `JDK_VERSION` 即可。
>
> **Node / Rust 换版本**要注意 glibc：源镜像必须继续取 bookworm 变体（glibc 2.36）。换成 `-noble` / `-trixie` 会因为 glibc 2.39 / 2.41 > 2.36 而炸。

## Node / Python 国内依赖源

容器内日常安装依赖，默认使用以下 HTTPS 源：

| 工具 | 默认源 | Docker 环境覆盖变量 |
|---|---|---|
| npm | `https://registry.npmmirror.com` | `npm_config_registry` |
| pnpm 12 | `https://registry.npmmirror.com` | `PNPM_CONFIG_REGISTRY` |
| Yarn Classic | `https://registry.npmmirror.com` | `YARN_REGISTRY` |
| pip | `https://mirrors.aliyun.com/pypi/simple/` | `PIP_INDEX_URL` |
| uv | `https://mirrors.aliyun.com/pypi/simple/` | `UV_DEFAULT_INDEX` |

**工具链构建与运行时依赖源分开。** 镜像内固定版本的 DSH、pnpm、uv 等仍从官方源构建；国内源在最后作为运行时默认值写入镜像。原因是镜像站存在同步延迟，实际遇到过阿里云 PyPI 缺少 `uv==0.12.17`，不能因此让构建失败或降低工具版本。日常安装若遇到镜像缺包，也可显式切回官方源，不会静默换源。

[pnpm 12 不再读取 `npm_config_*`](https://pnpm.io/configuring#environment-variables)，[uv 也有独立的索引配置](https://docs.astral.sh/uv/concepts/indexes/)，所以不能只设置 npm/pip 就认为其他工具也生效。这里没有关闭证书校验，也没有添加 `trusted-host`。

两份 Compose 提供两个输入，一次切换对应工具组。例如切回官方源：

```bash
NPM_REGISTRY=https://registry.npmjs.org/ \
PYPI_INDEX_URL=https://pypi.org/simple/ \
docker compose up -d --force-recreate
```

直接 `docker run` 时，用表中的变量逐项覆盖，例如 `-e PNPM_CONFIG_REGISTRY=https://registry.npmjs.org/`。npm、pnpm、Yarn 是独立变量；pip 和 uv 也是独立变量。项目显式指定的索引、scoped registry 或锁文件中的固定下载 URL 仍可能优先于默认源。

这些设置只改变包管理器的依赖源，不改变 Node/Python 的版本、基础镜像来源，也不代理 GitHub、浏览器驱动等独立二进制下载。Docker 拉取镜像的加速需要另行配置 Docker，不由 npm/pip 源控制。

镜像升级后需重建容器；如果部署面板保留了旧的源环境变量，应清除覆盖或更新其值。CI 会检查工具实际解析的源，并验证国内源下载与切回官方源的行为。

## 用户级 CLI：安装与持久化

新安装的用户级 CLI 默认统一放在 `/app/.home/.local` 下，随唯一的 `/app` 挂载持久化，**不再依赖 `/usr/local` 的属主或可写性**。两份 Compose 自动继承镜像默认值，无需新增挂载或手工运行 `pnpm setup`。

| 安装方式 | 安装数据位置 | 命令目录 | 原生覆盖变量 |
|---|---|---|---|
| `npm install -g` | `/app/.home/.local/lib/node_modules` | `/app/.home/.local/bin` | `npm_config_prefix` |
| `pnpm add -g` | `/app/.home/.local/share/pnpm/global`（版本子目录由 pnpm 管理） | `/app/.home/.local/share/pnpm/bin` | `PNPM_HOME`；也支持 `PNPM_CONFIG_GLOBAL_DIR` / `PNPM_CONFIG_GLOBAL_BIN_DIR` |
| `yarn global add` | `/app/.home/.local/share/yarn/global` | `/app/.home/.local/bin` | `YARN_GLOBAL_FOLDER` / `YARN_PREFIX` |
| `python -m pip install --user` | `/app/.home/.local/lib/python3.12/site-packages` | `/app/.home/.local/bin` | `PYTHONUSERBASE` |
| `uv tool install` | `/app/.home/.local/share/uv/tools` | `/app/.home/.local/bin` | `UV_TOOL_DIR` / `UV_TOOL_BIN_DIR` |
| `cargo install` | `/app/.home/.local`（含安装记录） | `/app/.home/.local/bin` | `CARGO_INSTALL_ROOT` |
| `go install` | 编译缓存仍在 `/app/.cache/go` | `/app/.home/.local/bin` | `GOBIN` |

日常以 root 身份安装，例如：

```bash
docker compose exec agent bash
npm install -g eslint
pnpm add -g @biomejs/biome
uv tool install ruff
```

- **安装与缓存分开**：新 CLI 的安装数据不放在可清理的 `/app/.cache`。不要把本地源码 `link` 安装等同于独立安装；链接指向的源码也必须保留。
- **两种 Shell 都可用**：[cli-env.sh](cli-env.sh) 在 root 入口和登录 Shell 中复用，路径在第一次安装前就加入 PATH；镜像 ENV 还覆盖不经过入口的 `docker exec ...`。pnpm **12** 的命令目录是 `$PNPM_HOME/bin`，不是旧版常见的 `$PNPM_HOME`。
- **不覆盖用户配置**：不会改写已有 npm、pnpm、Yarn 或 Shell 配置文件。表中环境变量按包管理器原生优先级覆盖配置文件；需要自定义时，通过 Docker 的 `-e` 或 Compose 的 `environment` 显式设置相应变量。自定义目录必须是非根目录的绝对路径、不能含冒号，并应位于 `/app` 中才能持久化。改变路径后通过入口或新的登录 Shell 更新 PATH；单独给裸 `docker exec` 改 prefix 不会自动改其 PATH。
- **不改变项目依赖**：项目内 npm 安装、Python venv 等仍按原方式工作；没有设置强制 `PIP_USER`。Python CLI 推荐 `uv tool install`，或明确使用 `pip install --user`。
- **权限统一为 root**：CLI 目录以 root 创建与验证，既有数据不递归改属主。路径被文件、链接占用或不可写时，在安装插件前失败；旧 UID 数据不再触发 HOME 身份迁移检查。
- **用户命令优先**：默认用户 CLI 路径排在镜像工具之前；同名命令尽量只交给一个包管理器管理，避免互相覆盖。镜像自带的 DSH、pnpm 和语言运行时仍在构建期安装到镜像层，不会被首次挂载遮蔽。

### 从旧版本升级

修改默认安装位置不等于搬迁已有工具：

1. 旧容器中装到 `/usr/local` 的额外全局包不会自动复制。删除旧容器前先记录需要保留的包和版本，再以 root 在新容器中重新安装；旧容器删除后无法从新镜像找回这些包。
2. 旧 Cargo/Go 工具所在的 `/app/.cache/cargo/bin`、`/app/.cache/go/bin` 仍保留在 PATH，重装到新默认目录后才适合清理旧缓存。
3. 旧 Yarn 全局包默认位于 HOME 的 `.config/yarn/global`；可显式保留 `YARN_GLOBAL_FOLDER=/app/.home/.config/yarn/global`，或按原包列表重新安装到新目录。已有文件不会被入口搬移或覆盖。

部署新行为需要**重新构建并重建容器**，只 `restart` 不会更新入口和镜像 ENV。持久化不保证跨 CPU 架构、Python 次版本或不兼容系统库升级后仍可运行；这类升级应重装相应的原生 CLI / 虚拟环境。

## HOME 持久化与旧版本迁移

root 的 `HOME` 和 Linux 账户家目录现在都是 `/app/.home`，不再创建额外的主目录兼容链接。工作目录仍是 `/app`，仍然只需挂载一个宿主目录。

- 新建 HOME 使用 `0700` 私有权限；[初始化模块](home-init.mjs) 只补缺失的系统 Shell 默认文件，不覆盖已有文件或跟随已有文件链接写入。
- Git/gh/SSH 的磁盘配置、凭据文件和 HOME 下的用户级安装现在随 `/app` 保留。pnpm store 仍单独放在 `/app/.cache/pnpm-store`；可用 `PNPM_CONFIG_STORE_DIR` 显式覆盖，已有用户配置文件不会被改写。
- 系统 Git 默认忽略 `/.home/` 和 `/.home-import.*/`，仓库也排除了这些目录。自定义 `core.excludesFile` 可能覆盖系统默认值；不要强制把 HOME 或导出的凭据提交到 Git。
- 这不保存 `ssh-agent` 解锁状态、`git credential-cache` 的内存数据，也不能恢复已过期/撤销的 token。`/usr/local` 的额外全局安装仍不属于 HOME 持久化范围。

**已有 `/app/.home` 时直接复用原挂载，不要为升级删除它。** 仓库不再提供旧容器层 HOME 的专用迁移脚本；尚未持久化的数据需要在删除旧容器前自行备份，新镜像无法自动找回已经删除的容器层。

日常登录工具与 DSH 一样使用 root，不需要 sudo：

```bash
docker exec -it dsh-agent bash
# 例如在该终端里运行 gh auth login / SSH 配置命令
```

## 缓存与卷

只有一个 bind mount，没有额外的命名卷：

| 宿主位置（默认） | 容器位置 | 内容 |
|---|---|---|
| `/srv/agent` | `/app` | 工作区代码 |
| `/srv/agent/.dsh` | `/app/.dsh` | DSH profile、插件、凭证、日志 |
| `/srv/agent/.home` | `/app/.home` | root 的用户配置、磁盘凭据和用户级安装 |
| `/srv/agent/.cache` | `/app/.cache` | 各语言缓存和 pnpm store |

`docker compose down` 删除容器，不删除这些宿主数据；加 `-v` **也不会删除 bind mount**。要验证全新状态，请换一个空的 `AGENT_HOME`，不要把清理命名卷误当作重置。

```bash
# 用隔离的空目录检查一次启动，不动原工作区
AGENT_HOME="$(mktemp -d)" DSH_PLUGINS='' docker compose run --rm --no-deps agent \
  sh -c 'id; test -w /app/.dsh && echo STATE-OK'
```

备份整个挂载目录即可保留工作区和 DSH 状态。清缓存前应先停止容器；不要在运行中的包管理器旁边删除缓存。

## 安全设计（这台机器还跑着线上服务）

- **没有挂 `/var/run/docker.sock`**。挂上等于容器内 root == 宿主机 root == 所有服务暴露。需要"容器里再跑容器"时，用 Sysbox 或 socket-proxy 单独解决。
- **资源限死**：`cpus` / `mem_limit` / `pids_limit`。`pids_limit` 是防 fork bomb 的，agent 跑失控构建会 fork 爆宿主机。
- **root-only + Docker 默认 capabilities**：不写 `cap_drop`，仅额外添加 `SYS_PTRACE`，保留 `no-new-privileges`，不加 privileged。默认能力不等于全部能力，`SYS_ADMIN/NET_ADMIN` 等仍未额外开放；也不会自动获得宿主文件系统、Docker socket 或所有设备。
- **日志上限 10MB × 3**，防止长输出写满磁盘。
- host 模式下**必须**配防火墙，见上文。

> 顺带一提：`@lolkda/dsh-web-lan` 支持 `autoLogin: true` + `/go` 免 token 入口。官方拒 `0.0.0.0` 的理由是"这个面板等价于任意命令执行"；而在容器里，那个"任意命令执行"被限制在容器内 —— 有工作区卷、有网络，但没有 docker.sock，也没有宿主文件系统。**同一个开关在容器里比在裸机上安全得多。**
>
> 开启方式：在 `$DSH_HOME/profiles/web/cordis.patch.yml` 里按 id 定向：
>
> ```yaml
> - id: dsh-web-lan
>   name: '@lolkda/dsh-web-lan'
>   config:
>     autoLogin: true
> ```

## 几个刻意的取舍

**base 用 `python:3.12-slim-bookworm` 而不是裸 `debian:bookworm-slim`。**
官方 python 镜像构建时会用 `ldd` 反查 python 实际依赖的 `.so`，把提供这些库的 apt 包（`libexpat1` / `libffi8` / `libsqlite3-0` / `liblzma5` / `libgdbm6` / `libreadline8` / `libuuid1` …）标记为 manual 保留，并跑过 `ldconfig`。换成裸 debian 再 COPY python 的 `/usr/local`，这些库一个都不会在，`import sqlite3` / `ssl` / `ctypes` 全部 ImportError，而且报错很晚。

**Java 不走 COPY。**
`eclipse-temurin:24-jdk` 只有 noble 变体（`24-jdk-jammy` 已 404），noble 的 glibc 2.39 > base 的 2.36，COPY 进来会炸。改用 Adoptium 官方 tarball，面向 glibc 2.17+ 构建，放进 bookworm 安全，且换版本不用动 base。下载后用 API 返回的 sha256 校验。

**Go 也不走 COPY。**
golang 官方镜像里 `/usr/local/go` 是指向 `/target/usr/local/go` 的**符号链接**（为了 `SOURCE_DATE_EPOCH` 可复现性刻意做的）。跨阶段 COPY 对符号链接的处理依赖构建器实现，不可靠，所以直接取 go.dev 的官方 tarball。

**Node 的 `/opt` 必须一起 COPY。**
node 镜像把 yarn 装在 `/opt/yarn-1.22.22/`，而 `/usr/local/bin/yarn` 是指向它的符号链接。只拷 `/usr/local/bin` 会留下断链 —— `which yarn` 找得到、一执行就失败。

**不能用 alpine。**
musl libc 和 manylinux wheel、native node 模块、JVM 全部不兼容，等于逼你从源码构建一切。

**`dsh` 不用 `@latest`。**
dist-tag 会变化，且不保证指向所需的预发布版本。镜像通过 `DSH_VERSION` 显式固定为 `0.2.1-alpha.2`，避免重建时随标签漂移。

**镜像工具链与用户 CLI 分开。**
`/usr/local` 保留构建期属主，运行时 root 可修改它，但容器重建后丢弃；新用户 CLI 通过持久化 HOME 下的原生安装目录避免重建丢失。显式指定 `/usr/local` 的系统级安装不保证重建后保留。DSH 插件继续安装在 `/app/.dsh`，项目依赖优先使用工作区或虚拟环境。

**rust / go 需要 `build-essential`。**
不只是为了编译 C 扩展：`rustc` 需要一个 cc 才能链接产物，node / rustc / libjvm.so 还都动态链接 `libstdc++6` 和 `libgcc_s`，这两个由 `build-essential` 带进来。

## 已知缺口

- **容器里的 profile 是全新的空 profile。** 宿主 `~/.dsh/profiles/web` 里的东西（dshmarket、prompt-manager、skills-manager、`link:` 装的本地插件）不会自动跟过来，只有 `DSH_PLUGINS` 里列的会装。要带全套得另做 seed。
- **MCP 服务器同理**：它们注册在 profile 的 `cordis.patch.yml` 里，不在容器里。而且 `ida` / `reqable` 是 Windows 宿主上的应用，本来就带不过来；`fastctx` 是纯文件/shell，可以。
- **`adb` 只有命令本身，默认没有 USB 透传。** 容器未映射宿主 USB 设备，也没装 udev 规则推荐包，真机调试的 udev 授权与设备映射由使用者在宿主侧按需处理；默认 compose 不为此扩大权限。详见 [ADB（Android 调试桥）](#adbandroid-调试桥)。
- 默认没有 docker 访问能力，容器内不能 `docker build` / `docker compose up`。
- 默认只支持 `amd64` / `arm64`，其他架构会在 Java / Go 那两步显式报错退出。

## 开发与回归验证

不需要安装 npm 测试依赖。静态检查和独立模块测试可用普通用户运行；入口的成功路径必须使用真实 root，普通用户运行 Node 测试时这些用例会明确跳过，不能算通过：

```bash
node --test tests/*.test.mjs
npm run verify-notes
for script in entrypoint.sh cli-env.sh tests/*.sh; do bash -n "$script"; done
shellcheck entrypoint.sh cli-env.sh tests/*.sh
sh -n cli-env.sh
node --check home-init.mjs
```

Linux 测试机上补跑 `sudo env PATH="$PATH" bash tests/entrypoint.test.sh` 和 `sudo env PATH="$PATH" node --test tests/*.test.mjs`；只操作隔离 fixture，不应对真实工作区运行入口。[CLI 回归测试](tests/entrypoint.test.sh) 实际执行 root 入口，只替换外部插件安装命令；[配置测试](tests/config.test.mjs) 验证空值展开、版本默认值、失败传播和发布约束；[用户 CLI 回归](tests/user-cli.test.mjs) 在隔离 HOME 中验证实际 npm prefix、本地包安装、路径覆盖和 PATH 恢复。用户 CLI 集成用例依赖 POSIX 路径和原生 npm，在 Windows 跳过、由 Linux CI 执行；配置测试可在 Git Bash 运行，root-only 入口验收需要 Linux。[ADB 回归](tests/adb.test.mjs) 校验 `adb` 来自最终镜像的系统包安装（而非用户目录或构建期临时下载）、构建期两条 PATH 都 fail-fast、并且没有 alias / shell 函数 / daemon 启动。这些检查**不能替代 Linux 的 UID、capability、挂载权限测试**。

Linux + Docker 下的快速权限验收：

```bash
docker build -f tests/Dockerfile -t dsh-entrypoint-test .
bash tests/container-runtime.sh dsh-entrypoint-test
```

[容器回归脚本](tests/container-runtime.sh) 使用真实文件权限和 Docker 默认 capabilities，额外验证测试子进程可切换到 1000:1000，覆盖 root 启动、旧 UID 的 `0700` 工作区与私有 HOME、深层混合属主文件读写且不改归属、重启、非 root/旧身份配置拒绝、缺少 capabilities、只读挂载和符号链接等场景；不会用 mock 冒充 Linux 权限模型。

完整镜像验收（需要网络安装默认插件）：

```bash
docker build -t dsh-dev-image:verify .
bash tests/container-runtime.sh dsh-dev-image:verify
bash tests/image-smoke.sh dsh-dev-image:verify
```

[完整镜像冒烟](tests/image-smoke.sh) 检查登录/非登录 shell、实际 TypeScript/TSX 与 Rust 编译运行、Maven/pnpm 缓存位置，以及默认 Web 的真实登录流程；同时在 **root** 的两种 Shell 里从 `/tmp` 执行 `adb version`，再用裸 `docker exec --workdir /tmp` 复核一次，全程不启动 ADB server（构建期也在两条 PATH 路径上各跑一次 `adb version`）。[TypeScript 验收](tests/typescript-smoke.sh) 在 root 的两种 Shell 中验证 ESM 跨模块导入、`enum` 转译、无框架 TSX 和类型错误拒绝，不下载项目依赖。其中的[用户 CLI 容器验收](tests/user-cli-runtime.sh) 以 root 在新目录与旧 UID 目录中运行[离线安装用例](tests/user-cli-smoke.sh)：实际安装 npm/pnpm/Yarn/pip/uv/Cargo/Go 的无依赖本地 CLI，换容器、清缓存后再次运行，并验证裸 `docker exec`；同时检查项目 npm 安装和 Python venv 未被全局目录配置影响。CI 中的 `dsh web --no-open` 是**临时验收**，只把随机端口发布到 runner 的 loopback，结束后删除容器和 cookie，不是在 Actions 上正式部署。

DSH 对匿名 `/` 请求返回 `401` 是正常鉴权行为，不能用匿名 `curl --fail` 判断服务是否启动。验收从该测试容器的启动日志取 token，跟随登录重定向并保留 cookie，最终必须获得 `200`；不会为了测试通过而关闭鉴权。[Web 登录回归](tests/web-ready.test.mjs) 使用真实 HTTP 服务覆盖此流程及失败分支。

CI 在发布前执行这些步骤；没有实际运行 Docker 的本地检查不能标记为容器验收通过。
