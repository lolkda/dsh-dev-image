import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const dockerfile = read('Dockerfile');
const defaultPlugins = '@lolkda/dsh-web-lan dsh-auto-thinking-levels';

test('image defaults contain the shared plugin list', () => {
  const expression = dockerfile.match(/^\s*DSH_PLUGINS=(.+)$/m)?.[1];
  assert.ok(expression, 'Missing image plugin defaults');
  const value = expression.startsWith('"') ? JSON.parse(expression) : expression;
  assert.equal(value, defaultPlugins);
});

// 两个插件都独立发版：默认列表不写版本号，启动时由 pnpm 解析 registry 最新发布。
const pluginDefaults = [
  ['Dockerfile', dockerfile],
  ['compose.yml', read('compose.yml')],
  ['compose.bridge.yml', read('compose.bridge.yml')],
];
const pinnedSpecs = /@lolkda\/dsh-web-lan@|dsh-auto-thinking-levels@/;
for (const [path, source] of pluginDefaults) {
  test(`${path}: default plugin specs carry no versions so startup installs the latest releases`, () => {
    assert.match(source, /@lolkda\/dsh-web-lan/);
    assert.match(source, /dsh-auto-thinking-levels/);
    assert.doesNotMatch(source, pinnedSpecs);
  });
}

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
    assert.doesNotMatch(source, /^\s+(GO_VERSION|JDK_VERSION|DSH_VERSION|PNPM_VERSION|TYPESCRIPT_VERSION|TSX_VERSION|USER_UID|USER_GID):/m);
  });

  test(`${path}: root-only identity with Docker defaults and only extra ptrace`, () => {
    assert.match(source, /^\s+user: "0:0"$/m);
    assert.doesNotMatch(source, /^\s+AGENT_(UID|GID):/m);
    const caps = source.match(/cap_add:\n((?:\s+(?:#.*|- [A-Z_]+)\n)+)/)?.[1] ?? '';
    assert.deepEqual([...caps.matchAll(/- ([A-Z_]+)/g)].map(match => match[1]).sort(), ['SYS_PTRACE']);
    assert.doesNotMatch(source, /^\s*cap_drop:/m);
    assert.match(source, /no-new-privileges:true/);
    assert.doesNotMatch(source, /privileged:\s*true/);
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

// 回归点：删除预装、取消版本锁定，或把安装移到运行时 prefix/镜像源之后。
for (const [name, versionArg] of [['typescript', 'TYPESCRIPT_VERSION'], ['tsx', 'TSX_VERSION']]) {
  test(`image preinstalls pinned ${name} before runtime package-manager defaults`, () => {
    const version = dockerfile.match(new RegExp(`^ARG ${versionArg}=(\\S+)$`, 'm'))?.[1] ?? '';
    assert.match(version, /^\d+\.\d+\.\d+$/, `Missing pinned ${versionArg}`);
    const source = dockerfile.replace(/\\\r?\n\s*/g, ' ');
    const spec = `"${name}@\${${versionArg}}"`;
    const install = source.split(/[;\n]/).find(command => /\bnpm install -g\b/.test(command) && command.includes(spec));
    assert.ok(install, `Missing global installation of ${spec}`);
    for (const setting of ['npm_config_registry=', 'npm_config_prefix=']) {
      assert.ok(source.indexOf(setting) > source.indexOf(install), `${name} must be installed before ${setting}`);
    }
  });
}

for (const command of ['tsc --version', 'tsx --version']) {
  test(`build smoke checks ${command} in both shell modes`, () => {
    const body = dockerfile.match(/\$sh '([^']+)'/)?.[1] ?? '';
    assert.ok(body.includes(command), `Missing build-time ${command}`);
  });
}

test('image provides persistent HOME even for docker exec', () => {
  assert.match(dockerfile, /\bHOME=\/app\/\.home\b/);
});

for (const path of ['Dockerfile', 'tests/Dockerfile']) {
  test(`${path}: root account and default exec share the persistent HOME`, () => {
    const source = read(path);
    assert.match(source, /sed -i '[^']+' \/etc\/passwd/);
    assert.match(source, /test "\$\(getent passwd root \| cut -d: -f6-7\)" = \/app\/\.home:\/bin\/bash/);
    assert.doesNotMatch(source, /\busermod\b/);
    assert.match(source, /^USER 0:0$/m);
    assert.doesNotMatch(source, /USER_UID|USER_GID|agent:agent|\b(?:useradd|groupadd)\b/);
  });
  test(`${path}: build-time account edit preserves identities and unrelated users`, () => {
    const expression = read(path).match(/sed -i '([^']+)' \/etc\/passwd/)?.[1];
    assert.ok(expression, 'Missing offline root account transformation');
    for (const oldHome of ['/root', '/existing/home']) {
      const otherAccounts = 'node:x:1000:1000:Node:/home/node:/bin/sh\notherroot:x:0:0:Other:/other:/bin/sh\n';
      const input = `root:x:0:0:Root User:${oldHome}:/bin/sh\n${otherAccounts}`;
      const result = spawnSync('sed', [expression], { input, encoding: 'utf8', timeout: 10_000 });
      assert.ifError(result.error);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout, `root:x:0:0:Root User:/app/.home:/bin/bash\n${otherAccounts}`);
    }
  });
}

test('runtime never rewrites owners or switches accounts', () => {
  const commands = read('entrypoint.sh').split('\n').filter(line => !/^\s*#/.test(line)).join('\n');
  assert.doesNotMatch(commands, /\b(?:chown|usermod|groupmod|setpriv|sudo)\b/);
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
