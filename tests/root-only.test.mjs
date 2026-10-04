import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));
const isRoot = process.getuid?.() === 0 && process.getgid?.() === 0;
const posix = process.platform !== 'win32';
function fixture(t) {
  const directory = mkdtempSync(join(tmpdir(), 'dsh-root-only-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const app = join(directory, 'app');
  const env = { PATH: process.env.PATH, APP_DIR: app, DSH_PLUGINS: '' };
  return { directory, app, env };
}
function start(options, program, extra = {}) {
  return spawnSync('bash', ['--noprofile', '--norc', join(root, 'entrypoint.sh'), 'bash', '-euc', program], {
    env: { ...options.env, ...extra }, encoding: 'utf8', timeout: 10_000,
  });
}

test('real non-root entrypoint rejects before creating state or running plugins/commands', { skip: !posix || isRoot }, (t) => {
  const options = fixture(t);
  const result = start(options, 'echo UNEXPECTED_COMMAND', { DSH_PLUGINS: 'fixture-plugin' });
  assert.ifError(result.error);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /仅支持 root \(0:0\)/);
  assert.doesNotMatch(result.stdout, /UNEXPECTED_COMMAND/);
  assert.doesNotMatch(result.stderr, /dsh plugin/);
  assert.equal(existsSync(options.app), false);
});

for (const extra of [{ AGENT_UID: '0' }, { AGENT_UID: '1000' }, { AGENT_GID: '1000' }]) {
  test(`root rejects removed identity override before writes: ${JSON.stringify(extra)}`, { skip: !isRoot && 'requires real UID/GID 0:0' }, (t) => {
    const options = fixture(t);
    const result = start(options, 'echo UNEXPECTED_COMMAND', { ...extra, DSH_PLUGINS: 'fixture-plugin' });
    assert.ifError(result.error);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /AGENT_UID\/AGENT_GID 已移除/);
    assert.doesNotMatch(result.stdout, /UNEXPECTED_COMMAND/);
    assert.doesNotMatch(result.stderr, /dsh plugin/);
    assert.equal(existsSync(options.app), false);
  });
}

test('plugin subprocess and final command keep root UID/GID without sudo', { skip: !isRoot && 'requires real UID/GID 0:0' }, (t) => {
  const options = fixture(t);
  const bin = join(options.directory, 'bin');
  mkdirSync(bin);
  const plugin = join(bin, 'dsh');
  writeFileSync(plugin, '#!/bin/sh\nprintf "%s:%s" "$(/usr/bin/id -u)" "$(/usr/bin/id -g)" > "$APP_DIR/plugin-identity"\n');
  chmodSync(plugin, 0o755);
  const result = start(options, 'printf "%s:%s:%s:%s" "$(id -u)" "$(id -g)" "$USER" "$LOGNAME"', {
    PATH: `${bin}:${process.env.PATH}`, DSH_PLUGINS: 'fixture-plugin',
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, '0:0:root:root');
  assert.equal(readFileSync(join(options.app, 'plugin-identity'), 'utf8'), '0:0');
});
