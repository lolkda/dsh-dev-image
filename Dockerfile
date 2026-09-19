# syntax=docker/dockerfile:1

# =============================================================================
#  dev-agent —— 通用开发镜像（Python / Node / Java / Rust / Go / git / DSH）
#
#  base 选 python:3.12-slim-bookworm 而不是裸 debian:bookworm-slim，是刻意的：
#
#    官方 python 镜像构建时会用 ldd 反查 python 二进制实际依赖的 .so，把提供
#    这些库的 apt 包（libexpat1 / libffi8 / libsqlite3-0 / liblzma5 / libbz2-1.0 /
#    libgdbm6 / libncursesw6 / libreadline8 / libuuid1 …）标记为 manual 保留下来，
#    并跑过 ldconfig。若改用裸 debian 再 COPY python 的 /usr/local，这些库一个
#    都不会在，`import sqlite3` / `ssl` / `ctypes` 全部 ImportError，且报错很晚、
#    很难查。
#
#    python:3.12-slim-bookworm 本身就是 debian 12 bookworm（glibc 2.36），
#    所以它既是 debian base，又白送了 python 的完整运行时。
#
#  glibc 规则（改版本时必读）：
#    被 COPY 的来源镜像 glibc 必须 <= base 的 2.36。
#    node / rust 都取 bookworm 变体（2.36）—— 相等，安全。
#    Go / Java / Maven / Gradle / yq 走官方 tarball，原因见各自段落。
# =============================================================================

# ---- 运行时来源层：只用于 COPY，不进入最终镜像 ------------------------------
FROM node:24-bookworm-slim      AS src-node
FROM rust:1.98.1-slim-bookworm  AS src-rust

# ---- 最终镜像 ---------------------------------------------------------------
FROM python:3.12-slim-bookworm

ARG GO_VERSION=1.27.1
ARG JDK_VERSION=24
ARG DSH_VERSION=0.1.6-alpha.2
ARG PNPM_VERSION=12.4.2
ARG MAVEN_VERSION=3.9.16
ARG GRADLE_VERSION=9.7.1
ARG UV_VERSION=0.12.17
ARG YQ_VERSION=4.53.6
ARG USER_UID=1000
ARG USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Shanghai

# -----------------------------------------------------------------------------
# 系统层
#
# 铁律：绝不 apt 安装任何语言运行时（python3 / nodejs / golang / openjdk-*）。
# 它们会和下面 COPY 进来的抢 /usr/bin 与 /usr/local，症状是"版本看着对、
# 实际跑的是另一个"。
#
# 特别注意 maven：Debian 的 maven 包硬依赖 `default-jre-headless | java7-runtime-headless`，
# 而 default-jre-headless 会拖进整套 openjdk-17-jre-headless（约 150MB），
# 还会让 update-alternatives 把 /usr/bin/java 指向 17 —— 正好踩中上面那条铁律。
# 所以 maven 也走官方 tarball，见下。
#
# apt 只负责系统库和命令行工具（gh 够用；maven / gradle / yq 都不够，见下）。
#
# build-essential 是必需的，不只是为了编译：它提供 libstdc++6 和 libgcc_s，
# 而 node、rustc、libjvm.so 都动态链接这两个；rust / go(cgo) 还需要一个 cc
# 才能链接产物。
#
# libatomic1：node 官方镜像显式装了它（注释写 "libatomic1 for arm"），arm64 需要。
# xxd：bookworm 里是独立包，**不在 vim-common 里**（trixie 才拆出来的说法是反的）。
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget git openssh-client gnupg jq \
        build-essential pkg-config \
        libssl-dev zlib1g-dev libatomic1 \
        procps less vim xxd unzip xz-utils zip rsync tzdata \
        libfreetype6 fontconfig \
        libx11-6 libxext6 libxrender1 libxi6 libxtst6 \
        \
        ripgrep fd-find file tree sqlite3 \
        iproute2 dnsutils netcat-openbsd lsof bc man-db tmux \
        shellcheck git-lfs \
        cmake ninja-build autoconf automake libtool \
        gdb strace \
        gh; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 环境变量
