import assert from 'node:assert/strict';
import test from 'node:test';

import { checkExactTestReplay } from '../../scripts/check-exact-test-replay.mjs';

const packagePath = '/private/source';
const expected = [
  'SwiftMutationTestingTests.CacheTests/testA',
  'SwiftMutationTestingTests.CacheTests/testB',
  'SwiftMutationTestingTests.OtherTests/testC',
];

function xunit(names) {
  return Buffer.from(`<?xml version="1.0"?><testsuite>${names.map((name) => {
    const [classname, testName] = name.split('/');
    return `<testcase classname="${classname}" name="${testName}"/>`;
  }).join('')}</testsuite>`);
}

function successfulRun({ list = expected, shards = {} } = {}) {
  const calls = [];
  const xunitFiles = new Map();
  return {
    calls,
    xunitFiles,
    run: async (executable, argv, options) => {
      calls.push({ executable, argv, options });
      if (argv.at(-1) === 'list') return { stdout: `${list.join('\n')}\n`, stderr: '', exitCode: 0 };
      const suite = argv[argv.indexOf('--filter') + 1];
      const executed = shards[suite] ?? expected.filter((name) => name.startsWith(suite));
      xunitFiles.set(argv[argv.indexOf('--xunit-output') + 1], xunit(executed));
      return { stdout: '', stderr: '', exitCode: 0 };
    },
    readFile: async (filePath) => {
      if (!xunitFiles.has(filePath)) {
        const error = new Error('missing xUnit');
        error.code = 'ENOENT';
        throw error;
      }
      return xunitFiles.get(filePath);
    },
  };
}

async function replay(fixture, options = {}) {
  return checkExactTestReplay({
    packagePath,
    run: fixture.run,
    readFile: fixture.readFile,
    makeXunitDirectory: async () => '/private/xunit-run',
    removeTree: async () => {},
    ...options,
  });
}

test('replays each stable suite exactly once with a fresh xUnit result and no parallel execution', async () => {
  const fixture = successfulRun();
  const receipt = await replay(fixture, { timeoutMs: 1234 });

  assert.deepEqual(receipt, {
    expected: [...expected].sort(),
    executed: [...expected].sort(),
    suites: ['SwiftMutationTestingTests.CacheTests', 'SwiftMutationTestingTests.OtherTests'],
  });
  assert.deepEqual(fixture.calls.map(({ executable, argv }) => [executable, argv.slice(0, argv.indexOf('--xunit-output') < 0 ? -1 : -1)]), [
    ['swift', ['test', '--package-path', packagePath]],
    ['swift', ['test', '--package-path', packagePath, '--no-parallel', '--filter', 'SwiftMutationTestingTests.CacheTests', '--xunit-output']],
    ['swift', ['test', '--package-path', packagePath, '--no-parallel', '--filter', 'SwiftMutationTestingTests.OtherTests', '--xunit-output']],
  ]);
  assert.equal(fixture.calls.every(({ options }) => options.timeoutMs === 1234), true);
});

test('fails closed when a shard has no xUnit result', async () => {
  const fixture = successfulRun();
  fixture.readFile = async () => { const error = new Error('missing'); error.code = 'ENOENT'; throw error; };
  await assert.rejects(() => replay(fixture), /xUnit|result/i);
});

for (const [name, shards, pattern] of [
  ['same-count wrong identity', { 'SwiftMutationTestingTests.CacheTests': [expected[0], 'SwiftMutationTestingTests.OtherTests/testC'] }, /exact.*set|unexpected|omitted/i],
  ['duplicate identity', { 'SwiftMutationTestingTests.CacheTests': [expected[0], expected[0], expected[1]] }, /duplicate/i],
  ['unexpected identity', { 'SwiftMutationTestingTests.CacheTests': [expected[0], expected[1], 'SwiftMutationTestingTests.CacheTests/testUnknown'] }, /unexpected|canonical/i],
]) {
  test(`fails closed for ${name} in a production xUnit result`, async () => {
    await assert.rejects(() => replay(successfulRun({ shards })), pattern);
  });
}

test('fails closed when a shard fails', async () => {
  const fixture = successfulRun();
  const original = fixture.run;
  fixture.run = async (...args) => args[1][args[1].indexOf('--filter') + 1] === 'SwiftMutationTestingTests.CacheTests'
    ? { stdout: '', stderr: 'failed', exitCode: 1 }
    : original(...args);
  await assert.rejects(() => replay(fixture), /shard|failed/i);
});

test('fails closed when a bounded shard watchdog times out', async () => {
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

test('rejects malformed swift test list output before running a shard', async () => {
  const fixture = successfulRun({ list: ['not a test identifier'] });
  await assert.rejects(() => replay(fixture), /list|malformed/i);
  assert.equal(fixture.calls.length, 1);
});
