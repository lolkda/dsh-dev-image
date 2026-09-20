import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const dockerfile = read('Dockerfile');
const defaultPlugins = '@lolkda/dsh-web-lan@0.1.1 dsh-auto-thinking-levels@0.1.0';

test('image defaults contain both pinned plugin versions', () => {
  const expression = dockerfile.match(/^\s*DSH_PLUGINS=(.+)$/m)?.[1];
  assert.ok(expression, 'Missing image plugin defaults');
  const value = expression.startsWith('"') ? JSON.parse(expression) : expression;
  assert.equal(value, defaultPlugins);
});

// 这些是轻量配置 contract；真实权限、YAML 展开和完整镜像另在 Docker CI 中验证。
for (const path of ['compose.yml', 'compose.bridge.yml']) {
  const source = read(path);
  const expression = source.match(/^\s+DSH_PLUGINS:\s*(.+)$/m)?.[1];
  assert.ok(expression, `${path}: missing DSH_PLUGINS expression`);

  for (const value of [undefined, '', '@example/plugin@1']) {
    test(`${path}: plugin default respects ${JSON.stringify(value) ?? 'unset'}`, () => {
      const env = { ...process.env };
      delete env.DSH_PLUGINS;
      if (value !== undefined) env.DSH_PLUGINS = value;
      const result = spawnSync('bash', ['--noprofile', '--norc', '-c', `printf '%s' "${expression}"`], {
        cwd: root, env, encoding: 'utf8', timeout: 10_000,
      });
      assert.ifError(result.error);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout, value ?? defaultPlugins);
    });
  }

  test(`${path}: Dockerfile owns toolchain version defaults`, () => {
    assert.doesNotMatch(source, /^\s+(GO_VERSION|JDK_VERSION|DSH_VERSION|PNPM_VERSION|USER_UID|USER_GID):/m);
  });

  test(`${path}: identity overrides reach the container`, () => {
    assert.match(source, /^\s+AGENT_UID:\s*\$\{AGENT_UID:-\}/m);
    assert.match(source, /^\s+AGENT_GID:\s*\$\{AGENT_GID:-\}/m);
  });
}

const smoke = dockerfile.match(/for sh in ((?:"bash [^"]+"\s*)+); do/);
assert.ok(smoke, 'Missing build-time shell smoke checks');
for (const [index, match] of [...smoke[1].matchAll(/"bash ([^"]+)"/g)].entries()) {
  test(`build smoke shell ${index + 1}: a failed command cannot be hidden by success`, () => {
    // 不读取本机用户 profile；只验证镜像所选 Bash flags 的错误传播语义。
    const flags = match[1].replace('l', '');
    const result = spawnSync('bash', ['--noprofile', '--norc', flags, 'false; printf HIDDEN_FAILURE'], {
      cwd: root, encoding: 'utf8', timeout: 10_000,
    });
    assert.ifError(result.error);
    assert.notEqual(result.status, 0, `Flags ${match[1]} hide a failed toolchain command`);
    assert.equal(result.stdout, '');
  });
}

const userCliDefaults = {
  npm_config_prefix: '/app/.home/.local',
  PNPM_HOME: '/app/.home/.local/share/pnpm',
  YARN_PREFIX: '/app/.home/.local',
  YARN_GLOBAL_FOLDER: '/app/.home/.local/share/yarn/global',
  PYTHONUSERBASE: '/app/.home/.local',
  UV_TOOL_DIR: '/app/.home/.local/share/uv/tools',
  UV_TOOL_BIN_DIR: '/app/.home/.local/bin',
  CARGO_INSTALL_ROOT: '/app/.home/.local',
  GOBIN: '/app/.home/.local/bin',
};
for (const [key, expected] of Object.entries(userCliDefaults)) {
  test(`image exposes persistent ${key} even for direct docker exec`, () => {
    const expression = dockerfile.match(new RegExp(`^(?:ENV\\s+|\\s+)${key}=(\\S+)`, 'm'))?.[1];
    assert.equal(expression, expected);
  });
}

test('user CLI defaults cannot redirect build-time installation of pinned image tools', () => {
  const bootstrap = dockerfile.indexOf('npm install -g "@deepseek-ai/dsh@${DSH_VERSION}"');
  const userDefaults = dockerfile.search(/^(?:ENV\s+|\s+)npm_config_prefix=/m);
  assert.ok(bootstrap >= 0);
  assert.ok(userDefaults > bootstrap, 'User CLI prefix must be enabled only after the image toolchain is installed');
});

test('image provides persistent HOME even for docker exec', () => {
  assert.match(dockerfile, /\bHOME=\/app\/\.home\b/);
});

test('agent account home is inside the persistent mount', () => {
  assert.match(dockerfile, /useradd[^\n;]*-d \/app\/\.home/);
});

for (const path of ['Dockerfile', 'tests/Dockerfile']) {
  test(`${path}: persistent HOME has no alternate compatibility alias`, () => {
    assert.doesNotMatch(read(path), /\bln\s+-s\s+\/app\/\.home\s/);
  });
}

test('pnpm store does not depend on an ephemeral user config file', () => {
  assert.match(dockerfile, /PNPM_CONFIG_STORE_DIR=\/app\/\.cache\/pnpm-store/);
});

test('Maven has an actual localRepository setting, not only an unused environment name', () => {
  assert.match(dockerfile, /<localRepository>\$\{env\.MAVEN_CONFIG\}\/repository<\/localRepository>/);
});

test('login shell only restores PATH; state initialization belongs to the entrypoint', () => {
  assert.doesNotMatch(dockerfile, /01-dsh-app-dirs\.sh/);
});

test('startup checks do not mistake a previous latest image for this revision', () => {
  const source = read('.github/workflows/verify-layout.yml');
  assert.doesNotMatch(source, /workflow_run:|docker pull .*:latest/);
  assert.match(source, /tests\/container-runtime\.sh/);
});

test('publication depends on tests of the loaded candidate and immutable digests', () => {
  const source = read('.github/workflows/build.yml');
  assert.match(source, /load:\s*true/);
  assert.match(source, /tests\/image-smoke\.sh/);
  assert.match(source, /\n  publish:\n\s+needs: build/);
  assert.match(source, /imagetools create/);
});