# 放在 COPY 之前，这样每条 COPY 后面能立刻冒烟验证。
# 所有包管理器缓存指向 /opt/cache，compose 把该目录整体挂成卷 —— 容器重建后
# pip / npm / go / maven / gradle 的下载缓存都还在。
# -----------------------------------------------------------------------------
ENV JAVA_HOME=/opt/java \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    GOPATH=/opt/go \
    GOMODCACHE=/opt/cache/go/pkg/mod \
    GOCACHE=/opt/cache/go/build \
    PIP_CACHE_DIR=/opt/cache/pip \
    npm_config_cache=/opt/cache/npm \
    MAVEN_CONFIG=/opt/cache/m2 \
    GRADLE_USER_HOME=/opt/cache/gradle \
    UV_CACHE_DIR=/opt/cache/uv \
    DSH_HOME=/home/agent/.dsh \
    PATH=/opt/java/bin:/opt/maven/bin:/opt/gradle/bin:/usr/local/cargo/bin:/usr/local/go/bin:/opt/go/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

# -----------------------------------------------------------------------------
# Node 24
#
# 逐路径 COPY，不用 `COPY --from=src-node /usr/local /usr/local`：
# 整目录拷贝会覆盖掉 base 里 python 的 /usr/local/lib 和 /usr/local/bin。
#
# /opt 也必须拷：node 镜像把 yarn 装在 /opt/yarn-<ver>/，而 /usr/local/bin/yarn
# 是指向它的符号链接。只拷 /usr/local/bin 会留下一个断链 —— `which yarn` 找得到、
# 一执行就报错，属于最难查的那类问题。
# -----------------------------------------------------------------------------
COPY --from=src-node /usr/local/bin/              /usr/local/bin/
COPY --from=src-node /usr/local/lib/node_modules/ /usr/local/lib/node_modules/
COPY --from=src-node /usr/local/include/node/     /usr/local/include/node/
COPY --from=src-node /opt/                        /opt/
RUN set -eux; node -v; npm -v; yarn --version

# -----------------------------------------------------------------------------
# Rust 1.98
#
# RUSTUP_HOME 放镜像内（工具链本体），CARGO_HOME 也放镜像内；compose 只把
# CARGO_HOME/registry 挂成卷，这样工具链不丢、依赖缓存可复用。
#
# clippy / rustfmt 必须单独加：官方 slim 镜像是 minimal profile，只有
# rustc / cargo / rust-std，没有这两个。对 agent 来说 cargo clippy 和
# cargo fmt 是最常用的两个命令，缺了等于半残。
#
# 冒烟验证用 `rustfmt --version`，不要用 `cargo fmt -V`：cargo-fmt 自己解析
# 参数（Usage: cargo fmt [OPTIONS] [-- <rustfmt_options>...]），不接受 -V，
# 会直接 exit 2 把构建打断。cargo clippy -V 是好的。
#
# 官方镜像会 chmod -R a+w 这两个目录，这里照做：即使以后去掉 /usr/local 的
# chown，非 root 也还能用。
# -----------------------------------------------------------------------------
COPY --from=src-rust /usr/local/rustup/ /usr/local/rustup/
COPY --from=src-rust /usr/local/cargo/  /usr/local/cargo/
RUN set -eux; \
    rustup component add clippy rustfmt; \
    chmod -R a+w /usr/local/rustup /usr/local/cargo; \
    rustup component list --installed; \
    rustc -V; cargo -V; cargo clippy -V; rustfmt --version

