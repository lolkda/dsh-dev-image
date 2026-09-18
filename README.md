# dev-agent

通用开发镜像：Python / Node / Java / Rust / Go / git / DeepSeek Harness，跑在 Linux 服务器的 Docker 里，本地零安装。

## 包含什么

版本均已核实存在（2026-09 实测 Docker Hub / Adoptium API / go.dev API / npm registry）。

| 组件 | 版本 | 来源 |
|---|---|---|
| base | Debian 12 bookworm, glibc 2.36 | `python:3.12-slim-bookworm` |
| Python | 3.12.x | base 自带 |
| Node | 24（24.21.0，含 npm / yarn / corepack） | `node:24-bookworm-slim` |
| Rust | 1.98.1 | `rust:1.98.1-slim-bookworm` |
| Go | 1.27.1 | go.dev 官方 tarball |
| Java | Temurin 24.0.2+12 | Adoptium API tarball |
| git | bookworm apt | — |
| DSH | 0.1.6-alpha.2 | npm |
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
| 版本控制 | `git` `git-lfs` `gh` | |
| 其他 | `shellcheck` `bc` `rsync` `zip` / `unzip` | |

**语言工具链补全**（apt 给不了、或给的版本不能用）：

| 工具 | 版本 | 为什么不用 apt |
|---|---|---|
| `cargo clippy` / `cargo fmt` | — | rust 官方 slim 镜像只有 minimal profile，没这两个。已 `rustup component add` |
| `gradle` | 9.7.1 | Debian 的是 **4.4.1**（2017 年的），现代项目根本用不了 → 官方 distribution + sha256 |
| `yq` | 4.53.6 | Debian 的是 **3.1.0**，那是 Python 版、语法和 mikefarah v4 完全不同（`yq -y` vs `yq -o=yaml`），装错比不装更坑 → 官方二进制 + 校验和 |
| `uv` | 0.12.17 | 不在 Debian → `pip install`（会校验 PyPI 哈希，比 `curl \| sh` 干净） |
| `maven` | 3.9.16 | Debian 的 maven 包硬依赖 `default-jre-headless`，会拖进整套 openjdk-17（约 150MB）并把 `/usr/bin/java` 指向它 → 官方 tarball |
| `gh` | 2.23.0 | Debian 版本够用，直接 apt（旧但能用） |

`MAVEN_CONFIG` 和 `GRADLE_USER_HOME` 都指向 `/opt/cache`，随 `agent-cache` 卷持久化。

**没装的**：`nmap` / `tcpdump` / `binwalk` 这类安全工具，以及 `gopls` / `dlv` / `rust-analyzer` 这类语言服务器。它们体积不小，前者还需要额外 capability（`NET_RAW`）。要加就在 apt 列表里补，或让 agent 自己 `go install` / `rustup component add`。

> 加上这些之后镜像大概 1.5–2 GB。想瘦身：删掉 `gradle`（约 200MB 解压后）、`gdb`、`maven` 里用不到的。

## 部署

```bash
# 1. 拿文件
git clone https://github.com/lolkda/dsh-dev-image.git
cd dsh-dev-image

# 2. 准备挂载目录（默认挂 /srv/agent/workspace，可用 AGENT_WORKSPACE 改）
mkdir -p /srv/agent/workspace

# 3. 起（自动拉镜像）
docker compose up -d

# 4. 看日志，确认插件装上了
docker compose logs -f
```

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

`compose.yml` 的 `image:` 指向已发布镜像，`docker compose up` 会自动拉。想本地自己构建就加 `--build`：

```bash
docker compose up -d --build
```

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

构建由 [.github/workflows/build.yml](.github/workflows/build.yml) 驱动：push 到 main 或打 tag 时构建并推送，PR 只构建不推送。

**版本号只写在 Dockerfile 的 ARG 默认值里**，CI 不重复声明 —— 改版本改那一行就够了。

> **已实测**：公开仓库推的 GHCR 包默认可匿名拉取，不需要手动改 visibility。
> 匿名请求 `ghcr.io/v2/lolkda/dsh-dev-image/manifests/latest` 返回 200。
>
> arm64 走 QEMU 模拟，整轮约 25 分钟。想快就换原生 ARM runner，workflow 顶部注释里有写法。
>
> 镜像不小：amd64 压缩后约 1.4 GB，arm64 约 1.3 GB。大头是 gradle（解压后约 200MB）、
> Go 工具链、JDK，以及 apt 那一层。想瘦身就删 gradle 或 gdb。

