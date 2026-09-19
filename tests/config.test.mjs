import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const dockerfile = read('Dockerfile');

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
      assert.equal(result.stdout, value ?? '@lolkda/dsh-web-lan@^0.1.0');
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

test('image provides agent HOME even for docker exec', () => {
  assert.match(dockerfile, /\bHOME=\/home\/agent\b/);
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
