import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const moduleUrl = new URL('../home-init.mjs', import.meta.url);
async function initializer() {
  assert.ok(existsSync(fileURLToPath(moduleUrl)), 'Persistent HOME initializer is missing');
  return (await import(moduleUrl.href)).initializeHome;
}
function fixture(t) {
  const directory = mkdtempSync(join(tmpdir(), 'dsh-home-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const home = join(directory, '.home');
  const skel = join(directory, 'skel');
  mkdirSync(skel);
  writeFileSync(join(skel, '.bashrc'), '# default shell configuration\n');
  return { directory, home, skel };
}

test('HOME initialization creates missing shell defaults', async (t) => {
  const options = fixture(t);
  const initializeHome = await initializer();
  initializeHome(options);
  assert.equal(readFileSync(join(options.home, '.bashrc'), 'utf8'), '# default shell configuration\n');
});

test('HOME initialization preserves existing user and credential files', async (t) => {
  const options = fixture(t);
  mkdirSync(options.home);
  writeFileSync(join(options.home, '.bashrc'), '# user customization\n');
  writeFileSync(join(options.home, 'credential.fixture'), 'not-a-real-credential');
  const initializeHome = await initializer();
  initializeHome(options);
  initializeHome(options);
  assert.equal(readFileSync(join(options.home, '.bashrc'), 'utf8'), '# user customization\n');
  assert.equal(readFileSync(join(options.home, 'credential.fixture'), 'utf8'), 'not-a-real-credential');
});

test('HOME initialization tolerates an absent optional skeleton', async (t) => {
  const options = fixture(t);
  const initializeHome = await initializer();
  initializeHome({ home: options.home, skel: join(options.directory, 'absent') });
  assert.ok(statSync(options.home).isDirectory());
});

test('HOME initialization rejects a file in place of a directory', async (t) => {
  const options = fixture(t);
  writeFileSync(options.home, 'do-not-overwrite');
  const initializeHome = await initializer();
  assert.throws(() => initializeHome(options), /目录|directory/);
  assert.equal(readFileSync(options.home, 'utf8'), 'do-not-overwrite');
});

test('HOME directory permissions are private on Linux', { skip: process.platform === 'win32' }, async (t) => {
  const options = fixture(t);
  const initializeHome = await initializer();
  initializeHome(options);
  assert.equal(statSync(options.home).mode & 0o777, 0o700);
});

test('HOME initialization rejects a symlink root', { skip: process.platform === 'win32' }, async (t) => {
  const options = fixture(t);
  const outside = join(options.directory, 'outside');
  mkdirSync(outside);
  symlinkSync(outside, options.home, 'dir');
  const initializeHome = await initializer();
  assert.throws(() => initializeHome(options), /链接|symlink/);
  assert.equal(existsSync(join(outside, '.bashrc')), false);
});

test('HOME initialization never follows an existing default-file symlink', { skip: process.platform === 'win32' }, async (t) => {
  const options = fixture(t);
  mkdirSync(options.home);
  const target = join(options.directory, 'untouched');
  symlinkSync(target, join(options.home, '.bashrc'));
  const initializeHome = await initializer();
  initializeHome(options);
  assert.equal(existsSync(target), false);
});
