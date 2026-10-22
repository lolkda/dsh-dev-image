import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const dockerfile = read('Dockerfile');

test('image no longer downloads or installs a global DexSQL binary', () => {
  assert.doesNotMatch(dockerfile, /^ARG DEXSQL_/m);
  assert.doesNotMatch(dockerfile, /\/opt\/dexsql/);
  assert.doesNotMatch(dockerfile, /dexsql-linux-/);
  assert.doesNotMatch(dockerfile, /ln -sfn .*\/usr\/local\/bin\/dexsql/);
  assert.doesNotMatch(dockerfile, /dexsql mcp --help/);
  assert.doesNotMatch(dockerfile, /THIRD_PARTY_NOTICES/);
});

test('image smoke verifies the plugin launcher and bundled binary instead of a global CLI', () => {
  const smoke = read('tests/image-smoke.sh');
  assert.match(smoke, /dexsqlPkg\.bin\?\.dexsql/);
  assert.match(smoke, /dexsqlRoot \+ "\/vendor\/" \+ target/);
  assert.match(smoke, /\[launcher, "--version"\]/);
  assert.match(smoke, /\[launcher, "mcp", "--help"\]/);
  assert.match(smoke, /image unexpectedly provides a global dexsql/);
  assert.match(smoke, /test ! -e \/opt\/dexsql/);
  assert.doesNotMatch(smoke, /for tool in .*dexsql/);
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
