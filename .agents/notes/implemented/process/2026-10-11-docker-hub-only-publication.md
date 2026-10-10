# Agent Note: 仅向 Docker Hub 发布镜像

Status: implemented

## Problem

用户选择将公开镜像发布目标从 GHCR 切换到 Docker Hub，目标仓库为 `chikennice/dsh-dev-image`。需要同步发布认证、镜像地址、digest 校验和部署文档，不能只替换 registry 字符串。初始检查时仓库没有 Docker Hub Actions secrets；用户随后配置两项凭据并授权直接提交、推送和执行首次发布。本地改动不能视为实际发布成功。

## Decision

- [发布工作流](../../../../.github/workflows/build.yml)仅发布到 `docker.io/${DOCKERHUB_USERNAME}/dsh-dev-image`；workflow 用 `DOCKERHUB_USERNAME` 动态生成命名空间，PR 无 secret 时回退到 GitHub owner 仅用于不推送的元数据。两份 Compose 和 README 的部署默认地址为 `chikennice/dsh-dev-image:latest`；移除 GHCR 登录、GITHUB_TOKEN 发布认证和 packages 写权限。
- 使用 `DOCKERHUB_USERNAME`、`DOCKERHUB_TOKEN` secrets；非 PR 先检查两项非空，再运行前置检查和构建。PR 不需要凭据，仍只测试 amd64、不推送。
- 原生双架构 runner、按架构缓存、候选镜像完整权限/工具链/Web 验收，以及推送已测镜像后合并两个 digest 的发布门槛保持不变。标签规则不变。
- Docker 本地 RepoDigests 可能省略 `docker.io/`，只接受目标仓库的合法 SHA-256 digest；导出统一为带 registry 的引用，不接受其他仓库或 malformed digest。
- 用户选择 Docker Hub 首次完整发布并确认公开双架构镜像可拉取之后，再删除原 GHCR 包。凭据缺失或新发布失败时不删除旧包，不自动加入包删除 workflow。
- 镜像内容、依赖镜像缓存源、运行容器和用户数据均不改变；按用户授权提交并推送，由一次 push 构建验证首次发布，不重复 dispatch；不创建或读取 Docker Hub 凭据内容。

## Alternatives considered

- 同时发布 GHCR 和 Docker Hub：保留旧地址并提供备用源，但用户明确只发布 Docker Hub，双目标增加认证和发布状态复杂度，故不采用。
- 立即删除 GHCR 包：可马上清理旧分发目标，但新凭据未配置、Docker Hub 尚未发布，会造成没有可用镜像；用户选择先验证新目标再删旧包。
- 保留 GHCR 专用 digest 正则，仅替换前缀：改动最少，但 Docker Hub 的 RepoDigests 可省略 registry，不能可靠匹配目标仓库，因此采用规范化后的严格验证。

## Testing

[Docker Hub 回归](../../../../tests/dockerhub.test.mjs)实际执行从 workflow 提取的 shell：四种凭据组合验证缺失即失败且不输出 token；隔离 Docker 替身验证有/无 registry 的目标 digest 被规范化，错误仓库、错误 registry、无效或缺失 digest 被拒绝，且只 tag/push 已测镜像，不重建。静态配置契约验证 PR 跳过凭据/发布、配置检查在构建前、两处认证均使用 Docker Hub secrets、部署无 GHCR 地址。原生 runner 与原有发布门槛回归保持不变。

用户确认真实 Docker Hub 用户名为 `chikennice` 后，workflow 改为从 `DOCKERHUB_USERNAME` 动态生成命名空间，Compose/README 默认地址同步为 `chikennice/dsh-dev-image`。提交 `87911d6` 的 [CI 38080055321](https://github.com/lolkda/dsh-dev-image/actions/runs/38080055321) 已成功完成：配置检查、checks、amd64 原生构建/容器验收/推送、arm64 原生构建/容器验收/推送，以及 manifest 发布均通过；Docker Hub 登录和写权限已实际验证。当前环境对 Docker Hub registry 的直接 HTTP 访问超时，不能从本机补做匿名 manifest 请求，但 GitHub Actions 的 `docker buildx imagetools create` 已成功执行。旧 GHCR 包仍保留，待取得 Packages 删除权限后清理。

## Consequences

只有一个公开发布目标和一套认证，部署默认地址改为 Docker Hub；GitHub workflow 不再需要 packages 写权限。Docker Hub 账号需有目标仓库写权限，仓库需公开才能匿名拉取。凭据轮换增加外部配置维护成本；错误或过期 token 只能由实际登录验证，非空检查不证明凭据有效。旧 GHCR 包删除会使旧标签和 digest 地址失效，只能在新镜像验证后执行，目前保留旧包。

## Related notes audit

检索 GHCR、发布、Docker Hub：[镜像缓存源](2026-10-10-ci-docker-hub-mirror.md)仅约束依赖拉取缓存，保持并互链，澄清发布凭据与缓存源无关；[原生 ARM](2026-10-10-native-arm-runner.md)的 runner/验收决定保留，历史 GHCR 测速证据不改写并互链新发布目标。root-only、默认 capabilities、迁移工具移除和工具安装决定不受影响，无笔记需归档。
