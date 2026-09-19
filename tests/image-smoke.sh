#!/usr/bin/env bash
# 验证本次完整镜像：非 root 工具链 + 实际缓存位置 + 默认插件启动后的 HTTP。
set -euo pipefail
image="${1:?usage: image-smoke.sh IMAGE}"
web_id=''
cleanup() {
    if [[ -n "$web_id" ]]; then
        docker rm -f "$web_id" >/dev/null
    fi
}
trap cleanup EXIT

caps=(--cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID
      --security-opt no-new-privileges:true)
for mode in -ec -lec; do
    docker run --rm "${caps[@]}" -e DSH_PLUGINS= "$image" bash "$mode" '
        set -euo pipefail
        test "$(id -u)" != 0
        test "$HOME" = /home/agent
        for tool in python node npm yarn pnpm go rustc cargo java javac mvn gradle \
                    git jq yq uv rg fd cmake ninja sqlite3 tmux shellcheck gh gdb strace dsh; do
            command -v "$tool" >/dev/null
        done
        python -V; node -v; npm -v; pnpm --version
        go version; rustc -V; cargo -V; cargo clippy -V; rustfmt --version
        java -version; mvn -v; gradle --version
        case "$(pnpm store path)" in
            /app/.cache/pnpm-store/*) ;;
            *) echo "pnpm store escaped /app" >&2; exit 1 ;;
        esac
        dsh --help >/dev/null
        project="$(mktemp -d)"
        cargo new --name smoke --vcs none "$project/rust" -q
        cargo build --manifest-path "$project/rust/Cargo.toml" -q
        "$project/rust/target/debug/smoke"
    '
done

# MAVEN_CONFIG 本身不是 Maven CLI 的配置开关，必须验证真正解析到的路径。
docker run --rm "${caps[@]}" -e DSH_PLUGINS= "$image" bash -euc '
    repository="$(mvn -q -Dstyle.color=never help:evaluate -Dexpression=settings.localRepository -DforceStdout)"
    test "$repository" = /app/.cache/m2/repository
'

# 不置空 DSH_PLUGINS：真的安装默认 LAN 插件、启动默认 CMD 并通过 bridge 发布端口。
web_id="$(docker run -d "${caps[@]}" --init -p 127.0.0.1::3080 "$image")"
port="$(docker port "$web_id" 3080/tcp)"
port="${port##*:}"
ready=0
for ((attempt = 0; attempt < 90; attempt++)); do
    if curl --fail --silent --max-time 2 --output /dev/null "http://127.0.0.1:$port/"; then
        ready=1
        break
    fi
    if [[ "$(docker inspect --format '{{.State.Running}}' "$web_id")" != true ]]; then
        break
    fi
    sleep 2
done
if (( ready != 1 )); then
    docker logs "$web_id" >&2
    printf 'Default Web startup did not become reachable\n' >&2
    exit 1
fi
docker exec --user agent "$web_id" node -e '
    const assert = require("node:assert/strict");
    const fs = require("node:fs");
    const profile = `${process.env.DSH_HOME}/profiles/web`;
    const pkg = JSON.parse(fs.readFileSync(`${profile}/package.json`, "utf8"));
    assert.ok(pkg.dependencies?.["@lolkda/dsh-web-lan"]);
    assert.ok(fs.existsSync(`${profile}/node_modules/@lolkda/dsh-web-lan/package.json`));
    assert.notEqual(process.getuid(), 0);
'
printf '\n=== FULL IMAGE AND DEFAULT WEB STARTUP PASSED ===\n'
