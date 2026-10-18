import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const dockerfile = read('Dockerfile');
const bundlePackage = JSON.parse(read('bundles/dsh-dexsql-mcp/package.json'));
const bundlePatch = read('bundles/dsh-dexsql-mcp/cordis.patch.yml');

test('DexSQL version and per-architecture checksums are pinned', () => {
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

test('DexSQL local bundle declares the DSH MCP client entry', () => {
  assert.equal(bundlePackage.name, '@local/dsh-dexsql-mcp');
  assert.equal(bundlePackage.dsh.bundle.patch, './cordis.patch.yml');
  assert.match(bundlePatch, /id: dexsql-mcp/);
  assert.match(bundlePatch, /name: "@deepseek-ai\/dsh-mcp-client"/);
  assert.match(bundlePatch, /serverName: dexsql/);
  assert.match(bundlePatch, /transport: stdio/);
  assert.match(bundlePatch, /command: \/usr\/local\/bin\/dexsql/);
  assert.match(bundlePatch, /cwd: \/app/);
  assert.match(bundlePatch, /failOnStartupError: false/);
});

test('default DSH_PLUGINS installs the DexSQL bundle in both deployment modes', () => {
  for (const path of ['Dockerfile', 'compose.yml', 'compose.bridge.yml']) {
    assert.match(read(path), /link:\/opt\/dsh-bundles\/dsh-dexsql-mcp/, `${path} is missing the DexSQL bundle`);
  }
});
