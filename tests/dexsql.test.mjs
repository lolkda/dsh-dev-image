import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const dockerfile = read('Dockerfile');

test('DexSQL binary version and per-architecture checksums are pinned', () => {
  assert.match(dockerfile, /^ARG DEXSQL_VERSION=0\.1\.1$/m);
  assert.match(dockerfile, /^ARG DEXSQL_SHA256_AMD64=[a-f0-9]{64}$/m);
  assert.match(dockerfile, /^ARG DEXSQL_SHA256_ARM64=[a-f0-9]{64}$/m);
  assert.match(dockerfile, /^ARG DEXSQL_LICENSE_SHA256=[a-f0-9]{64}$/m);
  assert.match(dockerfile, /^ARG DEXSQL_LICENSE_AUXILIARY_SHA256=[a-f0-9]{64}$/m);
  assert.match(dockerfile, /dexsql-linux-\$\{arch\}/);
  assert.match(dockerfile, /sha256sum -c -/);
});

test('DexSQL build installs the CLI, MCP help and license notices', () => {
  assert.match(dockerfile, /ln -sfn "\$install_dir\/dexsql" \/usr\/local\/bin\/dexsql/);
  assert.match(dockerfile, /dexsql mcp --help/);
  assert.match(dockerfile, /extract licenses --output/);
  assert.match(dockerfile, /THIRD_PARTY_NOTICES/);
  assert.match(dockerfile, /LICENSE-AUXILIARY/);
  assert.match(dockerfile, /\(cd \/tmp && dexsql --version && dexsql mcp --help >\/dev\/null\)/);
});

test('default plugins install the published DexSQL MCP bundle at latest', () => {
  for (const path of ['Dockerfile', 'compose.yml', 'compose.bridge.yml']) {
    const source = read(path);
    assert.match(source, /@lolkda\/dsh-dexsql-mcp@latest/, `${path} is missing the DexSQL npm bundle`);
    assert.doesNotMatch(source, /@lolkda\/dsh-dexsql-mcp@\d/, `${path} pinned the DexSQL npm bundle`);
    assert.doesNotMatch(source, /link:\/opt\/dsh-bundles\/dsh-dexsql-mcp/, `${path} still references the removed local bundle`);
  }
});

test('plugin installation uses the official registry while user dependencies keep the mirror', () => {
  assert.match(dockerfile, /DSH_PLUGIN_REGISTRY=https:\/\/registry\.npmjs\.org/);
  assert.match(dockerfile, /npm_config_registry=https:\/\/registry\.npmmirror\.com/);
});
