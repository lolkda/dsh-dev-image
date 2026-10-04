#!/usr/bin/env bash
# 仅使用隔离测试文件验证旧 HOME 导出，不访问真实登录状态。
# shellcheck disable=SC2016
set -euo pipefail
image="${1:?usage: home-migration-runtime.sh IMAGE}"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
source_home="/legacy data/owner's home"
containers=()
cleanup() {
    for container in "${containers[@]}"; do docker rm -f "$container" >/dev/null; done
    docker run --rm --network none --user 0 --entrypoint /bin/bash \
        --mount "type=bind,source=$scratch,target=/cases" "$image" \
        -euc 'find /cases -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +' >/dev/null
    rmdir -- "$scratch"
}
trap cleanup EXIT
run_migration() {
    # 以宿主 root 发布私有导出副本，目标固定为 0:0。
    if (( EUID == 0 )); then
        timeout 30 env TMPDIR="$scratch/export" bash "$root/scripts/migrate-home.sh" "$@" "$source_home"
    else
        timeout 30 sudo env TMPDIR="$scratch/export" bash "$root/scripts/migrate-home.sh" "$@" "$source_home"
    fi
}
mkdir "$scratch/app" "$scratch/bound-source" "$scratch/linked-source" "$scratch/export"

legacy="$(docker create --network none --user 0 --entrypoint /bin/bash \
    --env "SOURCE_HOME=$source_home" "$image" -euc '
    mkdir -p "$SOURCE_HOME/.config/gh" "$SOURCE_HOME/.ssh"
    printf legacy-gh-fixture > "$SOURCE_HOME/.config/gh/hosts.yml"
    printf legacy-key-fixture > "$SOURCE_HOME/.ssh/fixture-key"
    printf "# user shell fixture\n" > "$SOURCE_HOME/.bashrc"
    git config --file "$SOURCE_HOME/.gitconfig" user.name "Migrated Fixture"
    chown -R 1000:1000 "$SOURCE_HOME"
    chmod 700 "$SOURCE_HOME" "$SOURCE_HOME/.ssh"
    chmod 600 "$SOURCE_HOME/.config/gh/hosts.yml" "$SOURCE_HOME/.ssh/fixture-key"
    chown 0:0 "$SOURCE_HOME/.ssh/fixture-key"
')"
containers+=("$legacy")
docker start --attach "$legacy" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$legacy")" = 0

run_migration "$legacy" "$scratch/app"
test "$(docker inspect --format '{{.State.Running}}' "$legacy")" = false

docker run --rm --network none --cap-add SYS_PTRACE \
    --security-opt no-new-privileges:true -e DSH_PLUGINS= \
    --mount "type=bind,source=$scratch/app,target=/app" "$image" bash -euc '
        test "$(id -u):$(id -g)" = 0:0
        test "$(stat -c %u:%g /app/.home)" = 0:0
        test "$HOME" = /app/.home
        test "$(< "$HOME/.config/gh/hosts.yml")" = legacy-gh-fixture
        test "$(< "$HOME/.ssh/fixture-key")" = legacy-key-fixture
        test "$(git config --global user.name)" = "Migrated Fixture"
        test "$(stat -c %a "$HOME")" = 700
        test "$(stat -c %a "$HOME/.ssh/fixture-key")" = 600
        test "$(stat -c %u "$HOME/.ssh/fixture-key")" = "$(id -u)"
        test "$(< "$HOME/.bashrc")" = "# user shell fixture"
    '

if run_migration "$legacy" "$scratch/app" > "$scratch/conflict.log" 2>&1; then
    printf 'Migration overwrote an existing HOME\n' >&2; exit 1
fi
grep -q '目标已存在' "$scratch/conflict.log"

# 源 HOME 已挂到目标 APP：必须在创建 staging 前拒绝，不能自复制。
printf unchanged > "$scratch/bound-source/sentinel"
bound="$(docker create --network none --entrypoint /bin/true \
    --mount "type=bind,source=$scratch/bound-source,target=$source_home" "$image")"
containers+=("$bound")
if run_migration "$bound" "$scratch/bound-source" > "$scratch/bound.log" 2>&1; then
    printf 'Overlapping HOME mount unexpectedly accepted\n' >&2; exit 1
fi
grep -q '源 HOME 存在挂载' "$scratch/bound.log"
test "$(< "$scratch/bound-source/sentinel")" = unchanged

# 源 HOME 是指向 APP 的根链接：docker cp 必须复制链接本身，不跟随它递归。
printf unchanged > "$scratch/linked-source/sentinel"
linked="$(docker create --network none --user 0 --entrypoint /bin/bash \
    --env "SOURCE_HOME=$source_home" \
    --mount "type=bind,source=$scratch/linked-source,target=/app" "$image" -euc '
        mkdir -p -- "$(dirname -- "$SOURCE_HOME")"
        ln -s /app "$SOURCE_HOME"
    ')"
containers+=("$linked")
docker start --attach "$linked" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$linked")" = 0
status=0
run_migration "$linked" "$scratch/linked-source" > "$scratch/linked.log" 2>&1 || status=$?
test "$status" != 0
test "$status" != 124
test ! -e "$scratch/linked-source/.home"
test "$(< "$scratch/linked-source/sentinel")" = unchanged
docker run --rm --network none --user 0 --entrypoint /bin/bash \
    --mount "type=bind,source=$scratch/linked-source,target=/case,readonly" "$image" -euc '
        for directory in /case/.home-import.*; do
            [[ -d "$directory" ]] || continue
            test -z "$(find "$directory" -mindepth 1 -maxdepth 1 -type d -print -quit)"
        done
    '
# 父目录链接指向 bind mount：叶子虽然是真实目录，也不能绕过挂载限制。
mkdir -p "$scratch/parent-linked-source/private-home"
printf unchanged > "$scratch/parent-linked-source/private-home/sentinel"
parent_linked="$(docker create --network none --user 0 --entrypoint /bin/bash \
    --mount "type=bind,source=$scratch/parent-linked-source,target=/app" "$image" -euc '
        ln -s /app /alias
    ')"
containers+=("$parent_linked")
docker start --attach "$parent_linked" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$parent_linked")" = 0
if source_home=/alias/private-home run_migration "$parent_linked" "$scratch/parent-linked-source" > "$scratch/parent-linked.log" 2>&1; then
    printf 'Linked source ancestor unexpectedly accepted\n' >&2; exit 1
fi
grep -q '符号链接' "$scratch/parent-linked.log"
test ! -e "$scratch/parent-linked-source/.home"
test "$(< "$scratch/parent-linked-source/private-home/sentinel")" = unchanged

printf '\n=== HOME MIGRATION AND NO-OVERWRITE CONTRACTS PASSED ===\n'
