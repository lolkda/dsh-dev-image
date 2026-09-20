import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const exec = promisify(execFile);
const root = fileURLToPath(new URL('../', import.meta.url));
async function migrate(app, extraEnv = {}) {
  return exec('bash', ['--noprofile', '--norc', '-c',
    'app="$MIGRATION_APP"; if command -v cygpath >/dev/null; then app="$(cygpath -u "$app")"; fi; bash scripts/migrate-home.sh unused "$app"'], {
    cwd: root, env: { ...process.env, ...extraEnv, MIGRATION_APP: app }, timeout: 10_000,
  });
}

test('HOME migration refuses an existing target before contacting Docker', async (t) => {
  const app = mkdtempSync(join(tmpdir(), 'dsh-home-migration-'));
  t.after(() => rmSync(app, { recursive: true, force: true }));
  mkdirSync(join(app, '.home'));
  const marker = join(app, '.home', 'credential.fixture');
  writeFileSync(marker, 'existing-user-state');
  await assert.rejects(migrate(app), (error) => {
    assert.match(error.stderr, /已存在/);
    return true;
  });
  assert.equal(readFileSync(marker, 'utf8'), 'existing-user-state');
});

test('HOME migration rejects a missing host directory before contacting Docker', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'dsh-home-migration-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  await assert.rejects(migrate(join(directory, 'absent')), (error) => {
    assert.match(error.stderr, /不存在/);
    return true;
  });
});

test('HOME migration refuses remote Docker endpoints before exporting data', async (t) => {
  const app = mkdtempSync(join(tmpdir(), 'dsh-home-migration-'));
  t.after(() => rmSync(app, { recursive: true, force: true }));
  await assert.rejects(migrate(app, { DOCKER_HOST: 'tcp://127.0.0.1:1', DOCKER_CONTEXT: '' }), (error) => {
    assert.match(error.stderr, /拒绝远程 Docker endpoint/);
    return true;
  });
});

test('HOME migration requires explicit source and destination', async () => {
  await assert.rejects(exec('bash', ['scripts/migrate-home.sh'], { cwd: root, timeout: 10_000 }), (error) => {
    assert.match(error.stderr, /usage:/);
    return true;
  });
});
