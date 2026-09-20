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
> 宿主目录**不需要**预先 chown，入口会自动处理（见下面「权限」一节）。

### 用 compose：多了资源限制和日志上限

服务器上还跑着别的服务时建议用这个（`cpus` / `mem_limit` / `pids_limit` / 日志上限 / `cap_drop`）。

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
  ├── .home/  ← agent HOME：Git/gh/SSH 配置、用户级工具
  └── .cache/ ← cargo/go/pip/npm/maven/gradle/uv 缓存
```

- **备份** = 打包这一个目录
- **清缓存** = 停容器后清理 `/srv/agent/.cache`（不动代码和新安装的用户 CLI；旧版 Cargo/Go 工具须先迁移，见下文）
- **删容器** = 镜像层全部还原，你的东西一个不动

工具链本体（rustup 工具链、JDK、Go、Maven、Gradle）留在镜像内的 `/usr/local` 和 `/opt`，不占用挂载点 —— 它们不需要持久化，重建镜像本来就该换新的。

### 权限：为什么不需要你先 chown

**你可能会撞上的报错：**

```
Error: EACCES: permission denied, mkdir '/app/.dsh'
dsh-entrypoint: FATAL 插件安装失败: @lolkda/dsh-web-lan@^0.1.0
```

原因：`/app` 是宿主目录挂进来的，而**目录不存在时 Docker 会以 `root:root` 创建它**，容器内 UID 1000 的 `agent` 连建子目录都做不到。

[entrypoint.sh](entrypoint.sh) 的启动顺序：

```
校验配置 → root 调整身份与必要属主 → setpriv 降权
         → agent 创建并验证状态目录 → 安装插件 → exec 主命令
```

**关键点：不能先把 `/app` chown 给 agent，再让 root 创建子目录。** Compose 丢弃了 `DAC_OVERRIDE`，此时 root 也不能写 agent 的 `0755` 目录。这正是上一版“修了一半”后仍可能报错的原因。

- root 初始化仅依赖 `CHOWN`、`SETUID`、`SETGID`；没有为修权限恢复 `DAC_OVERRIDE` 或全部能力。
- `setpriv` 后主进程使用非 root UID，并开启 `no-new-privileges`；插件也只在降权后安装。
- 统一 `HOME` 和账户家目录为 `/app/.home`，不再创建额外的主目录兼容链接；pnpm store 通过 `PNPM_CONFIG_STORE_DIR` 固定在 `/app/.cache/pnpm-store`，不再需要覆盖用户的 pnpm 配置文件。
- 调整账户 UID 时会避免 `usermod` 隐式遍历私有 HOME。已有 HOME 必须属于目标 UID/GID；不一致时会在修改账户或 APP 属主前明确失败，普通启动不递归 chown 私有 HOME。若要改变已有数据的 UID/GID，应先停容器并在宿主完成显式离线迁移，不要放宽私钥权限。
- 只修改挂载点本身，以及**不可写的受管状态目录**；不递归 chown 工程代码和 `.git`，健康状态目录重启时不递归扫描。
- 只读挂载、无法修复的 ACL/NFS 权限、受管路径被普通文件或符号链接占用，会在插件安装前明确失败。`DSH_PLUGINS_REQUIRED=0` 不能跳过这些错误。
- 已有混合属主的深层文件仍需按报错路径处理；入口不会为发现每一个历史 root 文件而每次扫描整个缓存。

**UID 自动跟随**：`/app` 已属于非 root 用户时，采用该 UID/GID；空的 root-owned 挂载点使用镜像构建时的 `USER_UID/USER_GID`（默认 `1000:1000`）。不会自动加入 GID 0。

两份 Compose 都支持显式传入运行身份：

```bash
AGENT_UID=1001 AGENT_GID=1001 docker compose up -d --force-recreate
```

UID/GID 必须是非零十进制整数。已有授权目录也可以直接使用 `docker run --user UID:GID`，但该模式不会替你修改属主。

> `docker exec` 默认身份仍是 root，因为镜像入口需要 root 初始化。日常必须使用：
> `docker compose exec --user agent agent bash`，避免重新制造 root-owned 状态。
>
> 镜像支持的部署布局固定为 `/app`。入口的 `APP_DIR` 只用于隔离测试等底层调用；仅修改它不会同步镜像 ENV、登录 PATH 与 pnpm 配置，不应拿它更改部署布局。

然后浏览器直接开：

```
http://<宿主机IP>:3080
```

**不需要填任何 IP，没有别的步骤。**

容器起来就直接跑 `dsh web`，不用再 exec 进去手动启动。要 shell 就另开一个终端：

```bash
docker compose exec --user agent agent bash
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
docker compose exec --user agent agent sh -c 'id; printf "HOME=%s\n" "$HOME"; test -w /app/.dsh'
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
> arm64 走 QEMU，发布现在还会运行 ARM 版启动与工具链验收，因此耗时高于仅构建。单个平台上限 90 分钟；需要进一步提速时可改用原生 ARM runner。
>
> 镜像不小：amd64 压缩后约 1.4 GB，arm64 约 1.3 GB。大头是 gradle（解压后约 200MB）、
> Go 工具链、JDK，以及 apt 那一层。想瘦身就删 gradle 或 gdb。

