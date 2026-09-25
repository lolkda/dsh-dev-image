import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

// 轻量配置 contract；真实非 root 任意目录执行另在 Docker CI 的 image-smoke.sh 中验证。
const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const dockerfile = read('Dockerfile');
// 只认最终镜像 stage：源 stage（src-node / src-rust）装上 adb 不算交付。
// 整行注释先去掉，避免注释里出现 apt-get install adb 或 FROM 时误判。
const uncommented = dockerfile.split('\n').filter((line) => !/^\s*#/.test(line)).join('\n');
const finalStage = uncommented.split(/^\s*FROM\s+/m).at(-1);

// 回归点：adb 必须是装进最终镜像系统 PATH 的包，不是用户目录安装、源 stage 残留或临时下载。
test('final image installs the Debian adb package through the system package manager', () => {
  const installs = [...finalStage.matchAll(/apt-get install\b[\s\S]*?;/g)].map((match) => match[0]);
  assert.ok(installs.length > 0, 'Missing apt-get install command in the final stage');
  assert.ok(installs.some((install) => /(?:^|[\s;])adb(?=[\s;\\]|$)/m.test(install)),
    'adb is not installed from the Debian archive into the final image');
});

// 回归点：缺了 adb 必须在构建期就失败；两条 PATH 路径（ENV 与 /etc/profile）共用同一段
// payload，所以要在这段 $sh 真正执行的字符串里找到独立的 adb version 命令，echo、注释或
// 循环外的检查都不算。
test('build-time smoke runs adb version in the payload shared by both shells', () => {
  const loop = dockerfile.match(/for sh in "bash -ec" "bash -lec"; do([\s\S]*?)^\s*done/m)?.[1];
  assert.ok(loop, 'Missing build-time two-shell smoke loop');
  const payload = loop.match(/\$sh\s+'([\s\S]*?)'/)?.[1];
  assert.ok(payload, 'Missing the $sh payload that both shells execute');
  assert.match(payload, /(?:^|;|\n)[ \t]*adb version[ \t]*(?:;|\\|\n|$)/m,
    'The two-shell payload does not run adb version as its own fail-fast command');
});

// 回归点：alias/函数只在特定 shell 生效，裸 docker exec 用不到；构建期也不该起 daemon。
test('adb stays a plain system binary: no alias, function or daemon startup', () => {
  for (const path of ['Dockerfile', 'entrypoint.sh', 'cli-env.sh']) {
    const source = read(path);
    assert.doesNotMatch(source, /alias\s+adb\b/, `${path} hides adb behind an alias`);
    assert.doesNotMatch(source, /(?:^|[\s;])adb\s*\(\s*\)/, `${path} hides adb behind a shell function`);
  }
  assert.doesNotMatch(dockerfile, /adb\s+(?:start-server|kill-server)/, 'Build must not start an ADB daemon');
  assert.doesNotMatch(read('tests/image-smoke.sh'), /adb\s+(?:start-server|kill-server)/,
    'Container smoke must not start an ADB daemon');
});
