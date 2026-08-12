import assert from 'node:assert/strict';
import { execFile as execFileCallback } from 'node:child_process';
import { access, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);

const root = path.resolve(import.meta.dirname, '../..');

function exactEnvironment() {
  return {
    name: 'release-production',
    protection_rules: [{
      type: 'required_reviewers',
      prevent_self_review: true,
      reviewers: [{ type: 'User', reviewer: { login: 'release-maintainer' } }],
    }],
  };
}

function exactRuleset() {
  return {
    id: 17,
    name: 'immutable-release-tags',
    target: 'tag',
    enforcement: 'active',
    bypass_actors: [],
    conditions: { ref_name: { include: ['refs/tags/v*'], exclude: [] } },
    rules: [{ type: 'update' }, { type: 'deletion' }],
  };
}

function adapter({ environment = exactEnvironment(), rulesets = [exactRuleset()], after = {} } = {}) {
  const calls = [];
  let applied = false;
  return {
    calls,
    api: {
      async getEnvironment() { calls.push(['getEnvironment']); return applied && after.environment ? after.environment : environment; },
      async listRulesets() { calls.push(['listRulesets']); return applied && after.rulesets ? after.rulesets : rulesets; },
      async getRuleset(id) { calls.push(['getRuleset', id]); return (applied && after.ruleset) || rulesets.find((item) => item.id === id); },
      async putEnvironment(payload) { calls.push(['putEnvironment', payload]); applied = true; },
      async createRuleset(payload) { calls.push(['createRuleset', payload]); applied = true; return { id: 17 }; },
      async updateRuleset(id, payload) { calls.push(['updateRuleset', id, payload]); applied = true; },
      async getRepositoryPermission(login) { calls.push(['getRepositoryPermission', login]); return 'maintain'; },
    },
  };
}

async function owner() {
  return import('../../scripts/configure-release-controls.mjs');
}

test('coverage manifest is closed and the executable gate exists', async () => {
  const manifest = JSON.parse(await readFile(path.join(root, 'scripts/release-artifact-coverage-manifest.json')));
  assert.deepEqual(manifest, {
    includes: [
      'scripts/release-artifact.mjs',
      'scripts/build-release-candidate.mjs',
      'scripts/promote-release-candidate.mjs',
      'scripts/check-exact-test-replay.mjs',
      'scripts/configure-release-controls.mjs',
    ],
    thresholds: { lines: 100, branches: 100, functions: 100 },
    excludes: [],
  });
  await access(path.join(root, 'scripts/check-release-artifact-coverage.sh'));
});

test('coverage gate rejects a manifest owner absent from V8 output', async (t) => {
  const temporary = await mkdtemp(path.join(os.tmpdir(), 'task6-coverage-manifest-'));
  t.after(async () => (await import('node:fs/promises')).rm(temporary, { recursive: true, force: true }));
  const manifestPath = path.join(temporary, 'manifest.json');
  const absentOwner = path.join(root, 'scripts/owner-not-imported.mjs');
  await writeFile(absentOwner, 'export const value = true;\n');
  t.after(async () => (await import('node:fs/promises')).rm(absentOwner, { force: true }));
  await writeFile(manifestPath, JSON.stringify({ includes: ['scripts/owner-not-imported.mjs'], thresholds: { lines: 100, branches: 100, functions: 100 }, excludes: [] }));
  await assert.rejects(() => execFile(path.join(root, 'scripts/check-release-artifact-coverage.sh'), [], { cwd: root, env: { ...process.env, RELEASE_ARTIFACT_COVERAGE_MANIFEST: manifestPath } }), /coverage owner|absent|missing/i);
});

test('default check accepts exact controls without mutation', async () => {
  const { configureReleaseControls } = await owner();
  const fixture = adapter();
  const result = await configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', mode: 'check', api: fixture.api });
  assert.deepEqual(result, { repository: 'dsifry/swift-mutation-testing', environment: 'exact', ruleset: 'exact', changed: false });
  assert.equal(fixture.calls.some(([name]) => name.startsWith('put') || name.startsWith('create') || name.startsWith('update')), false);
});

