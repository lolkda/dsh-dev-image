#!/usr/bin/env bash
# 完整镜像验收：离线安装七类 CLI，再换容器、清缓存，并验证 docker exec。
# shellcheck disable=SC2016
set -euo pipefail
image="${1:?usage: user-cli-runtime.sh IMAGE}"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
live_id=''
cleanup() {
    if [[ -n "$live_id" ]]; then docker rm -f "$live_id" >/dev/null; fi
    docker run --rm --network none --user 0 --entrypoint /bin/bash \
        --mount "type=bind,source=$scratch,target=/cases" "$image" \
        -euc 'find /cases -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +' >/dev/null 2>&1 \
        || { printf 'CLI fixture cleanup failed: %s\n' "$scratch" >&2; return; }
    rmdir -- "$scratch"
}
trap cleanup EXIT

docker run --rm --network none --user 0 --entrypoint /bin/bash \
    --mount "type=bind,source=$scratch,target=/cases" "$image" -euc '
        chmod 755 /cases
        mkdir /cases/default /cases/mapped
        chmod 755 /cases/default /cases/mapped
    '
caps=(--cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID
      --security-opt no-new-privileges:true)
for identity in default mapped; do
    identity_env=()
    if [[ "$identity" == mapped ]]; then identity_env=(-e AGENT_UID=12345 -e AGENT_GID=12346); fi
    args=(--network none "${caps[@]}" "${identity_env[@]}" -e DSH_PLUGINS=
          --mount "type=bind,source=$scratch/$identity,target=/app"
          --mount "type=bind,source=$root/tests,target=/acceptance,readonly")
    printf '\n=== user CLI installation with %s identity ===\n' "$identity"
    docker run --rm "${args[@]}" "$image" bash -euc '
        printf "%s" "$(< /etc/hostname)" > "$HOME/cli-source-container"
        bash /acceptance/user-cli-smoke.sh install
    '
    for mode in -ec -lec; do
        docker run --rm "${args[@]}" "$image" bash "$mode" '
            test "$(< "$HOME/cli-source-container")" != "$(< /etc/hostname)"
            bash /acceptance/user-cli-smoke.sh check
        '
    done
    # 仅删除本测试专属 bind mount 中的缓存，不碰调用者的工作区。
    docker run --rm "${args[@]}" "$image" bash -euc 'rm -rf -- /app/.cache "$HOME/.cache"'
    docker run --rm "${args[@]}" "$image" bash -lec 'bash /acceptance/user-cli-smoke.sh check'

    live_id="$(docker run -d "${args[@]}" "$image" bash -euc ': > /tmp/dsh-cli-exec-ready; exec sleep infinity')"
    # docker exec 不经过入口；靠镜像 ENV 找到持久化的 CLI，而不是当前进程 export。
    # 标记只由降权后的主命令创建，避免自定义 UID 的账户调整与 exec 发生竞态。
    docker exec "$live_id" /bin/bash -euc '
        for ((attempt = 0; attempt < 100; attempt++)); do
            if [[ -f /tmp/dsh-cli-exec-ready ]]; then
                exit 0
            fi
            sleep 0.1
        done
        exit 1
    '
    [[ "$(docker exec --user agent "$live_id" npm prefix --global)" == /app/.home/.local ]]
    for manager in npm pnpm yarn pip uv cargo go; do
        [[ "$(docker exec --user agent "$live_id" "dsh-cli-$manager-fixture")" == "persistent $manager CLI" ]]
    done
    docker rm -f "$live_id" >/dev/null
    live_id=''
done
printf '\n=== USER CLI RECREATION AND UID CONTRACTS PASSED ===\n'
