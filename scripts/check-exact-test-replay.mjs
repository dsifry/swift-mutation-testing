import { execFile as execFileCallback } from 'node:child_process';
import { realpath } from 'node:fs/promises';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);
const TEST_IDENTIFIER = /^(?<suite>[A-Za-z_][A-Za-z0-9_.]*)\/(?<test>[A-Za-z_][A-Za-z0-9_]*)(?:\(\))?$/;
const DEFAULT_TIMEOUT_MS = 10 * 60 * 1000;

function fail(message) {
  throw new Error(`exact test replay: ${message}`);
}

function parseTestNames(stdout, label, { requireAtLeastOne = true } = {}) {
  if (typeof stdout !== 'string') fail(`${label} output is malformed`);
  const names = stdout.split(/\r?\n/).map((line) => line.trim()).filter((line) => TEST_IDENTIFIER.test(line));
  if (requireAtLeastOne && names.length === 0) fail(`${label} output is malformed`);
  for (const name of names) {
    if (!TEST_IDENTIFIER.test(name)) fail(`${label} output is malformed`);
  }
  if (new Set(names).size !== names.length) fail(`${label} contains a duplicate test`);
  return names;
}

function sorted(values) {
  return [...values].sort((left, right) => left.localeCompare(right, 'en'));
}

function assertExactSet(expected, executed) {
  const expectedSet = new Set(expected);
  const executedSet = new Set(executed);
  const unknown = [...executedSet].filter((test) => !expectedSet.has(test));
  const omitted = [...expectedSet].filter((test) => !executedSet.has(test));
  if (unknown.length > 0 || omitted.length > 0 || expected.length !== executed.length) {
    fail(`exact test set mismatch (unknown: ${sorted(unknown).join(',') || 'none'}; omitted: ${sorted(omitted).join(',') || 'none'})`);
  }
}

function executedCount(stdout, label) {
  const matches = [...stdout.matchAll(/Test run with (\d+) tests? in \d+ suites? passed after /g)];
  if (matches.length !== 1) fail(`${label} has no authenticated executed count`);
  const count = Number(matches[0][1]);
  if (!Number.isSafeInteger(count) || count < 1) fail(`${label} has an invalid executed count`);
  return count;
}

async function nativeRun(executable, argv, { timeoutMs }) {
  try {
    const result = await execFile(executable, argv, { encoding: 'utf8', timeout: timeoutMs, maxBuffer: 10 * 1024 * 1024 });
    return { ...result, exitCode: 0 };
  } catch (error) {
    if (error.killed || error.code === 'ETIMEDOUT') {
      const timeout = new Error('watchdog timeout');
      timeout.code = 'ETIMEDOUT';
      throw timeout;
    }
    return { stdout: error.stdout ?? '', stderr: error.stderr ?? '', exitCode: error.code === 0 ? 1 : Number.isInteger(error.code) ? error.code : 1 };
  }
}

export async function checkExactTestReplay({ packagePath, run = nativeRun, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  if (typeof packagePath !== 'string' || packagePath.length === 0) fail('package path is required');
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) fail('watchdog timeout must be a positive safe integer');

  const expectedResult = await run('swift', ['test', '--package-path', packagePath, 'list'], { timeoutMs });
  if (!expectedResult || expectedResult.exitCode !== 0) fail('swift test list failed');
  const expected = parseTestNames(expectedResult.stdout, 'swift test list');
  const suites = sorted([...new Set(expected.map((name) => TEST_IDENTIFIER.exec(name).groups.suite))]);
  const executed = [];

  for (const suite of suites) {
    let result;
    try {
      result = await run('swift', ['test', '--package-path', packagePath, '--no-parallel', '--filter', suite], { timeoutMs });
    } catch (error) {
      if (error?.code === 'ETIMEDOUT') fail(`shard watchdog timeout: ${suite}`);
      throw error;
    }
    if (!result || result.exitCode !== 0) fail(`shard failed: ${suite}`);
    const selected = expected.filter((name) => TEST_IDENTIFIER.exec(name).groups.suite === suite);
    const emitted = parseTestNames(result.stdout, `shard ${suite}`, { requireAtLeastOne: false });
    if (emitted.length > 0 && JSON.stringify(sorted(emitted)) !== JSON.stringify(sorted(selected))) {
      fail(`shard ${suite} output does not match its selected test set`);
    }
    if (executedCount(result.stdout, `shard ${suite}`) !== selected.length) fail(`shard ${suite} executed count does not match its selected test set`);
    executed.push(...selected);
  }

  if (new Set(executed).size !== executed.length) fail('executed tests contain a duplicate test');
  assertExactSet(expected, executed);
  return Object.freeze({ expected: sorted(expected), executed: sorted(executed), suites });
}

export async function runCli(argv = process.argv.slice(2), dependencies = {}) {
  const { stdout = (value) => process.stdout.write(value), realpath: realpathImpl = realpath, checkExactTestReplay: checkExactTestReplayImpl = checkExactTestReplay } = dependencies;
  if (argv.length !== 2 || argv[0] !== '--package-path' || !argv[1]) {
    throw new Error('usage: check-exact-test-replay.mjs --package-path SOURCE_ROOT');
  }
  const packagePath = await realpathImpl(argv[1]);
  const receipt = await checkExactTestReplayImpl({ packagePath });
  stdout(`${JSON.stringify(receipt)}\n`);
  return receipt;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  runCli().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
