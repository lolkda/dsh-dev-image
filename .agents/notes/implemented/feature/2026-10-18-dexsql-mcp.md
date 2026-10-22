# Agent Note: 镜像内置 DexSQL CLI 与 MCP bundle

Status: implemented

> Superseded by [2026-10-21 npm bundle migration](2026-10-21-dexsql-npm-package.md).
> 镜像内置 DexSQL 二进制的部分进一步由 [2026-10-22 移除镜像内置二进制](2026-10-22-dexsql-image-binary-removal.md) 取代。

## Problem

镜像已经有 apktool、adb、frida，但 APK/DEX 的类、方法、字符串和调用关系仍需要额外装工具。DexSQL 同时提供 CLI 和 stdio MCP；如果只装二进制，用户还要手动改 profile 才能让 agent 使用 MCP，不符合“镜像内置后直接可用”的目标。

## Decision

固定 DexSQL 0.1.1 的 Linux amd64/arm64 二进制和每架构 SHA-256，安装到 `/opt/dexsql/<version>/`，在 `/usr/local/bin/dexsql` 建立链接，并保留 `LICENSE`、`LICENSE-AUXILIARY` 和构建时导出的 `THIRD_PARTY_NOTICES`。

在镜像内增加本地 DSH bundle `bundles/dsh-dexsql-mcp`，其 `cordis.patch.yml` 插入 `@deepseek-ai/dsh-mcp-client`，配置 `serverName: dexsql`、`transport: stdio`、`command: /usr/local/bin/dexsql`、`args: [mcp, --timeout-ms, 300000]`、`cwd: /app`。默认 `DSH_PLUGINS` 通过 `link:/opt/dsh-bundles/dsh-dexsql-mcp` 安装该 bundle，所有新会话直接获得 `mcp__dexsql__*` 工具，不需要用户修改 `cordis.patch.yml`。

## Alternatives considered

专用 Agent 预设只在选中时加载，能节省普通会话约 5.5k tokens 的工具 schema，但用户仍要主动选择预设；按当前“内置后直接可用”的要求不采用。entrypoint 直接向 `$DSH_HOME/cordis.patch.yml` 追加配置能少一个 bundle，但会修改用户状态，且与 `!!js`、注释和后续升级的 YAML 合并风险较高，不采用。只装 CLI 不加 MCP 可避免工具 schema 开销，但不满足 MCP 内置目标。

## Testing

新增 `tests/dexsql.test.mjs` 校验版本、双架构 SHA、许可证、MCP bundle 配置和默认 `DSH_PLUGINS`；`tests/image-smoke.sh` 增加 `dexsql --version`、`dexsql mcp --help`、profile 中 `dexsql-mcp` 条目和本地 bundle 注册检查。

本地 Node 回归 144 项测试中 142 项通过、2 项非 root 测试跳过；`bash -n`、`shellcheck`、`sh -n`、`node --check` 全部通过；使用 DSH 自带的 `@modelcontextprotocol/client` 实际连接 `dexsql mcp`，返回 12 个工具。当前环境没有 Docker CLI，完整镜像构建和容器冒烟尚未在本地执行。

## Consequences

镜像增加约 22MB（amd64）/19MB（arm64）；所有会话的工具目录增加约 22KB schema、粗算约 5.5k tokens。DexSQL 是闭源二进制，升级必须同时更新 `DEXSQL_VERSION` 和两个架构的 SHA；许可证要求随镜像保留完整 LICENSE 和第三方 notices。用户可通过覆盖 `DSH_PLUGINS` 去掉本地 bundle 来关闭 MCP。`open_dataset` 接受绝对路径且容器以 root 运行，使用时应把 APK 放在 `/app`，不要把敏感文件暴露在容器可读范围。

## Related notes audit

检索 apktool、frida、root-only、MCP：apktool/Frida 笔记只涉及各自 CLI 安装；root-only 笔记约束运行身份；没有现成的 MCP 内置决策需要替代。本笔记只新增 DexSQL 的安装和 DSH bundle 约定，不改变既有权限、缓存和插件安装策略。
