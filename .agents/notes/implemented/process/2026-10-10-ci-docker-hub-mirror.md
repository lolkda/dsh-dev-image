# Agent Note: CI 使用 Docker Hub 镜像缓存降低限流影响

Status: implemented

## Problem

GitHub Actions 37992188725 及 37992575653 在轻量测试镜像解析 node:24-bookworm-slim 时返回 Docker Hub 429 Too Many Requests。代码检查通过，但依赖 checks 的正式构建和发布被跳过。重跑未解决，仓库无 Docker Hub 登录 secrets。

## Decision

轻量测试、正式候选构建和 manifest 发布的 BuildKit builder 都使用 `mirror.gcr.io/moby/buildkit:buildx-stable-1` 作为引导镜像，并为 `docker.io` 配置 `mirror.gcr.io` 镜像源。Dockerfile 保持官方镜像引用、版本及平台不变；BuildKit 镜像自身不再依赖 Docker Hub，基础镜像缓存未命中时仍由配置的 Docker Hub 镜像源处理。保留现有权限测试、全工具链/Web 测试和双架构通过才发布的门槛。

## Alternatives considered

Docker Hub 登录可提高配额且继续直接使用原源，但需要用户提供未配置的凭据，不凭空创建秘密。重复重跑无需改配置，但已重复出现相同 429，不能作为修复。直接改 FROM 为镜像域名最直观，但将镜像源写进产品构建文件并失去原源回退，因此采用 CI builder 配置。

## Testing

两处构建 workflow 和 publish builder 均已配置 BuildKit 引导镜像及 Docker Hub 镜像缓存规则，候选镜像的权限、工具链/Web 验收和双架构发布门槛保持不变。第一次修复后的运行 37994586101 已越过配置测试，但在 `setup-buildx-action` 拉取 `moby/buildkit:buildx-stable-1` 时超时，故补充 `driver-opts` 指定镜像。针对性配置与笔记测试共 50 项通过；actionlint 未安装，因此未执行该工具校验。GitHub Actions 后续运行仍需确认镜像源是否可用。

## Consequences

CI 在不改变 Dockerfile 官方镜像引用的情况下优先尝试缓存源，缓存源不可用时仍由原 Docker Hub 解析。仓库不需要新增 Docker Hub 凭据。缓存源可用性和覆盖率依赖外部服务，若未命中仍可能遭原源限流。


## Related notes audit

检索 Docker Hub、mirror、BuildKit、构建、发布：工具安装笔记只涉及工具来源；root-only 和默认 capabilities 笔记约束运行身份和发布验收。本决定不取代它们，保持全部验收条件，无现有缓存源决策。

[原生 ARM runner](2026-10-10-native-arm-runner.md)仅调整 arm64 的执行主机，保留本篇的 BuildKit 引导镜像与缓存源配置，两项决定并存。
