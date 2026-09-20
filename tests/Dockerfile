# syntax=docker/dockerfile:1
# 快速验证真实 Linux UID/权限/capabilities，不下载完整开发工具链。
FROM node:24-bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends util-linux passwd git \
    && rm -rf /var/lib/apt/lists/* \
    && groupmod -n agent node \
    && usermod -l agent -d /app/.home node \
    && mkdir -p /etc/dsh \
    && printf '/.home/\n/.home-import.*/\n' > /etc/dsh/gitignore \
    && git config --system core.excludesFile /etc/dsh/gitignore
ENV HOME=/app/.home \
    DSH_HOME=/app/.dsh \
    npm_config_prefix=/app/.home/.local \
    PNPM_HOME=/app/.home/.local/share/pnpm \
    YARN_PREFIX=/app/.home/.local \
    YARN_GLOBAL_FOLDER=/app/.home/.local/share/yarn/global \
    PYTHONUSERBASE=/app/.home/.local \
    UV_TOOL_DIR=/app/.home/.local/share/uv/tools \
    UV_TOOL_BIN_DIR=/app/.home/.local/bin \
    CARGO_INSTALL_ROOT=/app/.home/.local \
    GOBIN=/app/.home/.local/bin \
    PNPM_CONFIG_STORE_DIR=/app/.cache/pnpm-store \
    PATH=/app/.home/.local/bin:/app/.home/.local/share/pnpm/bin:/app/.cache/cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
COPY entrypoint.sh /usr/local/bin/dsh-entrypoint
COPY home-init.mjs /usr/local/bin/home-init.mjs
COPY cli-env.sh /usr/local/bin/cli-env.sh
RUN chmod 0755 /usr/local/bin/dsh-entrypoint \
    && chmod 0644 /usr/local/bin/cli-env.sh \
    && ln -s /usr/local/bin/cli-env.sh /etc/profile.d/10-dsh-cli.sh
WORKDIR /app
ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
CMD ["true"]
