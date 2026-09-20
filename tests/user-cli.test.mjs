import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test as nodeTest } from 'node:test';

// These integration checks use POSIX paths, executable bits and a native npm binary.
// Windows retains the portable configuration/entrypoint suite; Linux CI runs every case below.
const test = process.platform === 'win32' ? nodeTest.skip : nodeTest;

const root = fileURLToPath(new URL('../', import.meta.url));
const shellEnvironment = join(root, 'cli-env.sh');
const defaults = {
  npm_config_prefix: '.local',
  PNPM_HOME: '.local/share/pnpm',
  YARN_PREFIX: '.local',
  YARN_GLOBAL_FOLDER: '.local/share/yarn/global',
  PYTHONUSERBASE: '.local',
  UV_TOOL_DIR: '.local/share/uv/tools',
  UV_TOOL_BIN_DIR: '.local/bin',
  CARGO_INSTALL_ROOT: '.local',
  GOBIN: '.local/bin',
};

function fixture(t) {
  const directory = mkdtempSync(join(tmpdir(), 'dsh-user-cli-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const app = join(directory, "owner's workspace");
  const home = join(app, '.home');
  mkdirSync(app);
  const env = { ...process.env };
  for (const name of Object.keys(env)) {
    if (/^(?:DSH_|AGENT_|PNPM_|npm_config_|NPM_CONFIG_|YARN_|PIP_|UV_|XDG_)/.test(name)
      || ['CARGO_HOME', 'CARGO_INSTALL_ROOT', 'GOPATH', 'GOBIN', 'GOMODCACHE', 'GOCACHE', 'MAVEN_CONFIG', 'GRADLE_USER_HOME', 'PYTHONUSERBASE', 'PYTHONPATH'].includes(name)) {
      delete env[name];
    }
  }
  Object.assign(env, {
    APP_DIR: app, HOME: home, DSH_PLUGINS: '',
    npm_config_userconfig: join(directory, 'unused-npmrc'),
    npm_config_globalconfig: join(directory, 'unused-global-npmrc'),
    npm_config_cache: join(app, '.cache', 'npm'),
    CLI_ENV: shellEnvironment,
    CLI_KEYS: JSON.stringify(Object.keys(defaults)),
  });
  return { directory, app, home, env };
}

function entrypoint(options, program, extraEnv = {}) {
  return spawnSync('bash', ['--noprofile', '--norc', join(root, 'entrypoint.sh'),
    'bash', '--noprofile', '--norc', '-euc', program], {
    cwd: options.directory, env: { ...options.env, ...extraEnv }, encoding: 'utf8', timeout: 30_000,
  });
}

function successful(result) {
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return result.stdout.trim();
}

const reportEnvironment = `node -e '
  const keys = JSON.parse(process.env.CLI_KEYS);
  console.log(JSON.stringify(Object.fromEntries(keys.map(key => [key, process.env[key]]))));
'`;

test('entrypoint defaults user CLI installations to persistent HOME, not system or cache directories', (t) => {
  const options = fixture(t);
  const actual = JSON.parse(successful(entrypoint(options, reportEnvironment)));
  const expected = Object.fromEntries(Object.entries(defaults).map(([key, suffix]) => [key, join(options.home, suffix)]));
  assert.deepEqual(actual, expected);
});

test('npm actually resolves its global prefix inside persistent HOME', (t) => {
  const options = fixture(t);
  assert.equal(successful(entrypoint(options, 'npm prefix --global')), join(options.home, '.local'));
});

test('shell environment adds first-install paths without creating directories and is idempotent', (t) => {
  const options = fixture(t);
  assert.ok(existsSync(shellEnvironment), 'Missing shared user CLI shell environment');
  const result = spawnSync('bash', ['--noprofile', '--norc', '-euc', `
    . "$CLI_ENV"
    original_path="$PATH"
    . "$CLI_ENV"
    test "$original_path" = "$PATH"
    node -p 'JSON.stringify(process.env.PATH.split(":"))'
  `], { env: options.env, encoding: 'utf8', timeout: 10_000 });
  const paths = JSON.parse(successful(result));
  for (const suffix of ['.local/bin', '.local/share/pnpm/bin', 'bin']) {
    assert.equal(paths.filter(path => path === join(options.home, suffix)).length, 1, suffix);
  }
  assert.equal(existsSync(options.home), false, 'Sourcing shell configuration must not initialize state');
});

test('persisted CLI lookup survives a shell PATH reset', (t) => {
  const options = fixture(t);
  assert.ok(existsSync(shellEnvironment), 'Missing shared user CLI shell environment');
  for (const [suffix, command] of [['.local/bin', 'fixture-local-cli'], ['.local/share/pnpm/bin', 'fixture-pnpm-cli']]) {
    const directory = join(options.home, suffix);
    mkdirSync(directory, { recursive: true });
    const path = join(directory, command);
    writeFileSync(path, `#!/bin/sh\nprintf '${command}\\n'\n`);
    chmodSync(path, 0o755);
  }
  const result = spawnSync('bash', ['--noprofile', '--norc', '-euc', `
    PATH=/usr/local/bin:/usr/bin:/bin
    . "$CLI_ENV"
    fixture-local-cli
    fixture-pnpm-cli
  `], { env: options.env, encoding: 'utf8', timeout: 10_000 });
  assert.equal(successful(result), 'fixture-local-cli\nfixture-pnpm-cli');
});

test('explicit package-manager installation paths remain authoritative and executable', (t) => {
  const options = fixture(t);
  const overrides = Object.fromEntries(Object.keys(defaults).map(key => [key, join(options.home, 'custom', key)]));
  overrides.PNPM_CONFIG_GLOBAL_BIN_DIR = join(options.home, 'custom', 'pnpm-bin');
  overrides.PNPM_CONFIG_GLOBAL_DIR = join(options.home, 'custom', 'pnpm-global');
  const actual = JSON.parse(successful(entrypoint(options, reportEnvironment, overrides)));
  for (const key of Object.keys(defaults)) assert.equal(actual[key], overrides[key], key);
  const paths = JSON.parse(successful(entrypoint(options, `node -p 'JSON.stringify(process.env.PATH.split(":"))'`, overrides)));
  for (const path of [join(overrides.npm_config_prefix, 'bin'), overrides.PNPM_CONFIG_GLOBAL_BIN_DIR,
    join(overrides.YARN_PREFIX, 'bin'), join(overrides.PYTHONUSERBASE, 'bin'), overrides.UV_TOOL_BIN_DIR,
    join(overrides.CARGO_INSTALL_ROOT, 'bin'), overrides.GOBIN]) {
    assert.ok(paths.includes(path), `Missing overridden CLI path: ${path}`);
  }
  assert.equal(successful(entrypoint(options, 'npm prefix --global', overrides)), overrides.npm_config_prefix);
});

for (const collision of ['file', 'symlink', 'readonly']) {
  test(`a ${collision} at a managed CLI directory fails before plugins or the main command`, { skip: process.platform === 'win32' }, (t) => {
    const options = fixture(t);
    const local = join(options.home, '.local');
    mkdirSync(options.home, { recursive: true });
    if (collision === 'file') writeFileSync(local, 'do not overwrite');
    if (collision === 'symlink') symlinkSync(options.directory, local, 'dir');
    if (collision === 'readonly') {
      mkdirSync(local);
      chmodSync(local, 0o500);
      t.after(() => { if (existsSync(local)) chmodSync(local, 0o700); });
    }
    const bin = join(options.directory, 'fake-bin');
    mkdirSync(bin);
    writeFileSync(join(bin, 'dsh'), '#!/bin/sh\nprintf plugin-called > "$CLI_PLUGIN_MARKER"\n');
    chmodSync(join(bin, 'dsh'), 0o755);
    const pluginMarker = join(options.directory, 'plugin-called');
    const result = entrypoint(options, 'touch "$APP_DIR/main-called"', {
      PATH: `${bin}:${options.env.PATH}`, DSH_PLUGINS: '@example/plugin@1', CLI_PLUGIN_MARKER: pluginMarker,
    });
    assert.ifError(result.error);
    assert.notEqual(result.status, 0, `Unexpectedly accepted ${collision} at ${local}`);
    assert.equal(existsSync(pluginMarker), false);
    assert.equal(existsSync(join(options.app, 'main-called')), false);
  });
}

for (const prefix of ['relative-tools', '/tmp/ambiguous:tools']) {
  test(`an invalid CLI prefix is rejected: ${prefix}`, (t) => {
    const options = fixture(t);
    const result = entrypoint(options, 'touch "$APP_DIR/main-called"', { npm_config_prefix: prefix });
    assert.ifError(result.error);
    assert.notEqual(result.status, 0);
    assert.equal(existsSync(join(options.app, 'main-called')), false);
  });
}

test('npm-installed CLI survives a new entrypoint process without its source or download cache', (t) => {
  const options = fixture(t);
  // Before installing anything, prove the real npm target is isolated; never write into the host prefix.
  assert.equal(successful(entrypoint(options, 'npm prefix --global')), join(options.home, '.local'));
  const source = join(options.directory, 'package');
  mkdirSync(source);
  const command = 'dsh-persistent-npm-fixture';
  writeFileSync(join(source, 'package.json'), JSON.stringify({
    name: command, version: '1.0.0', bin: { [command]: 'cli.cjs' },
  }));
  writeFileSync(join(source, 'cli.cjs'), '#!/usr/bin/env node\nconsole.log("persistent npm CLI");\n');
  const packed = spawnSync('npm', ['pack', '--json', '--offline', '--ignore-scripts'], {
    cwd: source, env: options.env, encoding: 'utf8', timeout: 30_000,
  });
  const tarball = join(source, JSON.parse(successful(packed))[0].filename);
  successful(entrypoint(options, 'npm install --global --offline --ignore-scripts --no-audit --no-fund "$CLI_TARBALL"', { CLI_TARBALL: tarball }));
  assert.ok(realpathSync(join(options.home, '.local', 'bin', command)).startsWith(`${join(options.home, '.local')}/`));
  rmSync(source, { recursive: true });
  rmSync(join(options.app, '.cache'), { recursive: true });
  assert.equal(successful(entrypoint(options, command)), 'persistent npm CLI');
});

test('entrypoint preserves user package-manager configuration files', (t) => {
  const options = fixture(t);
  mkdirSync(join(options.home, '.config', 'pnpm'), { recursive: true });
  const files = ['.npmrc', '.yarnrc', '.config/pnpm/config.yaml'];
  for (const file of files) writeFileSync(join(options.home, file), '# user-owned configuration\n');
  successful(entrypoint(options, 'true'));
  for (const file of files) assert.equal(readFileSync(join(options.home, file), 'utf8'), '# user-owned configuration\n');
});
