# syntax=docker/dockerfile:1
# 快速验证真实 Linux UID/权限/capabilities，不下载完整开发工具链。
FROM node:24-bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends util-linux passwd \
    && rm -rf /var/lib/apt/lists/* \
    && groupmod -n agent node \
    && usermod -l agent -d /home/agent -m node
ENV DSH_HOME=/app/.dsh \
    PATH=/app/.cache/cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
COPY entrypoint.sh /usr/local/bin/dsh-entrypoint
RUN chmod 0755 /usr/local/bin/dsh-entrypoint
WORKDIR /app
ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
CMD ["true"]
