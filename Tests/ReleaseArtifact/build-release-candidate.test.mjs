import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { chmod, copyFile, lstat, mkdtemp, mkdir, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { runBuild } from '../../scripts/build-release-candidate.mjs';
import * as releaseArtifact from '../../scripts/release-artifact.mjs';

const commit = (character) => character.repeat(40);
const digest = async (filePath) => createHash('sha256').update(await readFile(filePath)).digest('hex');

async function ownedRead(filePath, root) {
  const initial = await lstat(filePath);
  const resolved = await realpath(filePath);
  const canonicalRoot = await realpath(root);
  assert.equal(initial.isFile() && initial.nlink === 1, true);
  assert.equal(resolved.startsWith(`${canonicalRoot}${path.sep}`), true);
  return readFile(resolved);
}

function realVerifierCommands(value) {
  return {
    tar: {
      list: async () => [{ path: 'swift-mutation-testing', type: 'file', linkCount: 1, mode: '0755', size: 6 }],
      extract: async (_archivePath, directory) => { await writeFile(path.join(directory, 'swift-mutation-testing'), 'binary'); await chmod(path.join(directory, 'swift-mutation-testing'), 0o755); },
    },
    codesign: { verify: async () => true },
    file: { inspect: async () => ({ type: 'Mach-O 64-bit executable arm64' }) },
    otool: { inspect: async () => ({ uuid: '12345678-1234-1234-1234-123456789abc', cpuType: 'arm64', deploymentTarget: '15.0' }) },
    executable: { version: async () => 'swift-mutation-testing 1.3.1 [arm64-macos26]' },
  };
}

async function fixture() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'release-candidate-build-'));
  const controlRoot = path.join(root, 'control');
  const sourceRoot = path.join(root, 'source');
  const outputRoot = path.join(root, 'output');
  await mkdir(path.join(controlRoot, 'scripts'), { recursive: true });
  await mkdir(path.join(sourceRoot, 'Sources', 'SwiftMutationTesting'), { recursive: true });
  await writeFile(path.join(controlRoot, 'scripts', 'check-focused-coverage.sh'), '#!/bin/sh\n');
  await chmod(path.join(controlRoot, 'scripts', 'check-focused-coverage.sh'), 0o755);
  await writeFile(path.join(controlRoot, 'scripts', 'check-exact-test-replay.mjs'), '');
  await writeFile(path.join(controlRoot, 'scripts', 'release-artifact.mjs'), '');
  await writeFile(path.join(sourceRoot, 'Sources', 'SwiftMutationTesting', 'Version.swift'), 'static let number = "0.0.0-dev"\n');
  const calls = [];
  const input = {
    controlRoot,
    sourceRoot,
    outputRoot,
    version: '1.3.1',
    sourceCommit: commit('a'),
    workflowCommit: commit('b'),
    runId: '123456789',
    runAttempt: '2',
    artifactName: 'swift-mutation-testing-v1.3.1-candidate-123456789-2',
  };
  const runCommand = async (executable, argv, options = {}) => {
    calls.push({ executable, argv, options });
    if (executable === 'git' && argv.join(' ') === 'rev-parse HEAD') {
      return { stdout: path.basename(options.cwd) === 'control' ? `${input.workflowCommit}\n` : `${input.sourceCommit}\n`, stderr: '', exitCode: 0 };
    }
    if (executable === 'git' && argv[0] === 'merge-base') return { stdout: '', stderr: '', exitCode: 0 };
    if (executable === 'swift' && argv[0] === '--version') return { stdout: 'Apple Swift version 6.3.3\n', stderr: '', exitCode: 0 };
    if (executable === 'xcodebuild' && argv[0] === '-version') return { stdout: 'Xcode 26.6\nBuild version 17F113\n', stderr: '', exitCode: 0 };
    if (executable === 'uname' && argv[0] === '-m') return { stdout: 'arm64\n', stderr: '', exitCode: 0 };
    if (executable === 'swift' && argv[0] === 'build') {
      const scratch = argv[argv.indexOf('--scratch-path') + 1];
      const binary = path.join(scratch, 'release', 'swift-mutation-testing');
      await mkdir(path.dirname(binary), { recursive: true });
      await writeFile(binary, 'binary');
      await chmod(binary, 0o755);
      return { stdout: '', stderr: '', exitCode: 0 };
    }
    if (executable === 'codesign') return { stdout: '', stderr: '', exitCode: 0 };
    if (executable === 'file') return { stdout: 'Mach-O 64-bit executable arm64\n', stderr: '', exitCode: 0 };
    if (executable === 'otool') return { stdout: 'cmd LC_UUID\n uuid 12345678-1234-1234-1234-123456789abc\ncmd LC_BUILD_VERSION\n minos 15.0\n', stderr: '', exitCode: 0 };
    if (executable.endsWith('swift-mutation-testing')) return { stdout: 'swift-mutation-testing 1.3.1 [arm64-macos26]\n', stderr: '', exitCode: 0 };
    if (executable === 'tar' && argv[0] === '-czf') {
      await writeFile(argv[1], 'archive');
      return { stdout: '', stderr: '', exitCode: 0 };
    }
    if (executable === 'tar' && argv[0] === '-tvzf') return { stdout: '-rwxr-xr-x  1 builder  staff  6 Aug 11 17:00 swift-mutation-testing\n', stderr: '', exitCode: 0 };
    if (executable === 'tar' && argv[0] === '-xzf') {
      const destination = argv[argv.indexOf('-C') + 1];
      await writeFile(path.join(destination, 'swift-mutation-testing'), 'binary');
      await chmod(path.join(destination, 'swift-mutation-testing'), 0o755);
      return { stdout: '', stderr: '', exitCode: 0 };
    }
    if (executable === 'shasum') {
      const bytes = await readFile(argv.at(-1));
      const digest = createHash('sha256').update(bytes).digest('hex');
      return { stdout: `${digest}  ${argv.at(-1)}\n`, stderr: '', exitCode: 0 };
    }
    if (executable === process.execPath || executable === 'node' || executable === 'bash') return { stdout: '', stderr: '', exitCode: 0 };
    throw new Error(`unexpected command ${executable}`);
  };
  return { root, controlRoot, sourceRoot, outputRoot, input, calls, runCommand };
}

