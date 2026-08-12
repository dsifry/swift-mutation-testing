import { createHash } from 'node:crypto';
import { execFile as execFileCallback } from 'node:child_process';
import { chmod, lstat, mkdir, readFile, realpath } from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);
const SHA256 = /^[a-f0-9]{64}$/;
const COMMIT = /^[a-f0-9]{40}$/;
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const CANDIDATE_KEYS = Object.freeze([
  'schemaVersion', 'repository', 'workflow', 'dispatch', 'run', 'artifactName',
  'sourceCommit', 'release', 'toolchain', 'archive', 'executable',
]);

function fail(scope, message) {
  throw new Error(`${scope}: ${message}`);
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) && Object.getPrototypeOf(value) === Object.prototype;
}

function assertObject(value, scope) {
  if (!isObject(value)) fail('candidate manifest', `${scope} must be an object`);
}

function assertExactKeys(value, keys, scope) {
  assertObject(value, scope);
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    fail('candidate manifest', `${scope} must have exactly ${expected.join(', ')}`);
  }
}

function assertString(value, scope) {
  if (typeof value !== 'string') fail('candidate manifest', `${scope} must be a string`);
}

function assertExact(value, expected, scope) {
  if (value !== expected) fail('candidate manifest', `${scope} must equal ${expected}`);
}

function assertCommit(value, scope) {
  assertString(value, scope);
  if (!COMMIT.test(value)) fail('candidate manifest', `${scope} must be a lowercase full commit SHA`);
}

function assertDigest(value, scope) {
  assertString(value, scope);
  if (!SHA256.test(value)) fail('candidate manifest', `${scope} must be a lowercase SHA-256 digest`);
}

function assertPositiveSafeInteger(value, scope) {
  if (!Number.isSafeInteger(value) || value <= 0) fail('candidate manifest', `${scope} must be a positive safe integer`);
}

function assertCandidateValues(value) {
  assertExactKeys(value, CANDIDATE_KEYS, 'candidate manifest');
  assertExact(value.schemaVersion, 'release-candidate-v1', 'schemaVersion');
  assertExact(value.repository, 'dsifry/swift-mutation-testing', 'repository');

  assertExactKeys(value.workflow, ['path', 'ref', 'commit'], 'workflow');
  assertExact(value.workflow.path, '.github/workflows/release-candidate.yml', 'workflow.path');
  assertExact(value.workflow.ref, 'refs/heads/main', 'workflow.ref');
  assertCommit(value.workflow.commit, 'workflow.commit');

  assertExactKeys(value.dispatch, ['event', 'triggerCommit', 'mainAnchorCommit'], 'dispatch');
  assertExact(value.dispatch.event, 'workflow_dispatch', 'dispatch.event');
  assertCommit(value.dispatch.triggerCommit, 'dispatch.triggerCommit');
  assertCommit(value.dispatch.mainAnchorCommit, 'dispatch.mainAnchorCommit');
  if (value.workflow.commit !== value.dispatch.triggerCommit || value.workflow.commit !== value.dispatch.mainAnchorCommit) {
    fail('candidate manifest', 'workflow, dispatch trigger, and main anchor commits must match');
  }

  assertExactKeys(value.run, ['id', 'attempt'], 'run');
  assertPositiveSafeInteger(value.run.id, 'run.id');
  assertPositiveSafeInteger(value.run.attempt, 'run.attempt');

  assertCommit(value.sourceCommit, 'sourceCommit');
  assertExact(value.artifactName, `swift-mutation-testing-v1.3.1-candidate-${value.run.id}-${value.run.attempt}`, 'artifactName');

  assertExactKeys(value.release, ['version', 'tag', 'versionOutput'], 'release');
  assertExact(value.release.version, '1.3.1', 'release.version');
  assertExact(value.release.tag, `v${value.release.version}`, 'release.tag');
  assertExact(value.release.versionOutput, 'swift-mutation-testing 1.3.1 [arm64-macos26]', 'release.versionOutput');

  assertExactKeys(value.toolchain, [
    'runnerImage', 'runnerArchitecture', 'xcodeVersion', 'xcodeBuild', 'swiftVersion',
    'compilerTarget', 'cpuType', 'deploymentTarget',
  ], 'toolchain');
  assertExact(value.toolchain.runnerImage, 'macos-26', 'toolchain.runnerImage');
  assertExact(value.toolchain.runnerArchitecture, 'arm64', 'toolchain.runnerArchitecture');
  assertExact(value.toolchain.xcodeVersion, '26.6', 'toolchain.xcodeVersion');
  assertExact(value.toolchain.xcodeBuild, '17F113', 'toolchain.xcodeBuild');
  assertExact(value.toolchain.swiftVersion, 'Apple Swift version 6.3.3', 'toolchain.swiftVersion');
  assertExact(value.toolchain.compilerTarget, 'arm64-apple-macosx26.0', 'toolchain.compilerTarget');
  assertExact(value.toolchain.cpuType, 'arm64', 'toolchain.cpuType');
  assertExact(value.toolchain.deploymentTarget, '15.0', 'toolchain.deploymentTarget');

  assertExactKeys(value.archive, ['filename', 'sha256'], 'archive');
  assertExact(value.archive.filename, `swift-mutation-testing-v${value.release.version}-macos.tar.gz`, 'archive.filename');
  assertDigest(value.archive.sha256, 'archive.sha256');

  assertExactKeys(value.executable, ['filename', 'mode', 'size', 'uuid', 'sha256'], 'executable');
  assertExact(value.executable.filename, 'swift-mutation-testing', 'executable.filename');
  assertExact(value.executable.mode, '0755', 'executable.mode');
  assertPositiveSafeInteger(value.executable.size, 'executable.size');
  assertString(value.executable.uuid, 'executable.uuid');
  if (!UUID.test(value.executable.uuid)) fail('candidate manifest', 'executable.uuid must be a lowercase UUID');
  assertDigest(value.executable.sha256, 'executable.sha256');
}

