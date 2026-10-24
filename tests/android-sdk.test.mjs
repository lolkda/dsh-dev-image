import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const dockerfile = read('Dockerfile');
const uncommented = dockerfile.split('\n').filter((line) => !/^\s*#/.test(line)).join('\n');
const finalStage = uncommented.split(/^\s*FROM\s+/m).at(-1);
const source = finalStage.replace(/\\\r?\n\s*/g, ' ').replace(/\s+/g, ' ');

const expected = {
  cmdlineTools: '23.0',
  cmdlineBuild: '16111833',
  cmdlineSha256: '0877a1d048fe4a24efe2eff536ca4223f7adeb58648bb81909d33c446918cfa8',
  platform: '37.2',
  buildTools: '37.0.0',
  platformTools: '37.0.1',
};

test('Android SDK component versions are pinned to the current stable releases', () => {
  const arg = (name) => dockerfile.match(new RegExp(`^ARG ${name}=(\\S+)$`, 'm'))?.[1];
  assert.equal(arg('ANDROID_CMDLINE_TOOLS_VERSION'), expected.cmdlineTools);
  assert.equal(arg('ANDROID_CMDLINE_TOOLS_BUILD'), expected.cmdlineBuild);
  assert.equal(arg('ANDROID_CMDLINE_TOOLS_SHA256'), expected.cmdlineSha256);
  assert.equal(arg('ANDROID_SDK_PLATFORM'), expected.platform);
  assert.equal(arg('ANDROID_BUILD_TOOLS_VERSION'), expected.buildTools);
  assert.equal(arg('ANDROID_PLATFORM_TOOLS_VERSION'), expected.platformTools);
});

test('cmdline-tools is downloaded from the official archive with a SHA-256 check', () => {
  assert.ok(source.includes(
    'https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_BUILD}_latest.zip',
  ));
  assert.match(source,
    /echo "\$\{ANDROID_CMDLINE_TOOLS_SHA256\}\s+\/tmp\/android-cmdline-tools\.zip" \| sha256sum -c -/);
  assert.ok(source.includes('unzip -q /tmp/android-cmdline-tools.zip -d "$ANDROID_HOME/cmdline-tools"'));
  assert.ok(source.includes('mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"'));
});

test('final image installs platform, build-tools and full platform-tools through sdkmanager', () => {
  assert.ok(source.includes(
    'sdkmanager --install "platforms;android-${ANDROID_SDK_PLATFORM}" "build-tools;${ANDROID_BUILD_TOOLS_VERSION}" "platform-tools"',
  ));
  assert.ok(source.includes(
    'grep -Fx "Pkg.Revision=${ANDROID_PLATFORM_TOOLS_VERSION}" "$ANDROID_HOME/platform-tools/source.properties"',
  ));
  assert.ok(source.includes(
    'grep -Fx "Pkg.Revision=${ANDROID_BUILD_TOOLS_VERSION}" "$ANDROID_HOME/build-tools/${ANDROID_BUILD_TOOLS_VERSION}/source.properties"',
  ));
  assert.ok(source.includes(
    'grep -Fx "AndroidVersion.ApiLevel=${ANDROID_SDK_PLATFORM}" "$ANDROID_HOME/platforms/android-${ANDROID_SDK_PLATFORM}/source.properties"',
  ));
});

test('amd64 installs no Debian adb while arm64 keeps it as a debug-only fallback', () => {
  const mainInstall = finalStage.match(/apt-get install -y --no-install-recommends[\s\S]*?gh;/)?.[0] ?? '';
  assert.ok(mainInstall, 'Missing main apt-get install command');
  assert.doesNotMatch(mainInstall, /(?:^|[\s;])adb(?=[\s;\\]|$)/m,
    'amd64 must not install Debian adb alongside the pinned SDK platform-tools');
  const arm64Fallback = finalStage.match(
    /if \[ "\$\(dpkg --print-architecture\)" = arm64 \]; then[\s\S]*?fi;/,
  )?.[0] ?? '';
  assert.match(arm64Fallback, /apt-get install[^;]*\badb\b/,
    'arm64 needs Debian adb because Google has no native arm64 Linux platform-tools');
});

test('the native Android SDK install is guarded to amd64', () => {
  assert.match(finalStage,
    /if \[ "\$\(dpkg --print-architecture\)" != amd64 \]; then[\s\S]*?exit 0;[\s\S]*?fi;/);
});

test('ANDROID_HOME, ANDROID_SDK_ROOT and every SDK command directory are on PATH', () => {
  assert.match(source, /\bANDROID_HOME=\/opt\/android-sdk\b/);
  assert.match(source, /\bANDROID_SDK_ROOT=\/opt\/android-sdk\b/);
  for (const directory of [
    '/opt/android-sdk/cmdline-tools/latest/bin',
    '/opt/android-sdk/platform-tools',
    '/opt/android-sdk/build-tools/37.0.0',
  ]) {
    assert.ok(source.includes(directory), `PATH is missing ${directory}`);
  }
  assert.ok(source.indexOf('/opt/android-sdk/build-tools/37.0.0') < source.indexOf('/usr/local/bin'),
    'SDK build-tools must precede /usr/local/bin on PATH');
});

test('login shells restore the same Android SDK PATH directories', () => {
  const profile = finalStage.match(/printf '%s\\n'[\s\S]*?00-dsh-path\.sh/)?.[0] ?? '';
  assert.ok(profile, 'Missing /etc/profile.d PATH restoration');
  for (const directory of [
    '/opt/android-sdk/cmdline-tools/latest/bin',
    '/opt/android-sdk/platform-tools',
    '/opt/android-sdk/build-tools/37.0.0',
  ]) {
    assert.ok(profile.includes(directory), `login shell PATH is missing ${directory}`);
  }
});

test('both build-time shells exercise SDK manager, adb, fastboot and build-tools', () => {
  const body = finalStage.match(/\$sh '([^']+)'/)?.[1] ?? '';
  for (const command of [
    'sdkmanager --version',
    'adb version',
    'fastboot --version',
    'aapt2 version',
    'apksigner version',
  ]) {
    assert.ok(body.includes(command), `build smoke is missing ${command}`);
  }
});

test('Android SDK binaries stay plain PATH entries without aliases or a build-time daemon', () => {
  for (const path of ['Dockerfile', 'entrypoint.sh', 'cli-env.sh']) {
    const text = read(path);
    assert.doesNotMatch(text, /alias\s+adb\b/, `${path} hides adb behind an alias`);
    assert.doesNotMatch(text, /(?:^|[\s;])adb\s*\(\s*\)/, `${path} hides adb behind a shell function`);
  }
  assert.doesNotMatch(dockerfile, /adb\s+(?:start-server|kill-server)/,
    'Build must not start an ADB daemon');
  assert.doesNotMatch(read('tests/image-smoke.sh'), /adb\s+(?:start-server|kill-server)/,
    'Container smoke must not start an ADB daemon');
});
