#!/usr/bin/env bash
# 在真实 Docker/Linux 中验证 root-only 入口；不 mock UID、文件权限或 capabilities。
# shellcheck disable=SC2016
set -euo pipefail
image="${1:?usage: container-runtime.sh IMAGE}"
command -v docker >/dev/null
scratch="$(mktemp -d -t dsh-root-runtime.XXXXXX)"
cleanup() {
    [[ "$scratch" == /*/dsh-root-runtime.* && -d "$scratch" && ! -L "$scratch" ]] || return 1
    docker run --rm --network none --user 0 --entrypoint /bin/bash \
        --mount "type=bind,source=$scratch,target=/cases" "$image" \
        -euc 'test -d /cases; find /cases -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +' >/dev/null 2>&1 \
        || { printf 'Fixture cleanup failed: %s\n' "$scratch" >&2; return; }
    rmdir -- "$scratch"
}
trap cleanup EXIT

docker run --rm --network none --entrypoint /bin/bash \
    --mount "type=bind,source=$scratch,target=/cases" "$image" -euc '
        test "$(id -u):$(id -g)" = 0:0
        chmod 755 /cases
        mkdir -p /cases/root /cases/private /cases/legacy/.home/.ssh /cases/legacy/.dsh/deep \
            /cases/readonly /cases/symlink /cases/home-file /cases/home-link \
            /cases/cli-file/.home /cases/cli-link/.home /cases/nonroot /cases/old-env \
            /cases/missing-dac /cases/missing-fowner/.home /cases/fake-bin
        chown 12345:12346 /cases/private /cases/missing-dac
        chmod 700 /cases/private /cases/missing-dac
        printf preserved-key > /cases/legacy/.home/.ssh/fixture-key
        printf "# custom shell\n" > /cases/legacy/.home/.bashrc
        printf old-state > /cases/legacy/.dsh/deep/state
        printf old-project > /cases/legacy/project-file
        chown -R 1000:1000 /cases/legacy /cases/missing-fowner
        chown 12345:12346 /cases/legacy/.dsh/deep/state
        chmod 700 /cases/legacy /cases/legacy/.home/.ssh
        chmod 755 /cases/legacy/.home /cases/missing-fowner/.home
        chmod 600 /cases/legacy/.home/.ssh/fixture-key /cases/legacy/.dsh/deep/state /cases/legacy/project-file
        chmod 640 /cases/legacy/.home/.bashrc
        touch /cases/home-file/.home /cases/cli-file/.home/.local
        ln -s /tmp /cases/home-link/.home
        ln -s /tmp /cases/cli-link/.home/.local
        ln -s /cases/root /cases/symlink/.dsh
        printf "#!/bin/sh\n/usr/bin/id -u > /app/plugin-uid\n/usr/bin/id -g > /app/plugin-gid\n" > /cases/fake-bin/dsh
        chmod 755 /cases/fake-bin/dsh
    '

run_runtime() {
    local mount="$1" program="$2"
    shift 2
    docker run --rm --network none --cap-add SYS_PTRACE \
        --security-opt no-new-privileges:true --env DSH_PLUGINS= \
        --mount "$mount" "$@" "$image" /bin/bash -euc "$program"
}

check='set -euo pipefail
    test "$(/usr/bin/id -u):$(/usr/bin/id -g)" = 0:0
    test "$USER:$LOGNAME" = root:root
    test "$HOME" = /app/.home
    test "$(getent passwd root | cut -d: -f6)" = "$HOME"
    test -d "$HOME" && test ! -L "$HOME"
    test "$(stat -c %a "$HOME")" = 700
    test "$PWD" = /app
    cap_eff="$(awk '\''$1 == "CapEff:" { print $2 }'\'' /proc/self/status)"
    # 检查本项目需要的能力子集，不复制 Docker 的完整默认列表。
    (( (16#$cap_eff & 0x800cb) == 0x800cb ))
    test "$(/usr/bin/setpriv --reuid=1000 --regid=1000 --clear-groups /usr/bin/id -u)" = 1000
    test "$(/usr/bin/setpriv --reuid=1000 --regid=1000 --clear-groups /usr/bin/id -g)" = 1000
    test "$(awk '\''$1 == "NoNewPrivs:" { print $2 }'\'' /proc/self/status)" = 1
    for d in /app/.dsh /app/.cache/cargo /app/.cache/go/pkg/mod /app/.cache/go/build \
             /app/.cache/npm /app/.cache/pip /app/.cache/m2 /app/.cache/gradle \
             /app/.cache/uv /app/.cache/pnpm-store /app/.home/.local/bin \
             /app/.home/.local/share/pnpm/bin /app/.home/.local/share/yarn/global \
             /app/.home/.local/share/uv/tools; do
        test -d "$d"; test -w "$d"; test -x "$d"
    done
    node -e '\''const fs=require("node:fs"); fs.writeFileSync("/app/.dsh/write-probe", "ok");'\''
    test "$(stat -c %u:%g /app/.dsh/write-probe)" = 0:0
    test "$(npm prefix --global)" = /app/.home/.local
    touch /app/ownership-probe
    chown 12345:12346 /app/ownership-probe
    test "$(stat -c %u:%g /app/ownership-probe)" = 12345:12346
    chown 0:0 /app/ownership-probe
'
persist_write='
    mkdir -p "$HOME/.config/gh" "$HOME/.ssh"
    printf fixture-gh > "$HOME/.config/gh/hosts.yml"
    printf fixture-key > "$HOME/.ssh/fixture-key"
    chmod 700 "$HOME/.ssh"
    chmod 600 "$HOME/.config/gh/hosts.yml" "$HOME/.ssh/fixture-key"
    git config --global user.name "Persistent Fixture"
    printf "%s" "$(< /etc/hostname)" > "$HOME/container-fixture-id"
    git -C /app init -q
    git -C /app check-ignore -q .home/.config/gh/hosts.yml
    printf "#!/bin/sh\nprintf persistent-cli\n" > "$HOME/.local/bin/dsh-runtime-cli-fixture"
    chmod 755 "$HOME/.local/bin/dsh-runtime-cli-fixture"
'
persist_check='
    test "$(< "$HOME/.config/gh/hosts.yml")" = fixture-gh
    test "$(< "$HOME/.ssh/fixture-key")" = fixture-key
    test "$(git config --global user.name)" = "Persistent Fixture"
    test "$(stat -c %a "$HOME/.ssh/fixture-key")" = 600
    test "$(< "$HOME/container-fixture-id")" != "$(< /etc/hostname)"
    for mode in -ec -lec; do
        bash "$mode" '\''test "$(dsh-runtime-cli-fixture)" = persistent-cli'\''
    done
'

printf '\n=== root startup and independent container persistence ===\n'
run_runtime "type=bind,source=$scratch/root,target=/app" "$check$persist_write"
run_runtime "type=bind,source=$scratch/root,target=/app" "$check$persist_check"

printf '\n=== private non-root mount remains owned by its original UID ===\n'
run_runtime "type=bind,source=$scratch/private,target=/app" "$check
    test \"\$(stat -c %u:%g /app)\" = 12345:12346"

printf '\n=== legacy HOME, deep mixed ownership and writable project files ===\n'
legacy_check='
    test "$(stat -c %u:%g /app)" = 1000:1000
    test "$(stat -c %u:%g "$HOME")" = 1000:1000
    test "$(stat -c %u:%g "$HOME/.ssh/fixture-key")" = 1000:1000
    test "$(stat -c %a "$HOME/.ssh/fixture-key")" = 600
    test "$(< "$HOME/.ssh/fixture-key")" = preserved-key
    test "$(< "$HOME/.bashrc")" = "# custom shell"
    test "$(stat -c %a "$HOME/.bashrc")" = 640
    test "$(stat -c %u:%g /app/project-file)" = 1000:1000
    test "$(stat -c %u:%g /app/.dsh/deep/state)" = 12345:12346
    printf changed-project > /app/project-file
    printf changed-state > /app/.dsh/deep/state
    test "$(stat -c %u:%g /app/project-file)" = 1000:1000
    test "$(stat -c %u:%g /app/.dsh/deep/state)" = 12345:12346
'
run_runtime "type=bind,source=$scratch/legacy,target=/app" "$check$legacy_check"
run_runtime "type=bind,source=$scratch/legacy,target=/app" "$check$legacy_check"

printf '\n=== plugin and command both run directly as root ===\n'
run_runtime "type=bind,source=$scratch/root,target=/app" \
    'test "$(< /app/plugin-uid):$(< /app/plugin-gid)" = 0:0; test "$(id -u):$(id -g)" = 0:0' \
    --mount "type=bind,source=$scratch/fake-bin,target=/fixture-bin,readonly" \
    -e PATH=/fixture-bin:/usr/local/bin:/usr/bin:/bin -e DSH_PLUGINS=fixture-plugin

expect_failure() {
    local name="$1" pattern="$2" mount="$3"
    shift 3
    if run_runtime "$mount" 'echo UNEXPECTED_COMMAND' "$@" > "$scratch/$name.log" 2>&1; then
        printf 'Unexpected success: %s\n' "$name" >&2; exit 1
    fi
    grep -q "$pattern" "$scratch/$name.log"
    if grep -q UNEXPECTED_COMMAND "$scratch/$name.log"; then exit 1; fi
}
expect_failure nonroot 'FATAL.*仅支持 root' "type=bind,source=$scratch/nonroot,target=/app" --user 1000:1000
expect_failure nonroot-group 'FATAL.*仅支持 root' "type=bind,source=$scratch/nonroot,target=/app" --user 0:1000
for setting in AGENT_UID=0 AGENT_UID=1000 AGENT_GID=1000; do
    expect_failure old-env 'FATAL.*AGENT_UID/AGENT_GID 已移除' "type=bind,source=$scratch/old-env,target=/app" -e "$setting"
done
# 失败身份分支不创建 HOME/状态。
test ! -e "$scratch/nonroot/.home"
test ! -e "$scratch/old-env/.home"
expect_failure readonly 'FATAL.*不可写' "type=bind,source=$scratch/root,target=/app,readonly"
for kind in symlink home-file home-link cli-file cli-link; do
    expect_failure "$kind" FATAL "type=bind,source=$scratch/$kind,target=/app"
done

printf '\n=== missing data-access capabilities fail explicitly ===\n'
for missing in dac fowner; do
    retained=FOWNER
    if [[ "$missing" == fowner ]]; then retained=DAC_OVERRIDE; fi
    if docker run --rm --network none --cap-drop ALL --cap-add "$retained" \
        --security-opt no-new-privileges:true -e DSH_PLUGINS= \
        --mount "type=bind,source=$scratch/missing-$missing,target=/app" \
        "$image" echo UNEXPECTED_COMMAND > "$scratch/missing-$missing.log" 2>&1; then
        printf 'Startup unexpectedly accepted missing %s capability\n' "$missing" >&2; exit 1
    fi
    grep -q FATAL "$scratch/missing-$missing.log"
    if grep -q UNEXPECTED_COMMAND "$scratch/missing-$missing.log"; then exit 1; fi
done

printf '\n=== ALL ROOT-ONLY RUNTIME CONTRACTS PASSED ===\n'