function readJSONString(source, start) {
  let index = start + 1;
  while (index < source.length) {
    const code = source.charCodeAt(index);
    if (code === 0x22) return { value: JSON.parse(source.slice(start, index + 1)), end: index + 1 };
    if (code < 0x20) fail('candidate manifest', 'JSON string contains an unescaped control character');
    if (code === 0x5c) {
      index += 1;
      if (index >= source.length) fail('candidate manifest', 'unterminated JSON escape');
      if (source[index] === 'u') index += 4;
    }
    index += 1;
  }
  fail('candidate manifest', 'unterminated JSON string');
}

function parseJSONRejectingDuplicateKeys(bytes) {
  if (!Buffer.isBuffer(bytes)) fail('candidate manifest', 'bytes must be a Buffer');
  const source = bytes.toString('utf8');
  let index = 0;
  const skipWhitespace = () => {
    while (index < source.length && /[\t\n\r ]/.test(source[index])) index += 1;
  };
  const parseValue = () => {
    skipWhitespace();
    const start = index;
    if (source[index] === '{') {
      index += 1;
      skipWhitespace();
      const keys = new Set();
      if (source[index] === '}') {
        index += 1;
        return;
      }
      while (true) {
        skipWhitespace();
        if (source[index] !== '"') fail('candidate manifest', 'object key must be a JSON string');
        const key = readJSONString(source, index);
        index = key.end;
        if (keys.has(key.value)) fail('candidate manifest', `duplicate JSON key ${key.value}`);
        keys.add(key.value);
        skipWhitespace();
        if (source[index] !== ':') fail('candidate manifest', 'object key is missing a colon');
        index += 1;
        parseValue();
        skipWhitespace();
        if (source[index] === '}') {
          index += 1;
          return;
        }
        if (source[index] !== ',') fail('candidate manifest', 'object members must be comma separated');
        index += 1;
      }
    }
    if (source[index] === '[') {
      index += 1;
      skipWhitespace();
      if (source[index] === ']') {
        index += 1;
        return;
      }
      while (true) {
        parseValue();
        skipWhitespace();
        if (source[index] === ']') {
          index += 1;
          return;
        }
        if (source[index] !== ',') fail('candidate manifest', 'array values must be comma separated');
        index += 1;
      }
    }
    if (source[index] === '"') {
      index = readJSONString(source, index).end;
      return;
    }
    while (index < source.length && !/[\t\n\r ,\]\}]/.test(source[index])) index += 1;
    if (start === index) fail('candidate manifest', 'invalid JSON value');
    try {
      JSON.parse(source.slice(start, index));
    } catch {
      fail('candidate manifest', 'invalid JSON value');
    }
  };
  try {
    parseValue();
    skipWhitespace();
    if (index !== source.length) fail('candidate manifest', 'trailing JSON data');
    return JSON.parse(source);
  } catch (error) {
    if (error.message?.startsWith('candidate manifest:')) throw error;
    fail('candidate manifest', 'invalid JSON');
  }
}

