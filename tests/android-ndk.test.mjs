import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, sep } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = name => readFileSync(join(root, name), 'utf8');
const helper = join(root, 'ndk-env.sh');
const ndkVersion = '30.0.16248370';

function fixture(t) {
  const parent = resolve(tmpdir());
  const directory = mkdtempSync(join(parent, 'dsh-ndk-env-'));
  t.after(() => {
    assert.ok(directory.startsWith(`${parent}${sep}dsh-ndk-env-`));
    rmSync(directory, { recursive: true, force: true });
  });
  return directory;
}

function environment(extra = {}) {
  const env = { ...process.env, PATH: '/usr/bin:/bin' };
  delete env.ANDROID_NDK_HOME;
  delete env.ANDROID_NDK_VERSION;
  delete env.ANDROID_HOME;
  return { ...env, ...extra };
}

function source(env, script = '. "$1"; . "$1"; printf "%s" "$PATH"') {
  return spawnSync('/bin/sh', ['-ec', script, 'ndk-env-test', helper], {
    env, encoding: 'utf8', timeout: 10_000,
  });
}

test('the image installs one explicitly versioned NDK through the amd64 SDK branch', () => {
  const dockerfile = read('Dockerfile');
  assert.equal(dockerfile.match(/^ARG ANDROID_NDK_VERSION=(\S+)$/m)?.[1], ndkVersion);
  assert.ok(dockerfile.includes('"ndk;${ANDROID_NDK_VERSION}"'));
  const install = dockerfile.slice(dockerfile.indexOf('# Android SDK'));
  assert.ok(install.indexOf('!= amd64') < install.indexOf('"ndk;${ANDROID_NDK_VERSION}"'));
  assert.ok(install.includes('$ANDROID_NDK_HOME/source.properties'));
  assert.ok(install.includes('$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake'));
});

test('image ENV exposes NDK tools without overriding existing host command priority', () => {
  const dockerfile = read('Dockerfile');
  assert.match(dockerfile, /ENV ANDROID_NDK_VERSION=\$\{ANDROID_NDK_VERSION\}/);
  assert.match(dockerfile, /ENV ANDROID_NDK_HOME=\/opt\/android-sdk\/ndk\/\$\{ANDROID_NDK_VERSION\}/);
  assert.ok(dockerfile.includes('ENV PATH="${PATH}:${ANDROID_NDK_HOME}:${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin"'));
});

test('NDK COPY sources are included in the restricted Docker build context', () => {
  const patterns = read('.dockerignore').split(/\r?\n/);
  for (const allow of ['!ndk-env.sh', '!tests/', '!tests/android-ndk-smoke.sh']) {
    assert.ok(patterns.includes(allow), `Docker context excludes ${allow}`);
  }
});

test('entrypoint and login shells source the same NDK environment helper', () => {
  const dockerfile = read('Dockerfile');
  assert.ok(dockerfile.includes('COPY ndk-env.sh /usr/local/bin/ndk-env.sh'));
  assert.ok(dockerfile.includes('. /usr/local/bin/ndk-env.sh'));
  assert.ok(read('entrypoint.sh').includes('source "$script_dir/ndk-env.sh"'));
  assert.ok(read('tests/Dockerfile').includes('COPY ndk-env.sh /usr/local/bin/ndk-env.sh'));
  assert.ok(read('.github/workflows/verify-layout.yml').includes('sh -n ndk-env.sh'));
});

test('NDK PATH is idempotent, supports quoted paths and preserves host tools', t => {
  const directory = fixture(t);
  const ndk = join(directory, "ndk with 'quotes'");
  const llvm = join(ndk, 'toolchains/llvm/prebuilt/linux-x86_64/bin');
  mkdirSync(llvm, { recursive: true });
  writeFileSync(join(ndk, 'ndk-build'), '#!/bin/sh\nprintf ndk-fixture\n');
  chmodSync(join(ndk, 'ndk-build'), 0o755);
  const result = source(environment({ ANDROID_NDK_HOME: ndk }));
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, `/usr/bin:/bin:${ndk}:${llvm}`);
  const command = source(environment({ ANDROID_NDK_HOME: ndk }), '. "$1"; ndk-build');
  assert.equal(command.status, 0, command.stderr);
  assert.equal(command.stdout, 'ndk-fixture');
});

test('an explicit NDK home replaces inherited image NDK paths without shadowing host paths', t => {
  const directory = fixture(t);
  const ndk = join(directory, 'selected-ndk');
  const llvm = join(ndk, 'toolchains/llvm/prebuilt/linux-x86_64/bin');
  mkdirSync(llvm, { recursive: true });
  const imageNdk = `/opt/android-sdk/ndk/${ndkVersion}`;
  const result = source(environment({
    ANDROID_NDK_HOME: ndk,
    PATH: `/usr/bin:/bin:${imageNdk}:${imageNdk}/toolchains/llvm/prebuilt/linux-x86_64/bin`,
  }));
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, `/usr/bin:/bin:${ndk}:${llvm}`);
});

test('an unset NDK home can resolve from the configured SDK and NDK version', t => {
  const directory = fixture(t);
  const ndk = join(directory, 'ndk', ndkVersion);
  mkdirSync(ndk, { recursive: true });
  const result = source(environment({ ANDROID_HOME: directory, ANDROID_NDK_VERSION: ndkVersion }),
    '. "$1"; printf "%s\\n%s" "$ANDROID_NDK_HOME" "$PATH"');
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, `${ndk}\n/usr/bin:/bin:${ndk}`);
});

test('missing NDK directories leave PATH unchanged and do not create files', t => {
  const absent = join(fixture(t), 'not-installed');
  const result = source(environment({ ANDROID_NDK_HOME: absent }));
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, '/usr/bin:/bin');
  assert.equal(existsSync(absent), false);
  const unset = source(environment());
  assert.equal(unset.status, 0, unset.stderr);
  assert.equal(unset.stdout, '/usr/bin:/bin');
});

test('NDK environment rejects relative paths and PATH separators', () => {
  for (const home of ['relative/ndk', '/tmp/ndk:injected']) {
    const result = source(environment({ ANDROID_NDK_HOME: home }));
    assert.notEqual(result.status, 0, home);
    assert.match(result.stderr, /ANDROID_NDK_HOME/);
  }
});

test('NDK smoke script requires C++20 Android API 28 linking and ELF inspection', () => {
  const smoke = read('tests/android-ndk-smoke.sh');
  for (const required of ['aarch64-linux-android28-clang++', '-std=c++20', '-shared', '-fPIC',
    '__ANDROID_API__ == 28', '__aarch64__', 'JNI_OnLoad', 'llvm-readelf', 'AArch64', 'DYN']) {
    assert.ok(smoke.includes(required), `smoke is missing ${required}`);
  }
  assert.ok(read('Dockerfile').includes('/usr/local/libexec/dsh-android-ndk-smoke'));
  const runtime = read('tests/image-smoke.sh');
  assert.ok(runtime.includes('/usr/local/libexec/dsh-android-ndk-smoke'));
  assert.ok(runtime.includes('docker exec --workdir /tmp "$web_id" aarch64-linux-android28-clang++ --version'));
});
