import assert from 'node:assert/strict';
import test from 'node:test';

import { checkExactTestReplay, completedCount, exactFilter, main, nativeRun, parseTestNames, runCli, runMain, assertExactSet } from '../../scripts/check-exact-test-replay.mjs';

const packagePath = '/private/source';
const expected = [
  'SwiftMutationTestingTests.CacheTests/testA()',
  'SwiftMutationTestingTests.CacheTests/testB()',
  'SwiftMutationTestingTests.OtherTests/testC()',
];

function completed(count) {
  return `Test run with ${count} test${count === 1 ? '' : 's'} in 1 suite passed after 0.001 seconds.\n`;
}

function successfulRun({ list = expected, completedCounts = {} } = {}) {
  const calls = [];
  const logs = new Map();
  return {
    calls,
    logs,
    run: async (executable, argv, options) => {
      calls.push({ executable, argv, options });
      if (argv.at(-1) === 'list') return { stdout: `${list.join('\n')}\n`, stderr: '', exitCode: 0 };
      const filter = argv[argv.indexOf('--filter') + 1];
      const identity = expected.find((candidate) => filter === candidate.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
      return { stdout: completed(completedCounts[identity] ?? 1), stderr: '', exitCode: 0 };
    },
    writeFile: async (filePath, value) => { logs.set(filePath, String(value)); },
  };
}

async function replay(fixture, options = {}) {
  return checkExactTestReplay({
    packagePath,
    run: fixture.run,
    makeRunDirectory: async () => '/private/exact-test-run',
    writeFile: fixture.writeFile,
    removeTree: async () => {},
    ...options,
  });
}

test('replays every listed test with an escaped collision-checked singleton filter and exact completion', async () => {
  const fixture = successfulRun();
  const receipt = await replay(fixture, { timeoutMs: 1234 });

  assert.deepEqual(receipt.executed, [...expected].sort());
  assert.equal(receipt.shards.every(({ count }) => count === 1), true);
  assert.deepEqual(fixture.calls.map(({ executable, argv }) => [executable, argv]), [
    ['swift', ['test', '--package-path', packagePath, 'list']],
    ['swift', ['test', '--package-path', packagePath, '--skip-build', '--no-parallel', '--filter', 'SwiftMutationTestingTests\\.CacheTests/testA\\(\\)']],
    ['swift', ['test', '--package-path', packagePath, '--skip-build', '--no-parallel', '--filter', 'SwiftMutationTestingTests\\.CacheTests/testB\\(\\)']],
    ['swift', ['test', '--package-path', packagePath, '--skip-build', '--no-parallel', '--filter', 'SwiftMutationTestingTests\\.OtherTests/testC\\(\\)']],
  ]);
  assert.equal(fixture.calls.every(({ options }) => options.timeoutMs === 1234), true);
  assert.equal(fixture.logs.size, expected.length);
});

for (const [name, completedCounts, pattern] of [
  ['absent completed count', { undefined: undefined }, /completed count|result/i],
  ['zero completed count', { [expected[0]]: 0 }, /exactly one|count/i],
  ['multiple completed count', { [expected[0]]: 2 }, /exactly one|count/i],
]) {
  test(`fails closed for ${name}`, async () => {
    const fixture = successfulRun({ completedCounts });
    if (name === 'absent completed count') fixture.run = async (executable, argv) => argv.at(-1) === 'list' ? { stdout: `${expected.join('\n')}\n`, stderr: '', exitCode: 0 } : { stdout: '', stderr: '', exitCode: 0 };
    await assert.rejects(() => replay(fixture), name === 'absent completed count' ? /completed test count|result/i : pattern);
  });
}

test('rejects a malformed listed identity instead of constructing an unanchored filter', async () => {
  const fixture = successfulRun({ list: ['SwiftMutationTestingTests.CacheTests/testA()|.*'] });
  await assert.rejects(() => replay(fixture), /list|malformed/i);
  assert.equal(fixture.calls.length, 1);
});

test('rejects duplicate listed identities before replay', async () => {
  const fixture = successfulRun({ list: [expected[0], expected[0]] });
  await assert.rejects(() => replay(fixture), /duplicate/i);
  assert.equal(fixture.calls.length, 1);
});

test('fails closed when preflight reports a filter collision', async () => {
  const fixture = successfulRun();
  await assert.rejects(() => replay(fixture, {
    matchListed: () => [expected[0], expected[1]],
  }), /collision|exactly one/i);
});

test('fails closed when a singleton shard exits unsuccessfully', async () => {
  const fixture = successfulRun();
  const original = fixture.run;
  fixture.run = async (...args) => args[1].includes(expected[0].replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
    ? { stdout: '', stderr: 'failed', exitCode: 1 }
    : original(...args);
  await assert.rejects(() => replay(fixture), /shard|failed/i);
});

test('fails closed when a singleton shard watchdog times out', async () => {
  const fixture = successfulRun();
  const original = fixture.run;
  fixture.run = async (...args) => {
    if (args[1].at(-1) === 'list') return original(...args);
    const error = new Error('timed out');
    error.code = 'ETIMEDOUT';
    throw error;
  };
  await assert.rejects(() => replay(fixture, { timeoutMs: 1 }), /timeout|watchdog/i);
});

test('decision helpers reject malformed inputs and set differences', () => {
  assert.throws(() => parseTestNames(null, 'list'), /malformed/);
  assert.throws(() => parseTestNames('noise', 'list'), /malformed/);
  assert.throws(() => exactFilter(null), /malformed/);
  assert.throws(() => completedCount(null, 'shard'), /malformed/);
  assert.throws(() => assertExactSet([expected[0]], [expected[1]]), /unknown.*omitted/);
  assert.throws(() => assertExactSet([expected[0]], [expected[0], expected[0]]), /mismatch/);
});

test('input and list failures remain fail closed', async () => {
  await assert.rejects(() => checkExactTestReplay(), /package path/);
  await assert.rejects(() => checkExactTestReplay({ packagePath, timeoutMs: 0 }), /watchdog/);
  await assert.rejects(() => checkExactTestReplay({ packagePath, run: async () => null }), /list failed/);
  await assert.rejects(() => checkExactTestReplay({ packagePath, run: async () => ({ exitCode: 1 }) }), /list failed/);
  const fixture = successfulRun({ list: [expected[0]] });
  fixture.run = async (...args) => {
    if (args[1].at(-1) === 'list') return { stdout: `${expected[0]}\n`, exitCode: 0 };
    throw new Error('unexpected');
  };
  await assert.rejects(() => replay(fixture), /unexpected/);
});

test('native runner covers success, process failure, and watchdog failure', async () => {
  assert.equal((await nativeRun(process.execPath, ['-e', 'process.stdout.write("ok"); process.stderr.write("warn")'], { timeoutMs: 1000 })).exitCode, 0);
  const failed = await nativeRun(process.execPath, ['-e', 'process.stdout.write("out"); process.stderr.write("bad"); process.exit(7)'], { timeoutMs: 1000 });
  assert.deepEqual(failed, { stdout: 'out', stderr: 'bad', exitCode: 7 });
  await assert.rejects(() => nativeRun(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { timeoutMs: 5 }), /watchdog/);
  assert.deepEqual(await nativeRun('/definitely/absent/task6', [], { timeoutMs: 1000 }), { stdout: '', stderr: '', exitCode: 1 });
  assert.deepEqual(await nativeRun('ignored', [], { timeoutMs: 1, runCommand: async () => { throw {}; } }), { stdout: '', stderr: '', exitCode: 1 });
});

test('missing shard streams are recorded as empty before failure', async () => {
  const fixture = successfulRun({ list: [expected[0]] });
  fixture.run = async (_executable, argv) => argv.at(-1) === 'list' ? { stdout: `${expected[0]}\n`, exitCode: 0 } : { exitCode: 1 };
  await assert.rejects(() => replay(fixture), /shard failed/);
  assert.equal([...fixture.logs.values()][0], '');
});

test('defaults write and remove private shard logs', async () => {
  const fixture = successfulRun({ list: [expected[0]] });
  const receipt = await checkExactTestReplay({ packagePath, run: fixture.run });
  assert.deepEqual(receipt.executed, [expected[0]]);
});

test('CLI validates shape and supports default output plus success and failure runners', async () => {
  await assert.rejects(() => runCli([]), /usage/);
  await assert.rejects(() => runCli(['--package-path', '']), /usage/);
  const output = [];
  const receipt = { expected: [], executed: [], shards: [] };
  assert.equal(await runCli(['--package-path', '.'], { realpath: async () => '/real', checkExactTestReplay: async ({ packagePath: value }) => { assert.equal(value, '/real'); return receipt; }, stdout: (value) => output.push(value) }), receipt);
  const originalWrite = process.stdout.write;
  process.stdout.write = () => true;
  try { assert.equal(await runCli(['--package-path', '.'], { realpath: async (value) => value, checkExactTestReplay: async () => receipt }), receipt); }
  finally { process.stdout.write = originalWrite; }
  assert.equal(await runMain(['--package-path', '.'], { realpath: async (value) => value, checkExactTestReplay: async () => receipt, stdout() {} }), 0);
  const errors = [];
  assert.equal(await runMain([], { stderr: (value) => errors.push(value) }), 1);
  const originalError = process.stderr.write;
  process.stderr.write = () => true;
  try { assert.equal(await runMain([]), 1); } finally { process.stderr.write = originalError; }
});

test('main dispatches only when invoked as the direct module', async () => {
  assert.equal(await main({ moduleURL: 'file:///owner.mjs', argv: ['node', '/other.mjs'] }), false);
  const oldExitCode = process.exitCode;
  try {
    assert.equal(await main({ moduleURL: 'file:///owner.mjs', argv: ['node', '/owner.mjs', '--package-path', '.'], runMainImpl: async (argv) => { assert.deepEqual(argv, ['--package-path', '.']); return 7; } }), true);
    assert.equal(process.exitCode, 7);
  } finally { process.exitCode = oldExitCode; }
});