function deepFreeze(value) {
  if (value && typeof value === 'object' && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const child of Object.values(value)) deepFreeze(child);
  }
  return value;
}

export function parseCandidateManifest(bytes) {
  const value = parseJSONRejectingDuplicateKeys(bytes);
  assertCandidateValues(value);
  return deepFreeze(value);
}

export function sha256(bytes) {
  if (!Buffer.isBuffer(bytes)) throw new TypeError('sha256 bytes must be a Buffer');
  return createHash('sha256').update(bytes).digest('hex');
}

function assertAbsoluteChild(root, target, label) {
  if (typeof root !== 'string' || typeof target !== 'string' || !path.isAbsolute(root) || !path.isAbsolute(target)) {
    fail('candidate bundle', `${label} must be an absolute path`);
  }
  const relative = path.relative(root, target);
  if (relative === '' || relative.startsWith(`..${path.sep}`) || relative === '..' || path.isAbsolute(relative)) {
    fail('candidate bundle', `${label} must be beneath the control root`);
  }
}

function assertBundleInput(input) {
  if (!isObject(input)) fail('candidate bundle', 'input must be an object');
  assertAbsoluteChild(input.controlRoot, input.archivePath, 'archive path');
  assertAbsoluteChild(input.controlRoot, input.manifestPath, 'manifest path');
  if (typeof input.sourceRoot !== 'string' || !path.isAbsolute(input.sourceRoot) || input.sourceRoot === input.controlRoot) {
    fail('candidate bundle', 'source root must be a separate absolute path');
  }
  if (typeof input.privateDirectory !== 'string' || !path.isAbsolute(input.privateDirectory)) {
    fail('candidate bundle', 'private directory must be an absolute path');
  }
  if (!isObject(input.fs) || typeof input.fs.readOwnedRegularFile !== 'function' || typeof input.fs.mkdirFreshPrivate !== 'function') {
    fail('candidate bundle', 'fs must provide owned regular reads and fresh private directories');
  }
  if (!isObject(input.commands)) fail('candidate bundle', 'commands must be an object');
  for (const [owner, method] of [['tar', 'list'], ['tar', 'extract'], ['codesign', 'verify'], ['file', 'inspect'], ['otool', 'inspect'], ['executable', 'version']]) {
    if (!isObject(input.commands[owner]) || typeof input.commands[owner][method] !== 'function') {
      fail('candidate bundle', `commands.${owner}.${method} must be a function`);
    }
  }
}

async function verifyArchiveListing(archivePath, manifest, commands) {
  const entries = await commands.tar.list(archivePath);
  if (!Array.isArray(entries) || entries.length !== 1) fail('candidate bundle', 'archive must contain exactly one entry');
  const [entry] = entries;
  if (!isObject(entry)) fail('candidate bundle', 'archive entry must be an object');
  if (entry.path !== manifest.executable.filename || entry.path.startsWith('/') || entry.path.split('/').includes('..')) {
    fail('candidate bundle', 'archive path is unsafe or unexpected');
  }
  if (entry.type !== 'file' || entry.linkCount !== 1 || entry.mode !== manifest.executable.mode || entry.size !== manifest.executable.size) {
    fail('candidate bundle', 'archive executable metadata does not match the manifest');
  }
}

async function extractPrivately(input, manifest) {
  await input.fs.mkdirFreshPrivate(input.privateDirectory, 0o700);
  await input.commands.tar.extract(input.archivePath, input.privateDirectory);
  return path.join(input.privateDirectory, manifest.executable.filename);
}