# -----------------------------------------------------------------------------
# Java —— 走 Adoptium 官方 tarball，不用 COPY
#
# 为什么不用 eclipse-temurin：24 这个版本只有 noble 变体，`24-jdk-jammy` 已 404。
# noble 的 glibc 是 2.39 > base 的 2.36，COPY 进来会炸。
#
# Adoptium 的 Linux tarball 面向 glibc 2.17+ 构建，放进 bookworm 安全；换
# JDK_VERSION=25 / 26 时 base 完全不用动，比 COPY 路线省事。
#
# 用 API 返回的 sha256 校验后再解包，保证构建可复现（不是盲下 tar）。
# 架构用 dpkg 探测而不是 TARGETARCH，这样不开 BuildKit 也不会拿错架构。
# -----------------------------------------------------------------------------
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) adoptium_arch=x64 ;; \
        arm64) adoptium_arch=aarch64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    meta="$(curl -fsSL "https://api.adoptium.net/v3/assets/latest/${JDK_VERSION}/hotspot?architecture=${adoptium_arch}&image_type=jdk&os=linux&vendor=eclipse")"; \
    url="$(printf '%s' "$meta" | jq -r '.[0].binary.package.link')"; \
    sum="$(printf '%s' "$meta" | jq -r '.[0].binary.package.checksum')"; \
    curl -fsSL -o /tmp/jdk.tar.gz "$url"; \
    echo "${sum}  /tmp/jdk.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/java; \
    tar -xzf /tmp/jdk.tar.gz -C /opt/java --strip-components=1; \
    rm -f /tmp/jdk.tar.gz; \
    java -version

# -----------------------------------------------------------------------------
# Maven —— 走官方 tarball，理由和 Gradle 不同
#
# Debian 的 maven 包硬依赖 default-jre-headless，apt 会连带装进整套
# openjdk-17-jre-headless（约 150MB），同时 update-alternatives 把
# /usr/bin/java 指向 17 —— 和本文件开头的铁律直接冲突，也让 `java` 的实际
# 行为依赖 PATH 顺序。官方 tarball 既避开这个，又白送 3.9.x（Debian 是 3.8.7）。
#
# MAVEN_CONFIG 已指向 /opt/cache/m2，所以本地仓库落在 /opt/cache/m2/repository，
# 随 agent-cache 卷持久化。
# -----------------------------------------------------------------------------
RUN set -eux; \
    base="https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries"; \
    file="apache-maven-${MAVEN_VERSION}-bin.tar.gz"; \
    curl -fsSL -o /tmp/maven.tgz "${base}/${file}"; \
    curl -fsSL -o /tmp/maven.tgz.sha512 "${base}/${file}.sha512"; \
    echo "$(cat /tmp/maven.tgz.sha512)  /tmp/maven.tgz" | sha512sum -c -; \
    mkdir -p /opt/maven; \
    tar -xzf /tmp/maven.tgz -C /opt/maven --strip-components=1; \
    rm -f /tmp/maven.tgz /tmp/maven.tgz.sha512; \
    mvn -v

# -----------------------------------------------------------------------------
# Gradle —— 走官方 distribution，不用 apt
#
# Debian bookworm 的 gradle 是 **4.4.1**（2017 年的），现代项目根本用不了。
# 官方 zip 带 sha256 校验。
# -----------------------------------------------------------------------------
RUN set -eux; \
    url="https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"; \
    curl -fsSL -o /tmp/gradle.zip "$url"; \
    curl -fsSL -o /tmp/gradle.zip.sha256 "${url}.sha256"; \
    echo "$(cat /tmp/gradle.zip.sha256)  /tmp/gradle.zip" | sha256sum -c -; \
    unzip -q /tmp/gradle.zip -d /opt; \
    rm -f /tmp/gradle.zip /tmp/gradle.zip.sha256; \
    ln -sfn "/opt/gradle-${GRADLE_VERSION}" /opt/gradle; \
    gradle --version

