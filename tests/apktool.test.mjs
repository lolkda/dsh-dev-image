import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const dockerfile = read('Dockerfile');

test('apktool installation pins and verifies the official JAR in the final image', () => {
  const stage = dockerfile.split(/^FROM /m).at(-1);
  assert.match(stage, /ARG APKTOOL_VERSION=3\.0\.3/);
  assert.match(stage, /ARG APKTOOL_SHA256=[a-f0-9]{64}\n/);
  assert.ok(stage.includes('https://github.com/iBotPeaches/Apktool/releases/download/v${APKTOOL_VERSION}/apktool_${APKTOOL_VERSION}.jar'));
  assert.ok(stage.includes('echo "${APKTOOL_SHA256}  /opt/apktool/apktool.jar" | sha256sum -c -'));
  assert.match(stage, /COPY apktool\.sh \/usr\/local\/bin\/apktool/);
  assert.match(read('.dockerignore'), /^!apktool\.sh$/m);
  assert.match(stage, /chmod 0755 \/usr\/local\/bin\/apktool/);
  assert.ok(stage.includes('test "$(apktool --version)" = "$APKTOOL_VERSION"'));
});

test('launcher preserves arguments, cwd and exit status in both shell modes', () => {
  const root = mkdtempSync(join(tmpdir(), 'apktool-launcher-'));
  const cwd = join(root, 'working directory');
  mkdirSync(cwd);
  const java = join(root, 'java');
  writeFileSync(java, '#!/bin/sh\nprintf "%s\\n" "$PWD" "$@"\nexit 23\n', { mode: 0o755 });
  const source = read('apktool.sh');
  assert.match(source, /^exec \/opt\/java\/bin\/java -jar \/opt\/apktool\/apktool.jar "\$@"$/m);
  const launcher = join(root, 'apktool');
  // Substitute only Java for an observable stub; execute the actual launcher body.
  writeFileSync(launcher, source.replace('/opt/java/bin/java', `"${java}"`), { mode: 0o755 });
  for (const mode of ['-ec', '-lec']) {
    const result = spawnSync('bash', [mode, 'exec "$@"', 'test', launcher, 'd', 'app with spaces.apk', '', '-o', 'relative output'], { cwd, encoding: 'utf8' });
    assert.equal(result.status, 23, result.stderr);
    assert.deepEqual(result.stdout.trimEnd().split('\n'), [cwd, '-jar', '/opt/apktool/apktool.jar', 'd', 'app with spaces.apk', '', '-o', 'relative output']);
  }
});

test('build and container smoke exercise apktool outside the installation directory', () => {
  const loop = dockerfile.match(/for sh in "bash -ec" "bash -lec"; do([\s\S]*?)^\s*done/m)?.[1];
  assert.ok(loop?.includes('(cd /tmp && apktool --version)'));
  const smoke = read('tests/image-smoke.sh');
  assert.ok(smoke.includes('(cd /tmp && apktool --version)'));
  assert.ok(smoke.includes('docker exec --workdir /tmp "$web_id" apktool --version'));
});
