#!/usr/bin/env bash
# 仅在隔离 HOME 中执行；使用本地无依赖包，验证真实包管理器而不依赖 registry。
# install 和 check 分开，以便 Docker CI 在两个容器之间验证持久化。
set -euo pipefail
mode="${1:?usage: user-cli-smoke.sh install|check}"
[[ "$mode" == install || "$mode" == check ]]
[[ "$(id -u)" != 0 ]]
[[ "$HOME" == "${APP_DIR:-/app}/.home" ]]

# 安装前检查真实解析结果，绝不能把 fixture 写进测试机的系统 prefix。
[[ "$(npm prefix --global)" == "$HOME/.local" ]]
[[ "$(pnpm bin --global)" == "$HOME/.local/share/pnpm/bin" ]]
[[ "$(yarn global bin)" == "$HOME/.local/bin" ]]
[[ "$(yarn global dir)" == "$HOME/.local/share/yarn/global" ]]
[[ "$(python -m site --user-base)" == "$HOME/.local" ]]
[[ "$(uv tool dir)" == "$HOME/.local/share/uv/tools" ]]
[[ "$(uv tool dir --bin)" == "$HOME/.local/bin" ]]
[[ "$CARGO_INSTALL_ROOT" == "$HOME/.local" ]]
[[ "$(go env GOBIN)" == "$HOME/.local/bin" ]]

if [[ "$mode" == install ]]; then
    work="$(mktemp -d)"
    trap 'rm -rf -- "$work"' EXIT
    export CLI_FIXTURES="$work"
    node --input-type=module <<'NODE'
import { chmodSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
const root = process.env.CLI_FIXTURES;
for (const manager of ['npm', 'pnpm', 'yarn']) {
  const directory = join(root, manager, 'package');
  mkdirSync(directory, { recursive: true });
  const name = `dsh-cli-${manager}-fixture`;
  writeFileSync(join(directory, 'package.json'), JSON.stringify({ name, version: '1.0.0', bin: { [name]: 'cli.cjs' } }));
  writeFileSync(join(directory, 'cli.cjs'), `#!/usr/bin/env node\nconsole.log("persistent ${manager} CLI");\n`);
  chmodSync(join(directory, 'cli.cjs'), 0o755);
}
for (const manager of ['pip', 'uv']) {
  const directory = join(root, manager);
  const name = `dsh_cli_${manager}_fixture`;
  const metadata = `${name}-1.0.0.dist-info`;
  mkdirSync(join(directory, metadata), { recursive: true });
  const files = {
    [`${name}.py`]: `def main() -> None:\n    """输出隔离 CLI 的持久化验收标记。\n\n    Args:\n        无参数。\n\n    Returns:\n        无返回值，向标准输出写入验收标记。\n    """\n    print("persistent ${manager} CLI")\n`,
    [`${metadata}/METADATA`]: `Metadata-Version: 2.1\nName: ${name}\nVersion: 1.0.0\n`,
    [`${metadata}/WHEEL`]: 'Wheel-Version: 1.0\nGenerator: isolated-fixture\nRoot-Is-Purelib: true\nTag: py3-none-any\n',
    [`${metadata}/entry_points.txt`]: `[console_scripts]\ndsh-cli-${manager}-fixture = ${name}:main\n`,
  };
  files[`${metadata}/RECORD`] = [...Object.keys(files), `${metadata}/RECORD`].map(path => `${path},,\n`).join('');
  for (const [path, content] of Object.entries(files)) writeFileSync(join(directory, path), content);
}
mkdirSync(join(root, 'rust', 'src'), { recursive: true });
writeFileSync(join(root, 'rust', 'Cargo.toml'), '[package]\nname = "dsh-cli-cargo-fixture"\nversion = "1.0.0"\nedition = "2021"\n');
writeFileSync(join(root, 'rust', 'src', 'main.rs'), 'fn main() { println!("persistent cargo CLI"); }\n');
mkdirSync(join(root, 'go'));
writeFileSync(join(root, 'go', 'go.mod'), 'module example.invalid/dsh-cli-go-fixture\n\ngo 1.24\n');
writeFileSync(join(root, 'go', 'main.go'), 'package main\nimport "fmt"\nfunc main() { fmt.Println("persistent go CLI") }\n');
NODE
    for manager in npm pnpm yarn; do
        tar -czf "$work/$manager.tgz" -C "$work/$manager" package
    done
    npm install --global --offline --ignore-scripts --no-audit --no-fund "$work/npm.tgz"
    pnpm add --global --offline --ignore-scripts --reporter=append-only "$work/pnpm.tgz"
    yarn global add --offline --ignore-scripts --non-interactive "$work/yarn.tgz"
    for manager in pip uv; do
        (cd "$work/$manager" && zip -qr "$work/dsh_cli_${manager}_fixture-1.0.0-py3-none-any.whl" .)
    done
    python -m pip install --user --no-index --no-deps --disable-pip-version-check \
        "$work/dsh_cli_pip_fixture-1.0.0-py3-none-any.whl"
    uv tool install --offline --no-index --no-cache --python "$(command -v python)" \
        "$work/dsh_cli_uv_fixture-1.0.0-py3-none-any.whl"
    cargo install --offline --path "$work/rust"
    GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off go -C "$work/go" install .

    # 全局 prefix 不能改变项目依赖安装位置，也不能强制 venv 使用 --user。
    mkdir "$work/project"
    printf '{"name":"isolated-project","version":"1.0.0","private":true}\n' > "$work/project/package.json"
    (cd "$work/project" && npm install --offline --ignore-scripts --no-audit --no-fund "$work/npm.tgz")
    test -f "$work/project/node_modules/dsh-cli-npm-fixture/package.json"
    python -m venv "$work/venv"
    "$work/venv/bin/python" -m pip install --no-index --no-deps --disable-pip-version-check \
        "$work/dsh_cli_pip_fixture-1.0.0-py3-none-any.whl"
    [[ "$("$work/venv/bin/dsh-cli-pip-fixture")" == 'persistent pip CLI' ]]
fi

for manager in npm pnpm yarn pip uv cargo go; do
    command="dsh-cli-$manager-fixture"
    [[ "$("$command")" == "persistent $manager CLI" ]]
    case "$(command -v "$command")" in
        "$HOME/.local/"*) ;;
        *) printf 'CLI escaped persistent HOME: %s\n' "$command" >&2; exit 1 ;;
    esac
    printf 'Verified persistent user CLI: %s\n' "$manager"
done
