# Agent Note: 移除镜像内置 DexSQL 二进制

Status: implemented

## Problem

镜像原先在 Dockerfile 中下载 DexSQL Linux 二进制，按架构校验 SHA-256，解压许可证和第三方 notices，并链接到 `/usr/local/bin/dexsql`。`@lolkda/dsh-dexsql-mcp` 从 `0.2.0` 起已经把 launcher 和六个平台的二进制打进 npm 包，因此镜像继续自装二进制会形成重复分发：镜像层多约 22MB（amd64）/19MB（arm64），插件升级二进制时镜像里的全局 CLI 不会同步，而且 `dexsql` 出现在系统 `PATH` 会让“镜像自带二进制”和“插件自带二进制”两个版本来源并存。

镜像默认插件仍写 `@latest`，因为用户此前明确要求每次启动跟随 registry。`0.1.x` 插件只有配置，不含二进制；如果 registry 的 `latest` 仍是 `0.1.x`，删掉镜像二进制后 DexSQL MCP 会不可用，所以本次必须同时把运行验收改成检查插件包内的 launcher 和 `vendor/`。

## Decision

- [Dockerfile](../../../../Dockerfile) 删除 `DEXSQL_*` 构建参数、下载/校验/解包/许可证明细、`/opt/dexsql` 安装目录和 `/usr/local/bin/dexsql` 链接；构建期全链路冒烟不再执行 `dexsql`。
- 默认 `DSH_PLUGINS` 保持 `@lolkda/dsh-web-lan@latest @lolkda/dsh-dexsql-mcp@latest`。镜像不再固定 DexSQL 二进制版本；运行时应解析到 `@lolkda/dsh-dexsql-mcp@0.2.0` 或更高，`0.1.x` 不满足本镜像的二进制契约。
- [镜像冒烟](../../../../tests/image-smoke.sh) 移除系统 `dexsql` 的可执行检查。默认 Web 启动后读取 profile 内插件的 `package.json`，要求存在 `bin.dexsql` 和 `vendor/<platform>-<arch>/dexsql`，再用该 launcher 执行 `--version` 和 `mcp --help`，验证实际可启动。
- 镜像内不再提供全局 `dexsql` CLI。需要在 shell 里直接调用时，使用 profile 内的 launcher：`/app/.dsh/profiles/<profile>/node_modules/@lolkda/dsh-dexsql-mcp/bin/dexsql.mjs`；MCP 使用方式不变。
- [DexSQL 回归](../../../../tests/dexsql.test.mjs) 改为断言 Dockerfile 不含二进制下载/安装、默认插件仍为 `@latest`、冒烟检查插件 launcher 和 `vendor/`；README、Compose 注释和旧决策笔记同步更新。
- 源仓库仍保持 configuration-only，`package.json` 仍为 `private`；二进制只在 npm 发布包中，不进入 Git，也不进入镜像层。

## Alternatives considered

- 保留镜像二进制并与插件二进制同时存在：改动最小，但重复分发、版本可能漂移，且会让用户无法判断实际运行的是哪一个，故删除。
- 把默认插件固定为 `@0.2.0`：可确保二进制存在，但违背此前“每次启动跟 `@latest`”的明确要求；需要可复现时仍可由部署方覆盖 `DSH_PLUGINS` 写死版本。
- 在 `/usr/local/bin` 建一个指向 profile launcher 的符号链接：看似保留命令行便利，但路径依赖 profile 名、插件安装状态和持久化卷，容器首次启动前不可用，增加隐藏耦合，不采用。
- 额外安装一个全局 DexSQL CLI：能满足 shell 使用，但又回到镜像自装二进制和版本漂移的问题，且与 MCP 插件重复，不采用。

## Testing

- `node --test tests/*.test.mjs`：147 项，145 通过、2 项因环境跳过、0 失败。静态契约覆盖镜像无 `DEXSQL_*`/`/opt/dexsql`/全局链接、默认插件 `@latest`、冒烟检查插件 launcher 与 `vendor/`。
- `bash -n`、`shellcheck`、内嵌 Node `--check`、`npm run verify-notes`（13 项通过）和 `git diff --check` 均通过。
- 本地临时 `DSH_HOME` 中安装 `@lolkda/dsh-dexsql-mcp@latest`，在 `PNPM_CONFIG_MINIMUM_RELEASE_AGE=0` 下解析到 `0.2.0`；`vendor/linux-x64/dexsql` 存在，launcher 输出版本 `dexsql 0.1.1`，`mcp --help` 成功。NPM registry 现已公开 `0.2.0` 和 `latest`。
- 当前环境没有 Docker CLI，完整镜像 `tests/image-smoke.sh` 尚未执行；它会在 Docker CI 中实际启动默认 Web、安装 `@latest` 并执行插件 launcher。不能用旧镜像的全局 `dexsql` 检查代替。

## Consequences

- 镜像层不再包含 DexSQL 二进制，系统 `PATH` 上不再有 `dexsql`；MCP 仍通过 npm 插件提供 `mcp__dexsql__*`。
- 首次启动需要联网安装插件；离线环境需预置 profile 或设置 `DSH_PLUGINS_REQUIRED=0`，但后者会让 DexSQL MCP 缺失。
- 插件包解压后约 132MB，落在持久化 `/app/.dsh`，与镜像层减少的体积不是同一量级；容器重建后 profile 可复用，是否重新下载取决于 pnpm store 和 registry。
- `@latest` 必须解析到 `0.2.0` 或更高。若 registry 仍返回 `0.1.x`，镜像冒烟会因缺少 launcher/`vendor/` 失败，部署方应等待 npm 发布可见，或临时把 `DSH_PLUGINS` 固定到 `@lolkda/dsh-dexsql-mcp@0.2.0`。
- 旧镜像中依赖全局 `dexsql` 的脚本需要改为调用 profile 内 launcher；仅重建容器不会改变旧镜像层，必须重新构建镜像。
