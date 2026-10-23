# Agent Note: 移除 DexSQL MCP 默认插件

Status: implemented

## Problem

镜像和两份 Compose 的默认插件列表原先包含 `@lolkda/dsh-dexsql-mcp@latest`。该插件会随首次启动把 launcher 和六个平台的 DexSQL 二进制安装进 profile，使默认镜像额外承担约 132MB 的插件体积，并让所有新会话自动暴露 `mcp__dexsql__*` 工具。用户要求去掉这个默认插件。

## Decision

- [Dockerfile](../../../../Dockerfile) 和两份 Compose 的 `DSH_PLUGINS` 默认值只保留 `@lolkda/dsh-web-lan@latest`。
- 当前容器 profile 执行 `dsh plugin --profile web remove @lolkda/dsh-dexsql-mcp`，同时移除依赖与 bundle 登记；`dsh --dump-config` 和 MCP 工具列表不再包含 DexSQL。
- [DexSQL 回归](../../../../tests/dexsql.test.mjs) 改为断言默认配置不安装该插件、镜像不提供全局 `dexsql`；[镜像冒烟](../../../../tests/image-smoke.sh) 不再校验插件 launcher 或 `vendor/` 二进制。
- [README](../../../../README.md) 删除 DexSQL 作为默认能力的说明，默认插件表只保留 LAN 插件。

## Alternatives considered

- 保留默认安装、仅在文档中标注可选：改动最小，但默认镜像仍会下载并加载用户不需要的插件，不满足"去掉"的要求。
- 删除默认插件并移除所有 DexSQL 相关文档与测试：会让后续维护者失去"不要重新引入全局二进制"的回归保护，故保留全局二进制缺失和默认插件列表的负向断言。
- 仅在当前 profile 卸载而不改镜像默认值：当前会话会干净，但重建容器或新部署仍会自动装回，问题未解决。

## Consequences

- 新容器和新会话默认没有 `mcp__dexsql__*` 工具，也不再下载 DexSQL 插件及其二进制。
- 已存在的 profile 不会因镜像默认值变化而自动卸载插件；需要时手动执行 `dsh plugin --profile web remove @lolkda/dsh-dexsql-mcp`，或删除对应 profile 后重建。
- 仍需要 DexSQL 的部署方可以在 `DSH_PLUGINS` 中显式追加 `@lolkda/dsh-dexsql-mcp@latest`，默认行为不再承担这部分体积和工具注册。
- 系统 `PATH` 和镜像层仍然不提供全局 `dexsql`，避免与插件自带二进制形成两个版本来源。
