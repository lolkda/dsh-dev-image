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
- 本地未安装 actionlint，未执行该校验。提交前配置回归 48 项通过、笔记校验 8 项通过，`git diff --check` 通过；配置回归本身不模拟 GitHub 调度。
- 提交 `898ef1782ccca7985f32f88aa37f406c770e6b99` 的 [CI 38050015269](https://github.com/lolkda/dsh-dev-image/actions/runs/38050015269) 已通过前置检查、双架构完整构建/容器验收和 manifest 发布。ARM job `114207315522` 的 Docker 信息显示 `Architecture: aarch64`，runner 为 `ubuntu-24.04-arm`，实际 Web 验收输出 `FULL IMAGE AND AUTHENTICATED WEB STARTUP PASSED`。

## Measurement

比较同一镜像定义和真实验收脚本：基线为父提交 `d745f9c446fd9f867b67159ed2661805a8251181` 的 [QEMU CI 38047200183](https://github.com/lolkda/dsh-dev-image/actions/runs/38047200183)，新构建为上述原生 ARM CI。`git diff` 确认镜像定义、入口、补丁、工具链/权限/用户 CLI 验收脚本及前置工作流均无变化。两次 ARM 构建日志各有 31 个 `CACHED` 步骤，属于热缓存对比，不是冷构建基准。

| 阶段 | QEMU 基线 | 原生 ARM |
| --- | --- | --- |
| ARM 构建并加载 | 61 秒 | 58 秒 |
| ARM 容器权限验收 | 53 秒 | 6 秒 |
| ARM 工具链/Web 验收 | 732 秒 | 43 秒 |
| ARM 镜像推送 | 51 秒 | 41 秒 |
| ARM 整个 job | 920 秒 | 164 秒 |
| amd64 整个 job | 197 秒 | 180 秒 |
| 整个发布流水线 | 1027 秒 | 288 秒 |

ARM job 耗时减少 82.2%，工具链/Web 验收减少 94.1%，整个流水线减少 72.0%。amd64 未观察到整体变慢；其小幅差异不能归因于 ARM runner。收益主要来自移除运行时验收的模拟执行开销，而非构建缓存优化。

耗时从 GitHub REST API 的 job/step `started_at`、`completed_at` 计算；流水线从 `run_started_at` 到 publish job 的 `completed_at`，不使用可能受后续事件影响的 `updated_at`。复核入口为 `gh api repos/lolkda/dsh-dev-image/actions/runs/<run_id>/jobs`；ARM 基线 job 为 `114199233350`，原生 job 为 `114207315522`，用 `gh run view <run_id> --job <job_id> --log` 核对缓存和架构。

publish job `114207813076` 将两种架构合并为 `sha256:aba282a311fe8bd1dd3e8174bbe6ec84a206cf52c7b0d8329299faaf8ae92d20`，更新 `ghcr.io/lolkda/dsh-dev-image:main` 和 `:latest`。仅补充测速证据的文档提交使用 `[skip ci]`，避免再触发相同镜像构建；被验收的镜像 revision 仍为 `898ef17`。

## Consequences

原生 runner 避免 ARM 构建和测试命令的 QEMU 模拟开销，不改变 amd64 的执行资源和镜像内容。本次 CI 已验证 action、BuildKit、完整容器验收与发布在原生 ARM 上可用，无需削减测试。上述数字仅代表一次热缓存对比；排队、网络、缓存失效和依赖源变化仍可能影响后续耗时，不承诺固定加速倍数。

## Related notes audit

检索活跃笔记中的 QEMU、runner、arm64、构建和发布：[镜像缓存源](2026-10-10-ci-docker-hub-mirror.md)与本决定部分重叠，缓存源配置保持不变并互链；[root-only](../simplification/2026-10-04-root-only-runtime.md)和[默认 capabilities](../simplification/2026-10-04-docker-default-capabilities.md)的运行与验收约束保持不变，无需取代。Apktool、Frida 和 child-setup 笔记仅涉及镜像功能，与 runner 选择无关。无旧 ARM runner 决定需要归档。

当前发布目标由[仅向 Docker Hub 发布](2026-10-11-docker-hub-only-publication.md)调整；本篇 runner 和验收决定仍成立，上述 GHCR digest 与耗时保留为历史实测证据。

## References

[GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#standard-github-hosted-runners-for-public-repositories)列出公开仓库的标准 `ubuntu-24.04-arm` runner；该选择不要求自建 ARM 机器。
