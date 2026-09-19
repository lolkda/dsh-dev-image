import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const exec = promisify(execFile);
const root = fileURLToPath(new URL('../', import.meta.url));
const token = 'isolated-ci-test-token';
const startupLog = `dsh web: http://127.0.0.1:3080/?token=${token}\n`;

async function fixture(t, handler) {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-web-probe-'));
  const server = createServer(handler);
  t.after(async () => {
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    await rm(directory, { recursive: true, force: true });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  assert.ok(address && typeof address === 'object');
  return {
    url: `http://127.0.0.1:${address.port}/`,
    cookieJar: join(directory, 'cookies.txt').replaceAll('\\', '/'),
  };
}

function probe({ url, cookieJar, log = startupLog }) {
  return exec('bash', ['--noprofile', '--norc', '-c',
    'source tests/image-smoke.sh; probe_web "$PROBE_URL" "$PROBE_LOG" "$COOKIE_JAR"'], {
    cwd: root,
    env: { ...process.env, PROBE_URL: url, PROBE_LOG: log, COOKIE_JAR: cookieJar },
    timeout: 10_000,
  });
}

// 回归点：恢复匿名 curl --fail，会在第一次 401 时失败，无法到达带 cookie 的 200。
test('Web probe completes the token-to-cookie login flow', async (t) => {
  let authenticatedRequests = 0;
  const target = await fixture(t, (req, res) => {
    if (req.url === `/?token=${token}`) {
      res.writeHead(302, { location: '/', 'set-cookie': 'ci_session=accepted; Path=/; HttpOnly' });
    } else if (req.headers.cookie === 'ci_session=accepted') {
      authenticatedRequests++;
      res.writeHead(200, { 'content-type': 'text/html' });
    } else {
      res.writeHead(401);
    }
    res.end();
  });
  await probe(target);
  assert.equal(authenticatedRequests, 1);
});

test('Web probe does not accept an unrelated anonymous 200 without a startup token', async (t) => {
  const target = await fixture(t, (_req, res) => { res.writeHead(200); res.end(); });
  await assert.rejects(probe({ ...target, log: 'server still initializing' }));
});

test('Web probe rejects a server error even with a startup token', async (t) => {
  const target = await fixture(t, (_req, res) => { res.writeHead(500); res.end(); });
  await assert.rejects(probe(target));
});

test('Web probe rejects a login flow that never authenticates', async (t) => {
  const target = await fixture(t, (req, res) => {
    if (req.url === `/?token=${token}`) res.writeHead(302, { location: '/' });
    else res.writeHead(401);
    res.end();
  });
  await assert.rejects(probe(target));
});