test('check rejects empty controls without mutation', async () => {
  const { configureReleaseControls } = await owner();
  const fixture = adapter({ environment: null, rulesets: [] });
  await assert.rejects(() => configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', mode: 'check', api: fixture.api }), /repository controls/i);
  assert.equal(fixture.calls.some(([name]) => name.startsWith('put') || name.startsWith('create') || name.startsWith('update')), false);
});

test('check rejects weaker and malformed controls', async () => {
  const { configureReleaseControls } = await owner();
  for (const fixture of [
    adapter({ environment: { ...exactEnvironment(), protection_rules: [] } }),
    adapter({ rulesets: [{ ...exactRuleset(), enforcement: 'evaluate' }] }),
    adapter({ rulesets: [{ ...exactRuleset(), bypass_actors: [{}] }] }),
    adapter({ rulesets: [{ ...exactRuleset(), conditions: {} }] }),
    adapter({ environment: {} }),
    adapter({ environment: { ...exactEnvironment(), name: 'other' } }),
    adapter({ environment: { ...exactEnvironment(), protection_rules: [{ ...exactEnvironment().protection_rules[0], prevent_self_review: false }] } }),
    adapter({ environment: { ...exactEnvironment(), protection_rules: [{ ...exactEnvironment().protection_rules[0], reviewers: [] }] } }),
    adapter({ environment: { ...exactEnvironment(), protection_rules: [{ ...exactEnvironment().protection_rules[0], reviewers: [{ type: 'Team', reviewer: { login: 'release-maintainer' } }] }] } }),
    adapter({ rulesets: null }),
    adapter({ rulesets: [{ ...exactRuleset(), target: 'branch' }] }),
    adapter({ rulesets: [{ ...exactRuleset(), bypass_actors: null }] }),
    adapter({ rulesets: [{ ...exactRuleset(), conditions: { ref_name: { include: [], exclude: [] } } }] }),
    adapter({ rulesets: [{ ...exactRuleset(), conditions: { ref_name: { include: ['refs/tags/v*'], exclude: ['refs/tags/v0*'] } } }] }),
    adapter({ rulesets: [{ ...exactRuleset(), rules: [{ type: 'update' }] }] }),
    adapter({ rulesets: [{ ...exactRuleset(), rules: [{ type: 'update' }, { type: 'creation' }] }] }),
  ]) {
    await assert.rejects(() => configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', mode: 'check', api: fixture.api }), /repository controls/i);
  }
});

test('rejects malformed and duplicate ruleset observations and a wrong apply reviewer', async () => {
  const { configureReleaseControls } = await owner();
  const malformed = adapter();
  malformed.api.listRulesets = async () => ({});
  await assert.rejects(() => configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', api: malformed.api }), /malformed/i);
  const duplicate = adapter({ rulesets: [exactRuleset(), { ...exactRuleset(), id: 18 }] });
  await assert.rejects(() => configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', api: duplicate.api }), /exactly one/i);
  await assert.rejects(() => configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', mode: 'apply', maintainer: 'other', api: adapter().api }), /post-apply/i);
  await assert.rejects(() => configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', mode: 'apply', maintainer: '', api: adapter().api }), /maintainer/i);
  await assert.rejects(() => configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', mode: 'check' }), /adapter/i);
  await assert.rejects(() => configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', mode: 'check', api: {} }), /authority/i);
});

test('apply creates missing controls and requires an exact reread', async () => {
  const { configureReleaseControls } = await owner();
  const fixture = adapter({ environment: null, rulesets: [], after: { environment: exactEnvironment(), rulesets: [exactRuleset()], ruleset: exactRuleset() } });
  const result = await configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', mode: 'apply', maintainer: 'release-maintainer', api: fixture.api });
  assert.equal(result.changed, true);
  assert.equal(fixture.calls.filter(([name]) => name === 'putEnvironment').length, 1);
  assert.equal(fixture.calls.filter(([name]) => name === 'createRuleset').length, 1);
});

test('apply updates weak controls and exact retry is a no-op', async () => {
  const { configureReleaseControls } = await owner();
  const weakEnvironment = { name: 'release-production', protection_rules: [] };
  const weakRuleset = { ...exactRuleset(), enforcement: 'evaluate' };
  const fixture = adapter({ environment: weakEnvironment, rulesets: [weakRuleset], after: { environment: exactEnvironment(), rulesets: [exactRuleset()], ruleset: exactRuleset() } });
  assert.equal((await configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', mode: 'apply', maintainer: 'release-maintainer', api: fixture.api })).changed, true);
  assert.equal(fixture.calls.filter(([name]) => name === 'updateRuleset').length, 1);

  const retry = adapter();
  assert.equal((await configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', mode: 'apply', maintainer: 'release-maintainer', api: retry.api })).changed, false);
  assert.equal(retry.calls.some(([name]) => name.startsWith('put') || name.startsWith('create') || name.startsWith('update')), false);
});

test('apply fails on partial mutation, weaker reread, lost authority, wrong repository, and invalid mode', async () => {
  const { configureReleaseControls } = await owner();
  const failed = adapter({ environment: null, rulesets: [] });
  failed.api.putEnvironment = async () => { throw new Error('forbidden'); };
  await assert.rejects(() => configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', mode: 'apply', maintainer: 'release-maintainer', api: failed.api }), /forbidden/);

  const weakReread = adapter({ environment: null, rulesets: [], after: { environment: exactEnvironment(), rulesets: [], ruleset: null } });
  await assert.rejects(() => configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', mode: 'apply', maintainer: 'release-maintainer', api: weakReread.api }), /repository controls/i);

  const lost = adapter();
  lost.api.getEnvironment = async () => { throw new Error('requires admin'); };
  await assert.rejects(() => configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', mode: 'check', api: lost.api }), /requires admin/);
  await assert.rejects(() => configureReleaseControls({ repository: 'other/repo', mode: 'check', api: adapter().api }), /repository/i);
  await assert.rejects(() => configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', mode: 'other', api: adapter().api }), /mode/i);
});

test('check and apply reject an approval reviewer without maintainer authority before mutation', async () => {
  const { configureReleaseControls } = await owner();
  for (const mode of ['check', 'apply']) {
    const fixture = adapter();
    fixture.api.getRepositoryPermission = async () => 'push';
    await assert.rejects(() => configureReleaseControls({ repository: 'dsifry/swift-mutation-testing', mode, maintainer: mode === 'apply' ? 'release-maintainer' : undefined, api: fixture.api }), /maintainer|admin|authority|weaker.*policy/i);
    assert.equal(fixture.calls.some(([name]) => name.startsWith('put') || name.startsWith('create') || name.startsWith('update')), false);
  }
});

test('release docs order checksum verification after extraction and provide executable lifecycle commands', async () => {
  const installation = await readFile(path.join(root, 'Docs/INSTALLATION.MD'), 'utf8');
  assert.ok(installation.indexOf('tar -xzf') < installation.indexOf('shasum -a 256 -c'));
  const building = await readFile(path.join(root, 'Docs/BUILDING.md'), 'utf8');
  for (const command of ['gh workflow run release-candidate.yml', 'gh run download', 'git tag -s', 'gh workflow run release.yml', 'gh run rerun']) assert.match(building, new RegExp(command.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});

test('CLI defaults to check, requires explicit apply maintainer, and emits JSON', async () => {
  const { runCli, runMain } = await owner();
  const output = [];
  const fixture = adapter();
  await runCli(['--repository', 'dsifry/swift-mutation-testing', '--check'], { api: fixture.api, stdout: (value) => output.push(value) });
  assert.match(output.join(''), /"changed":false/);
  await assert.rejects(() => runCli(['--repository', 'dsifry/swift-mutation-testing', '--apply'], { api: fixture.api }), /maintainer/i);
  await assert.rejects(() => runCli([], { api: fixture.api }), /usage/i);
  await assert.rejects(() => runCli(['--repository']), /missing value/i);
  await assert.rejects(() => runCli(['--bogus']), /unknown argument/i);
  await assert.rejects(() => runCli(['--check', '--apply', '--repository', 'dsifry/swift-mutation-testing'], { api: fixture.api }), /exactly one/i);
  assert.equal((await runCli(['--repository', 'dsifry/swift-mutation-testing'], { api: fixture.api, stdout() {} })).changed, false);
  assert.equal((await runCli(['--repository', 'dsifry/swift-mutation-testing'], { createNativeGitHubAdapter: () => fixture.api, stdout() {} })).changed, false);
  const originalWrite = process.stdout.write;
  process.stdout.write = () => true;
  try {
    assert.equal((await runCli(['--repository', 'dsifry/swift-mutation-testing'], { api: fixture.api })).changed, false);
  } finally {
    process.stdout.write = originalWrite;
  }
  const errors = [];
  assert.equal(await runMain([], { api: fixture.api, stderr: (value) => errors.push(value) }), 1);
  assert.match(errors.join(''), /usage/i);
  assert.equal(await runMain(['--repository', 'dsifry/swift-mutation-testing'], { api: fixture.api, stdout() {} }), 0);
  const originalErrorWrite = process.stderr.write;
  process.stderr.write = () => true;
  try {
    assert.equal(await runMain([], { api: fixture.api }), 1);
  } finally {
    process.stderr.write = originalErrorWrite;
  }
});

test('native GitHub adapter issues exact API reads and mutations', async () => {
  const { createNativeGitHubAdapter } = await owner();
  assert.equal(typeof createNativeGitHubAdapter('dsifry/swift-mutation-testing').listRulesets, 'function');
  const calls = [];
  const responses = [
    new Error('not found'),
    exactEnvironment(),
    [exactRuleset()],
    exactRuleset(),
    { permission: 'admin' },
    { id: 42 },
    null,
    { id: 17 },
    exactRuleset(),
  ];
  responses[0].code = 1;
  const runCommand = async (...args) => {
    calls.push(args);
    const response = responses.shift();
    if (response instanceof Error) throw response;
    return { stdout: response === null ? '' : JSON.stringify(response) };
  };
  const api = createNativeGitHubAdapter('dsifry/swift-mutation-testing', 'release-maintainer', { runCommand });
  assert.equal(await api.getEnvironment(), null);
  assert.deepEqual(await api.getEnvironment(), exactEnvironment());
  assert.deepEqual(await api.listRulesets(), [exactRuleset()]);
  assert.deepEqual(await api.getRuleset(17), exactRuleset());
  assert.equal(await api.getRepositoryPermission('release-maintainer'), 'admin');
  await api.putEnvironment({ maintainer: 'release-maintainer' });
  await api.createRuleset(exactRuleset());
  await api.updateRuleset(17, exactRuleset());
  assert.equal(calls.length, 9);
  assert.match(calls[6][1].join(' '), /--input -/);

  const bad = createNativeGitHubAdapter('dsifry/swift-mutation-testing', 'release-maintainer', { runCommand: async () => ({ stdout: '{}' }) });
  await assert.rejects(() => bad.putEnvironment({ maintainer: 'release-maintainer' }), /identity/i);
  const lost = createNativeGitHubAdapter('dsifry/swift-mutation-testing', 'release-maintainer', { runCommand: async () => { const error = new Error('lost'); error.code = 2; throw error; } });
  await assert.rejects(() => lost.getEnvironment(), /lost/);
});

test('direct CLI failure exits nonzero', async () => {
  await assert.rejects(() => execFile(process.execPath, ['scripts/configure-release-controls.mjs'], { cwd: root }), (error) => {
    assert.match(error.stderr, /usage/i);
    return true;
  });
});
