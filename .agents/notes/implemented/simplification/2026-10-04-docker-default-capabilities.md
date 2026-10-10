# Agent Note: 恢复 Docker 默认 capabilities

Status: implemented

## Problem

root-only 消除了账户切换，但初版 Compose 仍先 cap_drop ALL 再逐项加回能力。UID 0 并不因此拥有 Docker 默认的 SETUID/SETGID 等常用能力，专用开发容器还要维护一套白名单。用户确认删除这层收窄，采用 Docker 默认能力而不是 privileged。

## Decision

- 两份 Compose 不设置 cap_drop，不重复添加 CHOWN/DAC_OVERRIDE/FOWNER；cap_add 只包含 SYS_PTRACE。能力默认集合由 Docker 提供，不在项目中复制或硬编码完整列表。
- root 0:0、no-new-privileges、资源/日志限制、网络方式及 /app 数据布局保持不变；不开放 privileged，不挂载 Docker socket，不重启当前容器。
- 正常容器验收与默认部署对齐。用例检查 root、旧 UID 文件读写、HOME/CLI 持久化、手动 chown 和 setpriv 到 1000:1000 的行为；最后一项只在测试子进程中证明默认 SETUID/SETGID 可用，不恢复入口降权。
- 缺少 DAC_OVERRIDE/FOWNER 的负向测试仍显式缩减能力，不因部署默认值变化而删除失败用例。旧版显式 HOME 导出 helper 的独立只读/最小能力限制原本不属于日常服务；该 helper 已由[移除旧 HOME 迁移工具](2026-10-10-remove-home-migration-tools.md)删除，不影响日常容器的能力配置。
- 发布通过当前 GitHub 工作流进行。本会话中启动、被新配置取代的旧运行收到取消请求，避免它在新版本之后更新公共标签。

## Historical audit

与 [root-only 运行决定](../../implemented/simplification/2026-10-04-root-only-runtime.md) 部分重叠：仅取代其中的 Compose 能力白名单决定，账户、持久化、归权和构建修复仍成立，原笔记保留并互链，不归档。

## Alternatives considered

- 保留最小白名单：能限制 root 的操作范围，在多服务宿主更易收紧边界；但这是用户不需要的额外维护成本，且不同工具可能继续要求逐项加权，因此取消。
- privileged 或 cap_add ALL：最少遇到权限缺失；但会越过已确认的 Docker 默认能力方案，连带扩大设备和其他边界，不采用。
- 复制 Docker 默认能力列表到 Compose：能够固定具体位集合；但会形成项目自维护的另一份白名单，Docker 升级后容易漂移，直接继承默认更简单。

## Verification contract

1. 两份 Compose 无 cap_drop，唯一 cap_add 为 SYS_PTRACE，保留 no-new-privileges、root、资源限制，不启用 privileged。
2. 正常容器测试不再 cap_drop ALL；实际 root 下手动 chown 可用，setpriv 子进程成功变为 1000:1000，原入口仍始终以 root 启动。
3. 旧 UID 数据可读写但不自动改归属；HOME、CLI、只读挂载与错误路径检查不退化。缺失必要能力的负向用例仍失败。
4. 本地 Node/Shell/笔记检查与真实 Docker CI 的结果分开记录，未运行不能算通过。

## Verification results

- 本地 `node --test tests/*.test.mjs`：123 项，110 通过、13 项需要真实 root 而跳过、0 失败。
- Bash/POSIX Shell 语法、ShellCheck、`npm run verify-notes`、`git diff --check` 通过。
- 当前开发环境仍无 Docker/root；新增的默认能力和 setpriv 行为需由新一轮 GitHub CI 验证，不能用旧白名单版本的容器通过记录代替。

## Consequences

- 删除项目自维护的能力白名单，日常 root 工具可以使用 Docker 默认权限，减少因缺少单项能力而反复加配置。
- 服务权限比旧白名单宽，但仍受 Docker 默认隔离、挂载、设备与 no-new-privileges 等约束；不是宿主无限制 root。
- 已运行容器不会因修改 YAML 自动变更，部署时需要重建容器。此项本身无需改镜像内的 DSH 或账户实现。
- 不实施审查中的其他建议：插件安装时机、资源上限和 HOME 权限策略不变。
