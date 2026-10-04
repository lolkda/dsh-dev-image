#!/bin/sh
# 由 root 入口和 /etc/profile.d source；只设置环境，不写配置或创建目录。
# Docker ENV 同时提供默认值，保证不经过 Shell 的 docker exec 也使用持久化目录。
# 此模块在镜像工具链安装之后才启用，不把构建期工具安装重定向到卷。
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

# pnpm 12 的可执行文件位于 PNPM_HOME/bin；首次安装前也加入 PATH。
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
