import { execFile as execFileCallback } from 'node:child_process';
import { mkdtemp, readFile, realpath, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
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

function parseXunit(bytes, expected, label) {
  if (!Buffer.isBuffer(bytes)) fail(`${label} xUnit result is malformed`);
  const source = bytes.toString('utf8');
  const cases = [...source.matchAll(/<testcase\s+([^>]*?)(?:\/>|>[\s\S]*?<\/testcase>)/g)];
  if (cases.length === 0) fail(`${label} has no xUnit testcases`);
  const canonical = [];
  for (const match of cases) {
    const classname = /(?:^|\s)classname="([^"]+)"/.exec(match[1])?.[1];
    const name = /(?:^|\s)name="([^"]+)"/.exec(match[1])?.[1];
    if (!classname || !name || /[<&]/.test(classname) || /[<&]/.test(name)) fail(`${label} xUnit testcase identity is malformed`);
    const candidates = [`${classname}/${name}`, `${classname}/${name}()`].filter((candidate) => expected.includes(candidate));
    if (candidates.length !== 1) fail(`${label} xUnit testcase identity is unexpected`);
    canonical.push(candidates[0]);
  }
  if (new Set(canonical).size !== canonical.length) fail(`${label} xUnit result contains a duplicate test`);
  return canonical;
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

export async function checkExactTestReplay({ packagePath, run = nativeRun, timeoutMs = DEFAULT_TIMEOUT_MS, makeXunitDirectory = () => mkdtemp(path.join(os.tmpdir(), 'exact-test-replay-')), readFile: readFileImpl = readFile, removeTree = (directory) => rm(directory, { recursive: true, force: true }) } = {}) {
  if (typeof packagePath !== 'string' || packagePath.length === 0) fail('package path is required');
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) fail('watchdog timeout must be a positive safe integer');

  const expectedResult = await run('swift', ['test', '--package-path', packagePath, 'list'], { timeoutMs });
  if (!expectedResult || expectedResult.exitCode !== 0) fail('swift test list failed');
  const expected = parseTestNames(expectedResult.stdout, 'swift test list');
  const suites = sorted([...new Set(expected.map((name) => TEST_IDENTIFIER.exec(name).groups.suite))]);
  const executed = [];
  const xunitDirectory = await makeXunitDirectory();

  try {
    for (const [index, suite] of suites.entries()) {
      const xunitPath = path.join(xunitDirectory, `shard-${index}.xml`);
      let result;
      try {
        result = await run('swift', ['test', '--package-path', packagePath, '--no-parallel', '--filter', suite, '--xunit-output', xunitPath], { timeoutMs });
      } catch (error) {
        if (error?.code === 'ETIMEDOUT') fail(`shard watchdog timeout: ${suite}`);
        throw error;
      }
      if (!result || result.exitCode !== 0) fail(`shard failed: ${suite}`);
      let xunitBytes;
      try {
        xunitBytes = await readFileImpl(xunitPath);
      } catch {
        fail(`shard ${suite} xUnit result is absent`);
      }
      const shardExecuted = parseXunit(xunitBytes, expected, `shard ${suite}`);
      if (shardExecuted.some((name) => TEST_IDENTIFIER.exec(name).groups.suite !== suite)) fail(`shard ${suite} xUnit result contains an unexpected suite`);
      executed.push(...shardExecuted);
    }
  } finally {
    await removeTree(xunitDirectory);
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