test('builds the candidate exactly once from source while every owner path is control-confined', async (t) => {
  const value = await fixture();
  t.after(() => rm(value.root, { recursive: true, force: true }));
  const receipt = await runBuild(value.input, {
    runCommand: value.runCommand,
    loadArtifact: async () => ({
      sha256: (bytes) => createHash('sha256').update(bytes).digest('hex'),
      parseCandidateManifest: (bytes) => JSON.parse(bytes),
      verifyCandidateBundle: async () => ({ executableSHA256: 'verified' }),
    }),
  });

  assert.equal(receipt.archive.filename, 'swift-mutation-testing-v1.3.1-macos.tar.gz');
  assert.equal(receipt.manifest.filename, 'release-candidate-v1.json');
  assert.deepEqual((await (await import('node:fs/promises')).readdir(value.outputRoot)).sort(), [
    'archive-attestation-input-v1.json', 'manifest-attestation-input-v1.json', 'release-candidate-v1.json', 'swift-mutation-testing-v1.3.1-macos.tar.gz',
  ]);
  assert.equal(value.calls.filter(({ executable }) => executable === 'tar').length, 1);
  assert.equal(value.calls.some(({ executable }) => executable.startsWith(value.sourceRoot)), false);
  assert.equal(value.calls.some(({ executable, argv }) => executable === 'swift' && argv.includes('--no-parallel')), false);
  assert.equal(value.calls.some(({ executable, argv }) => executable === 'swift' && argv.includes('--scratch-path') && argv.some((argument) => argument.includes('.release-candidate-scratch-'))), true);
  assert.equal((await readFile(path.join(value.sourceRoot, 'Sources', 'SwiftMutationTesting', 'Version.swift'), 'utf8')).includes('1.3.1'), true);
});

test('verifies the produced candidate through the real root-bound release artifact verifier', async (t) => {
  const value = await fixture();
  t.after(() => rm(value.root, { recursive: true, force: true }));

  await runBuild(value.input, { runCommand: value.runCommand, loadArtifact: async () => releaseArtifact });

  assert.equal(value.calls.some(({ executable, argv }) => executable === 'tar' && argv[0] === '-tvzf'), true);
  assert.equal(value.calls.some(({ executable, argv }) => executable === 'tar' && argv[0] === '-xzf'), true);
});

