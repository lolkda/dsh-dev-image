# Agent Note: ARM 镜像构建与验收使用原生 runner

Status: implemented

## Problem

[CI 38045423793](https://github.com/lolkda/dsh-dev-image/actions/runs/38045423793) 中，arm64 的构建并加载耗时 62 秒，而工具链/Web 验收耗时 754 秒；amd64 对应耗时为 63 秒和 40 秒。两个架构均使用 x86 的 `ubuntu-latest`，arm64 依赖 QEMU。此次观测的主要等待在运行时验收，不是镜像构建或上传；不能把单次运行的差异当成原生 runner 的实测收益。

## Decision

- [发布工作流](../../../../.github/workflows/build.yml)仅将 arm64 build job 路由到 `ubuntu-24.04-arm`，amd64 保留 `ubuntu-latest`，不再注册 QEMU。
- PR 仅 amd64、非 PR 双架构的 matrix、并行执行、90 分钟超时和按架构隔离的 GHA 缓存保持不变。前置 checks 与 publish runner 不变。
- 权限、完整工具链和真实 Web 验收全部保留，继续推送已测候选并由双架构 digest 合并公开标签；原生 runner 不可用时不跳过 ARM 或降级发布。
- 本次不修改镜像内容、版本 ARG、缓存策略或当前运行的容器。用户确认后提交并推送，使用 push 自动触发的一次完整 CI 验证原生 ARM，不额外 dispatch 重复构建。

## Alternatives considered

- 保留 QEMU 并优化下载/缓存：改动较少且不依赖 ARM runner，但此次构建只耗时约一分钟，无法直接解决验收阶段的模拟执行开销，因此不作为本次方案。
- 减少 ARM 运行时测试：可立即减少等待，但会放过架构相关运行故障，不满足双架构实测后发布的既有约束。
- 自建 ARM runner：可固定硬件并保留本地缓存，但需要额外维护；当前公开仓库可使用 GitHub 标准 ARM runner，没有必要引入机器管理。

## Testing

- [配置回归](../../../../tests/config.test.mjs)分别检查两个架构的 runner 选择、无 QEMU、PR/release 架构选择、目标平台和缓存隔离；发布检查要求权限与工具链验收在推送之前、publish 依赖 build 且读取两个 digest。
- 修改 workflow 前，新增检查中 runner 选择两项与无 QEMU 一项按预期失败；修改后全量 `node --test tests/*.test.mjs` 为 150 通过、0 失败、2 跳过。跳过项为未设置 `FRIDA_TEST_BIN` 的真实 Frida CLI 测试，以及当前 root 环境不适用的非 root 入口测试。
- 本地未安装 actionlint，未执行该校验。配置回归不模拟 GitHub 调度，也不替代新配置的原生 ARM 构建与容器验收；实际耗时和 action 兼容性仍需下一次 CI 确认。

## Consequences

原生 runner 避免 ARM 构建和测试命令的 QEMU 模拟开销，不改变 amd64 的执行资源和镜像内容。首次原生 ARM 运行仍需验证各 action 与 BuildKit 镜像在该 runner 上可用；排队和网络波动仍可能影响总耗时。本次不承诺固定加速倍数，不降低测试门槛；本地修改在提交并推送后才影响后续工作流。

## Related notes audit

检索活跃笔记中的 QEMU、runner、arm64、构建和发布：[镜像缓存源](2026-10-10-ci-docker-hub-mirror.md)与本决定部分重叠，缓存源配置保持不变并互链；[root-only](../simplification/2026-10-04-root-only-runtime.md)和[默认 capabilities](../simplification/2026-10-04-docker-default-capabilities.md)的运行与验收约束保持不变，无需取代。Apktool、Frida 和 child-setup 笔记仅涉及镜像功能，与 runner 选择无关。无旧 ARM runner 决定需要归档。

## References

[GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#standard-github-hosted-runners-for-public-repositories)列出公开仓库的标准 `ubuntu-24.04-arm` runner；该选择不要求自建 ARM 机器。
