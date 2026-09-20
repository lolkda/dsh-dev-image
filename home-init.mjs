import { chmodSync, constants, copyFileSync, lstatSync, mkdirSync } from 'node:fs';
import { isAbsolute, join, parse, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** 初始化私有 HOME；仅补缺少的 Shell 默认文件，不读取或覆盖用户凭据。 */
export function initializeHome({ home, skel }) {
  if (!isAbsolute(home) || resolve(home) === parse(resolve(home)).root) {
    throw new Error('HOME 必须是非文件系统根目录的绝对路径');
  }
  const existing = lstatSync(home, { throwIfNoEntry: false });
  if (existing && (existing.isSymbolicLink() || !existing.isDirectory())) {
    throw new Error('HOME 必须是真实目录，不能是符号链接或普通文件');
  }
  mkdirSync(home, { recursive: true, mode: 0o700 });
  if ((lstatSync(home).mode & 0o7777) !== 0o700) chmodSync(home, 0o700);

  // 白名单只包含系统 Shell 默认文件，既不扫描用户 HOME，也不复制任何凭据模板。
  for (const name of ['.bashrc', '.profile', '.bash_logout']) {
    const source = join(skel, name);
    if (!lstatSync(source, { throwIfNoEntry: false })?.isFile()) continue;
    try {
      copyFileSync(source, join(home, name), constants.COPYFILE_EXCL);
    } catch (error) {
      // COPYFILE_EXCL 原子拒绝已存在的文件/链接，避免覆盖用户配置或跟随链接写入。
      if (error?.code !== 'EEXIST') throw error;
    }
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [home, skel = '/etc/skel'] = process.argv.slice(2);
  if (!home) {
    console.error('usage: node home-init.mjs HOME [SKEL]');
    process.exitCode = 1;
  } else {
    try {
      initializeHome({ home, skel });
    } catch (error) {
      console.error('dsh-home-init: ' + error.message);
      process.exitCode = 1;
    }
  }
}
