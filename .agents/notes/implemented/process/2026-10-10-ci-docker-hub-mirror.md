# Agent Note: CI 使用 Docker Hub 镜像缓存降低限流影响

Status: implemented

## Problem

GitHub Actions 37992188725 及 37992575653 在轻量测试镜像解析 node:24-bookworm-slim 时返回 Docker Hub 429 Too Many Requests。代码检查通过，但依赖 checks 的正式构建和发布被跳过。重跑未解决，仓库无 Docker Hub 登录 secrets。

## Decision

仅在轻量测试和正式候选镜像的 BuildKit builder 配置 docker.io 的 mirror.gcr.io 缓存镜像源。Dockerfile 保持官方镜像引用、版本及平台不变，允许 BuildKit 在缓存未命中时回退 Docker Hub。保留现有权限测试、全工具链/Web 测试和双架构通过才发布的门槛。

## Alternatives considered

Docker Hub 登录可提高配额且继续直接使用原源，但需要用户提供未配置的凭据，不凭空创建秘密。重复重跑无需改配置，但已重复出现相同 429，不能作为修复。直接改 FROM 为镜像域名最直观，但将镜像源写进产品构建文件并失去原源回退，因此采用 CI builder 配置。

## Testing

两处 BuildKit builder 均已配置同一 Docker Hub 镜像缓存规则，候选镜像的权限、工具链/Web 验收和双架构发布门槛保持不变。针对性配置与笔记测试共 50 项通过；actionlint 未安装，因此未执行该工具校验。GitHub Actions 后续运行仍需确认镜像源是否能越过外部 429。

## Consequences

CI 在不改变 Dockerfile 官方镜像引用的情况下优先尝试缓存源，缓存源不可用时仍由原 Docker Hub 解析。仓库不需要新增 Docker Hub 凭据。缓存源可用性和覆盖率依赖外部服务，若未命中仍可能遭原源限流。


## Related notes audit

检索 Docker Hub、mirror、BuildKit、构建、发布：工具安装笔记只涉及工具来源；root-only 和默认 capabilities 笔记约束运行身份和发布验收。本决定不取代它们，保持全部验收条件，无现有缓存源决策。
