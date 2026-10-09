import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const dockerfile = read('Dockerfile');
const tools = ['frida', 'frida-ps', 'frida-trace', 'frida-ls-devices'];

test('Frida installs pinned client packages in an image-owned isolated environment', () => {
  const stage = dockerfile.split(/^FROM /m).at(-1);
  assert.match(stage, /ARG FRIDA_VERSION=17\.23\.1/);
  assert.match(stage, /ARG FRIDA_TOOLS_VERSION=14\.11\.0/);
  assert.ok(stage.includes('python -m venv /opt/frida'));
  assert.ok(stage.includes('"frida==${FRIDA_VERSION}" "frida-tools==${FRIDA_TOOLS_VERSION}"'));
  assert.ok(stage.includes('/opt/frida/bin/python -m pip check'));
  assert.ok(stage.includes('for cli in /opt/frida/bin/frida*; do'));
  assert.ok(stage.includes('ln -s "$cli" "/usr/local/bin/$(basename "$cli")"'));
  assert.ok(stage.includes('test "$(frida --version)" = "$FRIDA_VERSION"'));
  assert.ok(stage.indexOf('python -m venv /opt/frida') < stage.indexOf('ENV HOME='));
});

test('build and container smoke check Frida from /tmp without starting a server', () => {
  const loop = dockerfile.match(/for sh in "bash -ec" "bash -lec"; do([\s\S]*?)^\s*done/m)?.[1];
  const payload = loop?.match(/\$sh\s+'([\s\S]*?)'/)?.[1];
  assert.ok(payload?.includes('(cd /tmp && frida --version'));
  const smoke = read('tests/image-smoke.sh');
  assert.ok(smoke.includes('(cd /tmp && frida --version'));
  for (const tool of tools.slice(1)) {
    assert.ok(payload.includes(`${tool} --help >/dev/null`));
    assert.ok(smoke.includes(`${tool} --help >/dev/null`));
  }
  assert.ok(smoke.includes('docker exec --workdir /tmp "$web_id" frida --version'));
  assert.ok(smoke.includes('docker exec --workdir /tmp "$web_id" "$tool" --help >/dev/null'));
  assert.doesNotMatch(dockerfile, /^\s*[^#\n]*frida-server/m);
});

test('real Frida console entry points work via PATH symlinks from unrelated directories', {
  skip: !process.env.FRIDA_TEST_BIN && 'Set FRIDA_TEST_BIN to an installed Frida venv bin directory',
}, () => {
  const bin = mkdtempSync(join(tmpdir(), 'frida-path-'));
  for (const tool of tools) symlinkSync(join(process.env.FRIDA_TEST_BIN, tool), join(bin, tool));
  for (const cwd of ['/tmp', '/']) {
    for (const tool of tools) {
      const option = tool === 'frida' ? '--version' : '--help';
      for (const mode of ['-ec', '-lec', 'direct']) {
        // Login shells reset PATH: inject the isolated link directory after profile loading.
        const command = mode === 'direct' ? tool : 'bash';
        const args = mode === 'direct' ? [option] : [mode, 'export PATH="$1:$PATH"; exec "$2" "$3"', 'check', bin, tool, option];
        const result = spawnSync(command, args, { cwd, encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}` } });
        assert.equal(result.status, 0, `${cwd} ${mode} ${tool}: ${result.stderr}`);
        if (tool === 'frida') assert.equal(result.stdout.trim(), '17.23.1');
        else assert.match(result.stdout, /usage:/i);
      }
    }
  }
});
