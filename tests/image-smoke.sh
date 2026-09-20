#!/usr/bin/env bash
# 验证本次完整镜像：非 root 工具链 + 实际缓存位置 + 默认插件启动后的登录流程。
set -euo pipefail

# 使用真实 HTTP，既不把匿名 401 当未启动，也不把任意匿名 200 当作 DSH 就绪。
probe_web() {
    local base_url="$1" startup_log="$2" cookie_jar="$3" token status
    local pattern='dsh web: http://[^[:space:]]+[?]token=([A-Za-z0-9_-]+)'
    [[ "$startup_log" =~ $pattern ]] || return 1
    token="${BASH_REMATCH[1]}"
    if ! status="$(curl --silent --location --max-time 5 --cookie-jar "$cookie_jar" \
        --output /dev/null --write-out '%{http_code}' "${base_url}?token=$token")"; then
        printf 'Web probe transport failed\n' >&2
        return 1
    fi
    if [[ "$status" != 200 ]]; then
        printf 'Web login probe returned HTTP %s\n' "$status" >&2
        return 1
    fi
}

cleanup() {
    if [[ -n "${web_id:-}" ]]; then
        docker rm -f "$web_id" >/dev/null
    fi
    if [[ -n "${cookie_jar:-}" ]]; then
        rm -f -- "$cookie_jar"
    fi
}

