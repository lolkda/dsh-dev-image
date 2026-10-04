#!/bin/bash
# root-only：校验配置 → root 建目录、装插件 → exec 主命令；不切换身份或改写属主。
# /app/.home 保持持久化；旧 UID 的文件通过运行时 capabilities 访问，不递归 chown。
set -euo pipefail

log() { printf 'dsh-entrypoint: %s\n' "$*" >&2; }
fatal() { log "FATAL $*"; exit 1; }

if (( EUID != 0 )) || [[ "$(/usr/bin/id -g)" != 0 ]]; then
    fatal '此镜像仅支持 root (0:0)；请移除非 root 的 user/--user 配置。'
fi
[[ -z "${AGENT_UID:-}" && -z "${AGENT_GID:-}" ]] \
    || fatal 'AGENT_UID/AGENT_GID 已移除；root-only 镜像不再映射身份，请删除旧配置。'
export USER=root LOGNAME=root
APP_DIR="${APP_DIR:-/app}"
profile="${DSH_PROFILE:-web}"
# HOME 是受管持久化状态，统一到挂载点内的真实路径，不改为 /root。
export HOME="$APP_DIR/.home"
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

state_dirs=(
    "$HOME" "$APP_DIR/.cache" "$DSH_HOME" "$CARGO_HOME" "$GOPATH" "$GOMODCACHE"
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

permission_error() {
    fatal "目录不可写：$1（运行身份 root 0:0）。检查只读挂载、宿主 ACL/NFS root-squash、用户命名空间及 DAC_OVERRIDE/FOWNER；不要用 DSH_PLUGINS_REQUIRED=0 掩盖权限错误。"
}

# 初始化只补目录，不更改属主；绝对工具路径避免初始化被工作区同名工具覆盖。
[[ ! -L "$APP_DIR" ]] || fatal "挂载目录不能是符号链接：$APP_DIR"
/usr/bin/mkdir -p -- "$APP_DIR" || permission_error "$APP_DIR"
[[ -d "$APP_DIR" && -w "$APP_DIR" && -x "$APP_DIR" ]] || permission_error "$APP_DIR"
for dir in "${state_dirs[@]}"; do
    [[ ! -L "$dir" ]] || fatal "受管状态目录不能是符号链接：$dir"
    if [[ "$dir" == "$HOME" ]]; then
        (umask 077; /usr/bin/mkdir -p -- "$dir") || permission_error "$dir"
    else
        /usr/bin/mkdir -p -- "$dir" || permission_error "$dir"
    fi
    [[ -d "$dir" && -w "$dir" && -x "$dir" ]] || permission_error "$dir"
done
script_dir="$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd)"
node_command=/usr/local/bin/node
[[ -x "$node_command" ]] || node_command=node
"$node_command" "$script_dir/home-init.mjs" "$HOME" /etc/skel || fatal '持久化 HOME 初始化失败；检查目录类型与 FOWNER 权限。'
# shellcheck source=cli-env.sh
source "$script_dir/cli-env.sh" || fatal '用户级 CLI 环境配置无效。'

# 缓存与安装产物分开：清理 .cache 不应删除新安装的用户 CLI。
cli_dirs=(
    "$HOME/.local" "$HOME/.local/bin" "$HOME/.local/share"
    "$HOME/.local/share/yarn" "$HOME/.local/share/uv"
    "$npm_config_prefix" "$npm_config_prefix/bin" "$PNPM_HOME"
    "${PNPM_CONFIG_GLOBAL_BIN_DIR:-$PNPM_HOME/bin}" "${PNPM_CONFIG_GLOBAL_DIR:-$PNPM_HOME/global}"
    "$YARN_PREFIX" "$YARN_PREFIX/bin" "$YARN_GLOBAL_FOLDER"
    "$PYTHONUSERBASE" "$PYTHONUSERBASE/bin" "$UV_TOOL_DIR" "$UV_TOOL_BIN_DIR"
    "$CARGO_INSTALL_ROOT" "$CARGO_INSTALL_ROOT/bin" "$GOBIN"
)
for dir in "${cli_dirs[@]}"; do
    [[ ! -L "$dir" ]] || fatal "受管 CLI 目录不能是符号链接：$dir"
    /usr/bin/mkdir -p -- "$dir" || permission_error "$dir"
    [[ -d "$dir" && -w "$dir" && -x "$dir" ]] || permission_error "$dir"
done
cd -- "$APP_DIR" || permission_error "$APP_DIR"
log "以 root (0:0) 启动，HOME=$HOME"

# pnpm 12 默认 24h 成熟期只在插件安装时关闭，用户项目仍用自己的默认策略。
for spec in "${plugins[@]}"; do
    log "dsh plugin --profile $profile add $spec"
    if ! PNPM_CONFIG_MINIMUM_RELEASE_AGE=0 dsh plugin --profile "$profile" add "$spec"; then
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
