import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const workflow = read('.github/workflows/build.yml');
const shellTest = process.platform === 'win32' ? test.skip : test;

function stepScript(name) {
  const start = workflow.indexOf(`      - name: ${name}\n`);
  assert.ok(start >= 0, `Missing workflow step ${name}`);
  const step = workflow.slice(start).split(/\n      - /)[0];
  const marker = '\n        run: |\n';
  const runStart = step.indexOf(marker);
  assert.ok(runStart >= 0, `Missing shell block for ${name}`);
  const lines = step.slice(runStart + marker.length).split('\n');
  const end = lines.findIndex(line => line.trim() && !line.startsWith('          '));
  return lines.slice(0, end < 0 ? lines.length : end).map(line => line.replace(/^          /, '')).join('\n');
}

function run(script, env) {
  const result = spawnSync('bash', ['--noprofile', '--norc', '-c', script], {
    cwd: root, env: { ...process.env, ...env }, encoding: 'utf8', timeout: 10_000,
  });
  assert.ifError(result.error);
  return result;
}

test('only Docker Hub is used for publishing and deployment', () => {
  assert.match(workflow, /^  REGISTRY: docker\.io$/m);
  assert.match(workflow, /^  IMAGE_NAME: lolkda\/dsh-dev-image$/m);
  assert.doesNotMatch(workflow, /ghcr|GITHUB_TOKEN|packages:\s*write/i);
  assert.equal([...workflow.matchAll(/username: \$\{\{ secrets\.DOCKERHUB_USERNAME \}\}/g)].length, 2);
  assert.equal([...workflow.matchAll(/password: \$\{\{ secrets\.DOCKERHUB_TOKEN \}\}/g)].length, 2);
  for (const path of ['compose.yml', 'compose.bridge.yml']) {
    assert.match(read(path), /^    image: lolkda\/dsh-dev-image:latest$/m);
  }
  for (const path of ['README.md', 'compose.yml', 'compose.bridge.yml']) {
    assert.doesNotMatch(read(path), /ghcr\.io/i);
  }
});

test('release configuration gates checks while PRs skip credentials and publication', () => {
  assert.match(workflow, /  publication-config:\n[\s\S]*?name: Validate Docker Hub credentials\n        if: github\.event_name != 'pull_request'/);
  assert.match(workflow, /  checks:\n    needs: publication-config\n/);
  assert.match(workflow, /  build:\n    needs: checks\n/);
  assert.match(workflow, /  publish:\n    needs: build\n    if: github\.event_name != 'pull_request'/);
  assert.match(workflow, /name: Log in to Docker Hub\n        if: github\.event_name != 'pull_request'/);
  assert.match(workflow, /name: Push the tested image without rebuilding\n        if: github\.event_name != 'pull_request'/);
});

for (const [username, token, succeeds] of [['', '', false], ['fixture', '', false], ['', 'private-token-fixture', false], ['fixture', 'private-token-fixture', true]]) {
  shellTest(`publication config validates credential presence (${Boolean(username)}, ${Boolean(token)})`, () => {
    const result = run(stepScript('Validate Docker Hub credentials'), {
      DOCKERHUB_USERNAME: username, DOCKERHUB_TOKEN: token,
    });
    assert.equal(result.status === 0, succeeds, result.stderr);
    if (!succeeds) assert.match(result.stderr, /Missing Actions secret: DOCKERHUB_(USERNAME|TOKEN)/);
    assert.doesNotMatch(result.stdout + result.stderr, /private-token-fixture/);
  });
}

const digest = `sha256:${'a'.repeat(64)}`;
const fixtures = [
  [`lolkda/dsh-dev-image@${digest}`, true],
  [`docker.io/lolkda/dsh-dev-image@${digest}`, true],
  [`other/dsh-dev-image@${digest}`, false],
  [`docker.io/other/dsh-dev-image@${digest}`, false],
  [`registry.example/lolkda/dsh-dev-image@${digest}`, false],
  [`lolkda/dsh-dev-image@sha256:${'a'.repeat(63)}`, false],
  ['lolkda/dsh-dev-image@sha256:INVALID', false],
  ['', false],
];
for (const [repoDigest, succeeds] of fixtures) {
  shellTest(`tested image push validates and normalizes digest ${JSON.stringify(repoDigest)}`, t => {
    const temp = mkdtempSync(join(tmpdir(), 'dsh-dockerhub-'));
    t.after(() => rmSync(temp, { recursive: true, force: true }));
    const bin = join(temp, 'bin');
    mkdirSync(bin);
    writeFileSync(join(bin, 'docker'), `#!/bin/bash
set -euo pipefail
printf '%s\\n' "$*" >> "$DOCKER_FIXTURE_LOG"
case "$1" in
  tag|push) ;;
  image) printf '%s\\n' "$DOCKER_FIXTURE_DIGEST" ;;
  *) exit 99 ;;
esac
`, { mode: 0o755 });
    const log = join(temp, 'docker.log');
    const result = run(stepScript('Push the tested image without rebuilding'), {
      PATH: `${bin}:${process.env.PATH}`, RUNNER_TEMP: temp,
      REGISTRY: 'docker.io', IMAGE_NAME: 'lolkda/dsh-dev-image',
      GITHUB_RUN_ID: '123', GITHUB_RUN_ATTEMPT: '1', ARCH: 'arm64',
      DOCKER_FIXTURE_LOG: log, DOCKER_FIXTURE_DIGEST: repoDigest,
    });
    assert.equal(result.status === 0, succeeds, result.stderr);
    const artifact = join(temp, 'digests', 'arm64.txt');
    if (succeeds) {
      assert.equal(readFileSync(artifact, 'utf8'), `docker.io/lolkda/dsh-dev-image@${digest}\n`);
    } else {
      assert.equal(existsSync(artifact), false);
      assert.match(result.stderr, /Unexpected image repository|Invalid pushed image digest/);
    }
    const calls = readFileSync(log, 'utf8').trim().split('\n');
    const ref = 'docker.io/lolkda/dsh-dev-image:ci-123-1-arm64';
    assert.deepEqual(calls, [
      `tag dsh-dev-image:ci ${ref}`, `push ${ref}`,
      `image inspect ${ref} --format {{index .RepoDigests 0}}`,
    ]);
  });
}
