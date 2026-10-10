import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { cpSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { before, after, test } from 'node:test';

const root = fileURLToPath(new URL('../', import.meta.url));
const baseline = JSON.parse(readFileSync(join(root, 'patches/dsh-subagent-child-setup-v1.baseline.json'), 'utf8'));
const patch = join(root, 'patches/dsh-subagent-child-setup-v1.patch');
const scratch = mkdtempSync(join(tmpdir(), 'dsh-child-setup-test-'));
let pristine;
let candidate;
const run = (command, args) => {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 120000 });
  assert.equal(result.status, 0, `${command}: ${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  return result.stdout + result.stderr;
};
const digest = file => createHash('sha256').update(readFileSync(file)).digest('hex');
before(() => {
  if (process.env.SUBAGENT_PRISTINE_DIR) {
    pristine = process.env.SUBAGENT_PRISTINE_DIR;
  } else {
    const name = run('npm', ['pack', `${baseline.package}@${baseline.version}`, '--ignore-scripts', '--silent', '--pack-destination', scratch]).trim();
    run('tar', ['-xzf', join(scratch, name), '-C', scratch]);
    pristine = join(scratch, 'package');
  }
  candidate = join(scratch, 'patched');
  cpSync(pristine, candidate, { recursive: true });
});
after(() => {
  assert.ok(scratch.startsWith(join(tmpdir(), 'dsh-child-setup-test-')));
  rmSync(scratch, { recursive: true, force: true });
});

test('patch baseline tracks the image version and applies exactly to pristine npm bytes', () => {
  const dockerfile = readFileSync(join(root, 'Dockerfile'), 'utf8');
  assert.equal(dockerfile.match(/^ARG DSH_VERSION=(.+)$/m)[1], baseline.version);
  assert.equal(JSON.parse(readFileSync(join(pristine, 'package.json'), 'utf8')).version, baseline.version);
  const targets = [...readFileSync(patch, 'utf8').matchAll(/^\+\+\+ b\/(.+)$/gm)].map(match => match[1]);
  assert.deepEqual(targets, Object.keys(baseline.files));
  for (const [file, hashes] of Object.entries(baseline.files)) {
    assert.equal(digest(join(pristine, file)), hashes.beforeSha256, file);
  }
  const args = ['--batch', '--fuzz=0', '-p1', '-d', candidate, '-i', patch];
  assert.doesNotMatch(run('patch', ['--dry-run', ...args]), /offset|fuzz|FAILED|reject/i);
  assert.doesNotMatch(run('patch', args), /offset|fuzz|FAILED|reject/i);
  for (const [file, hashes] of Object.entries(baseline.files)) {
    assert.equal(digest(join(candidate, file)), hashes.afterSha256, file);
    if (file.endsWith('.js')) run(process.execPath, ['--check', join(candidate, file)]);
  }
});

// Execute unchanged method/setup bodies from both patched distribution forms.
// Dependency stubs delimit this check: it verifies ordering and protocol, not AgentLoop integration.
function runtime(file) {
  const text = readFileSync(join(candidate, file), 'utf8');
  const from = text.indexOf('/** Versioned, native, pre-publication');
  const to = text.indexOf('resolveMaxDepth(configured)', from);
  assert.ok(from >= 0 && to > from);
  const Type = new Function(`return class { ${text.slice(from, to)} }`)();
  const instance = new Type();
  instance.childSetupHooks = new Set();
  instance.ctx = { effect(factory) {
    const iterator = factory();
    const cleanup = iterator.next().value;
    return () => { cleanup(); iterator.next(); };
  } };
  return instance;
}
function setup(file, deps) {
  const text = readFileSync(join(candidate, file), 'utf8');
  const from = text.indexOf('const setup = async (childCtx, child) => {');
  const to = text.indexOf('const handle = create ===', from);
  assert.ok(from >= 0 && to > from);
  return new Function('create', 'parent', 'inputs', 'childId', 'applyChildComposition', 'appendDelegatedPolicyOverrides', 'attachStructuredRuntime', `let structured; ${text.slice(from, to)} return { setup, structured: () => structured };`)
    .call(deps.manager, deps.create, deps.parent, deps.inputs, 'child', deps.compose, deps.policies, deps.structured);
}
for (const [runtimeFile, managerFile] of [['lib/index.js', 'lib/index.js'], ['lib/types/index.js', 'lib/types/manager.js']]) {
  test(`${runtimeFile}: setup awaits in order and defers synchronous commits`, async () => {
    const host = runtime(runtimeFile);
    assert.equal(host.childSetupVersion, 1);
    const calls = [];
    host.registerChildSetup(async payload => {
      calls.push(payload.source);
      await Promise.resolve();
      return { commit() { calls.push('commit'); } };
    });
    host.registerChildSetup(() => { calls.push('second'); });
    const prepared = await host.prepareChildSetup({ source: 'startup', signal: new AbortController().signal });
    assert.deepEqual(calls, ['startup', 'second']);
    prepared.commit();
    assert.deepEqual(calls, ['startup', 'second', 'commit']);
  });
  test(`${runtimeFile}: cancellation and owner removal fail before publication`, async () => {
    for (const boundary of ['before', 'during', 'commit', 'owner-during', 'owner-commit']) {
      const host = runtime(runtimeFile);
      const controller = new AbortController();
      let committed = false;
      let stop;
      stop = host.registerChildSetup(async () => {
        if (boundary === 'during') controller.abort();
        if (boundary === 'owner-during') stop();
        return { commit() { committed = true; } };
      });
      if (boundary === 'before') controller.abort();
      if (['before', 'during', 'owner-during'].includes(boundary)) {
        await assert.rejects(host.prepareChildSetup({ signal: controller.signal }));
      } else {
        const prepared = await host.prepareChildSetup({ signal: controller.signal });
        if (boundary === 'commit') controller.abort(); else stop();
        assert.throws(() => prepared.commit());
      }
      assert.equal(committed, false, boundary);
    }
  });
  test(`${runtimeFile}: malformed callbacks and asynchronous commits are rejected`, async () => {
    const host = runtime(runtimeFile);
    assert.throws(() => host.registerChildSetup(null), /callback/);
    for (const result of [null, {}, 1]) {
      const stop = host.registerChildSetup(() => result);
      await assert.rejects(host.prepareChildSetup({ signal: new AbortController().signal }), /synchronous commit/);
      stop();
    }
    const stop = host.registerChildSetup(() => ({ commit: async () => {} }));
    const prepared = await host.prepareChildSetup({ signal: new AbortController().signal });
    assert.throws(() => prepared.commit(), /synchronous/);
    stop();
  });
  const flow = (create, events = [], header = 'fallback', overrides = {}) => {
    const calls = [];
    const controller = new AbortController();
    const parent = { id: 'lead' };
    const child = { session: {
      header: { agentPreset: header }, inheritedEventCount: 7,
      append: type => calls.push(type),
      snapshotEvents(offset) { assert.equal(offset, 7); return events; },
    } };
    const ctx = { get(name) {
      if (name === 'workingDirectory') return { set: async () => { calls.push('cwd'); } };
      if (name === 'agentPresets') return { mount: async (_ctx, id) => { calls.push(`mount:${id}`); if (overrides.abortMount) controller.abort(); } };
    } };
    const prepared = { commit() { calls.push('commit'); } };
    const deps = {
      create, parent, inputs: { signal: controller.signal, composition: {}, outputSchema: {} },
      manager: { host: { async prepareChildSetup(payload) {
        assert.equal(payload.child, child); assert.equal(payload.parent, parent);
        calls.push(payload.source); return prepared;
      } } },
      compose: () => calls.push('compose'), policies: () => calls.push('policies'),
      structured: () => { calls.push('structured'); return 'attachment'; },
    };
    return { ...setup(managerFile, deps), calls, child, ctx, prepared };
  };
  test(`${managerFile}: fresh setup preserves cwd and structured output before returning commit`, async () => {
    const f = flow({ descriptor: {}, delegatedPolicies: {}, cwd: '/tmp' });
    assert.equal(await f.setup(f.ctx, f.child), f.prepared);
    assert.deepEqual(f.calls, ['subagent/descriptor', 'policies', 'cwd', 'compose', 'structured', 'startup']);
    assert.equal(f.structured(), 'attachment');
    f.prepared.commit();
    assert.equal(f.calls.at(-1), 'commit');
  });
  test(`${managerFile}: cold resume restores own latest identity, without a selecting plugin`, async () => {
    const f = flow(undefined, [{ type: 'agent-preset/selected', data: { agentPreset: 'old' } }, { type: 'agent-preset/selected', data: { agentPreset: 'beta' } }]);
    await f.setup(f.ctx, f.child);
    assert.deepEqual(f.calls, ['compose', 'mount:beta', 'structured', 'resume']);
    const fallback = flow(undefined);
    await fallback.setup(fallback.ctx, fallback.child);
    assert.deepEqual(fallback.calls, ['compose', 'mount:fallback', 'structured', 'resume']);
  });
  test(`${managerFile}: invalid persisted selection and cancelled mount never invoke hooks`, async () => {
    for (const f of [flow(undefined, [{ type: 'agent-preset/selected', data: { agentPreset: '' } }]), flow(undefined, [], 'fallback', { abortMount: true })]) {
      await assert.rejects(f.setup(f.ctx, f.child));
      assert.ok(!f.calls.includes('resume'));
    }
  });
}