async function inspectExecutable(executablePath, manifest, commands, fs) {
  const signature = await commands.codesign.verify(executablePath);
  if (signature !== true) fail('candidate bundle', 'executable code signature verification failed');
  const fileResult = await commands.file.inspect(executablePath);
  if (!isObject(fileResult) || fileResult.type !== 'Mach-O 64-bit executable arm64') {
    fail('candidate bundle', 'executable is not the required arm64 Mach-O');
  }
  const machO = await commands.otool.inspect(executablePath);
  if (!isObject(machO) || machO.uuid !== manifest.executable.uuid || machO.cpuType !== manifest.toolchain.cpuType || machO.deploymentTarget !== manifest.toolchain.deploymentTarget) {
    fail('candidate bundle', 'executable Mach-O metadata does not match the manifest');
  }
  const version = await commands.executable.version(executablePath);
  if (version !== manifest.release.versionOutput) fail('candidate bundle', 'executable version output does not match the manifest');
  const executableBytes = await fs.readOwnedRegularFile(executablePath);
  return { executableSHA256: sha256(executableBytes) };
}

export async function verifyCandidateBundle(input) {
  assertBundleInput(input);
  const manifestBytes = await input.fs.readOwnedRegularFile(input.manifestPath);
  const manifest = parseCandidateManifest(manifestBytes);
  await verifyArchiveListing(input.archivePath, manifest, input.commands);
  const executablePath = await extractPrivately(input, manifest);
  const observed = await inspectExecutable(executablePath, manifest, input.commands, input.fs);
  const archiveSHA256 = sha256(await input.fs.readOwnedRegularFile(input.archivePath));
  const manifestSHA256 = sha256(manifestBytes);
  if (archiveSHA256 !== manifest.archive.sha256 || observed.executableSHA256 !== manifest.executable.sha256) {
    fail('candidate bundle', 'observed digest does not match the candidate manifest');
  }
  return Object.freeze({ manifest, archiveSHA256, manifestSHA256, executableSHA256: observed.executableSHA256 });
}

function assertAttestation(condition, message) {
  if (!condition) fail('attestation', message);
}

function subjectDigest(subject, name) {
  if (!isObject(subject) || subject.name !== name || !isObject(subject.digest) || !SHA256.test(subject.digest.sha256) || Object.keys(subject.digest).length !== 1) {
    fail('attestation', `subject ${name} is invalid`);
  }
  return subject.digest.sha256;
}

export function verifyAttestationBundle(bundle, expected) {
  assertAttestation(isObject(bundle) && Object.keys(bundle).length === 1 && isObject(bundle.statement), 'bundle must contain exactly one statement');
  const statement = bundle.statement;
  assertAttestation(isObject(expected), 'expected provenance must be an object');
  assertAttestation(Object.keys(statement).length === 4, 'statement schema is not closed');
  assertAttestation(statement._type === 'https://in-toto.io/Statement/v1', 'statement type is invalid');
  assertAttestation(statement.predicateType === 'https://slsa.dev/provenance/v1', 'predicate type is invalid');
  assertAttestation(Array.isArray(statement.subject) && statement.subject.length === 2, 'attestation must have both subjects');
  const subjectNames = new Set(statement.subject.map((subject) => subject?.name));
  assertAttestation(subjectNames.size === 2 && subjectNames.has('swift-mutation-testing-v1.3.1-macos.tar.gz') && subjectNames.has('release-candidate-v1.json'), 'attestation subjects are not closed');
  const archive = statement.subject.find((subject) => subject.name === 'swift-mutation-testing-v1.3.1-macos.tar.gz');
  const manifest = statement.subject.find((subject) => subject.name === 'release-candidate-v1.json');
  assertAttestation(subjectDigest(archive, 'swift-mutation-testing-v1.3.1-macos.tar.gz') === expected.archiveSHA256, 'archive subject digest does not match');
  assertAttestation(subjectDigest(manifest, 'release-candidate-v1.json') === expected.manifestSHA256, 'manifest subject digest does not match');
  const predicate = statement.predicate;
  assertAttestation(isObject(predicate) && Object.keys(predicate).length === 6, 'predicate schema is not closed');
  assertAttestation(predicate.repository === expected.repository, 'repository does not match');
  assertAttestation(predicate.workflowPath === expected.workflowPath, 'workflow path does not match');
  assertAttestation(predicate.workflowRef === expected.workflowRef, 'workflow ref does not match');
  assertAttestation(predicate.workflowCommit === expected.workflowCommit, 'workflow commit does not match');
  assertAttestation(predicate.event === expected.event, 'event does not match');
  assertAttestation(predicate.runnerInvocationUri === `https://github.com/${expected.repository}/actions/runs/${expected.runId}/attempts/${expected.runAttempt}`, 'runner invocation URI does not match');
  return deepFreeze(statement);
}

