import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test as nodeTest } from 'node:test';

// The migration host is Linux; these tests exercise real HTTP over a Unix socket.
const test = process.platform === 'linux' ? nodeTest : nodeTest.skip;
const checker = fileURLToPath(new URL('../scripts/verify-home-path.sh', import.meta.url));
const directory = { mode: 0x80000000 + 0o700, linkTarget: '' };
const link = { mode: 0x08000000 + 0o777, linkTarget: '/app' };

async function fixture(t, replyFor) {
  const temp = mkdtempSync(join(tmpdir(), 'dsh-home-path-'));
  const socket = join(temp, 'docker.sock');
  const requests = [];
  const server = createServer((request, response) => {
    const url = new URL(request.url, 'http://localhost');
    const path = url.searchParams.get('path');
    requests.push({ method: request.method, path });
    if (request.method !== 'HEAD' || url.pathname !== '/containers/fixture/archive') {
      response.writeHead(400).end();
      return;
    }
    const reply = replyFor(path);
    response.statusCode = reply.status ?? 200;
    if (reply.stat !== undefined) {
      response.setHeader('X-Docker-Container-Path-Stat', Buffer.from(JSON.stringify(reply.stat)).toString('base64'));
    } else if (reply.header !== undefined) {
      response.setHeader('X-Docker-Container-Path-Stat', reply.header);
    }
    response.end();
  });
  t.after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    rmSync(temp, { recursive: true, force: true });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(socket, resolve);
  });
  const check = (path) => new Promise((resolve) => {
    execFile('bash', [checker, socket, 'fixture', path], { timeout: 10_000 }, (error, stdout, stderr) => {
      resolve({ code: error === null ? 0 : error.code ?? error.signal ?? 'unknown', stdout, stderr });
    });
  });
  return { requests, check };
}

test('source HOME validation checks every directory component using metadata only', async (t) => {
  const { requests, check } = await fixture(t, () => ({ stat: directory }));
  const path = "/legacy data/owner's home";
  const result = await check(path);
  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, '');
  assert.deepEqual(requests, [path, '/legacy data'].map(path => ({ method: 'HEAD', path })));
});

test('source HOME validation rejects a linked ancestor even when the leaf is a real directory', async (t) => {
  const { check } = await fixture(t, path => ({ stat: path === '/alias' ? link : directory }));
  const result = await check('/alias/private-home');
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /符号链接.*\/alias/);
});

test('source HOME validation rejects a link at the source root', async (t) => {
  const { check } = await fixture(t, () => ({ stat: link }));
  const result = await check('/linked-home');
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /符号链接/);
});

test('source HOME validation rejects an ordinary file', async (t) => {
  const { check } = await fixture(t, () => ({ stat: { mode: 0o600, linkTarget: '' } }));
  const result = await check('/not-a-directory');
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /实际目录/);
});

for (const [name, reply] of [
  ['HTTP failure', { status: 404 }],
  ['missing metadata', {}],
  ['invalid base64', { header: 'not-base64!' }],
  ['invalid JSON', { header: Buffer.from('not-json').toString('base64') }],
  ['missing mode', { stat: { linkTarget: '' } }],
  ['invalid mode', { stat: { mode: 'directory', linkTarget: '' } }],
]) {
  test(`source HOME validation fails closed on ${name}`, async (t) => {
    const { check } = await fixture(t, () => reply);
    const result = await check('/source-home');
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /元数据/);
  });
}
