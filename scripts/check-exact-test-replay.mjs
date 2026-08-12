import { execFile as execFileCallback } from 'node:child_process';
import { mkdtemp, realpath, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);
const TEST_IDENTIFIER = /^(?<suite>[A-Za-z_][A-Za-z0-9_.]*)\/(?<test>[A-Za-z_][A-Za-z0-9_]*)(?:\(\))?$/;
const DEFAULT_TIMEOUT_MS = 10 * 60 * 1000;

function fail(message) {
  throw new Error(`exact test replay: ${message}`);
}

function parseTestNames(stdout, label) {
  if (typeof stdout !== 'string') fail(`${label} output is malformed`);
  const names = stdout.split(/\r?\n/).map((line) => line.trim()).filter((line) => TEST_IDENTIFIER.test(line));
  if (names.length === 0) fail(`${label} output is malformed`);
  if (new Set(names).size !== names.length) fail(`${label} contains a duplicate test`);
  return names;
}

function exactFilter(identity) {
  if (typeof identity !== 'string' || !TEST_IDENTIFIER.test(identity)) fail('listed test identity is malformed');
  return identity.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function completedCount(stdout, label) {
  if (typeof stdout !== 'string') fail(`${label} output is malformed`);
  const matches = [...stdout.matchAll(/Test run with (\d+) tests? in \d+ suites? passed after /g)];
  if (matches.length !== 1) fail(`${label} has no independently completed test count`);
  const count = Number(matches[0][1]);
  if (!Number.isSafeInteger(count) || count !== 1) fail(`${label} must complete exactly one test`);
  return count;
}

function sorted(values) {
  return [...values].sort((left, right) => left.localeCompare(right, 'en'));
}

function assertExactSet(expected, executed) {
  const expectedSet = new Set(expected);
  const executedSet = new Set(executed);
  const unknown = [...executedSet].filter((identity) => !expectedSet.has(identity));
  const omitted = [...expectedSet].filter((identity) => !executedSet.has(identity));
  if (unknown.length || omitted.length || expected.length !== executed.length) {
    fail(`exact test set mismatch (unknown: ${sorted(unknown).join(',') || 'none'}; omitted: ${sorted(omitted).join(',') || 'none'})`);
  }
}

async function nativeRun(executable, argv, { timeoutMs }) {
  try {
    const { stdout = '', stderr = '' } = await execFile(executable, argv, { encoding: 'utf8', timeout: timeoutMs, maxBuffer: 10 * 1024 * 1024 });
    return { stdout, stderr, exitCode: 0 };
  } catch (error) {
    if (error.killed || error.code === 'ETIMEDOUT') {
      const timeout = new Error('watchdog timeout');
      timeout.code = 'ETIMEDOUT';
      throw timeout;
    }
    return { stdout: error.stdout ?? '', stderr: error.stderr ?? '', exitCode: Number.isInteger(error.code) ? error.code : 1 };
  }
}

export async function checkExactTestReplay({ packagePath, run = nativeRun, timeoutMs = DEFAULT_TIMEOUT_MS, makeRunDirectory = () => mkdtemp(path.join(os.tmpdir(), 'exact-test-replay-')), writeFile: writeFileImpl = writeFile, removeTree = (directory) => rm(directory, { recursive: true, force: true }), matchListed = (filter, identities) => {
  const expression = new RegExp(filter);
  return identities.filter((identity) => expression.test(identity));
} } = {}) {
  if (typeof packagePath !== 'string' || packagePath.length === 0) fail('package path is required');
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) fail('watchdog timeout must be a positive safe integer');
  const listed = await run('swift', ['test', '--package-path', packagePath, 'list'], { timeoutMs });
  if (!listed || listed.exitCode !== 0) fail('swift test list failed');
  const expected = parseTestNames(listed.stdout, 'swift test list');
  const runDirectory = await makeRunDirectory();
  const shards = [];
  try {
    for (const [index, identity] of expected.entries()) {
      const filter = exactFilter(identity);
      const matching = matchListed(filter, expected);
      if (!Array.isArray(matching) || matching.length !== 1 || matching[0] !== identity) fail(`filter collision or mismatch for ${identity}`);
      let result;
      try {
        result = await run('swift', ['test', '--package-path', packagePath, '--skip-build', '--no-parallel', '--filter', filter], { timeoutMs });
      } catch (error) {
        if (error?.code === 'ETIMEDOUT') fail(`shard watchdog timeout: ${identity}`);
        throw error;
      }
      await writeFileImpl(path.join(runDirectory, `shard-${index}.log`), `${result?.stdout ?? ''}${result?.stderr ?? ''}`, { encoding: 'utf8', mode: 0o600, flag: 'wx' });
      if (!result || result.exitCode !== 0) fail(`shard failed: ${identity}`);
      const count = completedCount(result.stdout, `shard ${identity}`);
      shards.push(Object.freeze({ identity, filter, count }));
    }
  } finally {
    await removeTree(runDirectory);
  }
  const executed = shards.map(({ identity }) => identity);
  if (new Set(executed).size !== executed.length) fail('executed tests contain a duplicate test');
  assertExactSet(expected, executed);
  return Object.freeze({ expected: sorted(expected), executed: sorted(executed), shards: Object.freeze(shards) });
}

export async function runCli(argv = process.argv.slice(2), dependencies = {}) {
  const { stdout = (value) => process.stdout.write(value), realpath: realpathImpl = realpath, checkExactTestReplay: checkExactTestReplayImpl = checkExactTestReplay } = dependencies;
  if (argv.length !== 2 || argv[0] !== '--package-path' || !argv[1]) throw new Error('usage: check-exact-test-replay.mjs --package-path SOURCE_ROOT');
  const receipt = await checkExactTestReplayImpl({ packagePath: await realpathImpl(argv[1]) });
  stdout(`${JSON.stringify(receipt)}\n`);
  return receipt;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  runCli().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
