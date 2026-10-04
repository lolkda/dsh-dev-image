import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const root = fileURLToPath(new URL('../.agents/notes/', import.meta.url));
const lifecycles = ['proposed', 'implemented', 'rejected', 'archived'];
const classes = ['feature', 'bug-fix', 'simplification', 'architecture', 'process', 'testing'];
const files = readdirSync(root, { recursive: true, withFileTypes: true });
const notes = files.filter(entry => entry.isFile());

test('note tree contains decisions and only supported paths', () => {
  assert.ok(notes.length > 0, 'At least one decision note is required');
  for (const entry of files) {
    assert.ok(!entry.isSymbolicLink(), `Note tree must not contain symlinks: ${entry.name}`);
    const parts = relative(root, join(entry.parentPath, entry.name)).split(/[\\/]/);
    assert.ok(lifecycles.includes(parts[0]), `Unknown lifecycle: ${parts[0]}`);
    if (parts.length >= 2) assert.ok(classes.includes(parts[1]), `Unknown note class: ${parts[1]}`);
    assert.equal(parts.length, entry.isFile() ? 3 : Math.min(parts.length, 2), `Invalid note depth: ${parts.join('/')}`);
    if (entry.isFile()) assert.match(entry.name, /^\d{4}-\d{2}-\d{2}-[a-z0-9-]+\.md$/);
  }
});

for (const entry of notes) {
  const path = join(entry.parentPath, entry.name);
  const lifecycle = relative(root, path).split(/[\\/]/)[0];
  test(`decision note format and links: ${relative(root, path)}`, () => {
    const text = readFileSync(path, 'utf8');
    assert.match(text, /^# Agent Note: .+\n\nStatus: /);
    const status = text.split('\n')[2];
    if (lifecycle === 'rejected') assert.match(status, /^Status: rejected — .+/);
    else assert.equal(status, `Status: ${lifecycle}`);
    const required = ['Problem', 'Alternatives considered'];
    if (lifecycle === 'implemented') required.push('Decision', 'Consequences');
    if (['proposed', 'rejected'].includes(lifecycle)) required.push('Proposal', 'Acceptance criteria', 'Risks');
    for (const section of required) assert.ok(text.includes(`\n## ${section}\n`), `Missing ${section}`);
    if (lifecycle === 'implemented') {
      assert.doesNotMatch(text, /^## (?:Proposal|Plan|Migration plan|Acceptance criteria|提案|计划|迁移计划|验收标准)\s*$/m);
    }
    for (const match of text.matchAll(/\[[^\]]*\]\(<?([^\s)>]+)>?\)/g)) {
      const target = match[1].split('#')[0];
      if (!target || /^[a-z][a-z0-9+.-]*:/i.test(target)) continue;
      assert.ok(existsSync(resolve(dirname(path), decodeURIComponent(target))), `Broken link: ${target}`);
    }
  });
}
