#!/usr/bin/env bash
# =============================================================================
#  dsh-entrypoint —— 启动准备 → 登记 DSH 插件 → 降权 exec
#
#  ── 为什么入口需要 root ────────────────────────────────────────────────────
#
#  真实故障（第一次部署就撞上）：
#
#      Error: EACCES: permission denied, mkdir '/app/.dsh'
#          at async runPluginCommand (.../dsh-plugin-manager/lib/types/operations.js:146:5)
#
#  原因：/app 是宿主目录挂进来的，而【目录不存在时 Docker 会以 root:root
#  创建它】。于是容器内 UID 1000 的 agent 连建个子目录都做不到。
#
#  把"宿主要先 chown 1000"写进文档是把问题推给用户，不算修完。postgres /
#  mysql / grafana / redis 官方镜像面对的是同一个问题，标准解法就是：
#
#      入口以 root 起 → 把数据目录交给运行用户 → 降权 exec 真正的进程
#
#  ── 与 cap_drop: ALL 的关系 ────────────────────────────────────────────────
#
#  cap_drop: ALL 会让 root 也失去 chown / setuid 能力，所以 compose 里必须
#  补回三个能力，否则这个入口根本跑不动：
#
#      CHOWN      改 /app 属主
#      SETUID     降权到 agent
#      SETGID     同上（含补充组）
#
#  其余能力仍全部丢弃，比 Docker 默认（含 NET_RAW、DAC_OVERRIDE 等）紧得多。
#  setpriv 降权成功后，进程就不再持有这三个能力。
#
#  ── UID 自动跟随挂载目录 ───────────────────────────────────────────────────
#
#  如果 /app 已经被某个非 root 用户拥有（例如你挂的是自己的工程目录），
#  且没有显式设置 AGENT_UID，就让 agent 直接采用那个 UID/GID。
#
#  这样"挂载自己的目录"这个最常见场景零配置就能用，agent 建出来的文件
#  在宿主上就归你自己，不需要 sudo 才能改。
#
#  ── 什么时候做递归 chown ───────────────────────────────────────────────────
#
#  只在 /app 对 agent 不可写时做（也就是首次挂载一个 root 属主的新目录）。
#  之后每次重启 /app 已经可写，就跳过整树扫描 —— 否则一个几万文件的工程
#  会拖慢每次容器启动。
#
#  ── 环境变量 ───────────────────────────────────────────────────────────────
#    AGENT_UID / AGENT_GID  显式指定运行用户；默认 1000，或自动跟随 /app 属主
#    APP_DIR                挂载点，默认 /app
#    DSH_PROFILE            默认 web
#    DSH_PLUGINS            空格分隔的插件 spec，留空则不登记
#    DSH_PLUGINS_REQUIRED   默认 1：装失败就退出。设 0 容忍失败继续启动
# =============================================================================
set -euo pipefail

APP_DIR="${APP_DIR:-/app}"
profile="${DSH_PROFILE:-web}"

# /app 下由本镜像管理的子树。全部在 /app 之内 —— 这是唯一挂载点，
# 容器里其余部分都是只读镜像内容。
SUBDIRS="
.dsh
.cache/cargo
.cache/go/pkg/mod
.cache/go/build
.cache/pip
.cache/npm
.cache/m2
.cache/gradle
.cache/uv
.cache/pnpm-store
"

# 以 agent 身份测试某个目录是否可写
writable_as_agent() {
    setpriv --reuid=agent --regid=agent --init-groups \
            sh -c "test -w '$1'" 2>/dev/null
}