async function readOwnedRegularFile(filePath) {
  const resolved = await realpath(filePath);
  const stat = await lstat(resolved);
  if (!stat.isFile() || stat.nlink !== 1) throw new Error(`candidate bundle: ${filePath} is not an owned regular file`);
  return readFile(resolved);
}

async function mkdirFreshPrivate(directory, mode) {
  try {
    await lstat(directory);
    throw new Error(`candidate bundle: private directory already exists: ${directory}`);
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
  }
  await mkdir(directory, { mode, recursive: false });
  await chmod(directory, mode);
  return directory;
}

async function run(command, arguments_) {
  const { stdout } = await execFile(command, arguments_, { encoding: 'utf8' });
  return stdout;
}

function parseTarListing(stdout) {
  return stdout.trim().split('\n').filter(Boolean).map((line) => {
    const match = /^(?<type>.)(?<mode>[rwx-]{9})\s+(?<links>\d+)\s+\S+(?:\s+\S+)?\s+(?<size>\d+)\s+.+?\s+(?<name>.+)$/.exec(line);
    if (!match?.groups) throw new Error('candidate bundle: unable to parse tar listing');
    return {
      path: match.groups.name.replace(/\s+link to .+$/, ''),
      type: match.groups.type === '-' ? 'file' : match.groups.type === 'd' ? 'directory' : match.groups.type === 'l' ? 'symlink' : 'other',
      linkCount: Number(match.groups.links),
      mode: `0${match.groups.mode.replace(/[^rwx-]/g, '').split('').reduce((total, character, index) => total + ((character !== '-' ? 1 : 0) << (8 - index)), 0).toString(8)}`,
      size: Number(match.groups.size),
    };
  });
}

function nativeCommands() {
  return {
    tar: {
      list: async (archivePath) => parseTarListing(await run('tar', ['-tvzf', archivePath])),
      extract: async (archivePath, directory) => run('tar', ['-xzf', archivePath, '-C', directory]),
    },
    codesign: { verify: async (filePath) => { await run('codesign', ['--verify', '--strict', filePath]); return true; } },
    file: { inspect: async (filePath) => ({ type: (await run('file', ['-b', filePath])).trim().includes('Mach-O 64-bit executable arm64') ? 'Mach-O 64-bit executable arm64' : 'other' }) },
    otool: {
      inspect: async (filePath) => {
        const output = await run('otool', ['-l', filePath]);
        const uuid = /cmd LC_UUID\s+cmdsize \d+\s+uuid ([0-9A-F-]+)/s.exec(output)?.[1]?.toLowerCase();
        const deploymentTarget = /cmd LC_BUILD_VERSION[\s\S]*?minos (\d+(?:\.\d+)?)/.exec(output)?.[1];
        return { uuid, cpuType: (await run('file', ['-b', filePath])).includes('arm64') ? 'arm64' : 'other', deploymentTarget };
      },
    },
    executable: { version: async (filePath) => (await run(filePath, ['--version'])).trim() },
  };
}

async function runCli() {
  const [command, first, second] = process.argv.slice(2);
  if (command === 'candidate-manifest' && first && !second) {
    process.stdout.write(`${JSON.stringify(parseCandidateManifest(await readOwnedRegularFile(first)))}\n`);
    return;
  }
  if (command === 'attestation' && first && second) {
    const bundle = JSON.parse(await readFile(first, 'utf8'));
    const expected = JSON.parse(await readFile(second, 'utf8'));
    process.stdout.write(`${JSON.stringify(verifyAttestationBundle(bundle, expected))}\n`);
    return;
  }
  if (command === 'candidate-bundle' && first && !second) {
    const input = JSON.parse(await readFile(first, 'utf8'));
    const controlRoot = await realpath(input.controlRoot);
    const sourceRoot = await realpath(input.sourceRoot);
    const verified = await verifyCandidateBundle({
      ...input,
      controlRoot,
      sourceRoot,
      fs: { readOwnedRegularFile, mkdirFreshPrivate },
      commands: nativeCommands(),
    });
    process.stdout.write(`${JSON.stringify(verified)}\n`);
    return;
  }
  throw new Error('usage: release-artifact.mjs candidate-manifest <manifest> | attestation <bundle> <expected> | candidate-bundle <input-json>');
}

if (import.meta.url === `file://${process.argv[1]}`) {
  runCli().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