# -----------------------------------------------------------------------------
# Go —— 同样走官方 tarball，但原因不同
#
# golang 官方镜像里 /usr/local/go 是一个指向 /target/usr/local/go 的符号链接
# （为了 SOURCE_DATE_EPOCH 可复现性刻意做的）。跨阶段 COPY 对符号链接的处理
# 依赖构建器实现，不可靠 —— 与其赌，不如直接取官方 tarball。
#
# sha256 从 go.dev 的 JSON API 现取，所以换 GO_VERSION 不用手改校验和。
# -----------------------------------------------------------------------------
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) goarch=amd64 ;; \
        arm64) goarch=arm64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    file="go${GO_VERSION}.linux-${goarch}.tar.gz"; \
    sha="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' \
             | jq -r --arg f "$file" '.[].files[] | select(.filename==$f) | .sha256' | head -n1)"; \
    [ -n "$sha" ] && [ "$sha" != "null" ] || { echo "no sha256 for $file" >&2; exit 1; }; \
    curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/${file}"; \
    echo "${sha}  /tmp/go.tgz" | sha256sum -c -; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm -f /tmp/go.tgz; \
    go version

# -----------------------------------------------------------------------------
# uv（Python 包管理器）
#
# 用 pip 装而不是 `curl | sh`：pip 会校验 PyPI 的哈希，比管道执行远端脚本干净。
# -----------------------------------------------------------------------------
RUN set -eux; \
    pip install --no-cache-dir "uv==${UV_VERSION}"; \
    uv --version

# -----------------------------------------------------------------------------
# yq v4 —— 走官方二进制，不用 apt
#
# Debian bookworm 的 yq 是 **3.1.0**，那是 Python 版、语法和 mikefarah v4
# 完全不同（`yq -y` vs `yq -o=yaml`）。装错了比不装更坑，所以取官方 v4。
#
# 校验和不能按列取：yq 的 checksums 文件不是 `<hash>  <file>`，而是
#     <file>  <crc32>  <md5>  <sha1>  …  <sha256>  …  <sha512>
# 一行一个文件、八种算法并排。所以反过来做 —— 自己算出 sha256，再看它是否
# 出现在官方为该文件声明的那一行里。
# -----------------------------------------------------------------------------
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) yq_arch=amd64 ;; \
        arm64) yq_arch=arm64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}"; \
    curl -fsSL -o /usr/local/bin/yq "${base}/yq_linux_${yq_arch}"; \
    chmod 0755 /usr/local/bin/yq; \
    line="$(curl -fsSL "${base}/checksums" | grep -E "^yq_linux_${yq_arch}[[:space:]]")"; \
    [ -n "$line" ] || { echo "no checksums entry for yq_linux_${yq_arch}" >&2; exit 1; }; \
    actual="$(sha256sum /usr/local/bin/yq | awk '{print $1}')"; \
    echo "$line" | grep -qF "$actual" || { echo "sha256 mismatch for yq_linux_${yq_arch}" >&2; exit 1; }; \
    yq --version

# -----------------------------------------------------------------------------
# Debian 把 fd 的二进制改名成 fdfind（避开 fdclone 的 fd），建个 fd 别名，
# 否则 agent 按习惯敲 fd 会 command not found。
# -----------------------------------------------------------------------------
RUN set -eux; ln -sfn /usr/bin/fdfind /usr/local/bin/fd; fd --version

# -----------------------------------------------------------------------------
# 非 root 用户 + 目录
#
# /usr/local 交给 agent，是为了让非 root 也能 `npm i -g` / `pip install` /
# `uv tool install`（否则只能靠 venv / --user）。容器本身就是隔离边界，
# 这个让步是刻意的；要收紧就删掉 chown 里的 /usr/local
# （rust 那两个目录已单独 a+w，不受影响）。
#
# git safe.directory 必设：挂载进来的目录属主和容器内 UID 不一致时，
# git 会直接拒绝操作（"detected dubious ownership"）。
# -----------------------------------------------------------------------------
RUN set -eux; \
    groupadd -g "${USER_GID}" agent; \
    useradd -m -u "${USER_UID}" -g agent -s /bin/bash agent; \
    mkdir -p /opt/cache/pip /opt/cache/npm /opt/cache/m2 /opt/cache/gradle \
             /opt/cache/uv /opt/cache/go/pkg/mod /opt/cache/go/build /opt/go \
             /workspace "${DSH_HOME}"; \
    chown -R agent:agent /opt/cache /opt/go /workspace "${DSH_HOME}" /usr/local; \
    git config --system --add safe.directory '*'; \
    git config --system core.autocrlf false; \
    git config --system init.defaultBranch main