# -----------------------------------------------------------------------------
# 第一段：以 root 运行时做准备，做完把自己降权重入本脚本
# -----------------------------------------------------------------------------
if [ "$(id -u)" = "0" ] && [ "${DSH_ENTRYPOINT_DROPPED:-0}" != "1" ]; then

    # ---- 1. 决定运行用的 UID/GID ----
    want_uid="${AGENT_UID:-}"
    want_gid="${AGENT_GID:-}"
    if [ -z "$want_uid" ] || [ -z "$want_gid" ]; then
        app_uid="$(stat -c '%u' "$APP_DIR" 2>/dev/null || echo 0)"
        app_gid="$(stat -c '%g' "$APP_DIR" 2>/dev/null || echo 0)"
        if [ "$app_uid" != "0" ]; then
            want_uid="${want_uid:-$app_uid}"
            want_gid="${want_gid:-$app_gid}"
            echo "dsh-entrypoint: ${APP_DIR} 属主 ${app_uid}:${app_gid}，agent 跟随该 UID/GID"
        fi
    fi
    want_uid="${want_uid:-1000}"
    want_gid="${want_gid:-1000}"

    # ---- 2. 把 agent 改成目标 UID/GID（-o 允许与已有 ID 重复）----
    cur_gid="$(id -g agent 2>/dev/null || echo "$want_gid")"
    if [ "$cur_gid" != "$want_gid" ]; then
        echo "dsh-entrypoint: agent GID ${cur_gid} -> ${want_gid}"
        groupmod -o -g "$want_gid" agent
    fi
    cur_uid="$(id -u agent 2>/dev/null || echo "$want_uid")"
    if [ "$cur_uid" != "$want_uid" ]; then
        echo "dsh-entrypoint: agent UID ${cur_uid} -> ${want_uid}"
        usermod -o -u "$want_uid" agent
        chown -R "$want_uid:$want_gid" /home/agent 2>/dev/null || true
    fi

    # ---- 3. /app 对 agent 不可写时，整树交给 agent ----
    # 典型场景：宿主目录不存在，Docker 以 root:root 建了个空的出来。
    # 做成条件判断而不是无条件递归：否则每次重启都要扫一遍整个工程。
    if [ ! -d "$APP_DIR" ] || ! writable_as_agent "$APP_DIR"; then
        echo "dsh-entrypoint: ${APP_DIR} 对 agent 不可写，整树 chown -> ${want_uid}:${want_gid}"
        chown -R "$want_uid:$want_gid" "$APP_DIR" 2>/dev/null || true
    fi

    # ---- 4. 补建 /app 子树（卷首次挂载时是空的）----
    for d in $SUBDIRS; do
        mkdir -p "${APP_DIR}/${d}"
    done
    chown "$want_uid:$want_gid" "$APP_DIR" 2>/dev/null || true
    for d in $SUBDIRS; do
        chown -R "$want_uid:$want_gid" "${APP_DIR}/${d}" 2>/dev/null || true
    done

    # ---- 5. 验证 agent 真的写得进去 ----
    if writable_as_agent "$APP_DIR"; then
        echo "dsh-entrypoint: ${APP_DIR} ok (owner=$(stat -c '%u:%g' "$APP_DIR"))"
    else
        cat >&2 <<EOF

dsh-entrypoint: FATAL  ${APP_DIR} 对 agent(${want_uid}:${want_gid}) 不可写。

  在宿主机上二选一：

    # A. 把挂载目录交给容器运行用户
    sudo chown -R ${want_uid}:${want_gid} <你挂到 ${APP_DIR} 的那个宿主目录>

    # B. 让容器跟随你自己的 UID（推荐，建出来的文件直接归你）
    #    在 compose 的 environment 里加：
    #        AGENT_UID: "\$(id -u)"
    #        AGENT_GID: "\$(id -g)"

  改完：docker compose down && docker compose up -d

EOF
        exit 1
    fi

    # ---- 6. 降权重入，后续全部以 agent 身份执行 ----
    export DSH_ENTRYPOINT_DROPPED=1
    exec setpriv --reuid=agent --regid=agent --init-groups "$0" "$@"
fi

# -----------------------------------------------------------------------------
# 第二段：以 agent 运行（正常路径走这里）
#
# 插件登记必须放在降权【之后】：`dsh plugin add` 会在 profile 目录里跑 pnpm
# 并写文件，这些文件必须属于 agent，否则下次启动又写不了。
# -----------------------------------------------------------------------------
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