## 进去干活

```bash
docker compose exec --user agent agent bash
```

冒烟测试：

```bash
docker run --rm -e DSH_PLUGINS= ghcr.io/lolkda/dsh-dev-image:latest bash -lc \
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

所以登记放在 [entrypoint.sh](entrypoint.sh) 里，卷挂好并降权后才执行。每次启动仍会执行 `pnpm add`：缓存可以复用，但带版本范围的包仍可能查询 registry，**不保证完全离线或永远解析成同一版本**。

`DSH_PROFILE` 同时用于插件安装和默认 Web 启动。`dsh web` 会转换为 `dsh --profile <所选 profile>`，其余启动参数保留；非默认 profile 仍需要具备相应的 Web 配置。

`DSH_PLUGINS` 未设置时使用镜像/Compose 默认插件；显式置空会跳过安装。注意：跳过安装**不会卸载已有 profile 内的插件**；新 profile 若没有 LAN 插件，也不会按默认方案对外监听。

### 默认插件与升级

镜像和两份 Compose 的默认列表固定为：

| 插件 | 版本 | 用途 |
|---|---|---|
| `@lolkda/dsh-web-lan` | `0.1.1` | Web 局域网访问与相关设置 |
| [`dsh-auto-thinking-levels`](https://github.com/lolkda/dsh-auto-thinking-levels) | `0.1.0` | 为 `llm-pi-ai` 路由补充缺失的思考等级，不覆盖已有档位或 `reasoningEfforts: false` |

这里的“内置”沿用启动时自动安装并登记到 profile 的方式，不代表首次启动无需联网。自动思考等级插件只处理 `llm-pi-ai`，不保证其他 adapter 或上游模型支持所有等级。

### 加 / 换插件

在 [compose.yml](compose.yml) 中覆盖 `DSH_PLUGINS`（空格分隔，需要额外插件时追加到末尾）：

```yaml
DSH_PLUGINS: "@lolkda/dsh-web-lan@0.1.1 dsh-auto-thinking-levels@0.1.0"
```

升级旧容器时必须重新创建容器。若部署面板或旧配置保留了原来的 `DSH_PLUGINS` 环境变量，请清除覆盖值或改为上面的新列表；只拉取镜像、只重启旧容器不会更新已经保存的环境变量。启动用户仍应为 `0:0`，入口完成准备后会自动降权。

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

日常以 `agent` 身份安装，例如：

```bash
docker compose exec --user agent agent bash
npm install -g typescript
pnpm add -g @biomejs/biome
uv tool install ruff
```

- **安装与缓存分开**：新 CLI 的安装数据不放在可清理的 `/app/.cache`。不要把本地源码 `link` 安装等同于独立安装；链接指向的源码也必须保留。
- **两种 Shell 都可用**：[cli-env.sh](cli-env.sh) 在降权后的入口和登录 Shell 中复用，路径在第一次安装前就加入 PATH；镜像 ENV 还覆盖不经过入口的 `docker exec --user agent ...`。pnpm **12** 的命令目录是 `$PNPM_HOME/bin`，不是旧版常见的 `$PNPM_HOME`。
- **不覆盖用户配置**：不会改写已有 npm、pnpm、Yarn 或 Shell 配置文件。表中环境变量按包管理器原生优先级覆盖配置文件；需要自定义时，通过 Docker 的 `-e` 或 Compose 的 `environment` 显式设置相应变量。自定义目录必须是非根目录的绝对路径、不能含冒号，并应位于 `/app` 中才能持久化。改变路径后通过入口或新的登录 Shell 更新 PATH；单独给裸 `docker exec` 改 prefix 不会自动改其 PATH。
- **不改变项目依赖**：项目内 npm 安装、Python venv 等仍按原方式工作；没有设置强制 `PIP_USER`。Python CLI 推荐 `uv tool install`，或明确使用 `pip install --user`。
- **权限仍由 agent 负责**：CLI 目录只在降权后创建与验证，root 不递归修改私有 HOME。路径被文件、链接占用或不可写时，在安装插件前失败；旧 HOME 的 UID/GID 变更仍需显式离线迁移。
- **用户命令优先**：默认用户 CLI 路径排在镜像工具之前；同名命令尽量只交给一个包管理器管理，避免互相覆盖。镜像自带的 DSH、pnpm 和语言运行时仍在构建期安装到镜像层，不会被首次挂载遮蔽。

### 从旧版本升级

修改默认安装位置不等于搬迁已有工具：

1. 旧容器中装到 `/usr/local` 的额外全局包不会自动复制。删除旧容器前先记录需要保留的包和版本，再以 agent 在新容器中重新安装；旧容器删除后无法从新镜像找回这些包。
2. 旧 Cargo/Go 工具所在的 `/app/.cache/cargo/bin`、`/app/.cache/go/bin` 仍保留在 PATH，重装到新默认目录后才适合清理旧缓存。
3. 旧 Yarn 全局包默认位于 HOME 的 `.config/yarn/global`；可显式保留 `YARN_GLOBAL_FOLDER=/app/.home/.config/yarn/global`，或按原包列表重新安装到新目录。已有文件不会被入口搬移或覆盖。

部署新行为需要**重新构建并重建容器**，只 `restart` 不会更新入口和镜像 ENV。持久化不保证跨 CPU 架构、Python 次版本或不兼容系统库升级后仍可运行；这类升级应重装相应的原生 CLI / 虚拟环境。

## HOME 持久化与旧版本迁移

`agent` 的 `HOME` 和 Linux 账户家目录现在都是 `/app/.home`，不再创建额外的主目录兼容链接。工作目录仍是 `/app`，仍然只需挂载一个宿主目录。

- 新建 HOME 使用 `0700` 私有权限；[初始化模块](home-init.mjs) 只补缺失的系统 Shell 默认文件，不覆盖已有文件或跟随已有文件链接写入。
- Git/gh/SSH 的磁盘配置、凭据文件和 HOME 下的用户级安装现在随 `/app` 保留。pnpm store 仍单独放在 `/app/.cache/pnpm-store`；可用 `PNPM_CONFIG_STORE_DIR` 显式覆盖，已有用户配置文件不会被改写。
- 系统 Git 默认忽略 `/.home/` 和 `/.home-import.*/`，仓库也排除了这些目录。自定义 `core.excludesFile` 可能覆盖系统默认值；不要强制把 HOME 或导出的凭据提交到 Git。
- 这不保存 `ssh-agent` 解锁状态、`git credential-cache` 的内存数据，也不能恢复已过期/撤销的 token。`/usr/local` 的额外全局安装仍不属于 HOME 持久化范围。

### 首次升级前，先从旧容器导出 HOME

**新镜像无法自动找回已经删除的旧容器层。** 如果旧容器还在，应在首次启动新版之前，在 Linux Docker 宿主机执行 [迁移脚本](scripts/migrate-home.sh)。脚本只复制显式指定的旧 HOME，不预设源路径，不会打印 token、私钥或配置内容，不会删除源容器。

以下假设已把新版仓库放到部署机，宿主机已安装 Docker、`curl` 和 `jq`，挂载目录为 `/home/docker/agent`（其他目录请替换）。若只复制脚本，需将[迁移脚本](scripts/migrate-home.sh)和[路径检查器](scripts/verify-home-path.sh)放在同一目录：

```bash
docker pull ghcr.io/lolkda/dsh-dev-image:latest
# 停止前读取源 HOME；若自定义过启动环境，请核对它与旧进程实际使用的路径一致。
source_home="$(docker exec --user agent dsh-agent sh -c 'printf "%s" "$HOME"')"
docker stop dsh-agent
sudo bash scripts/migrate-home.sh dsh-agent /home/docker/agent "$source_home"

