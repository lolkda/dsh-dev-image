# Agent Note: DSH 0.2.1-alpha.2 子 Agent setup 补丁适配

Status: implemented

## Problem

镜像默认 DSH 已升级到 0.2.1-alpha.2，但 child-setup v1 补丁仍以 dsh-subagent 0.2.0-rc.2 为基线。新版将 continuation 激活逻辑合并到 SubagentManager，旧文件被删除，导致精确应用失败。具体 Team preset 仍依赖该接口，不能通过删除补丁或忽略失败恢复构建。

## Decision

仅更新镜像持有的补丁及哈希基线，覆盖新包的 bundle、manager 模块、runtime 模块和类型声明。manager 通过已有 host 对象转发 setup，不引入额外构造参数。保留 childSetupVersion=1/registerChildSetup 和同步 commit 的协议；冷恢复仅回放子会话自身选择、header 为后备；工作目录设置与结构化输出初始化仍执行。具体 preset 挂载必须在 Agent 发布前完成。

新增回归测试，对 npm 原始发布包执行零模糊精确应用并校验前后 SHA256；执行补丁后的初始化及钩子实现，覆盖创建、恢复、取消、owner 卸载、非法返回和原有结构化输出分支。CI 同时隔离安装 DSH 与发布版插件 1.5.1，执行真实 Team/AgentLoop/JSONL 创建、恢复、工具隔离及结构化输出注册验收；模型 IO 被捕获，不调用付费 API。统一 diff 的上下文空格在上游 tab 前属于格式语法，.gitattributes 只对 .patch 关闭 space-before-tab，其他空白检查保留。

恢复失败的无模型 IO 断言只统计目标子会话的 sessionId；父会话正常接收队友状态通知不属于失败子 Agent 的模型请求。

## Existing note audit

已检索活跃笔记中的 DSH/subagent/preset/child-setup。root-only-runtime 和 docker-default-capabilities 只约束镜像账户、权限，与本补丁不重叠。没有现有 child-setup 决策笔记需要替代。CI mirror 笔记保留，修复下载问题与源码适配独立。

## Alternatives considered

- 删除补丁：可立即消除构建失败和本地维护负担，但插件会拒绝保存具体 preset，违反此次保留功能的决定。
- 在插件运行时包装 factory：不改依赖包文件，但仍耦合内部生命周期，且卸载插件后无法继续负责持久化身份恢复，不能作为等价替代。
- 只允许 patch 偏移、模糊匹配或忽略错误：能减少升级时构建阻塞，但新版删除旧模块，无法证明功能完整，拒绝降级验收。

## Testing

- 对 pristine dsh-subagent@0.2.1-alpha.2，patch --fuzz=0 精确应用，无拒绝、偏移、模糊匹配，前后哈希匹配基线。
- 13 项补丁测试覆盖 bundle 和模块 JS 的创建、恢复、取消、owner 卸载、非法回调和异步 commit。
- 干净安装上的 9 项真实宿主集成测试通过：fresh/fork、冷恢复、插件卸载后恢复、未知与失效 preset、冻结策略、普通子 Agent、结构化工具及 cwd、发布版插件模型/effort 共存。
- 21 项入口测试及新增脚本 bash -n、shellcheck 通过。
- 全量 Node 测试包含两个既有环境跳过项：真实 Frida 需指定 venv、非 root 场景当前 root 环境不执行。对应容器验收未取消。

## Consequences

保留具体 Team preset 的发布前初始化能力，同时让新版依赖能够精确构建。维护成本仍存在：每次升级须匹配真实 npm 字节并重跑生命周期验收；不修改插件项目或正在运行的宿主，不降低双平台发布门禁。局部协议测试不能代替真实 Team/AgentLoop 集成，因此 CI 明确运行两层验证；完整镜像构建与发布尚需 CI 完成。未来上游原生提供等效接口时再评估取消补丁，不能仅凭方法名判断语义。
