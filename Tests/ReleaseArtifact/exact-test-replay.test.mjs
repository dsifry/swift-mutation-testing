import assert from 'node:assert/strict';
import test from 'node:test';

import { checkExactTestReplay } from '../../scripts/check-exact-test-replay.mjs';

const packagePath = '/private/source';
const expected = [
  'SwiftMutationTestingTests.CacheTests/testA',
  'SwiftMutationTestingTests.CacheTests/testB',
  'SwiftMutationTestingTests.OtherTests/testC',
];

function successfulRun({ list = expected, shards = {} } = {}) {
  const calls = [];
  return {
    calls,
    run: async (executable, argv, options) => {
      calls.push({ executable, argv, options });
      if (argv.at(-1) === 'list') return { stdout: `${list.join('\n')}\n`, stderr: '', exitCode: 0 };
      const filter = argv.at(-1);
      const executed = shards[filter] ?? expected.filter((name) => name.startsWith(filter));
      return {
        stdout: `${executed.join('\n')}\nTest run with ${executed.length} test${executed.length === 1 ? '' : 's'} in 1 suite passed after 0.001 seconds.\n`,
        stderr: '',
        exitCode: 0,
      };
    },
  };
}

test('replays each stable suite exactly once without parallel execution', async () => {
  const fixture = successfulRun();

  const receipt = await checkExactTestReplay({ packagePath, run: fixture.run, timeoutMs: 1234 });

  assert.deepEqual(receipt, {
    expected: [...expected].sort(),
    executed: [...expected].sort(),
    suites: ['SwiftMutationTestingTests.CacheTests', 'SwiftMutationTestingTests.OtherTests'],
  });
  assert.deepEqual(fixture.calls.map(({ executable, argv }) => [executable, argv]), [
    ['swift', ['test', '--package-path', packagePath, 'list']],
    ['swift', ['test', '--package-path', packagePath, '--no-parallel', '--filter', 'SwiftMutationTestingTests.CacheTests']],
    ['swift', ['test', '--package-path', packagePath, '--no-parallel', '--filter', 'SwiftMutationTestingTests.OtherTests']],
  ]);
  assert.equal(fixture.calls.every(({ options }) => options.timeoutMs === 1234), true);
});

test('fails closed when a production shard result has no authenticated executed count', async () => {
  const fixture = successfulRun();
  fixture.run = async (executable, argv, options) => {
    if (argv.at(-1) === 'list') return { stdout: `${expected.join('\n')}\n`, stderr: '', exitCode: 0 };
    return { stdout: '', stderr: '', exitCode: 0 };
  };

  await assert.rejects(() => checkExactTestReplay({ packagePath, run: fixture.run }), /executed count|result/i);
});

test('accepts a production-form shard summary only when its independently reported count matches the selected suite', async () => {
  const fixture = successfulRun();
  fixture.run = async (executable, argv, options) => {
    if (argv.at(-1) === 'list') return { stdout: `${expected.join('\n')}\n`, stderr: '', exitCode: 0 };
    const suite = argv.at(-1);
    const count = expected.filter((name) => name.startsWith(suite)).length;
    return { stdout: `Test run with ${count} test${count === 1 ? '' : 's'} in 1 suite passed after 0.001 seconds.\n`, stderr: '', exitCode: 0 };
  };

  const receipt = await checkExactTestReplay({ packagePath, run: fixture.run });
  assert.deepEqual(receipt.executed, [...expected].sort());
});

for (const [name, options, pattern] of [
  ['duplicate executed test', { shards: { 'SwiftMutationTestingTests.CacheTests': [expected[0], expected[0], expected[1]] } }, /duplicate/i],
  ['omitted executed test', { shards: { 'SwiftMutationTestingTests.CacheTests': [expected[0]] } }, /exact.*set|omitted/i],
  ['unknown executed test', { shards: { 'SwiftMutationTestingTests.CacheTests': [expected[0], expected[1], 'SwiftMutationTestingTests.CacheTests/testUnknown'] } }, /exact.*set|unknown/i],
]) {
  test(`fails closed for ${name}`, async () => {
    const fixture = successfulRun(options);
    await assert.rejects(() => checkExactTestReplay({ packagePath, run: fixture.run }), pattern);
  });
}

test('fails closed when a shard fails', async () => {
  const fixture = successfulRun();
  fixture.run = async (executable, argv, options) => {
    if (argv.at(-1) === 'list') return { stdout: `${expected.join('\n')}\n`, stderr: '', exitCode: 0 };
    if (argv.at(-1) === 'SwiftMutationTestingTests.CacheTests') return { stdout: '', stderr: 'failed', exitCode: 1 };
    return { stdout: `${expected[2]}\n`, stderr: '', exitCode: 0 };
  };
  await assert.rejects(() => checkExactTestReplay({ packagePath, run: fixture.run }), /shard|failed/i);
});

test('fails closed when a bounded shard watchdog times out', async () => {
  const fixture = successfulRun();
  fixture.run = async (executable, argv) => {
    if (argv.at(-1) === 'list') return { stdout: `${expected.join('\n')}\n`, stderr: '', exitCode: 0 };
    const error = new Error('timed out');
    error.code = 'ETIMEDOUT';
    throw error;
  };
  await assert.rejects(() => checkExactTestReplay({ packagePath, run: fixture.run, timeoutMs: 1 }), /timeout|watchdog/i);
});

test('rejects malformed swift test list output before running a shard', async () => {
  const fixture = successfulRun({ list: ['not a test identifier'] });
  await assert.rejects(() => checkExactTestReplay({ packagePath, run: fixture.run }), /list|malformed/i);
  assert.equal(fixture.calls.length, 1);
});