test('preserves exact archive bytes through verifier staging and simulated upload download', async (t) => {
  const value = await fixture();
  t.after(() => rm(value.root, { recursive: true, force: true }));
  const receipt = await runBuild(value.input, { runCommand: value.runCommand, loadArtifact: async () => releaseArtifact });
  const archiveName = receipt.archive.filename;
  const archivePath = path.join(value.outputRoot, archiveName);
  const beforeVerifier = await digest(archivePath);
  assert.equal(beforeVerifier, receipt.archive.sha256);

  const downloadRoot = path.join(value.root, 'download');
  await mkdir(downloadRoot);
  const downloadedArchive = path.join(downloadRoot, archiveName);
  const downloadedManifest = path.join(downloadRoot, 'release-candidate-v1.json');
  await copyFile(archivePath, downloadedArchive);
  await copyFile(path.join(value.outputRoot, 'release-candidate-v1.json'), downloadedManifest);
  const afterDownload = await digest(downloadedArchive);
  assert.equal(afterDownload, beforeVerifier);

  const canonicalDownloadRoot = await realpath(downloadRoot);
  await releaseArtifact.verifyCandidateBundle({
    controlRoot: await realpath(value.controlRoot), sourceRoot: await realpath(value.sourceRoot), artifactRoot: canonicalDownloadRoot,
    archivePath: path.join(canonicalDownloadRoot, archiveName), manifestPath: path.join(canonicalDownloadRoot, 'release-candidate-v1.json'), privateDirectory: path.join(canonicalDownloadRoot, 'verify-private'),
    fs: {
      readOwnedRegularFile: ownedRead,
      mkdirFreshPrivate: async (directory, mode) => { await mkdir(directory, { mode }); await chmod(directory, mode); },
      stageOwnedArchive: async (source, root, privateDirectory) => { const bytes = await ownedRead(source, root); const staged = path.join(privateDirectory, '.candidate-archive'); await writeFile(staged, bytes, { flag: 'wx', mode: 0o600 }); return { path: staged, bytes }; },
    },
    commands: realVerifierCommands(value),
    git: { controlHead: async () => value.input.workflowCommit, sourceHead: async () => value.input.sourceCommit, isAncestor: async () => true },
  });
  const afterVerifier = await digest(downloadedArchive);
  assert.equal(afterVerifier, beforeVerifier);
});

test('preserves a pre-existing source scratch path and uses a new owned scratch path', async (t) => {
  const value = await fixture();
  t.after(() => rm(value.root, { recursive: true, force: true }));
  const staleScratch = path.join(value.sourceRoot, '.release-candidate-scratch');
  await mkdir(staleScratch);
  await writeFile(path.join(staleScratch, 'preserve-me'), 'prior run');

  await runBuild(value.input, {
    runCommand: value.runCommand,
    loadArtifact: async () => ({ sha256: (bytes) => createHash('sha256').update(bytes).digest('hex'), parseCandidateManifest: JSON.parse, verifyCandidateBundle: async () => ({}) }),
  });

  assert.equal(await readFile(path.join(staleScratch, 'preserve-me'), 'utf8'), 'prior run');
  assert.equal(value.calls.some(({ executable, argv }) => executable === 'swift' && argv.includes('--scratch-path') && argv.some((argument) => argument.includes('.release-candidate-scratch-'))), true);
});

test('runs the control-owned focused gate against the source package path', async (t) => {
  const value = await fixture();
  t.after(() => rm(value.root, { recursive: true, force: true }));

  await runBuild(value.input, {
    runCommand: value.runCommand,
    loadArtifact: async () => ({ sha256: (bytes) => createHash('sha256').update(bytes).digest('hex'), parseCandidateManifest: JSON.parse, verifyCandidateBundle: async () => ({}) }),
  });

  const [focused] = value.calls.filter(({ executable }) => executable === 'bash').map(({ argv }) => argv);
  assert.equal(focused[0].endsWith('/control/scripts/check-focused-coverage.sh'), true);
  assert.deepEqual(focused.slice(1), ['--package-path', await (await import('node:fs/promises')).realpath(value.sourceRoot)]);
});

test('does not execute source-supplied control owners when source attempts replacement', async (t) => {
  const value = await fixture();
  t.after(() => rm(value.root, { recursive: true, force: true }));
  await mkdir(path.join(value.sourceRoot, 'scripts'));
  const poisonedOwner = path.join(value.sourceRoot, 'scripts', 'check-exact-test-replay.mjs');
  await writeFile(poisonedOwner, 'throw new Error("source owner executed")');

  await runBuild(value.input, {
    runCommand: value.runCommand,
    loadArtifact: async () => ({ sha256: (bytes) => createHash('sha256').update(bytes).digest('hex'), parseCandidateManifest: JSON.parse, verifyCandidateBundle: async () => ({}) }),
  });

  assert.equal(value.calls.some(({ executable, argv }) => executable === process.execPath && argv[0] === poisonedOwner), false);
});

