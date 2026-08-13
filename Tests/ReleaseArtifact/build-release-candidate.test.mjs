import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { access, chmod, copyFile, lstat, mkdtemp, mkdir, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { artifactCommands, canonicalOutputRoot, controlPath, freshScratchRoot, main, nativeRunCommand, ownedRegularFile, parseArguments, parseDigest, parseMachO, runBuild, runChecked, runCli, runMain } from '../../scripts/build-release-candidate.mjs';
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
    if (executable === 'xcrun' && argv[0] === '--show-sdk-version') return { stdout: '26.0\n', stderr: '', exitCode: 0 };
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
    if (executable === 'otool') return { stdout: '      cmd LC_UUID\n  cmdsize 24\n     uuid 12345678-1234-1234-1234-123456789ABC\n      cmd LC_BUILD_VERSION\n  cmdsize 32\n    minos 15.0\n', stderr: '', exitCode: 0 };
    if (executable.endsWith('swift-mutation-testing')) return { stdout: 'swift-mutation-testing 1.3.1 [arm64-macos26]\n', stderr: '', exitCode: 0 };
    if (executable === 'tar' && argv[0] === '-czf') {
      await writeFile(argv[1], 'archive');
      return { stdout: '', stderr: '', exitCode: 0 };
    }
    if (executable === 'tar' && argv[0] === '-tvzf') return { stdout: '-rwxr-xr-x  0 builder  staff  6 Aug 11 17:00 swift-mutation-testing\n', stderr: '', exitCode: 0 };
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
      canonicalLocalProvenance: releaseArtifact.canonicalLocalProvenance,
      parseCandidateManifest: (bytes) => JSON.parse(bytes),
      verifyCandidateBundle: async () => ({ executableSHA256: 'verified' }),
    }),
  });

  assert.equal(receipt.archive.filename, 'swift-mutation-testing-v1.3.1-macos.tar.gz');
  assert.equal(receipt.manifest.filename, 'release-candidate-v2.json');
  assert.deepEqual((await (await import('node:fs/promises')).readdir(value.outputRoot)).sort(), [
    'local-release-provenance-v1.json', 'release-candidate-v2.json', 'swift-mutation-testing-v1.3.1-macos.tar.gz',
  ]);
  const provenanceBytes = await readFile(path.join(value.outputRoot, 'local-release-provenance-v1.json'));
  const provenance = releaseArtifact.parseLocalProvenance(provenanceBytes);
  assert.equal(receipt.provenance.sha256, createHash('sha256').update(provenanceBytes).digest('hex'));
  assert.equal(provenance.manifestSHA256, receipt.manifest.sha256);
  assert.equal(provenance.archiveSHA256, receipt.archive.sha256);
  assert.equal(provenance.binarySHA256, receipt.executable.sha256);
  assert.equal(value.calls.filter(({ executable }) => executable === 'tar').length, 1);
  assert.equal(value.calls.some(({ executable }) => executable.startsWith(`${path.join(value.sourceRoot, 'scripts')}${path.sep}`)), false);
  assert.equal(value.calls.some(({ executable, argv }) => executable === 'swift' && argv.includes('--no-parallel')), false);
  assert.equal(value.calls.some(({ executable, argv }) => executable === 'swift' && argv.includes('--scratch-path') && argv.some((argument) => argument.includes('.release-candidate-scratch-'))), true);
  assert.equal((await readFile(path.join(value.sourceRoot, 'Sources', 'SwiftMutationTesting', 'Version.swift'), 'utf8')).includes('1.3.1'), true);
});

test('Mach-O parser requires the real LC_UUID cmdsize layout', () => {
  assert.deepEqual(parseMachO('cmd LC_UUID\ncmdsize 24\nuuid 12345678-1234-1234-1234-123456789ABC\ncmd LC_BUILD_VERSION\ncmdsize 32\nminos 15.0\n'), {
    uuid: '12345678-1234-1234-1234-123456789abc',
    deploymentTarget: '15.0',
  });
  assert.throws(() => parseMachO('cmd LC_UUID\nuuid 12345678-1234-1234-1234-123456789ABC\ncmd LC_BUILD_VERSION\nminos 15.0\n'), /Mach-O metadata/u);
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
  const downloadedManifest = path.join(downloadRoot, 'release-candidate-v2.json');
  await copyFile(archivePath, downloadedArchive);
  await copyFile(path.join(value.outputRoot, 'release-candidate-v2.json'), downloadedManifest);
  const afterDownload = await digest(downloadedArchive);
  assert.equal(afterDownload, beforeVerifier);

  const canonicalDownloadRoot = await realpath(downloadRoot);
  await releaseArtifact.verifyCandidateBundle({
    controlRoot: await realpath(value.controlRoot), sourceRoot: await realpath(value.sourceRoot), artifactRoot: canonicalDownloadRoot,
    archivePath: path.join(canonicalDownloadRoot, archiveName), manifestPath: path.join(canonicalDownloadRoot, 'release-candidate-v2.json'), privateDirectory: path.join(canonicalDownloadRoot, 'verify-private'),
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
    loadArtifact: async () => ({ sha256: (bytes) => createHash('sha256').update(bytes).digest('hex'), canonicalLocalProvenance: releaseArtifact.canonicalLocalProvenance, parseCandidateManifest: JSON.parse, verifyCandidateBundle: async () => ({}) }),
  });

  assert.equal(await readFile(path.join(staleScratch, 'preserve-me'), 'utf8'), 'prior run');
  assert.equal(value.calls.some(({ executable, argv }) => executable === 'swift' && argv.includes('--scratch-path') && argv.some((argument) => argument.includes('.release-candidate-scratch-'))), true);
});

