#!/usr/bin/env bash
# =============================================================================
#  dsh-entrypoint —— 启动时登记 DSH 插件
#
#  为什么必须放在启动时，而不是 build 期：
#
#    `dsh plugin --profile <p> add <spec>` 本质是在 profile 目录里跑 pnpm，
#    而 profile 位于 $DSH_HOME/profiles/<p>/ —— $DSH_HOME 在 compose 里是挂载卷。
#    构建期写进镜像的 profile 内容会被（首次启动时还是空的）卷整个遮蔽，
#    症状是"插件装了但没生效"，而且完全静默。
#
#    放进启动时做就没有这个问题：卷挂好之后才登记，登记结果落在卷里，
#    后续重启直接命中缓存。
#
#  幂等性：pnpm add 一个已存在且版本一致的包是空操作，重启不会重复下载。
#
#  环境变量：
#    DSH_PROFILE          默认 web
#    DSH_PLUGINS          空格分隔的 spec 列表，例如
#                         "@lolkda/dsh-web-lan@0.1.0 other-plugin@1.2.3"
#                         留空则不登记任何插件
#    DSH_PLUGINS_REQUIRED 默认 1：装失败就退出（不静默降级）
#                         设 0 可容忍失败继续启动，适合离线场景
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# /app 是唯一的挂载点，卷会遮蔽镜像里那一层 —— 卷首次挂载时是空的，
# 所以子目录得在这里补建。登录 shell 下 /etc/profile.d/01-dsh-app-dirs.sh
# 也会兜一次（见 Dockerfile 注释）。
#
# 用 -p 且忽略失败：宿主目录可能属主不对，那种情况下让后面的 dsh 报错
# 比在这里静默死掉更容易诊断。
# -----------------------------------------------------------------------------
for d in "${DSH_HOME:-/app/.dsh}" \
         "${CARGO_HOME:-/app/.cache/cargo}" \
         "${GOPATH:-/app/.cache/go}"/pkg/mod \
         "${GOCACHE:-/app/.cache/go/build}" \
         "${PIP_CACHE_DIR:-/app/.cache/pip}" \
         "${npm_config_cache:-/app/.cache/npm}" \
         "${MAVEN_CONFIG:-/app/.cache/m2}" \
         "${GRADLE_USER_HOME:-/app/.cache/gradle}" \
         "${UV_CACHE_DIR:-/app/.cache/uv}"; do
    mkdir -p "$d" 2>/dev/null || true
done

profile="${DSH_PROFILE:-web}"

if [ -n "${DSH_PLUGINS:-}" ]; then
    # shellcheck disable=SC2086  # 按空白拆成多个 spec 是刻意的
    for spec in ${DSH_PLUGINS}; do
        echo "dsh-entrypoint: dsh plugin --profile ${profile} add ${spec}"
        if ! dsh plugin --profile "${profile}" add "${spec}"; then
            if [ "${DSH_PLUGINS_REQUIRED:-1}" = "1" ]; then
                echo "dsh-entrypoint: FATAL 插件安装失败: ${spec}" >&2
                echo "dsh-entrypoint: 离线环境可设 DSH_PLUGINS_REQUIRED=0 跳过" >&2
                exit 1
            fi
            echo "dsh-entrypoint: WARNING 插件安装失败: ${spec}（已按 DSH_PLUGINS_REQUIRED=0 继续）" >&2
        fi
    done
fi

exec "$@"