## 进去干活

```bash
docker compose exec agent bash
```

冒烟测试：

```bash
docker run --rm dev-agent:latest bash -lc \
  'python -V && node -v && pnpm -v && go version && rustc -V && java -version && git --version && dsh --help >/dev/null && echo ALL-OK'
```

镜像构建过程本身有两道检查：每条 COPY 后面立刻验证该工具链，最后再跑一次全链路冒烟。任何一条路径不对，`docker compose build` 当场失败，不会拖到运行时。

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

所以登记放在 [entrypoint.sh](entrypoint.sh) 里，卷挂好之后才执行。`pnpm add` 幂等，重启直接命中缓存。

### 加 / 换插件

改 `compose.yml` 的 `DSH_PLUGINS`（空格分隔）：

```yaml
DSH_PLUGINS: "@lolkda/dsh-web-lan@^0.1.0 @lolkda/dsh-skills-manager@^0.1.0"
```

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
| `DSH_VERSION` | `0.1.6-alpha.2` | npm 版本号或 dist-tag |
| `PNPM_VERSION` | `12.4.2` | — |
| `USER_UID` / `USER_GID` | `1000` | 和挂载目录属主对齐 |

> **Java 版本建议**：24 是 non-LTS，早已 EOL。当前 LTS 是 **25**，最新 feature release 是 26。走 Adoptium 路线换版本**不需要动 base**，改 `JDK_VERSION` 即可。
>
> **Node / Rust 换版本**要注意 glibc：源镜像必须继续取 bookworm 变体（glibc 2.36）。换成 `-noble` / `-trixie` 会因为 glibc 2.39 / 2.41 > 2.36 而炸。

## 缓存与卷

| 卷 | 挂到 | 装什么 |
|---|---|---|
| `agent-cache` | `/opt/cache` | pip / npm / go / maven / gradle 下载缓存 |
| `cargo-registry` | `/usr/local/cargo/registry` | cargo 依赖缓存 |
| `dsh-home` | `/home/agent/.dsh` | profile、插件、`.credentials.yaml`、日志 |

```bash
docker compose down -v          # 连卷一起删（会丢缓存和插件）
docker builder prune            # 清构建缓存 —— 服务器磁盘最容易被这个吃满
```

## 安全设计（这台机器还跑着线上服务）

- **没有挂 `/var/run/docker.sock`**。挂上等于容器内 root == 宿主机 root == 所有服务暴露。需要"容器里再跑容器"时，用 Sysbox 或 socket-proxy 单独解决。
- **资源限死**：`cpus` / `mem_limit` / `pids_limit`。`pids_limit` 是防 fork bomb 的，agent 跑失控构建会 fork 爆宿主机。
- **`cap_drop: ALL` + `no-new-privileges`**。副作用是 `ping` / `traceroute` 不可用（需要 `NET_RAW`）。
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
npm 上 `latest` = `0.1.5-rc.2`，比 `alpha` = `0.1.6-alpha.2` 还旧，`npm i -g @deepseek-ai/dsh` 会装到旧版本。

**`/usr/local` 的属主给了 `agent`。**
为了让非 root 也能 `npm i -g` 和 `pip install`（否则只能 venv / `--user`）。容器本身就是隔离边界，这个让步是刻意的；要收紧就删掉 Dockerfile 里 chown 的 `/usr/local`（rust 的两个目录已单独 `a+w`，不受影响）。

**rust / go 需要 `build-essential`。**
不只是为了编译 C 扩展：`rustc` 需要一个 cc 才能链接产物，node / rustc / libjvm.so 还都动态链接 `libstdc++6` 和 `libgcc_s`，这两个由 `build-essential` 带进来。

## 已知缺口

- **容器里的 profile 是全新的空 profile。** 宿主 `~/.dsh/profiles/web` 里的东西（dshmarket、prompt-manager、skills-manager、`link:` 装的本地插件）不会自动跟过来，只有 `DSH_PLUGINS` 里列的会装。要带全套得另做 seed。
- **MCP 服务器同理**：它们注册在 profile 的 `cordis.patch.yml` 里，不在容器里。而且 `ida` / `reqable` 是 Windows 宿主上的应用，本来就带不过来；`fastctx` 是纯文件/shell，可以。
- 默认没有 docker 访问能力，容器内不能 `docker build` / `docker compose up`。
- 默认只支持 `amd64` / `arm64`，其他架构会在 Java / Go 那两步显式报错退出。
