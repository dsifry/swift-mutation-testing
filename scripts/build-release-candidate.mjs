import { createHash } from 'node:crypto';
import { execFile as execFileCallback } from 'node:child_process';
import { chmod, lstat, mkdir, readFile, realpath, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);
const COMMIT = /^[a-f0-9]{40}$/;
const VERSION = /^\d+\.\d+\.\d+$/;
const SHA256 = /^[a-f0-9]{64}$/;
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const executableName = 'swift-mutation-testing';

function fail(message) {
  throw new Error(`build release candidate: ${message}`);
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function isDescendant(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative !== '' && relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function assertDistinctAndDisjoint(...roots) {
  for (let left = 0; left < roots.length; left += 1) {
    for (let right = left + 1; right < roots.length; right += 1) {
      if (roots[left] === roots[right] || isDescendant(roots[left], roots[right]) || isDescendant(roots[right], roots[left])) {
        fail('control, source, and output roots must be distinct and disjoint');
      }
    }
  }
}

export async function canonicalOutputRoot(outputRoot, realpathImpl = realpath) {
  if (typeof outputRoot !== 'string' || !path.isAbsolute(outputRoot)) fail('output root must be absolute');
  try {
    return await realpathImpl(outputRoot);
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
    const parent = await realpathImpl(path.dirname(outputRoot));
    return path.join(parent, path.basename(outputRoot));
  }
}

export async function nativeRunCommand(executable, argv, options = {}, runCommand = execFile) {
  try {
    const { stdout = '', stderr = '' } = await runCommand(executable, argv, { encoding: 'utf8', maxBuffer: 10 * 1024 * 1024, ...options });
    return { stdout, stderr, exitCode: 0 };
  } catch (error) {
    return { stdout: error.stdout ?? '', stderr: error.stderr ?? '', exitCode: Number.isInteger(error.code) ? error.code : 1 };
  }
}

export async function runChecked(runCommand, executable, argv, options, label) {
  const result = await runCommand(executable, argv, options);
  if (!result || result.exitCode !== 0) fail(`${label} failed`);
  return result.stdout ?? '';
}

async function assertHead(runCommand, root, expected, label) {
  const head = (await runChecked(runCommand, 'git', ['rev-parse', 'HEAD'], { cwd: root }, `${label} HEAD`)).trim();
  if (head !== expected) fail(`${label} checkout HEAD does not match its required commit`);
}

function assertInput(input) {
  if (!input || typeof input !== 'object') fail('input is required');
  if (!VERSION.test(input.version ?? '')) fail('version must be canonical X.Y.Z');
  if (!COMMIT.test(input.sourceCommit ?? '') || !COMMIT.test(input.workflowCommit ?? '')) fail('source and workflow commits must be lowercase full commit SHAs');
  if (!Number.isSafeInteger(Number(input.runId)) || Number(input.runId) <= 0 || !Number.isSafeInteger(Number(input.runAttempt)) || Number(input.runAttempt) <= 0) fail('run id and attempt must be positive safe integers');
  if (input.artifactName !== `swift-mutation-testing-v${input.version}-candidate-${input.runId}-${input.runAttempt}`) fail('artifact name does not match version, run id, and attempt');
}

export function controlPath(controlRoot, relativePath) {
  const resolved = path.resolve(controlRoot, relativePath);
  if (!isDescendant(controlRoot, resolved)) fail(`control owner path escapes control root: ${relativePath}`);
  return resolved;
}

async function replaceVersion(sourceRoot, version) {
  const filePath = path.join(sourceRoot, 'Sources', 'SwiftMutationTesting', 'Version.swift');
  const bytes = await readFile(filePath);
  const source = bytes.toString('utf8');
  const matches = source.match(/0\.0\.0-dev/g) ?? [];
  if (matches.length !== 1) fail('version injection must replace exactly one placeholder');
  await writeFile(filePath, source.replace('0.0.0-dev', version), { encoding: 'utf8' });
  return filePath;
}

function parseToolchain(swift, xcode, runnerArchitecture) {
  const swiftVersion = /\bApple Swift version 6\.3\.3\b/.exec(swift)?.[0];
  const xcodeVersion = /^Xcode 26\.6$/m.test(xcode);
  const xcodeBuild = /^Build version 17F113$/m.test(xcode);
  if (!swiftVersion || !xcodeVersion || !xcodeBuild || runnerArchitecture !== 'arm64') fail('toolchain observations do not match the release policy');
  return { swiftVersion, xcodeVersion: '26.6', xcodeBuild: '17F113', runnerArchitecture };
}

export function parseMachO(stdout) {
  const uuid = /cmd LC_UUID\s+cmdsize \d+\s+uuid ([0-9A-Fa-f-]+)/s.exec(stdout)?.[1]?.toLowerCase();
  const deploymentTarget = /cmd LC_BUILD_VERSION[\s\S]*?minos (\d+(?:\.\d+)?)/.exec(stdout)?.[1];
  if (!uuid || !UUID.test(uuid) || deploymentTarget !== '15.0') fail('Mach-O metadata does not match the release policy');
  return { uuid, deploymentTarget };
}

export function parseDigest(stdout, filePath) {
  const digest = /^([a-f0-9]{64})\s+\*?.+$/m.exec(stdout)?.[1];
  if (!digest || !SHA256.test(digest) || !stdout.includes(path.basename(filePath))) fail(`SHA-256 output is invalid for ${path.basename(filePath)}`);
  return digest;
}

async function writeExclusive(filePath, value) {
  await writeFile(filePath, value, { encoding: 'utf8', mode: 0o600, flag: 'wx' });
  await chmod(filePath, 0o600);
}

async function loadArtifactDefault(controlRoot) {
  return import(pathToFileURL(controlPath(controlRoot, 'scripts/release-artifact.mjs')).href);
}

export async function freshScratchRoot(sourceRoot, { mkdirImpl = mkdir, chmodImpl = chmod, limit = 1024 } = {}) {
  for (let index = 0; index < limit; index += 1) {
    const candidate = path.join(sourceRoot, `.release-candidate-scratch-${process.pid}-${index}`);
    try {
      await mkdirImpl(candidate, { mode: 0o700 });
      await chmodImpl(candidate, 0o700);
      return candidate;
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error;
    }
  }
  fail('cannot create a fresh source scratch root');
}

export async function ownedRegularFile(filePath, root, { lstatImpl = lstat, realpathImpl = realpath, readFileImpl = readFile } = {}) {
  const original = await lstatImpl(filePath);
  if (!original.isFile() || original.nlink !== 1) fail('release artifact read must be an owned regular file');
  const resolved = await realpathImpl(filePath);
  if (!isDescendant(root, resolved)) fail('release artifact read escapes its root');
  const current = await lstatImpl(resolved);
  if (!current.isFile() || current.nlink !== 1) fail('release artifact read must be an owned regular file');
  return readFileImpl(resolved);
}

async function freshPrivateDirectory(directory, mode) {
  await mkdir(directory, { mode, recursive: false });
  await chmod(directory, mode);
  return directory;
}

async function stageOwnedArchive(filePath, root, privateDirectory) {
  const bytes = await ownedRegularFile(filePath, root);
  const staged = path.join(privateDirectory, '.candidate-archive');
  await writeFile(staged, bytes, { mode: 0o600, flag: 'wx' });
  return { path: staged, bytes };
}

export function artifactCommands(runCommand, controlRoot) {
  return {
    tar: {
      list: async (archivePath) => {
        const listing = await runChecked(runCommand, 'tar', ['-tvzf', archivePath], { cwd: controlRoot }, 'candidate archive listing');
        const match = /^-rwxr-xr-x\s+0\s+\S+\s+\S+\s+(\d+)\s+\S+\s+\d+\s+(?:\d{2}:\d{2}|\d{4})\s+(swift-mutation-testing)$/m.exec(listing);
        if (!match) fail('candidate archive listing is malformed');
        return [{ path: match[2], type: 'file', linkCount: 1, mode: '0755', size: Number(match[1]) }];
      },
      extract: async (archivePath, directory) => runChecked(runCommand, 'tar', ['-xzf', archivePath, '-C', directory], { cwd: controlRoot }, 'candidate archive extraction'),
    },
    codesign: { verify: async (filePath) => { await runChecked(runCommand, 'codesign', ['--verify', '--strict', filePath], { cwd: controlRoot }, 'candidate code signature'); return true; } },
    file: { inspect: async (filePath) => ({ type: (await runChecked(runCommand, 'file', ['-b', filePath], { cwd: controlRoot }, 'candidate file inspection')).includes('Mach-O 64-bit executable arm64') ? 'Mach-O 64-bit executable arm64' : 'other' }) },
    otool: { inspect: async (filePath) => {
      const output = await runChecked(runCommand, 'otool', ['-l', filePath], { cwd: controlRoot }, 'candidate Mach-O inspection');
      const metadata = parseMachO(output);
      return { ...metadata, cpuType: 'arm64' };
    } },
    executable: { version: async (filePath) => (await runChecked(runCommand, filePath, ['--version'], { cwd: controlRoot }, 'candidate executable version')).trim() },
  };
}

export async function runBuild(input, dependencies = {}) {
  assertInput(input);
  const runCommand = dependencies.runCommand ?? nativeRunCommand;
  const loadArtifact = dependencies.loadArtifact ?? loadArtifactDefault;
  const controlRoot = await realpath(input.controlRoot);
  const sourceRoot = await realpath(input.sourceRoot);
  const outputRoot = await canonicalOutputRoot(input.outputRoot);
  assertDistinctAndDisjoint(controlRoot, sourceRoot, outputRoot);
  try {
    await lstat(outputRoot);
    fail('output root must be fresh');
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
  }
  const sourceVersion = path.join(sourceRoot, 'Sources', 'SwiftMutationTesting', 'Version.swift');
  const archiveName = `swift-mutation-testing-v${input.version}-macos.tar.gz`;

  let createdOutput = false;
  let scratchRoot;
  try {
    await assertHead(runCommand, controlRoot, input.workflowCommit, 'workflow');
    await assertHead(runCommand, sourceRoot, input.sourceCommit, 'source');
    await runChecked(runCommand, 'git', ['merge-base', '--is-ancestor', input.sourceCommit, input.workflowCommit], { cwd: sourceRoot }, 'source ancestry');
    await runChecked(runCommand, 'bash', [controlPath(controlRoot, 'scripts/check-focused-coverage.sh'), '--package-path', sourceRoot], { cwd: controlRoot }, 'focused coverage gate');
    await runChecked(runCommand, process.execPath, [controlPath(controlRoot, 'scripts/check-exact-test-replay.mjs'), '--package-path', sourceRoot], { cwd: controlRoot }, 'exact test replay');
    await replaceVersion(sourceRoot, input.version);
    const toolchain = parseToolchain(
      await runChecked(runCommand, 'swift', ['--version'], { cwd: controlRoot }, 'Swift toolchain check'),
      await runChecked(runCommand, 'xcodebuild', ['-version'], { cwd: controlRoot }, 'Xcode toolchain check'),
      (await runChecked(runCommand, 'uname', ['-m'], { cwd: controlRoot }, 'runner architecture check')).trim(),
    );
    const sdkVersionOutput = (await runChecked(runCommand, 'xcrun', ['--show-sdk-version'], { cwd: controlRoot }, 'SDK version check')).trim();
    if (!/^\d+\.\d+$/u.test(sdkVersionOutput)) fail('SDK version output is invalid');
    scratchRoot = await freshScratchRoot(sourceRoot);
    await runChecked(runCommand, 'swift', ['build', '--package-path', sourceRoot, '--scratch-path', scratchRoot, '-c', 'release'], { cwd: controlRoot }, 'clean release build');
    const binaryPath = path.join(scratchRoot, 'release', executableName);
    const binaryStat = await stat(binaryPath);
    if (!binaryStat.isFile() || binaryStat.mode & 0o022) fail('built executable is not a safe regular file');
    await runChecked(runCommand, 'codesign', ['--verify', '--strict', binaryPath], { cwd: controlRoot }, 'code signature verification');
    const fileType = (await runChecked(runCommand, 'file', ['-b', binaryPath], { cwd: controlRoot }, 'Mach-O file check')).trim();
    if (!fileType.includes('Mach-O 64-bit executable arm64')) fail('built executable is not arm64 Mach-O');
    const machO = parseMachO(await runChecked(runCommand, 'otool', ['-l', binaryPath], { cwd: controlRoot }, 'Mach-O inspection'));
    const versionOutput = (await runChecked(runCommand, binaryPath, ['--version'], { cwd: controlRoot }, 'release executable version')).trim();
    if (versionOutput !== `swift-mutation-testing ${input.version} [arm64-macos26]`) fail('release executable version output is wrong');

    await mkdir(outputRoot, { mode: 0o700, recursive: false });
    createdOutput = true;
    await chmod(outputRoot, 0o700);
    const archivePath = path.join(outputRoot, archiveName);
    const manifestPath = path.join(outputRoot, 'release-candidate-v2.json');
    await runChecked(runCommand, 'tar', ['-czf', archivePath, '-C', path.dirname(binaryPath), executableName], { cwd: controlRoot }, 'one-time archive package');
    const archiveSHA256 = parseDigest(await runChecked(runCommand, 'shasum', ['-a', '256', archivePath], { cwd: controlRoot }, 'archive SHA-256'), archivePath);
    const executableSHA256 = parseDigest(await runChecked(runCommand, 'shasum', ['-a', '256', binaryPath], { cwd: controlRoot }, 'executable SHA-256'), binaryPath);
    const manifest = {
      schemaVersion: 'release-candidate-v2', repository: 'dsifry/swift-mutation-testing',
      workflow: { path: '.github/workflows/release-candidate.yml', ref: 'refs/heads/main', commit: input.workflowCommit },
      dispatch: { event: 'workflow_dispatch', triggerCommit: input.workflowCommit, mainAnchorCommit: input.workflowCommit },
      run: { id: Number(input.runId), attempt: Number(input.runAttempt) }, artifactName: input.artifactName, sourceCommit: input.sourceCommit,
      release: { version: input.version, tag: `v${input.version}`, versionOutput },
      toolchain: { runnerImage: 'macos-26', runnerArchitecture: toolchain.runnerArchitecture, xcodeVersion: toolchain.xcodeVersion, xcodeBuild: toolchain.xcodeBuild, swiftVersion: toolchain.swiftVersion, compilerTarget: 'arm64-apple-macosx26.0', cpuType: 'arm64', deploymentTarget: machO.deploymentTarget },
      archive: { filename: archiveName, sha256: archiveSHA256 },
      executable: { filename: executableName, mode: '0755', size: binaryStat.size, uuid: machO.uuid, sha256: executableSHA256 },
    };
    const manifestBytes = Buffer.from(`${JSON.stringify(manifest)}\n`);
    await writeExclusive(manifestPath, manifestBytes);
    const artifact = await loadArtifact(controlRoot);
    if (typeof artifact.parseCandidateManifest !== 'function' || typeof artifact.verifyCandidateBundle !== 'function' || typeof artifact.sha256 !== 'function' || typeof artifact.canonicalLocalProvenance !== 'function') fail('control release artifact interface is incomplete');
    artifact.parseCandidateManifest(manifestBytes);
    const manifestSHA256 = artifact.sha256(manifestBytes);
    const provenancePath = path.join(outputRoot, 'local-release-provenance-v1.json');
    const provenanceBytes = artifact.canonicalLocalProvenance({
      schemaVersion: 'local-release-provenance-v1', repository: 'dsifry/swift-mutation-testing',
      sourceCommit: input.sourceCommit, versionOutput, capability: 'prepared-cache-v1',
      manifestSHA256, archiveSHA256, binarySHA256: executableSHA256,
      swiftVersionOutput: toolchain.swiftVersion, sdkVersionOutput,
      targetTriple: 'arm64-apple-macosx26.0', configuration: 'release', codesignVerified: true,
    });
    await writeExclusive(provenancePath, provenanceBytes);
    await artifact.verifyCandidateBundle({ controlRoot, sourceRoot, artifactRoot: outputRoot, archivePath, manifestPath, privateDirectory: path.join(outputRoot, '.verification'), fs: { readOwnedRegularFile: ownedRegularFile, mkdirFreshPrivate: freshPrivateDirectory, stageOwnedArchive }, commands: artifactCommands(runCommand, controlRoot), git: { controlHead: async () => input.workflowCommit, sourceHead: async () => input.sourceCommit, isAncestor: async () => true } });
    await rm(path.join(outputRoot, '.verification'), { recursive: true, force: true });
    const output = await import('node:fs/promises').then(({ readdir }) => readdir(outputRoot));
    if (output.length !== 3) fail('candidate output contains files outside the closed artifact set');
    const receipt = Object.freeze({ archive: { filename: archiveName, sha256: archiveSHA256 }, manifest: { filename: 'release-candidate-v2.json', sha256: manifestSHA256 }, executable: { filename: executableName, sha256: executableSHA256 }, provenance: { filename: path.basename(provenancePath), sha256: sha256(provenanceBytes) } });
    await rm(scratchRoot, { recursive: true, force: true });
    scratchRoot = undefined;
    return receipt;
  } catch (error) {
    if (createdOutput) await rm(outputRoot, { recursive: true, force: true });
    if (scratchRoot) await rm(scratchRoot, { recursive: true, force: true });
    throw error;
  }
}

export function parseArguments(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith('--') || !value || Object.hasOwn(values, key.slice(2))) fail('usage: build-release-candidate.mjs --control-root ROOT --source-root ROOT --output-root ROOT --version X.Y.Z --source-commit SHA --workflow-commit SHA --run-id ID --run-attempt ATTEMPT --artifact-name NAME');
    values[key.slice(2)] = value;
  }
  const expected = ['control-root', 'source-root', 'output-root', 'version', 'source-commit', 'workflow-commit', 'run-id', 'run-attempt', 'artifact-name'];
  if (Object.keys(values).length !== expected.length || expected.some((key) => !Object.hasOwn(values, key))) fail('usage: build-release-candidate.mjs --control-root ROOT --source-root ROOT --output-root ROOT --version X.Y.Z --source-commit SHA --workflow-commit SHA --run-id ID --run-attempt ATTEMPT --artifact-name NAME');
  return { controlRoot: values['control-root'], sourceRoot: values['source-root'], outputRoot: values['output-root'], version: values.version, sourceCommit: values['source-commit'], workflowCommit: values['workflow-commit'], runId: values['run-id'], runAttempt: values['run-attempt'], artifactName: values['artifact-name'] };
}

export async function runCli(argv = process.argv.slice(2), dependencies = {}) {
  const receipt = await (dependencies.runBuild ?? runBuild)(parseArguments(argv), dependencies);
  (dependencies.stdout ?? ((value) => process.stdout.write(value)))(`${JSON.stringify(receipt)}\n`);
  return receipt;
}

export async function runMain(argv = process.argv.slice(2), dependencies = {}) {
  try { await runCli(argv, dependencies); return 0; }
  catch (error) { (dependencies.stderr ?? ((value) => process.stderr.write(value)))(`${error.message}\n`); return 1; }
}

export async function main({ moduleURL = import.meta.url, argv = process.argv, runMainImpl = runMain } = {}) {
  if (moduleURL !== pathToFileURL(argv[1]).href) return false;
  process.exitCode = await runMainImpl(argv.slice(2));
  return true;
}

await main();
