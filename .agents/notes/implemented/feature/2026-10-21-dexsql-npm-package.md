# Agent Note: DexSQL MCP bundle 改由 npm 提供

Status: implemented

## Problem

原先把 `@local/dsh-dexsql-mcp` 作为本地 bundle 复制进镜像，再用 `link:/opt/dsh-bundles/dsh-dexsql-mcp` 安装。这个 bundle 的配置和版本跟镜像强绑定，其他 DSH 部署无法复用；要改 MCP 参数还必须重建镜像。

## Decision

`@lolkda/dsh-dexsql-mcp` 已发布为独立的 npm 配置型 bundle。镜像删除本地 `bundles/dsh-dexsql-mcp`，默认 `DSH_PLUGINS` 改为：

```text
@lolkda/dsh-web-lan@latest @lolkda/dsh-dexsql-mcp@latest
```

DexSQL 二进制仍由 Dockerfile 下载，继续由 `DEXSQL_VERSION` 和 `DEXSQL_SHA256_*` 固定；npm 包只提供 `@deepseek-ai/dsh-mcp-client` 的配置，不包含二进制。

新增 `DSH_PLUGIN_REGISTRY`，只传给 `dsh plugin add --registry`，默认 `https://registry.npmjs.org`。这是因为新发布的 bundle 不保证已同步到国内镜像；用户项目的 npm/pnpm 依赖仍使用 `NPM_REGISTRY` / `npm_config_registry`，两者不混用。显式设置 `DSH_PLUGIN_REGISTRY=` 可以关闭该参数，沿用 pnpm 自身配置。

## Alternatives considered

- 保留本地 `link:` bundle：镜像最简单，但无法复用，配置变更仍要重建镜像。
- 在 `DSH_PLUGINS` 里写 npm tarball URL：能绕过镜像站同步问题，但 spec 很长，升级时要改 URL，不如包名清晰。
- 把全局 `NPM_REGISTRY` 改成官方源：会让用户项目依赖也走官方源，改变运行时默认值，范围过大。
- 固定 `@lolkda/dsh-dexsql-mcp@0.1.1`：可复现，但用户明确要求跟 `@latest`；代价是首次启动可能拿到新版本。

## Testing

`tests/dexsql.test.mjs` 校验默认插件使用 npm 包 `@latest`、不再引用本地 bundle、插件源与用户依赖源隔离；`tests/entrypoint.test.sh` 校验 `DSH_PLUGIN_REGISTRY` 传递和非法值拒绝；`tests/image-smoke.sh` 同时检查 web-lan 和 DexSQL bundle 安装版本等于 registry 当前 latest。完整镜像构建与容器冒烟仍需在 Linux Docker 环境执行。

## Consequences

首次启动需要能访问 npm 官方源；离线环境仍需 `DSH_PLUGINS_REQUIRED=0` 或预置 profile 缓存。`@latest` 与 `PNPM_CONFIG_MINIMUM_RELEASE_AGE=0` 的组合意味着同一镜像在不同时间启动可能拿到不同 bundle 版本；需要可复现时在 `DSH_PLUGINS` 写死版本。DexSQL 二进制仍随镜像固定，npm 包升级不会自动更换二进制。