test('runs the control-owned focused gate against the source package path', async (t) => {
  const value = await fixture();
  t.after(() => rm(value.root, { recursive: true, force: true }));

  await runBuild(value.input, {
    runCommand: value.runCommand,
    loadArtifact: async () => ({ sha256: (bytes) => createHash('sha256').update(bytes).digest('hex'), canonicalLocalProvenance: releaseArtifact.canonicalLocalProvenance, parseCandidateManifest: JSON.parse, verifyCandidateBundle: async () => ({}) }),
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
    loadArtifact: async () => ({ sha256: (bytes) => createHash('sha256').update(bytes).digest('hex'), canonicalLocalProvenance: releaseArtifact.canonicalLocalProvenance, parseCandidateManifest: JSON.parse, verifyCandidateBundle: async () => ({}) }),
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
  ['wrong SDK version', (value) => { const original = value.runCommand; value.runCommand = async (...args) => args[0] === 'xcrun' ? { stdout: 'unknown\n', stderr: '', exitCode: 0 } : original(...args); }, /SDK version/i],
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

test('input, parsing, and native command decisions fail closed', async (t) => {
  for (const input of [null, {}, { version: '01.3' }, { version: '1.3.1' }, { version: '1.3.1', sourceCommit: commit('a') }, { version: '1.3.1', sourceCommit: 'bad', workflowCommit: commit('b') }, { version: '1.3.1', sourceCommit: commit('a'), workflowCommit: commit('b'), runId: 0, runAttempt: 1 }, { version: '1.3.1', sourceCommit: commit('a'), workflowCommit: commit('b'), runId: 1, runAttempt: 1, artifactName: 'bad' }]) {
    await assert.rejects(() => runBuild(input), /build release candidate/);
  }
  await assert.rejects(() => canonicalOutputRoot('relative'), /absolute/);
  const root = await mkdtemp(path.join(os.tmpdir(), 'task6-output-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await assert.rejects(() => canonicalOutputRoot(path.join(root, 'missing', 'output')), /ENOENT/);
  await assert.rejects(() => canonicalOutputRoot('/absolute', async () => { const error=new Error('denied'); error.code='EACCES'; throw error; }), /denied/);
  assert.throws(() => parseMachO('bad'), /Mach-O/);
  assert.throws(() => parseMachO('cmd LC_UUID\n uuid bad\ncmd LC_BUILD_VERSION\n minos 15.0'), /Mach-O/);
  assert.throws(() => parseDigest('bad', '/x/file'), /SHA-256/);
  assert.throws(() => parseDigest(`${'a'.repeat(64)}  other\n`, '/x/file'), /SHA-256/);
  assert.throws(() => parseArguments([]), /usage/);
  assert.throws(() => parseArguments(['bad', 'x']), /usage/);
  assert.throws(() => parseArguments(['--version', 'x', '--version', 'y']), /usage/);
  assert.deepEqual(await nativeRunCommand('x', [], {}, async () => ({ stdout: 'ok', stderr: 'warn' })), { stdout: 'ok', stderr: 'warn', exitCode: 0 });
  assert.deepEqual(await nativeRunCommand('x', [], {}, async () => { throw {}; }), { stdout: '', stderr: '', exitCode: 1 });
  assert.deepEqual(await nativeRunCommand('x', [], {}, async () => { const error = new Error(); error.code = 7; error.stdout = 'out'; error.stderr = 'bad'; throw error; }), { stdout: 'out', stderr: 'bad', exitCode: 7 });
  assert.equal(await runChecked(async()=>({exitCode:0}),'x',[],{},'x'),'');
  await assert.rejects(() => freshScratchRoot('/tmp', { limit: 1, mkdirImpl: async () => { const error = new Error(); error.code = 'EEXIST'; throw error; } }), /fresh/);
  await assert.rejects(() => freshScratchRoot('/tmp', { limit: 1, mkdirImpl: async () => { throw new Error('denied'); } }), /denied/);
  assert.throws(() => controlPath('/control', '../escape'), /escapes/);
  const commands = artifactCommands(async (_command, argv) => argv[0] === '-tvzf' ? { stdout: 'bad', exitCode: 0 } : { stdout: 'text', exitCode: 0 }, '/control');
  await assert.rejects(() => commands.tar.list('/archive'), /listing/);
  assert.deepEqual(await commands.file.inspect('/binary'), { type: 'other' });
});

test('owned file reads reject links, escapes, and post-resolution replacement', async (t) => {
  const root=await mkdtemp(path.join(os.tmpdir(),'task6-owned-')); t.after(()=>rm(root,{recursive:true,force:true}));
  const file=path.join(root,'file'); await writeFile(file,'x');
  const canonical = await realpath(root);
  assert.equal((await ownedRegularFile(file,canonical)).toString(),'x');
  const directory=path.join(root,'directory'); await mkdir(directory);
  await assert.rejects(()=>ownedRegularFile(directory,canonical),/regular/);
  const outside=path.join(path.dirname(root),`${path.basename(root)}-outside`); await writeFile(outside,'x'); t.after(()=>rm(outside,{force:true}));
  await assert.rejects(()=>ownedRegularFile(outside,canonical),/escapes/);
  let checks=0;
  const canonicalFile=path.join(canonical,'file');
  await assert.rejects(()=>ownedRegularFile(file,canonical,{lstatImpl:async()=>({isFile:()=>++checks===1,nlink:1}),realpathImpl:async()=>canonicalFile,readFileImpl:readFile}),/regular/);
});

test('default loader imports only the control-owned artifact module', async (t) => {
  const value=await fixture(); t.after(()=>rm(value.root,{recursive:true,force:true}));
  await assert.rejects(()=>runBuild(value.input,{runCommand:value.runCommand}),/interface/);
  await assert.rejects(()=>runBuild(value.input),/build release candidate/);
});

for (const [name, mutate, pattern] of [
  ['unsafe built executable', (value) => { const original=value.runCommand; value.runCommand=async(...args)=>{const result=await original(...args); if(args[0]==='swift'&&args[1][0]==='build'){const scratch=args[1][args[1].indexOf('--scratch-path')+1]; await chmod(path.join(scratch,'release','swift-mutation-testing'),0o777);} return result;}; }, /safe regular/],
  ['malformed Mach-O', (value) => { const original=value.runCommand; value.runCommand=async(...args)=>args[0]==='otool'?{stdout:'bad',exitCode:0}:original(...args); }, /Mach-O metadata/],
  ['malformed archive digest', (value) => { const original=value.runCommand; value.runCommand=async(...args)=>args[0]==='shasum'&&args[1].at(-1).endsWith('.tar.gz')?{stdout:'bad',exitCode:0}:original(...args); }, /SHA-256/],
  ['incomplete artifact interface', () => {}, /interface/],
]) test(`rejects ${name}`, async (t) => {
  const value=await fixture(); t.after(()=>rm(value.root,{recursive:true,force:true})); mutate(value);
  await assert.rejects(()=>runBuild(value.input,{runCommand:value.runCommand,loadArtifact:async()=>name==='incomplete artifact interface'?{}:{sha256:(b)=>createHash('sha256').update(b).digest('hex'),canonicalLocalProvenance:releaseArtifact.canonicalLocalProvenance,parseCandidateManifest:JSON.parse,verifyCandidateBundle:async()=>({})}}),pattern);
});

test('removes output when late output-set validation fails', async (t) => {
  const value=await fixture(); t.after(()=>rm(value.root,{recursive:true,force:true}));
  await assert.rejects(()=>runBuild(value.input,{runCommand:value.runCommand,loadArtifact:async()=>({sha256:(b)=>createHash('sha256').update(b).digest('hex'),canonicalLocalProvenance:releaseArtifact.canonicalLocalProvenance,parseCandidateManifest:JSON.parse,verifyCandidateBundle:async()=>{await writeFile(path.join(value.outputRoot,'extra'),'x');}})}),/outside/);
  await assert.rejects(()=>access(value.outputRoot),/ENOENT/);
});

test('CLI and main preserve the closed argument contract', async () => {
  const argv = ['--control-root','/c','--source-root','/s','--output-root','/o','--version','1.3.1','--source-commit',commit('a'),'--workflow-commit',commit('b'),'--run-id','1','--run-attempt','1','--artifact-name','swift-mutation-testing-v1.3.1-candidate-1-1'];
  const output = [];
  const receipt = { ok: true };
  assert.equal(await runCli(argv, { runBuild: async () => receipt, stdout: (value) => output.push(value) }), receipt);
  const originalWrite = process.stdout.write;
  process.stdout.write = () => true;
  try { assert.equal(await runCli(argv, { runBuild: async () => receipt }), receipt); } finally { process.stdout.write = originalWrite; }
  assert.equal(await runMain(argv, { runBuild: async () => receipt, stdout() {} }), 0);
  const errors = [];
  assert.equal(await runMain([], { stderr: (value) => errors.push(value) }), 1);
  const originalError = process.stderr.write;
  process.stderr.write = () => true;
  try { assert.equal(await runMain([]), 1); } finally { process.stderr.write = originalError; }
  assert.equal(await main({ moduleURL: 'file:///a', argv: ['node','/b'] }), false);
  const old = process.exitCode;
  try { assert.equal(await main({ moduleURL: 'file:///a', argv: ['node','/a','x'], runMainImpl: async (args) => { assert.deepEqual(args, ['x']); return 3; } }), true); assert.equal(process.exitCode, 3); }
  finally { process.exitCode = old; }
});