# 只有迁移成功后才继续；保留旧容器便于回看配置
docker rename dsh-agent "dsh-agent-old-$(date +%Y%m%d-%H%M%S)"
docker run -d --name dsh-agent --user 0:0 --restart unless-stopped --network host \
  -v /home/docker/agent:/app \
  ghcr.io/lolkda/dsh-dev-image:latest dsh web --no-open
```

第三个参数 `SOURCE_HOME` 必须明确提供：它是旧容器内非根目录的规范绝对路径，不能包含控制字符、重复分隔符、`.` / `..` 路径段或末尾斜杠；省略时脚本直接报错，不猜测源目录。若显式使用 `AGENT_UID/AGENT_GID`，用 `sudo env AGENT_UID=... AGENT_GID=... bash scripts/migrate-home.sh ...` 传入相同值。脚本仅支持在实际 Docker 宿主机、通过本机 Unix socket 迁移未挂载的旧容器层 HOME；源 HOME 的挂载、源目录及其父目录链接、privileged/SYS_ADMIN 容器和 Docker 内部数据路径会被拒绝，避免源/目标重叠及递归自复制。

路径检查器使用 Docker 的 `HEAD /containers/{id}/archive` 接口，按 [PathStat 字段约定](https://raw.githubusercontent.com/moby/moby/v28.3.1/api/types/container/container.go)逐级确认实际目录；它只读取元数据，不启动源容器，不复制父目录内容，读取失败时停止迁移。

迁移先导出到源挂载范围之外的私有临时目录，再放入目标文件系统暂存；需要较大临时空间时可显式指定 `TMPDIR`，但它不能位于源容器挂载范围内。使用旧镜像作为无网络、只读根文件系统的权限修复工具时，APP 只读，仅导出副本可写，并仅授予 `CHOWN`、`DAC_READ_SEARCH`。最终由宿主 root 原子发布 `0700` 的目标目录。正常服务启动仍只需要原来的 `CHOWN/SETUID/SETGID`，没有增加 `DAC_OVERRIDE`。

**目标 `.home` 已存在时，脚本会拒绝覆盖。** 不要直接删除它：先备份并决定如何合并。迁移失败时源容器不受影响，暂存目录会保留并打印位置；可先重新启动旧容器。若旧容器早已删除，只能重新登录一次，之后的磁盘状态才会由新布局保留。之后的常规镜像升级无需再次迁移。

日常登录工具请使用 agent，而不是 root：

```bash
docker exec -it --user agent dsh-agent bash
# 例如在该终端里运行 gh auth login / SSH 配置命令
```

## 缓存与卷

只有一个 bind mount，没有额外的命名卷：

| 宿主位置（默认） | 容器位置 | 内容 |
|---|---|---|
| `/srv/agent` | `/app` | 工作区代码 |
| `/srv/agent/.dsh` | `/app/.dsh` | DSH profile、插件、凭证、日志 |
| `/srv/agent/.home` | `/app/.home` | agent 的用户配置、磁盘凭据和用户级安装 |
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

**镜像工具链与用户 CLI 分开。**
`/usr/local` 的属主只在构建时调整，不随运行时 UID 递归改写；新用户 CLI 通过持久化 HOME 下的原生安装目录解决权限和重建丢失问题。显式指定 `/usr/local` 的系统级安装仍不保证任意 UID 可写或重建后保留。DSH 插件继续安装在 `/app/.dsh`，项目依赖优先使用工作区或虚拟环境。

**rust / go 需要 `build-essential`。**
不只是为了编译 C 扩展：`rustc` 需要一个 cc 才能链接产物，node / rustc / libjvm.so 还都动态链接 `libstdc++6` 和 `libgcc_s`，这两个由 `build-essential` 带进来。

## 已知缺口

- **容器里的 profile 是全新的空 profile。** 宿主 `~/.dsh/profiles/web` 里的东西（dshmarket、prompt-manager、skills-manager、`link:` 装的本地插件）不会自动跟过来，只有 `DSH_PLUGINS` 里列的会装。要带全套得另做 seed。
- **MCP 服务器同理**：它们注册在 profile 的 `cordis.patch.yml` 里，不在容器里。而且 `ida` / `reqable` 是 Windows 宿主上的应用，本来就带不过来；`fastctx` 是纯文件/shell，可以。
- 默认没有 docker 访问能力，容器内不能 `docker build` / `docker compose up`。
- 默认只支持 `amd64` / `arm64`，其他架构会在 Java / Go 那两步显式报错退出。

## 开发与回归验证

不需要给仓库安装 npm 测试依赖。先在**非 root** 的 Bash 环境（Windows 可用 Git Bash）运行：

```bash
bash tests/entrypoint.test.sh
node --test tests/*.test.mjs
for script in entrypoint.sh cli-env.sh scripts/*.sh tests/*.sh; do bash -n "$script"; done
shellcheck entrypoint.sh cli-env.sh scripts/*.sh tests/*.sh
sh -n cli-env.sh
node --check home-init.mjs
```

[CLI 回归测试](tests/entrypoint.test.sh) 实际执行入口，只替换外部插件安装命令；[配置测试](tests/config.test.mjs) 验证空值展开、版本默认值、失败传播和发布约束；[用户 CLI 回归](tests/user-cli.test.mjs) 在隔离 HOME 中验证实际 npm prefix、本地包安装、路径覆盖和 PATH 恢复。用户 CLI 集成用例依赖 POSIX 路径和原生 npm，在 Windows 跳过、由 Linux CI 执行；配置与可移植入口用例仍可在 Git Bash 运行。[HOME 路径回归](tests/home-path.test.mjs) 在 Linux 上使用真实 Unix socket HTTP 测试服务验证元数据协议与父目录链接拒绝，需要 `curl` 和 `jq`，不需要 Docker。这些检查**不能替代 Linux 的 UID、capability、挂载权限测试**。

Linux + Docker 下的快速权限验收：

```bash
docker build -f tests/Dockerfile -t dsh-entrypoint-test .
bash tests/container-runtime.sh dsh-entrypoint-test
```

[容器回归脚本](tests/container-runtime.sh) 使用真实 `chown`、`setpriv`、文件权限与最小 capabilities，覆盖 root-owned `0755`、非 root-owned `0700`、UID/GID 映射、旧状态、重启、只读挂载和符号链接等场景；不会用 mock 冒充 Linux 权限模型。

完整镜像验收（需要网络安装默认插件）：

```bash
docker build -t dsh-dev-image:verify .
bash tests/container-runtime.sh dsh-dev-image:verify
bash tests/image-smoke.sh dsh-dev-image:verify
```

[完整镜像冒烟](tests/image-smoke.sh) 检查登录/非登录 shell、实际 Rust 编译、Maven/pnpm 缓存位置，以及默认 Web 的真实登录流程。其中的[用户 CLI 容器验收](tests/user-cli-runtime.sh) 用默认与自定义 UID 运行[离线安装用例](tests/user-cli-smoke.sh)：实际安装 npm/pnpm/Yarn/pip/uv/Cargo/Go 的无依赖本地 CLI，换容器、清缓存后再次运行，并验证裸 `docker exec --user agent`；同时检查项目 npm 安装和 Python venv 未被全局目录配置影响。CI 中的 `dsh web --no-open` 是**临时验收**，只把随机端口发布到 runner 的 loopback，结束后删除容器和 cookie，不是在 Actions 上正式部署。

DSH 对匿名 `/` 请求返回 `401` 是正常鉴权行为，不能用匿名 `curl --fail` 判断服务是否启动。验收从该测试容器的启动日志取 token，跟随登录重定向并保留 cookie，最终必须获得 `200`；不会为了测试通过而关闭鉴权。[Web 登录回归](tests/web-ready.test.mjs) 使用真实 HTTP 服务覆盖此流程及失败分支。

CI 在发布前执行这些步骤；没有实际运行 Docker 的本地检查不能标记为容器验收通过。
