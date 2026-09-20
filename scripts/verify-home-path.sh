#!/usr/bin/env bash
# migrate-home.sh 的内部预检：只读停止容器的路径元数据，不导出父目录内容。
# 调用方已完成 SOURCE_HOME 的规范绝对路径校验以及容器/Unix endpoint 校验。
set -euo pipefail
fatal() { printf 'dsh-home-path: %s\n' "$*" >&2; exit 1; }
socket="${1:?usage: verify-home-path.sh UNIX_SOCKET CONTAINER SOURCE_HOME}"
container="${2:?缺少源容器}"
current="${3:?缺少源 HOME}"
for command in curl jq base64 awk; do
    command -v "$command" >/dev/null || fatal "缺少路径元数据检查命令：$command"
done

while [[ -n "$current" ]]; do
    headers="$(curl --silent --show-error --fail --max-time 10 --noproxy '*' \
        --unix-socket "$socket" --head --get --data-urlencode "path=$current" \
        "http://localhost/containers/$container/archive")" \
        || fatal "无法读取路径元数据：$current"
    encoded="$(awk 'tolower($1) == "x-docker-container-path-stat:" { sub(/\r$/, "", $2); print $2 }' <<< "$headers")"
    [[ -n "$encoded" ]] || fatal "缺少路径元数据：$current"
    metadata="$(printf '%s' "$encoded" | base64 --decode)" || fatal "路径元数据编码无效：$current"
    # Docker 返回 Go os.FileMode，不是 POSIX st_mode；类型标志使用高位。
    kind="$(jq -er '
        if type != "object" then error("invalid path stat") else . end
        | if (.mode | type) != "number" or (.linkTarget | type) != "string"
          then error("invalid path stat fields") else . end
        | .mode as $mode
        | if $mode < 0 or $mode > 4294967295 or ($mode | floor) != $mode
          then error("invalid path mode")
          elif .linkTarget != "" or (($mode / 134217728 | floor) % 2) == 1 then "link"
          elif (($mode / 2147483648 | floor) % 2) == 1 then "directory"
          else "other" end
    ' <<< "$metadata")" || fatal "路径元数据无效：$current"
    case "$kind" in
        directory) ;;
        link) fatal "源 HOME 不能经过符号链接：$current" ;;
        *) fatal "源 HOME 路径必须由实际目录组成：$current" ;;
    esac
    current="${current%/*}"
done