main() {
    local image="${1:?usage: image-smoke.sh IMAGE}" mode port ready attempt startup_log
    # EXIT trap 需要在 main 返回后仍能读取这两个清理目标。
    web_id=''
    cookie_jar="$(mktemp)"
    trap cleanup EXIT

    local caps=(--cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID
                --security-opt no-new-privileges:true)
    for mode in -ec -lec; do
        docker run --rm "${caps[@]}" -e DSH_PLUGINS= "$image" bash "$mode" '
            set -euo pipefail
            test "$(id -u)" != 0
            test "$HOME" = /app/.home
            test "$(getent passwd agent | cut -d: -f6)" = "$HOME"
            test -d "$HOME" && test ! -L "$HOME"
            for tool in python node npm yarn pnpm go rustc cargo java javac mvn gradle \
                        git jq yq uv rg fd cmake ninja sqlite3 tmux shellcheck gh gdb strace dsh; do
                command -v "$tool" >/dev/null
            done
            python -V; node -v; npm -v; pnpm --version
            go version; rustc -V; cargo -V; cargo clippy -V; rustfmt --version
            java -version; mvn -v; gradle --version
            npm_registry="$(npm config get registry)"
            pnpm_registry="$(pnpm config get registry)"
            yarn_registry="$(yarn config get registry)"
            pip_index="$(python -m pip config get :env:.index-url)"
            test "${npm_registry%/}" = "${npm_config_registry%/}"
            test "${pnpm_registry%/}" = "${PNPM_CONFIG_REGISTRY%/}"
            test "${yarn_registry%/}" = "${YARN_REGISTRY%/}"
            test "${pip_index%/}" = "${PIP_INDEX_URL%/}"
            printf "Verified package sources: npm=%s pnpm=%s yarn=%s pip=%s\n" \
                "$npm_registry" "$pnpm_registry" "$yarn_registry" "$pip_index"
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

    # 默认国内源和显式切回官方源都做真实解析/下载；不改系统 Python 环境。
    for source_mode in domestic official; do
        source_env=()
        if [[ "$source_mode" == official ]]; then
            source_env=(-e npm_config_registry=https://registry.npmjs.org/
                        -e PNPM_CONFIG_REGISTRY=https://registry.npmjs.org/
                        -e YARN_REGISTRY=https://registry.npmjs.org/
                        -e PIP_INDEX_URL=https://pypi.org/simple/
                        -e UV_DEFAULT_INDEX=https://pypi.org/simple/)
        fi
        docker run --rm "${caps[@]}" -e DSH_PLUGINS= "${source_env[@]}" "$image" bash -euc '
            npm_registry="$(npm config get registry)"
            pnpm_registry="$(pnpm config get registry)"
            yarn_registry="$(yarn config get registry)"
            pip_index="$(python -m pip config get :env:.index-url)"
            test "${npm_registry%/}" = "${npm_config_registry%/}"
            test "${pnpm_registry%/}" = "${PNPM_CONFIG_REGISTRY%/}"
            test "${yarn_registry%/}" = "${YARN_REGISTRY%/}"
            test "${pip_index%/}" = "${PIP_INDEX_URL%/}"
            directory="$(mktemp -d)"
            python -m pip download --disable-pip-version-check --no-deps --no-cache-dir \
                --dest "$directory/wheels" packaging==25.0
            test -f "$directory/wheels/packaging-25.0-py3-none-any.whl"
            printf "packaging==25.0\n" > "$directory/requirements.in"
            uv --no-cache pip compile --quiet --emit-index-url \
                --output-file "$directory/requirements.txt" "$directory/requirements.in"
            grep -Fx "packaging==25.0" "$directory/requirements.txt"
            if [[ "${UV_DEFAULT_INDEX%/}" != https://pypi.org/simple ]]; then
                grep -F -- "${UV_DEFAULT_INDEX%/}" "$directory/requirements.txt"
            elif grep -Fq mirrors.aliyun.com "$directory/requirements.txt"; then
                echo "uv ignored the official-index override" >&2
                exit 1
            fi
            printf "Verified dependency indexes: pip=%s uv=%s pnpm=%s\n" \
                "$pip_index" "$UV_DEFAULT_INDEX" "$pnpm_registry"
        '
    done

    # MAVEN_CONFIG 本身不是 Maven CLI 的配置开关，检查真正解析到的路径。
    docker run --rm "${caps[@]}" -e DSH_PLUGINS= "$image" bash -euc '
        repository="$(mvn -q -Dstyle.color=never help:evaluate -Dexpression=settings.localRepository -DforceStdout)"
        test "$repository" = /app/.cache/m2/repository
    '

    # 在独立 bind mount 中用默认与自定义 UID 安装 CLI，跨容器验证并清理缓存。
    local root
    root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
    bash "$root/tests/user-cli-runtime.sh" "$image"

    # 临时启动默认 Web/插件；只发布 runner 的 loopback 端口，不在 CI 打开浏览器。
    # 与默认 CMD 唯一差别是 --no-open；结束时清理容器和 cookie。
    web_id="$(docker run -d "${caps[@]}" --init -p 127.0.0.1::3080 "$image" dsh web --no-open)"
    port="$(docker port "$web_id" 3080/tcp)"
    port="${port##*:}"
    ready=0
    for ((attempt = 0; attempt < 90; attempt++)); do
        startup_log="$(docker logs --tail 200 "$web_id" 2>&1)"
        if probe_web "http://127.0.0.1:$port/" "$startup_log" "$cookie_jar"; then
            ready=1
            break
        fi
        if [[ "$(docker inspect --format '{{.State.Running}}' "$web_id")" != true ]]; then
            break
        fi
        sleep 2
    done
    if (( ready != 1 )); then
        # 诊断保留，但不把临时登录 token 明文写进公开 Actions 日志。
        docker logs "$web_id" 2>&1 | sed -E 's/([?&]token=)[^&[:space:])]+/\1[REDACTED]/g' >&2
        printf 'Default Web authenticated startup check failed\n' >&2
        exit 1
    fi
    docker exec --user agent "$web_id" node -e '
        const assert = require("node:assert/strict");
        const fs = require("node:fs");
        const profile = `${process.env.DSH_HOME}/profiles/web`;
        const pkg = JSON.parse(fs.readFileSync(`${profile}/package.json`, "utf8"));
        const plugins = {
            "@lolkda/dsh-web-lan": "0.1.1",
            "dsh-auto-thinking-levels": "0.1.0",
        };
        for (const [name, version] of Object.entries(plugins)) {
            assert.ok(pkg.dependencies?.[name], name + " is missing from dependencies");
            assert.ok(pkg.dsh?.profile?.bundles?.includes(name), name + " is not registered as a bundle");
            const installed = JSON.parse(fs.readFileSync(profile + "/node_modules/" + name + "/package.json", "utf8"));
            assert.equal(installed.version, version, name + " version mismatch");
            console.log("Verified plugin: " + name + "@" + installed.version);
        }
        assert.notEqual(process.getuid(), 0);
    '
    printf '\n=== FULL IMAGE AND AUTHENTICATED WEB STARTUP PASSED ===\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
