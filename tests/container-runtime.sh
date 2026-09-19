#!/usr/bin/env bash
# 在真实 Docker/Linux 中跑入口 interface，不 mock id/chown/setpriv/mkdir。
# 用法：bash tests/container-runtime.sh <本次构建的镜像>
# 单引号中的程序刻意在容器内展开，不能在宿主提前展开。
# shellcheck disable=SC2016
set -euo pipefail
image="${1:?usage: container-runtime.sh IMAGE}"
command -v docker >/dev/null
scratch="$(mktemp -d)"
cleanup() {
    # 只清理本脚本创建的临时 fixture；不用宿主 sudo，也不触碰用户工作区。
    docker run --rm --network none --user 0 --entrypoint /bin/bash \
        --mount "type=bind,source=$scratch,target=/cases" "$image" \
        -euc 'find /cases -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +' >/dev/null 2>&1 \
        || { printf 'Fixture cleanup failed: %s\n' "$scratch" >&2; return; }
    rmdir -- "$scratch"
}
trap cleanup EXIT

image_uid="$(docker run --rm --network none --entrypoint /usr/bin/id "$image" -u agent)"
image_gid="$(docker run --rm --network none --entrypoint /usr/bin/id "$image" -g agent)"

docker run --rm --network none --user 0 --entrypoint /bin/bash \
    --mount "type=bind,source=$scratch,target=/cases" "$image" -euc '
        chmod 755 /cases
        mkdir -p /cases/root /cases/private /cases/legacy/.dsh \
            /cases/readonly /cases/symlink /cases/explicit /cases/injected/.cache/cargo/bin
        chmod 755 /cases/root /cases/legacy /cases/readonly /cases/symlink /cases/explicit /cases/injected
        chown 12345:12346 /cases/private
        chmod 700 /cases/private
        touch /cases/root/project-file /cases/legacy/.dsh/old-state
        chmod 600 /cases/root/project-file /cases/legacy/.dsh/old-state
        chmod 700 /cases/legacy/.dsh
        ln -s /home/agent /cases/symlink/.dsh
        printf "#!/bin/bash\ntouch /app/root-path-executed\nexec /usr/bin/id \"\u0024@\"\n" > /cases/injected/.cache/cargo/bin/id
        chmod 755 /cases/injected/.cache/cargo/bin/id
    '

run_runtime() {
    local mount="$1" program="$2"
    shift 2
    docker run --rm --network none --cap-drop ALL \
        --cap-add CHOWN --cap-add SETUID --cap-add SETGID \
        --security-opt no-new-privileges:true \
        --env DSH_PLUGINS= --mount "$mount" "$@" "$image" /bin/bash -euc "$program"
}

check='set -euo pipefail
    test "$(/usr/bin/id -u)" = "$EXPECT_UID"
    test "$(/usr/bin/id -g)" = "$EXPECT_GID"
    test "$HOME" = /home/agent
    test "$PWD" = /app
    test "$(awk '\''$1 == "CapEff:" { print $2 }'\'' /proc/self/status)" = 0000000000000000
    for d in /app/.dsh /app/.cache/cargo /app/.cache/go/pkg/mod /app/.cache/go/build \
             /app/.cache/npm /app/.cache/pip /app/.cache/m2 /app/.cache/gradle \
             /app/.cache/uv /app/.cache/pnpm-store; do
        test -d "$d"; test -w "$d"; test -x "$d"
    done
    node -e '\''const fs=require("node:fs"); fs.mkdirSync("/app/.dsh/probe",{recursive:true}); fs.writeFileSync("/app/.dsh/probe/write", "ok");'\''
    test "$(stat -c %u:%g /app/.dsh/probe/write)" = "$EXPECT_UID:$EXPECT_GID"
'

printf '\n=== root-owned 0755, minimal capabilities ===\n'
run_runtime "type=bind,source=$scratch/root,target=/app" "$check
    test \"\$(stat -c %u /app/project-file)\" = 0" \
    -e "EXPECT_UID=$image_uid" -e "EXPECT_GID=$image_gid"

printf '\n=== healthy restart, keep project ownership ===\n'
run_runtime "type=bind,source=$scratch/root,target=/app" "$check
    test \"\$(stat -c %u /app/project-file)\" = 0" \
    -e "EXPECT_UID=$image_uid" -e "EXPECT_GID=$image_gid"

printf '\n=== non-root-owned 0700, follow UID and GID ===\n'
run_runtime "type=bind,source=$scratch/private,target=/app" "$check" \
    -e EXPECT_UID=12345 -e EXPECT_GID=12346

printf '\n=== explicit identity, ignore forged dropped marker ===\n'
run_runtime "type=bind,source=$scratch/explicit,target=/app" "$check" \
    -e AGENT_UID=12347 -e AGENT_GID=12348 -e DSH_ENTRYPOINT_DROPPED=1 \
    -e EXPECT_UID=12347 -e EXPECT_GID=12348

printf '\n=== migrate root-owned state, not project files ===\n'
run_runtime "type=bind,source=$scratch/legacy,target=/app" "$check
    test -w /app/.dsh/old-state" \
    -e "EXPECT_UID=$image_uid" -e "EXPECT_GID=$image_gid"

printf '\n=== direct non-root entrypoint ===\n'
run_runtime "type=bind,source=$scratch/private,target=/app" \
    'test "$(id -u)" = 12345; test -w /app/.dsh; touch /app/direct-user' \
    --user 12345:12346

printf '\n=== root must not resolve commands from workspace PATH ===\n'
run_runtime "type=bind,source=$scratch/injected,target=/app" \
    'test "$(/usr/bin/id -u)" != 0; test ! -e /app/root-path-executed'

printf '\n=== readonly mount fails before command ===\n'
if run_runtime "type=bind,source=$scratch/readonly,target=/app,readonly" \
    'echo UNEXPECTED_COMMAND' > "$scratch/readonly.log" 2>&1; then
    printf 'Readonly mount unexpectedly succeeded\n' >&2; exit 1
fi
grep -q 'FATAL.*不可写' "$scratch/readonly.log"
if grep -q UNEXPECTED_COMMAND "$scratch/readonly.log"; then
    printf 'Command ran despite a readonly mount\n' >&2; exit 1
fi

printf '\n=== managed state symlink is rejected ===\n'
if run_runtime "type=bind,source=$scratch/symlink,target=/app" \
    'echo UNEXPECTED_COMMAND' > "$scratch/symlink.log" 2>&1; then
    printf 'Managed symlink unexpectedly accepted\n' >&2; exit 1
fi
grep -q 'FATAL.*符号链接' "$scratch/symlink.log"
if grep -q UNEXPECTED_COMMAND "$scratch/symlink.log"; then
    printf 'Command ran despite a managed symlink\n' >&2; exit 1
fi

printf '\n=== root UID configuration is rejected ===\n'
if run_runtime "type=bind,source=$scratch/root,target=/app" true \
    -e AGENT_UID=0 > "$scratch/uid.log" 2>&1; then
    printf 'UID 0 unexpectedly accepted\n' >&2; exit 1
fi
grep -q 'FATAL.*AGENT_UID' "$scratch/uid.log"
printf '\n=== ALL RUNTIME CONTRACTS PASSED ===\n'
