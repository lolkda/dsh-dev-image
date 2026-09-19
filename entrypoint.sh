#!/bin/bash
# 启动顺序：校验配置 → root 仅修复身份/必要属主 → agent 建目录、装插件、exec。
# root 阶段只需 CHOWN / SETUID / SETGID；普通文件操作不依赖 DAC_OVERRIDE。
# 只管理 /app 本身和状态目录，不递归改写用户的整个项目。
set -euo pipefail

log() { printf 'dsh-entrypoint: %s\n' "$*" >&2; }
fatal() { log "FATAL $*"; exit 1; }

# 非 root 路径也执行同一套准备，可配合预先授权的 docker run --user 使用。
APP_DIR="${APP_DIR:-/app}"
profile="${DSH_PROFILE:-web}"
export DSH_HOME="${DSH_HOME:-$APP_DIR/.dsh}"
export CARGO_HOME="${CARGO_HOME:-$APP_DIR/.cache/cargo}"
export GOPATH="${GOPATH:-$APP_DIR/.cache/go}"
export GOMODCACHE="${GOMODCACHE:-$GOPATH/pkg/mod}"
export GOCACHE="${GOCACHE:-$GOPATH/build}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$APP_DIR/.cache/pip}"
export npm_config_cache="${npm_config_cache:-$APP_DIR/.cache/npm}"
export MAVEN_CONFIG="${MAVEN_CONFIG:-$APP_DIR/.cache/m2}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$APP_DIR/.cache/gradle}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$APP_DIR/.cache/uv}"

