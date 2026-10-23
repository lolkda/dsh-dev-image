import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const dockerfile = read('Dockerfile');

test('image does not install a global DexSQL binary', () => {
  assert.doesNotMatch(dockerfile, /^ARG DEXSQL_/m);
  assert.doesNotMatch(dockerfile, /\/opt\/dexsql/);
  assert.doesNotMatch(dockerfile, /dexsql-linux-/);
  assert.doesNotMatch(dockerfile, /ln -sfn .*\/usr\/local\/bin\/dexsql/);
  assert.doesNotMatch(dockerfile, /dexsql mcp --help/);
  assert.doesNotMatch(dockerfile, /THIRD_PARTY_NOTICES/);
});

test('DexSQL MCP is not part of the default plugin install', () => {
  for (const path of ['Dockerfile', 'compose.yml', 'compose.bridge.yml']) {
    assert.doesNotMatch(read(path), /@lolkda\/dsh-dexsql-mcp/, `${path} still installs the DexSQL plugin`);
  }
});

test('image smoke rejects a global dexsql and does not expect the plugin', () => {
  const smoke = read('tests/image-smoke.sh');
  assert.match(smoke, /image unexpectedly provides a global dexsql/);
  assert.match(smoke, /test ! -e \/opt\/dexsql/);
  assert.doesNotMatch(smoke, /dsh-dexsql-mcp/);
});

test('plugin installation uses the official registry while user dependencies keep the mirror', () => {
  assert.match(dockerfile, /DSH_PLUGIN_REGISTRY=https:\/\/registry\.npmjs\.org/);
  assert.match(dockerfile, /npm_config_registry=https:\/\/registry\.npmmirror\.com/);
});
