# Agent Note: 移除旧容器 HOME 迁移工具

Status: implemented

## Problem

用户确认不再保留两个旧 HOME 导出脚本。它们并非日常 HOME 初始化或镜像构建入口，但有专属 Node/容器测试、README 操作流程和 CI Shell glob；只删脚本会留下断链和失败的检查命令。

## Decision

- 删除旧容器 HOME 导出脚本及其路径元数据检查器，同时删除仅验证这项功能的两个 Node 测试文件和一个容器测试文件。
- [容器验收](../../../../tests/container-runtime.sh)不再调用迁移测试；[前置 CI](../../../../.github/workflows/verify-layout.yml)及 README 的 Shell 检查命令不再包含已不存在的 scripts glob。
- README 不再提供旧容器层的迁移步骤；已有持久化 HOME 继续复用，未持久化的旧数据需用户自行备份。
- 镜像定义、入口、HOME 初始化、用户 CLI 持久化、已有数据和运行中的容器均不改变。历史迁移暂存目录的 Git/Docker 排除规则保留，避免旧副本意外进入提交或构建上下文。

## Alternatives considered

- 保留按需使用的迁移工具：能降低旧容器层升级的数据导出风险，但用户已明确不要这项能力，继续维护路径协议、宿主权限和专属测试没有必要。
- 只删除两个脚本：改动最小，但容器测试仍会调用缺失文件，CI 的 scripts glob 会作为字面量传给检查器，README 也继续引导执行不存在的脚本；因此一并移除专属依赖。

## Testing

验收覆盖两个脚本及三个专属测试文件已删除、活动调用和文档链接无残留、Shell 检查不再引用空目录，以及现有 HOME 初始化/root/用户 CLI 回归。容器验收仅移除末尾的迁移调用和其专用 root 路径变量，保留新建/已有 HOME、跨容器持久化、权限和错误路径分支。本地检查与真实 Docker 验收分别记录，不用旧 CI 结果替代删除后的验收。

- 全量 Node 回归为 122 通过、0 失败、2 跳过；跳过项是未配置真实 Frida 环境的 CLI 测试和当前 root 环境不适用的非 root 入口测试。专属迁移测试随功能删除，不是将失败用例改为跳过。
- Bash/POSIX Shell 语法、ShellCheck、9 项笔记格式/链接检查和 `git diff --check` 通过。仓库检索无已删除文件名或 scripts Shell glob 残留。
- 当前没有 Docker CLI，未运行删除后的真实容器验收；保留的容器权限与持久化分支需在后续 CI 验证。

## Consequences

仓库减少一项旧版迁移能力及其专属维护成本，日常持久化 HOME 和容器启动行为不变。仓库不再提供从旧容器可写层导出 HOME 的专用工具；在删除旧容器前需要自行备份。删除脚本不会迁移、删除或修复任何现有用户数据。未来若确有旧容器层迁移需求，应重新评估独立工具，而不是把导出或递归归权加入日常入口。

## Related notes audit

检索迁移脚本名、HOME 导出、旧 HOME：[root-only 决定](2026-10-04-root-only-runtime.md)的独立导出条款被本决定部分取代，其账户、HOME 持久化和不自动改属主的约束保留；[默认 capabilities](2026-10-04-docker-default-capabilities.md)中关于独立导出 helper 的说明随功能删除同步标记，两篇保留并互链，不归档。镜像工具安装、缓存源和原生 ARM runner 决定与本次移除无关；此前 ARM 测速对应删除前的测试集合，不重写历史数字。