# -----------------------------------------------------------------------------
# DeepSeek Harness + pnpm
#
# 不要用 @latest：npm 上 latest=0.1.5-rc.2，比 alpha=0.1.6-alpha.2 还旧，
# `npm i -g @deepseek-ai/dsh` 会装到旧版本。这里默认锁到与本地一致的版本。
#
# pnpm 是必需的：`dsh plugin --profile <p> add <spec>` 的实现就是"把剩余参数
# 转发给 profile 目录里的 pnpm"。没有 pnpm 就装不了任何插件。
# -----------------------------------------------------------------------------
RUN set -eux; \
    npm install -g "pnpm@${PNPM_VERSION}"; \
    npm install -g "@deepseek-ai/dsh@${DSH_VERSION}"; \
    npm cache clean --force; \
    test -x "$(command -v dsh)"; \
    test -x "$(command -v pnpm)"

# -----------------------------------------------------------------------------
# 全链路冒烟：任一工具链没装好，构建就在这里失败，不会拖到运行时才发现
# -----------------------------------------------------------------------------
RUN set -eux; \
    python -V; \
    node -v; npm -v; yarn --version; pnpm --version; \
    go version; \
    rustc -V; cargo -V; cargo clippy -V; rustfmt --version; \
    java -version; javac -version; mvn -v; gradle --version; \
    git --version; git lfs version; \
    jq --version; yq --version; uv --version; \
    rg --version; fd --version; \
    cmake --version; ninja --version; \
    sqlite3 --version; tmux -V; shellcheck --version; \
    gh --version; gdb --version; strace -V; \
    for c in xxd file tree nc dig ss lsof bc man; do command -v "$c" >/dev/null; done; \
    dsh --help > /dev/null; \
    echo '=== ALL TOOLCHAINS OK ==='

# -----------------------------------------------------------------------------
# 入口：启动时登记插件
# 为什么不在 build 期登记，见 entrypoint.sh 头部注释（$DSH_HOME 是卷，会遮蔽）。
# -----------------------------------------------------------------------------
COPY entrypoint.sh /usr/local/bin/dsh-entrypoint
RUN chmod 0755 /usr/local/bin/dsh-entrypoint

# -----------------------------------------------------------------------------
# 默认行为：直接起 Web GUI
#
# 这两行放在文件最末尾是刻意的：ENV / CMD 会让其后的所有层缓存失效，放最后
# 就只重跑这几层，前面那些大下载（JDK / Go / Gradle / rust 组件）全部命中缓存。
#
# DSH_PLUGINS 给默认值，是为了让裸 `docker run` 不带 -e 也能用。不给的话
# entrypoint 会跳过插件登记，dsh 就绑 127.0.0.1，外面完全连不上 —— 典型的
# "看起来起来了但用不了"。想关掉就显式 `-e DSH_PLUGINS=`（空值会被尊重）。
#
# CMD 设成 dsh web，所以 `docker run <image>` 开箱即用；要 shell 就
# `docker run -it <image> bash`（参数会覆盖 CMD）。
# -----------------------------------------------------------------------------
ENV DSH_PLUGINS=@lolkda/dsh-web-lan@^0.1.0

WORKDIR /workspace
USER agent
EXPOSE 3080
ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
CMD ["dsh", "web"]