test('rejects a pre-existing output root without deleting its contents', async (t) => {
  const value = await fixture();
  t.after(() => rm(value.root, { recursive: true, force: true }));
  await mkdir(value.outputRoot);
  await writeFile(path.join(value.outputRoot, 'preserve-me'), 'existing evidence');

  await assert.rejects(() => runBuild(value.input, { runCommand: value.runCommand, loadArtifact: async () => ({}) }), /output.*exists|fresh/i);

  assert.equal(await readFile(path.join(value.outputRoot, 'preserve-me'), 'utf8'), 'existing evidence');
});

for (const [name, mutate, pattern] of [
  ['output nested under control', (value) => { value.input.outputRoot = path.join(value.controlRoot, 'output'); }, /disjoint|output/i],
  ['source nested under control', (value) => { value.input.sourceRoot = path.join(value.controlRoot, 'source'); }, /disjoint|source/i],
  ['unequal control head', (value) => { const original = value.runCommand; value.runCommand = async (...args) => args[0] === 'git' && args[1].join(' ') === 'rev-parse HEAD' && path.basename(args[2].cwd) === 'control' ? { stdout: `${commit('c')}\n`, stderr: '', exitCode: 0 } : original(...args); }, /HEAD|workflow/i],
  ['multiple version placeholders', async (value) => { await writeFile(path.join(value.sourceRoot, 'Sources', 'SwiftMutationTesting', 'Version.swift'), '0.0.0-dev 0.0.0-dev'); }, /exactly one|version/i],
  ['zero version placeholders', async (value) => { await writeFile(path.join(value.sourceRoot, 'Sources', 'SwiftMutationTesting', 'Version.swift'), 'static let number = "released"'); }, /exactly one|version/i],
  ['wrong toolchain', (value) => { const original = value.runCommand; value.runCommand = async (...args) => args[0] === 'swift' && args[1][0] === '--version' ? { stdout: 'Swift 5', stderr: '', exitCode: 0 } : original(...args); }, /toolchain|Swift/i],
  ['wrong Xcode build', (value) => { const original = value.runCommand; value.runCommand = async (...args) => args[0] === 'xcodebuild' ? { stdout: 'Xcode 26.6\nBuild version wrong\n', stderr: '', exitCode: 0 } : original(...args); }, /toolchain|Xcode/i],
  ['wrong runner architecture', (value) => { const original = value.runCommand; value.runCommand = async (...args) => args[0] === 'uname' ? { stdout: 'x86_64\n', stderr: '', exitCode: 0 } : original(...args); }, /toolchain|architecture/i],
  ['build failure', (value) => { const original = value.runCommand; value.runCommand = async (...args) => args[0] === 'swift' && args[1][0] === 'build' ? { stdout: '', stderr: 'bad', exitCode: 1 } : original(...args); }, /build/i],
  ['focused test failure', (value) => { const original = value.runCommand; value.runCommand = async (...args) => args[0] === 'bash' ? { stdout: '', stderr: 'failed', exitCode: 1 } : original(...args); }, /coverage|gate/i],
  ['wrong binary type', (value) => { const original = value.runCommand; value.runCommand = async (...args) => args[0] === 'file' ? { stdout: 'text\n', stderr: '', exitCode: 0 } : original(...args); }, /Mach-O|binary/i],
  ['wrong binary version', (value) => { const original = value.runCommand; value.runCommand = async (...args) => args[0].endsWith('swift-mutation-testing') ? { stdout: 'wrong\n', stderr: '', exitCode: 0 } : original(...args); }, /version/i],
]) {
  test(`fails closed for ${name} and removes partial output`, async (t) => {
    const value = await fixture();
    t.after(() => rm(value.root, { recursive: true, force: true }));
    await mutate(value);
    await assert.rejects(() => runBuild(value.input, { runCommand: value.runCommand, loadArtifact: async () => ({}) }), pattern);
    await assert.rejects(() => readFile(value.input.outputRoot), /ENOENT|is a directory/i);
  });
}
