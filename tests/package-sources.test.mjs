import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));
const dockerfile = readFileSync(new URL('../Dockerfile', import.meta.url), 'utf8');
const sources = [
  { input: 'NPM_REGISTRY', mirror: 'https://registry.npmmirror.com', official: 'https://registry.npmjs.org/', keys: ['npm_config_registry', 'PNPM_CONFIG_REGISTRY', 'YARN_REGISTRY'] },
  { input: 'PYPI_INDEX_URL', mirror: 'https://mirrors.aliyun.com/pypi/simple/', official: 'https://pypi.org/simple/', keys: ['PIP_INDEX_URL', 'UV_DEFAULT_INDEX'] },
];

// 回归点：移除任何一个工具自己的配置，或误把 pnpm/uv 当作读取 npm/pip 的变量。
for (const { keys, mirror } of sources) {
  for (const key of keys) {
    test(`image configures ${key} with its domestic mirror`, () => {
      const expression = dockerfile.match(new RegExp(`^(?:ENV\\s+|\\s+)${key}=(\\S+)`, 'm'))?.[1];
      assert.equal(expression, mirror);
    });
  }
}

for (const file of ['compose.yml', 'compose.bridge.yml']) {
  const source = readFileSync(new URL(`../${file}`, import.meta.url), 'utf8');
  for (const { input, mirror, official, keys } of sources) {
    for (const value of [undefined, '', official]) {
      test(`${file}: ${input}=${JSON.stringify(value) ?? 'unset'} configures every consumer`, () => {
        const env = { ...process.env };
        delete env[input];
        if (value !== undefined) env[input] = value;
        for (const key of keys) {
          const expression = source.match(new RegExp(`^\\s+${key}:\\s*(.+)$`, 'm'))?.[1];
          assert.ok(expression, `${file} does not expose ${key}`);
          const result = spawnSync('bash', ['--noprofile', '--norc', '-c', `printf '%s' "${expression}"`], {
            cwd: root, env, encoding: 'utf8', timeout: 10_000,
          });
          assert.ifError(result.error);
          assert.equal(result.status, 0, result.stderr);
          assert.equal(result.stdout, value || mirror, key);
        }
      });
    }
  }
}