(( $# > 0 )) || fatal '缺少启动命令，例如：dsh web 或 bash。'
[[ "$APP_DIR" = /* && "$APP_DIR" != / ]] || fatal 'APP_DIR 必须是非根目录的绝对路径。'
[[ "${DSH_PLUGINS_REQUIRED:-1}" =~ ^[01]$ ]] || fatal 'DSH_PLUGINS_REQUIRED 只能是 0 或 1。'

validate_id() {
    # 拒绝 root、符号、前导零和超出 Linux uid_t 范围的值；不用不安全的算术求值。
    local name="$1" value="$2"
    [[ "$value" =~ ^[1-9][0-9]{0,9}$ ]] || fatal "$name 必须是非零的十进制 UID/GID。"
    (( 10#$value < 4294967295 )) || fatal "$name 超出 UID/GID 范围。"
}
[[ -z "${AGENT_UID:-}" ]] || validate_id AGENT_UID "$AGENT_UID"
[[ -z "${AGENT_GID:-}" ]] || validate_id AGENT_GID "$AGENT_GID"

state_dirs=(
    "$APP_DIR/.cache" "$DSH_HOME" "$CARGO_HOME" "$GOPATH" "$GOMODCACHE"
    "$GOCACHE" "$PIP_CACHE_DIR" "$npm_config_cache" "$MAVEN_CONFIG"
    "$GRADLE_USER_HOME" "$UV_CACHE_DIR" "$APP_DIR/.cache/pnpm-store"
)
for dir in "${state_dirs[@]}"; do
    [[ "$dir" = /* && "$dir" != / ]] || fatal "状态目录必须是非根目录的绝对路径：$dir"
done

# 保留 spec 的字面量，不让 * / ? / [] 被工作区文件名展开。
plugins=()
plugin_specs="${DSH_PLUGINS:-}"
read -r -a plugins <<< "${plugin_specs//$'\n'/ }"
for spec in "${plugins[@]}"; do
    [[ "$spec" != -* ]] || fatal "插件 spec 不能是包管理器选项：$spec"
done

as_agent() {
    /usr/bin/setpriv --reuid=agent --regid=agent --init-groups -- "$@"
}

writable_as_agent() {
    # 路径通过参数传入，不能插入 sh -c 的代码字符串（路径可能含单引号）。
    # shellcheck disable=SC2016 # $1 由降权后的 sh 展开，不由当前 root shell 展开。
    as_agent /bin/sh -c 'test -d "$1" && test -w "$1" && test -x "$1"' sh "$1"
}

permission_error() {
    fatal "目录不可写：$1（目标 UID:GID=${want_uid:-$EUID}:${want_gid:-$(id -g)}）。检查挂载是否只读、宿主 ACL/NFS root-squash，以及 CHOWN/SETUID/SETGID；不要用 DSH_PLUGINS_REQUIRED=0 掩盖权限错误。"
}

if (( EUID == 0 )); then
    # 不信任 DSH_ENTRYPOINT_DROPPED 等外部标记；是否降权只看实际 EUID。
    # 特别是 /app/.cache/*/bin 可由工作区写入，绝不能让 root 从那里找命令。
    runtime_path="$PATH"
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    cur_uid="$(id -u agent)" || fatal '镜像缺少 agent 用户。'
    cur_gid="$(id -g agent)" || fatal '镜像缺少 agent 组。'
    want_uid="${AGENT_UID:-}"
    want_gid="${AGENT_GID:-}"
    [[ ! -L "$APP_DIR" ]] || fatal "挂载目录不能是符号链接：$APP_DIR"

    if [[ -d "$APP_DIR" ]]; then
        app_uid="$(stat -c '%u' -- "$APP_DIR")"
        app_gid="$(stat -c '%g' -- "$APP_DIR")"
        if [[ "$app_uid" != 0 ]]; then
            want_uid="${want_uid:-$app_uid}"
            # 不自动跟随 root 组，未指定时保留镜像的 agent GID。
            if [[ "$app_gid" != 0 ]]; then
                want_gid="${want_gid:-$app_gid}"
            fi
        fi
    else
        mkdir -p -- "$APP_DIR" || permission_error "$APP_DIR"
    fi
    # 尊重构建时 USER_UID/USER_GID，不再把非 1000 的镜像重置为 1000。
    want_uid="${want_uid:-$cur_uid}"
    want_gid="${want_gid:-$cur_gid}"
    validate_id AGENT_UID "$want_uid"
    validate_id AGENT_GID "$want_gid"

    if [[ "$cur_gid" != "$want_gid" ]]; then
        log "agent GID $cur_gid -> $want_gid"
        groupmod -o -g "$want_gid" agent || fatal '无法调整 agent GID。'
    fi
    if [[ "$cur_uid" != "$want_uid" ]]; then
        log "agent UID $cur_uid -> $want_uid"
        usermod -o -u "$want_uid" agent || fatal '无法调整 agent UID。'
    fi
    if [[ "$cur_uid:$cur_gid" != "$want_uid:$want_gid" ]]; then
        chown -hR "$want_uid:$want_gid" /home/agent || permission_error /home/agent
    fi

    # 只修复挂载点本身，不动工程内的代码、.git 或其他不属于镜像管理的文件。
    if ! writable_as_agent "$APP_DIR"; then
        log "修复挂载点属主：$APP_DIR -> $want_uid:$want_gid"
        chown -h "$want_uid:$want_gid" "$APP_DIR" || permission_error "$APP_DIR"
        writable_as_agent "$APP_DIR" || permission_error "$APP_DIR"
    fi

    # 兼容旧容器留下的 root-owned 状态。健康目录不做递归扫描；缺的交给 agent 建。
    # 通过 agent 检查，才能支持 0700 的非 root 挂载目录和最小 capabilities。
    for dir in "${state_dirs[@]}"; do
        if as_agent test -L "$dir"; then
            fatal "受管状态目录不能是符号链接：$dir"
        fi
        if as_agent test -e "$dir" && ! writable_as_agent "$dir"; then
            as_agent test -d "$dir" || fatal "状态路径不是目录：$dir"
            log "修复状态目录属主：$dir -> $want_uid:$want_gid"
            chown -hR "$want_uid:$want_gid" "$dir" || permission_error "$dir"
            writable_as_agent "$dir" || permission_error "$dir"
        fi
    done

    # setpriv 不会像 login 一样重置 HOME；不重置会让 pnpm 错读 /root 的配置。
    export HOME=/home/agent USER=agent LOGNAME=agent PATH="$runtime_path"
    log "以 agent ($want_uid:$want_gid) 启动，HOME=$HOME"
    exec /usr/bin/setpriv --reuid=agent --regid=agent --init-groups --no-new-privs \
        -- /bin/bash "$0" "$@"
fi

# 从这里起绝不需要 root，也不尝试 chown。失败必须发生在插件安装之前。
[[ -d "$APP_DIR" && -w "$APP_DIR" && -x "$APP_DIR" ]] || permission_error "$APP_DIR"
for dir in "${state_dirs[@]}"; do
    [[ ! -L "$dir" ]] || fatal "受管状态目录不能是符号链接：$dir"
    mkdir -p -- "$dir" || permission_error "$dir"
    [[ -d "$dir" && -w "$dir" && -x "$dir" ]] || permission_error "$dir"
done
cd -- "$APP_DIR" || permission_error "$APP_DIR"

for spec in "${plugins[@]}"; do
    log "dsh plugin --profile $profile add $spec"
    if ! dsh plugin --profile "$profile" add "$spec"; then
        if [[ "${DSH_PLUGINS_REQUIRED:-1}" == 1 ]]; then
            fatal "插件安装失败：$spec。只有允许缺少插件时才设 DSH_PLUGINS_REQUIRED=0；检查上方原始错误。"
        fi
        log "WARNING 插件安装失败：$spec（DSH_PLUGINS_REQUIRED=0，继续启动）"
    fi
done

# dsh web 是 dsh --profile web 的简写；环境选择必须同时用于安装与启动。
if [[ "$1" == dsh && "${2:-}" == web ]]; then
    shift 2
    set -- dsh --profile "$profile" "$@"
fi
exec "$@"
