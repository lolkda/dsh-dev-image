# Agent Note: 升级 Node.js 与 Java 安全版本

Status: implemented

## Problem

镜像的 Node 来源写的是浮动标签 `node:24-bookworm-slim`，构建结果会随 Docker Hub 的 24.x 补丁漂移，无法从 Dockerfile 判断实际包含哪个安全修复。Node 24.22.1 修复了 Brotli 解码器越界写入等问题，而 README 仍记录为 24.21.0。

Java 默认 `JDK_VERSION=24`。24 是 non-LTS 且已 EOL，不再获得公开安全更新；继续使用会把已知漏洞带进所有新构建的镜像。

## Decision

- [Dockerfile](../../../../Dockerfile) 的 `src-node` 固定为 `node:24.22.1-bookworm-slim`，继续使用 Node 24 LTS 和 bookworm（glibc 2.36）。
- [测试镜像](../../../../tests/Dockerfile) 同步固定到 `node:24.22.1-bookworm-slim`，避免轻量入口测试跑在另一条 Node 版本线上。
- `ARG JDK_VERSION` 默认改为 `25`。Adoptium 仍按 feature version 取最新 25.x LTS 补丁；验证时解析到 Temurin `25.0.5+8`（amd64 / arm64 均有构建）。
- [README](../../../../README.md) 的版本表、`JDK_VERSION` 默认值和 Java 版本建议同步更新；Node 来源列改为精确标签。
- [配置回归](../../../../tests/config.test.mjs) 新增两条契约：Node 基础镜像必须写死精确的 bookworm 版本且不低于 24.22.1；Java 默认必须是 25 LTS。

## Alternatives considered

- 继续使用 `node:24`：改动最小，但无法审计当前构建包含哪个补丁，也无法阻止下一次构建悄悄换版本。
- 升级到 Node 26.12.1：同样包含本轮安全修复，但 26 不是当前 LTS；开发镜像优先选择 Active LTS 24，减少项目兼容性波动。
- 升级到 JDK 26 / 27：都包含 2026-10 CPU 修复，但均为 non-LTS；默认仍选 25 LTS，需要尝鲜时可用 `--build-arg JDK_VERSION=26`。
- 只修改 Java 版本、不动 Node 标签：Java 会被修复，但 Node 的构建漂移和 README 版本失真仍然存在。
- 在 Dockerfile 中固定 JDK 的完整 build 号：可进一步提高可复现性，但会改变现有 Adoptium `latest/<feature>` 取版流程；本轮先保证脱离 EOL 的 24，并让 25 线继续接收补丁。

## Testing

- `node --test tests/config.test.mjs`：52 项全部通过。
- `node --test tests/*.test.mjs`：152 项，150 通过、2 项环境跳过、0 失败。
- `git diff --check`、`bash -n entrypoint.sh cli-env.sh tests/*.sh`、`shellcheck entrypoint.sh cli-env.sh tests/*.sh` 均通过。
- 已核实 Docker Hub 存在 `node:24.22.1-bookworm-slim`（2026-10-21 更新），Adoptium 的 amd64 / arm64 JDK 25 均解析到 `25.0.5+8.0.LTS`。
- 当前沙箱的 Node 已是 24.22.1；`/opt/java` 原为 Temurin 24.0.2+12，已就地替换为校验过的 25.0.5+8，旧目录保留在 `/opt/java-24.0.2.bak`。`java -version`、`javac -version`、最小 Java 编译运行、`mvn -v`、`gradle --version`、`apktool --version` 均通过；Maven 与 Gradle 各实际编译并运行了一个 Java 25 项目。
- 当前环境没有 Docker CLI，未执行完整镜像构建和 `tests/image-smoke.sh`；Docker CI 仍需实际构建 amd64 / arm64 镜像并跑完整冒烟。

## Consequences

- 已运行容器不会自动获得新运行时，必须重新构建镜像并重新创建容器。
- Node 升级点从浮动标签变成精确标签，后续 Node 安全更新需要显式修改 Dockerfile 和测试镜像。
- 默认 Java 从 EOL 的 24 跳到 25 LTS；依赖特定 JDK 24 行为的项目应在自己的构建中验证，必要时用 `JDK_VERSION` 覆盖。
- JDK 25 线内的补丁更新仍由 Adoptium 的 `latest` API 跟随，构建日志会输出实际 `java -version`，便于审计。
