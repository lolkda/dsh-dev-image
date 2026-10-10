#!/bin/bash
# Install and patch an isolated runtime; never touch the running DSH host.
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/dsh-team-preset.XXXXXX")"
cleanup() {
  case "$scratch" in "${TMPDIR:-/tmp}"/dsh-team-preset.*) ;; *) return 1 ;; esac
  test -d "$scratch"
  test "$(realpath -- "$scratch")" = "$scratch"
  rm -rf -- "$scratch"
}
trap cleanup EXIT
version="$(node -p "require(process.argv[1]).version" "$repo/patches/dsh-subagent-child-setup-v1.baseline.json")"
npm install --prefix "$scratch" --ignore-scripts --no-audit --no-fund \
  "@deepseek-ai/dsh@$version" '@lolkda/dsh-agent-team-model-pin@1.5.1'
subagent="$scratch/node_modules/@deepseek-ai/dsh-subagent"
# Verify the actual installed package and every pristine/post-patch byte.
node --input-type=module - "$repo" "$subagent" <<'NODE'
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
const [, , repo, subagent] = process.argv;
const baseline = JSON.parse(readFileSync(join(repo, 'patches/dsh-subagent-child-setup-v1.baseline.json')));
const pkg = JSON.parse(readFileSync(join(subagent, 'package.json')));
if (pkg.version !== baseline.version) throw new Error('Subagent version mismatch');
for (const [file, hashes] of Object.entries(baseline.files)) {
  if (createHash('sha256').update(readFileSync(join(subagent, file))).digest('hex') !== hashes.beforeSha256) {
    throw new Error(`Pristine hash mismatch: ${file}`);
  }
}
NODE
patch --batch --fuzz=0 -p1 -d "$subagent" -i "$repo/patches/dsh-subagent-child-setup-v1.patch"
node --input-type=module - "$repo" "$subagent" <<'NODE'
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
const [, , repo, subagent] = process.argv;
const baseline = JSON.parse(readFileSync(join(repo, 'patches/dsh-subagent-child-setup-v1.baseline.json')));
for (const [file, hashes] of Object.entries(baseline.files)) {
  if (createHash('sha256').update(readFileSync(join(subagent, file))).digest('hex') !== hashes.afterSha256) {
    throw new Error(`Patched hash mismatch: ${file}`);
  }
}
NODE
mkdir -p "$scratch/tests"
cp "$repo/tests/integration/team-preset.mjs" "$scratch/tests/team-preset.mjs"
node --test "$scratch/tests/team-preset.mjs"
