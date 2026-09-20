#!/bin/sh
# 由入口（降权后）和 /etc/profile.d source；只设置环境，不写用户配置或创建目录。
# Docker ENV 同时提供这些默认值，保证不经过 Shell 的 docker exec 也使用持久化目录。
# root 不从这里引入用户可写的 CLI 路径，构建期工具安装仍留在镜像中。
if [ "$(/usr/bin/id -u)" -ne 0 ]; then
    export npm_config_prefix="${npm_config_prefix:-${NPM_CONFIG_PREFIX:-$HOME/.local}}"
    export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
    export YARN_PREFIX="${YARN_PREFIX:-$HOME/.local}"
    export YARN_GLOBAL_FOLDER="${YARN_GLOBAL_FOLDER:-$HOME/.local/share/yarn/global}"
    export PYTHONUSERBASE="${PYTHONUSERBASE:-$HOME/.local}"
    export UV_TOOL_DIR="${UV_TOOL_DIR:-$HOME/.local/share/uv/tools}"
    export UV_TOOL_BIN_DIR="${UV_TOOL_BIN_DIR:-$HOME/.local/bin}"
    export CARGO_INSTALL_ROOT="${CARGO_INSTALL_ROOT:-$HOME/.local}"
    export GOBIN="${GOBIN:-$HOME/.local/bin}"

    # 冒号无法作为单个 PATH 项表达；不要把相对目录意外加入命令搜索路径。
    for dsh_cli_dir in "$HOME" "$npm_config_prefix" "$PNPM_HOME" \
        "${PNPM_CONFIG_GLOBAL_BIN_DIR:-$PNPM_HOME/bin}" "${PNPM_CONFIG_GLOBAL_DIR:-$PNPM_HOME/global}" \
        "$YARN_PREFIX" "$YARN_GLOBAL_FOLDER" "$PYTHONUSERBASE" \
        "$UV_TOOL_DIR" "$UV_TOOL_BIN_DIR" "$CARGO_INSTALL_ROOT" "$GOBIN"; do
        case "$dsh_cli_dir" in
            /|*:*|[!/]*)
                printf 'dsh-cli-env: CLI 目录必须是非根目录的绝对路径，且不能包含冒号：%s\n' "$dsh_cli_dir" >&2
                return 1 ;;
        esac
    done

    # pnpm 12 的可执行文件位于 PNPM_HOME/bin；不同于旧版本的 PNPM_HOME。
    # 即使尚未安装任何工具也加入 PATH，避免第一次安装后还得重开 Shell。
    for dsh_cli_dir in "$HOME/bin" "$PNPM_HOME/bin" "$PYTHONUSERBASE/bin" \
        "$YARN_PREFIX/bin" "$CARGO_INSTALL_ROOT/bin" "$GOBIN" "$UV_TOOL_BIN_DIR" \
        "$npm_config_prefix/bin" "${PNPM_CONFIG_GLOBAL_BIN_DIR:-$PNPM_HOME/bin}"; do
        case ":${PATH:-}:" in
            *":$dsh_cli_dir:"*) ;;
            *) PATH="$dsh_cli_dir${PATH:+:$PATH}" ;;
        esac
    done
    export PATH
    unset dsh_cli_dir
fi
