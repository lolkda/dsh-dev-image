# Agent Note: 统一 root 运行并取消身份映射

Status: implemented

## Problem

旧入口以 root 初始化再降权为 agent，而 docker exec 默认仍为 root，导致同一挂载内可能出现混合属主。自动修复刻意不接管工程代码、.git 和私有 HOME，用户仍需去宿主机修归属。用户明确选择 root-only，优先减少单人开发容器的身份切换成本。

## Decision

- [镜像定义](../../../../Dockerfile)和两份 Compose 固定 `0:0`；入口、插件、DSH 及默认 exec 都直接使用 root，不经过 sudo，不支持非 root 入口。
- 构建时仅替换 `/etc/passwd` 中 root 的 HOME/shell 字段，保留 UID/GID、密码占位和其他账户，并立即校验结果。使用 `usermod` 本来可以复用系统账户工具，但 [CI 37204734771](https://github.com/lolkda/dsh-dev-image/actions/runs/37204734771) 证明它拒绝修改 PID 1 正在使用的 root（exit 8）；因此不在构建期调用它，也不把账户修改延迟到运行期。
- [入口](../../../../entrypoint.sh)删除 agent 账户依赖和 UID/GID 跟随机制；镜像不再提供 USER_UID/USER_GID 构建参数。非空 AGENT_UID/AGENT_GID 是过时配置，入口明确拒绝，不静默换身份。
- `/app` 仍为唯一持久化挂载；HOME、root 的账户家目录均为 `/app/.home`。CLI 安装、缓存、插件目录和用户文件保留原布局，不重置或递归 chown 数据。初始化只补缺失 Shell 文件，HOME 仍收紧为 0700。
- Compose 保留 cap_drop ALL、no-new-privileges 和已有 SYS_PTRACE/CHOWN；删除 SETUID/SETGID，增加 DAC_OVERRIDE/FOWNER。后两者允许读写旧 UID 文件及初始化旧 HOME 权限。CHOWN 仅供用户在容器内显式处理个别属主检查或包管理器使用，入口不自动归权，不开放 privileged。
- [CLI 环境模块](../../../../cli-env.sh)不再排除 root，安装时机仍在镜像工具链安装之后；登录 Shell 与裸 docker exec 使用同一持久化布局。
- [显式旧 HOME 导出工具](../../../../scripts/migrate-home.sh)仅把新导出副本准备为 0:0，不修改源容器和工作区；已有 `.home` 仍拒绝覆盖。
- 非 root、过时配置、只读挂载、受管路径类型错误在插件/主命令前失败。CLI/PATH、插件参数、失败策略和选定 profile 保持原有行为。
- 本次交付只改仓库，不修改当前镜像层、账户、挂载数据，不重建或重启当前服务。

## Historical audit

实施前 checkout 没有 `.agents/notes/`、项目 AGENTS.md 或笔记门禁；无可更新或归档的历史笔记。旧决定的最强理由在下节保留。无外部依赖的 `npm run verify-notes` 门禁与既有 Node 测试一起验证笔记结构及相对链接，不引入包安装或通用笔记管理框架。

## Alternatives considered

- 保留非 root 并统一日常 exec：优点是限制插件和命令对其他属主文件的写权限，也减少新建 root 文件；但仍要求宿主 UID 配合，并不满足用户统一 root 的要求。
- root/non-root 双模式：兼容现有部署最强，但需要保留账户、映射、迁移、两套测试，继续留下身份混用入口；选择明确的破坏性 root-only 契约。
- 每次启动递归 chown 整个挂载：能使旧数据归属一致；但会改工程/.git/凭据的元数据、扫描大量文件，而且用户要求不批量修改数据归属，因此不采用。
- 删除全部 capability 限制或 privileged：最省配置，但范围超过访问旧数据所需；保留已有 CHOWN/SYS_PTRACE 与边界，并只增加 DAC_OVERRIDE/FOWNER。

## Verification contract

1. 两份镜像定义及 Compose 为 0:0；真实入口、插件和主命令的 UID/GID 为 0:0；root 账户 HOME 与 ENV 一致。直接非 root 入口和非空旧身份变量明确失败，插件和命令未执行。
2. 新建 root-owned、旧 1000:1000/其他 UID 的 0700 工作区、混合属主深层文件均可读写；旧文件及目录 UID/GID 不变。新普通文件为 0:0；既有 HOME/SSH 内容和私钥 0600 不被重写，HOME 可由 0755 收紧为 0700。
3. 两次独立容器启动保持 HOME 配置与 CLI 可执行文件；登录/非登录 Shell 及默认 docker exec 使用持久化工具路径。
4. 真实只读挂载、受管目录文件/符号链接冲突在插件和主命令前失败；保留插件失败策略、参数字面量、选定 profile 与退出码。缺少 DAC_OVERRIDE/FOWNER 有真实失败用例。
5. 显式 HOME 导出副本为 0:0/0700；源容器不变，目标存在和源路径/挂载重叠仍拒绝。
6. Shell/Node 检查、笔记门禁和真实 Docker 用例分别记录执行结果；无法运行 Docker 不是通过。

对应检查分别在[入口身份回归](../../../../tests/root-only.test.mjs)、[配置回归](../../../../tests/config.test.mjs)、[真实权限回归](../../../../tests/container-runtime.sh)、[完整镜像冒烟](../../../../tests/image-smoke.sh)和[HOME 导出回归](../../../../tests/home-migration-runtime.sh)。权限模式位只读不等于只读挂载：root 可绕过前者，后者使用 Docker readonly mount 测试，不以 chmod/mock 冒充。

## Local verification

- `node --test tests/*.test.mjs`：120 项，107 通过、13 因缺少真实 root 环境明确跳过、0 失败。真实非 root 入口拒绝已执行。
- `bash -n`、`sh -n cli-env.sh`、`shellcheck`、`node --check home-init.mjs`、`git diff --check` 通过。
- `npm run verify-notes` 通过。
- 本地未执行真实 root 入口成功路径、Docker Compose 展开、镜像构建、容器权限/CLI/旧 HOME 导出和完整 DSH 启动验收。当前环境为 UID 1000，无 Docker/sudo，unshare 返回 Operation not permitted；不通过修改入口或模拟 UID 来掩盖缺口。
- [CI 37204734771](https://github.com/lolkda/dsh-dev-image/actions/runs/37204734771) 已通过真实 root Shell 入口回归（21 项）、Node 回归（119 通过、1 项非 root 用例跳过）及两份 Compose 展开；随后测试镜像在 `usermod root` 处 exit 8。构建修复的 43 项配置测试已本地通过，其中真实 sed 用例验证仅更改 root HOME/shell，不更改其他字段或账户；修复后的容器构建与发布仍须以新一轮 CI 为准。

## Consequences

- 删除双身份与自动归权流程；入口不扫描工程或凭据树，不要求旧私有 HOME 改属主才能启动。保留 CHOWN 使显式个别文件修复可在容器内完成。
- 新文件通常属于 root，宿主普通用户可能需要 sudo；容器 root 不绕过只读文件系统、NFS root-squash、user namespace 映射及工具自身的身份校验。
- OpenSSH 等工具可能拒绝旧 UID 拥有的配置；保留数据属主不等于绕过应用级校验。此类配置可在容器内按实际报错单独处理，不把所有凭据自动接管。
- 默认 exec 使用 root，因此允许的 capabilities 对主程序也有效；不再承诺非 root 权限隔离，也不承诺 root 拥有所有内核 capabilities。
- 现有 `/app/.home` 直接复用，禁止为升级而删除或再次导入。只有旧 HOME 尚在容器可写层时才使用显式导出工具。
- 变更需重新构建并重建容器才生效；只 restart 或拉取尚未包含此变更的 latest 不生效。真实容器验收仍需由 Docker CI 或部署机完成。
