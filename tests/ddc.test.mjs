import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const dockerfile = read('Dockerfile');

test('ddc installation pins per-architecture release binaries and verifies them', () => {
  const stage = dockerfile.split(/^FROM /m).at(-1);
  const version = stage.match(/ARG DDC_VERSION=(\d+\.\d+\.\d+)\n/)?.[1];
  assert.ok(version, 'DDC_VERSION must be pinned in the final stage');
  const amd64 = stage.match(/ARG DDC_SHA256_AMD64=([a-f0-9]{64})\n/)?.[1];
  const arm64 = stage.match(/ARG DDC_SHA256_ARM64=([a-f0-9]{64})\n/)?.[1];
  assert.ok(amd64, 'DDC_SHA256_AMD64 must be a hex digest');
  assert.ok(arm64, 'DDC_SHA256_ARM64 must be a hex digest');
  assert.notEqual(amd64, arm64, 'the two architectures must not share one digest');
  // 架构沿用 JDK 段的 dpkg 探测，不用 BuildKit 的 TARGETARCH：不开 BuildKit 也不能拿错二进制。
  assert.ok(stage.includes('arch="$(dpkg --print-architecture)"'));
  assert.ok(stage.includes('amd64) ddc_target="x86_64-unknown-linux-gnu"; ddc_sha256="$DDC_SHA256_AMD64" ;;'));
  assert.ok(stage.includes('arm64) ddc_target="aarch64-unknown-linux-gnu"; ddc_sha256="$DDC_SHA256_ARM64" ;;'));
  assert.ok(stage.includes('"https://github.com/ejfkdev/ddc/releases/download/v${DDC_VERSION}/ddc-v${DDC_VERSION}-${ddc_target}"'));
  assert.ok(stage.includes('echo "${ddc_sha256}  /tmp/ddc" | sha256sum -c -'));
  // 上游发的是单个静态 ELF，落 /usr/local/bin 即可被 PATH 命中，不需要 wrapper 脚本。
  assert.ok(stage.includes('install -m 0755 /tmp/ddc /usr/local/bin/ddc'));
  assert.ok(!stage.includes('COPY ddc'), 'ddc must come from the pinned release, not the build context');
  assert.ok(stage.includes('test "$(ddc --version | head -n1 | awk \'{print $1, $2}\')" = "ddc $DDC_VERSION"'));
});

test('the pinned version assertion matches the upstream --version banner', () => {
  const stage = dockerfile.split(/^FROM /m).at(-1);
  const version = stage.match(/ARG DDC_VERSION=(\d+\.\d+\.\d+)\n/)[1];
  // 断言写法必须对上游真实输出成立：首行是 "ddc <版本> — <描述>"，不是裸版本号。
  const banner = `ddc ${version} — DEX → Java decompiler\nhttps://github.com/ejfkdev/ddc\n`;
  const result = spawnSync('bash', ['-c', "head -n1 | awk '{print $1, $2}'"], { input: banner, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), `ddc ${version}`);
});

test('build and container smoke exercise ddc outside the installation directory', () => {
  const loop = dockerfile.match(/for sh in "bash -ec" "bash -lec"; do([\s\S]*?)^\s*done/m)?.[1];
  assert.ok(loop?.includes('(cd /tmp && ddc --version)'));
  const smoke = read('tests/image-smoke.sh');
  // 工具清单和调用分处不同行（列表带续行符），按 token 判断而不是按行匹配。
  const toolList = smoke.match(/for tool in([^;]*); do/)?.[1];
  assert.ok(toolList, 'tool list check must stay in the container smoke');
  assert.ok(toolList.split(/\s+/).includes('ddc'), 'ddc must be checked on PATH in the running container');
  assert.ok(smoke.includes('(cd /tmp && ddc --version)'));
  assert.ok(smoke.includes('docker exec --workdir /tmp "$web_id" ddc --version'));
});
