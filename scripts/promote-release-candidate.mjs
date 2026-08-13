#!/usr/bin/env node

import { execFile as execFileCallback } from 'node:child_process';
import { chmod, lstat, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';

import {
  classifyReleaseState,
  createNativeCandidateVerificationInput,
  parseCandidateManifest,
  parseLocalProvenance,
  sha256,
  verifyCandidateBundle,
  verifyPromotionAuthority,
  verifyRepositoryControls,
  verifyTagTuple,
} from './release-artifact.mjs';

const execFile = promisify(execFileCallback);
const CLI_KEYS = Object.freeze([
  'version', 'repository', 'source-commit', 'manifest-sha256', 'archive-sha256', 'executable-sha256', 'provenance-sha256',
  'candidate-descriptor-sha256', 'control-commit', 'guide-commit', 'guide-proof-sha256',
  'archive-path', 'manifest-path', 'provenance-path', 'control-root', 'work-root',
]);

function promotionFail(message) {
  throw new Error(`promotion: ${message}`);
}

export function verifyLocalBundleCustody(input, bundle) {
  if (!bundle || !Buffer.isBuffer(bundle.archiveBytes) || !Buffer.isBuffer(bundle.manifestBytes) || !Buffer.isBuffer(bundle.provenanceBytes)) {
    promotionFail('local bundle is incomplete');
  }
  if (sha256(bundle.archiveBytes) !== input.archiveSHA256 || sha256(bundle.manifestBytes) !== input.manifestSHA256) promotionFail('local bundle digest mismatch');
  if (sha256(bundle.provenanceBytes) !== input.provenanceSHA256) promotionFail('local provenance digest mismatch');
  const manifest = parseCandidateManifest(bundle.manifestBytes);
  const provenance = parseLocalProvenance(bundle.provenanceBytes);
  if (manifest.sourceCommit !== input.sourceCommit || manifest.archive.sha256 !== input.archiveSHA256
    || manifest.executable.sha256 !== input.executableSHA256 || provenance.sourceCommit !== input.sourceCommit
    || provenance.manifestSHA256 !== input.manifestSHA256 || provenance.archiveSHA256 !== input.archiveSHA256
    || provenance.binarySHA256 !== input.executableSHA256 || provenance.versionOutput !== manifest.release.versionOutput) {
    promotionFail('local provenance does not bind the exact candidate');
  }
  return Object.freeze({ ...bundle, manifest, provenance });
}

function checksumBytes(input, manifest) {
  return Buffer.from(`${input.executableSHA256}  ${manifest.executable.filename}\n${input.archiveSHA256}  ${manifest.archive.filename}\n`);
}

function expectedAssets(input, manifest, checksums) {
  return [
    { name: manifest.archive.filename, sha256: input.archiveSHA256 },
    { name: 'release-candidate-v2.json', sha256: input.manifestSHA256 },
    { name: `swift-mutation-testing-v${input.version}-SHA256SUMS`, sha256: sha256(checksums) },
  ];
}

export function verifyDownloadedCandidate(input, downloaded) {
  if (!downloaded || !Buffer.isBuffer(downloaded.archiveBytes) || !Buffer.isBuffer(downloaded.manifestBytes)) {
    promotionFail('candidate download is incomplete');
  }
  if (sha256(downloaded.archiveBytes) !== input.archiveSHA256
    || sha256(downloaded.manifestBytes) !== input.manifestSHA256) {
    promotionFail('candidate download digest does not match promotion input');
  }
  const manifest = parseCandidateManifest(downloaded.manifestBytes);
  if (manifest.archive.sha256 !== input.archiveSHA256
    || manifest.executable.sha256 !== input.executableSHA256
    || manifest.sourceCommit !== input.sourceCommit) {
    promotionFail('candidate download manifest does not match promotion input');
  }
  return manifest;
}

export function verifyAssetDownloads(downloaded, expected) {
  if (!downloaded || typeof downloaded !== 'object' || Array.isArray(downloaded)) {
    promotionFail('draft asset downloads are absent');
  }
  const names = Object.keys(downloaded).sort();
  const expectedNames = expected.map(({ name }) => name).sort();
  if (names.length !== expectedNames.length || names.some((name, index) => name !== expectedNames[index])) {
    promotionFail('draft asset downloads do not exactly match the candidate');
  }
  for (const asset of expected) {
    if (!Buffer.isBuffer(downloaded[asset.name]) || sha256(downloaded[asset.name]) !== asset.sha256) {
      promotionFail(`draft asset ${asset.name} digest does not match the candidate`);
    }
  }
}

export function requireAdapter(github) {
  const methods = [
    'readState', 'createDraft', 'uploadAsset',
    'downloadDraftAssets', 'getTagTuple', 'publishDraft',
    'downloadPublicArchive', 'extractPublicExecutable',
  ];
  if (!github || methods.some((method) => typeof github[method] !== 'function')) {
    promotionFail('GitHub adapter is incomplete');
  }
}

export function requireSameTag(current, original) {
  if (JSON.stringify(current) !== JSON.stringify(original)) promotionFail('tag tuple changed during promotion');
}

export async function nativeRun(command, arguments_, options = {}, runCommand = execFile) {
  const { stdout = '' } = await runCommand(command, arguments_, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, ...options });
  return stdout;
}

export function parseJSONBytes(bytes, scope) {
  try {
    return JSON.parse(Buffer.isBuffer(bytes) ? bytes.toString('utf8') : bytes);
  } catch {
    promotionFail(`${scope} returned malformed JSON`);
  }
}

export function createNativeGitHubAdapter({
  token,
  controlRoot,
  candidateControlRoot,
  sourceRoot,
  workRoot,
  input,
  runCommand = nativeRun,
  readFileImpl = readFile,
  writeFileImpl = writeFile,
  mkdirImpl = mkdir,
  chmodImpl = chmod,
  rmImpl = rm,
} = {}) {
  if (typeof token !== 'string' || token.length === 0) promotionFail('GH_TOKEN authentication is required');
  if (![controlRoot, workRoot].every((root) => typeof root === 'string' && path.isAbsolute(root))) {
    promotionFail('native GitHub adapter roots must be absolute');
  }
  const ghEnvironment = { ...process.env, GH_TOKEN: token };
  const gh = async (arguments_, options = {}) => runCommand('gh', ['api', ...arguments_], { env: ghEnvironment, ...options });
  const ghJSON = async (arguments_) => parseJSONBytes(await gh(arguments_), `gh api ${arguments_[0]}`);
  const ghBytes = async (arguments_) => {
    const output = await gh(arguments_, { encoding: 'buffer' });
    return Buffer.isBuffer(output) ? output : Buffer.from(output);
  };
  const getTagTuple = async () => {
    const ref = await ghJSON([`repos/${input.repository}/git/ref/tags/v${input.version}`]);
    const tag = await ghJSON([`repos/${input.repository}/git/tags/${ref.object?.sha}`]);
    return { ref: ref.ref, refSha: ref.object?.sha, tag };
  };

  const repositoryControls = async () => {
    const rulesets = await ghJSON([`repos/${input.repository}/rulesets`]);
    const environment = await ghJSON([`repos/${input.repository}/environments/release-production`]);
    const normalizedRulesets = (Array.isArray(rulesets) ? rulesets : []).map((rule) => ({
      name: rule.name,
      enforcement: rule.enforcement,
      targets: rule.conditions?.ref_name?.include ?? [],
      restrictsUpdates: rule.rules?.some(({ type }) => type === 'update') === true,
      restrictsDeletions: rule.rules?.some(({ type }) => type === 'deletion') === true,
      bypassActors: rule.bypass_actors ?? [],
    }));
    const reviewerRule = environment.protection_rules?.find(({ type }) => type === 'required_reviewers');
    return {
      rulesets: normalizedRulesets,
      environment: {
        name: environment.name,
        requiredApprovals: reviewerRule?.reviewers?.length ?? 0,
        preventSelfReview: reviewerRule?.prevent_self_review === true,
      },
    };
  };

  const downloadReleaseAsset = async (asset) => ghBytes([asset.url, '-H', 'Accept: application/octet-stream']);
  const normalizeRelease = async (release) => {
    if (release === null) return null;
    const assets = [];
    for (const asset of release.assets ?? []) assets.push({ name: asset.name, sha256: sha256(await downloadReleaseAsset(asset)) });
    return { id: release.id, draft: release.draft, assets, rawAssets: release.assets ?? [], upload_url: release.upload_url };
  };
  const findRelease = async () => {
    try {
      return await ghJSON([`repos/${input.repository}/releases/tags/v${input.version}`]);
    } catch (error) {
      if (/404|not found/i.test(`${error?.stderr ?? ''} ${error?.message ?? ''}`)) return null;
      throw error;
    }
  };

  return {
    readState: async () => {
      const controlHead = (await runCommand('git', ['rev-parse', 'HEAD'], { cwd: controlRoot })).trim();
      return {
        controlHead,
        guideProofBytes: await readFileImpl(path.join(controlRoot, 'Docs', 'ReleaseEvidence', 'v1.3.1-guide-proof.json')),
        tagTuple: await getTagTuple(),
        repositoryControls: await repositoryControls(),
        release: await normalizeRelease(await findRelease()),
      };
    },
    getTagTuple,
    createDraft: async ({ tag, name, targetCommitish }) => ghJSON([
      '--method', 'POST', `repos/${input.repository}/releases`,
      '-f', `tag_name=${tag}`, '-f', `name=${name}`, '-f', `target_commitish=${targetCommitish}`, '-F', 'draft=true',
    ]),
    uploadAsset: async (release, asset) => {
      const uploadUrl = typeof release.upload_url === 'string'
        ? release.upload_url.replace(/\{\?name,label\}$/u, '')
        : '';
      const expectedUploadUrl = `https://uploads.github.com/repos/${input.repository}/releases/${release.id}/assets`;
      if (uploadUrl !== expectedUploadUrl) promotionFail('release upload URL is not authoritative');
      const assetPath = path.join(workRoot, `upload-${asset.name}`);
      await writeFileImpl(assetPath, asset.bytes, { flag: 'wx', mode: 0o600 });
      try {
        await gh([
          '--method', 'POST', `${uploadUrl}?name=${encodeURIComponent(asset.name)}`,
          '-H', 'Content-Type: application/octet-stream', '--input', assetPath,
        ]);
      } finally {
        await rmImpl(assetPath, { force: true });
      }
    },
    downloadDraftAssets: async (release) => {
      const current = await ghJSON([`repos/${input.repository}/releases/${release.id}`]);
      const result = {};
      for (const asset of current.assets ?? []) result[asset.name] = await downloadReleaseAsset(asset);
      return result;
    },
    publishDraft: async (release) => ghJSON(['--method', 'PATCH', `repos/${input.repository}/releases/${release.id}`, '-F', 'draft=false']),
    downloadPublicArchive: async () => {
      const release = await findRelease();
      const asset = release?.assets?.find(({ name }) => name === `swift-mutation-testing-v${input.version}-macos.tar.gz`);
      if (!asset || release.draft === true) promotionFail('public release archive is absent');
      return downloadReleaseAsset(asset);
    },
    extractPublicExecutable: async (archiveBytes) => {
      const archivePath = path.join(workRoot, 'public-archive.tar.gz');
      const extractionRoot = path.join(workRoot, 'public-extraction');
      await writeFileImpl(archivePath, archiveBytes, { flag: 'wx', mode: 0o600 });
      await mkdirImpl(extractionRoot, { mode: 0o700, recursive: false });
      await runCommand('tar', ['-xzf', archivePath, '-C', extractionRoot]);
      return readFileImpl(path.join(extractionRoot, 'swift-mutation-testing'));
    },
  };
}

export async function promoteReleaseCandidate(input, github, dependencies = {}) {
  requireAdapter(github);
  if (!dependencies.localBundle) promotionFail('owner-custodied local bundle is required');
  const candidateDownload = verifyLocalBundleCustody(input, dependencies.localBundle);
  const observedState = await github.readState(input);
  const githubState = { ...observedState, manifestBytes: candidateDownload.manifestBytes, provenanceBytes: candidateDownload.provenanceBytes };
  const authority = verifyPromotionAuthority(input, githubState);
  const originalTagTuple = verifyTagTuple(githubState.tagTuple, input);
  verifyRepositoryControls(githubState.repositoryControls);

  const manifest = verifyDownloadedCandidate(input, candidateDownload);
  const verifiedCandidate = dependencies.verifyCandidateBundle
    ? await dependencies.verifyCandidateBundle(candidateDownload)
    : { archiveSHA256: input.archiveSHA256, manifestSHA256: input.manifestSHA256, executableSHA256: input.executableSHA256, manifest };
  if (verifiedCandidate.archiveSHA256 !== input.archiveSHA256
    || verifiedCandidate.manifestSHA256 !== input.manifestSHA256
    || verifiedCandidate.executableSHA256 !== input.executableSHA256
    || JSON.stringify(verifiedCandidate.manifest) !== JSON.stringify(manifest)) {
    promotionFail('Task 1 candidate bundle verification does not match promotion input');
  }
  const checksums = checksumBytes(input, manifest);
  const assets = expectedAssets(input, manifest, checksums);
  const releaseState = classifyReleaseState(githubState.release, assets);
  const mutations = [];

  const requireUnchangedTag = async () => {
    const current = verifyTagTuple(await github.getTagTuple(input), input);
    requireSameTag(current, originalTagTuple);
  };

  await requireUnchangedTag();
  let release = githubState.release;
  if (releaseState === 'absent') {
    release = await github.createDraft({
      repository: input.repository,
      tag: `v${input.version}`,
      name: `swift-mutation-testing ${input.version}`,
      targetCommitish: input.sourceCommit,
    });
    mutations.push('create-draft');
    await requireUnchangedTag();
    const uploadAssets = [
      { name: manifest.archive.filename, bytes: candidateDownload.archiveBytes },
      { name: 'release-candidate-v2.json', bytes: candidateDownload.manifestBytes },
      { name: `swift-mutation-testing-v${input.version}-SHA256SUMS`, bytes: checksums },
    ];
    for (const asset of uploadAssets) {
      await github.uploadAsset(release, asset);
      mutations.push(`upload:${asset.name}`);
    }
  }

  verifyAssetDownloads(await github.downloadDraftAssets(release, assets), assets);
  await requireUnchangedTag();
  await requireUnchangedTag();
  await github.publishDraft(release);
  mutations.push('publish-existing-draft');

  await requireUnchangedTag();
  const publicArchive = await github.downloadPublicArchive(input);
  if (!Buffer.isBuffer(publicArchive) || sha256(publicArchive) !== input.archiveSHA256) {
    promotionFail('public archive digest does not match the proven candidate');
  }
  const publicExecutable = await github.extractPublicExecutable(publicArchive, manifest);
  if (!Buffer.isBuffer(publicExecutable) || sha256(publicExecutable) !== input.executableSHA256) {
    promotionFail('public executable digest does not match the proven candidate');
  }
  return Object.freeze({ authority, mutations: Object.freeze(mutations) });
}

export function parseCliArguments(argv) {
  if (!Array.isArray(argv) || argv.length !== CLI_KEYS.length * 2) promotionFail('usage: exact promotion inputs are required');
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (typeof flag !== 'string' || !flag.startsWith('--') || typeof value !== 'string' || value.length === 0) {
      promotionFail('usage: every promotion flag requires one value');
    }
    const key = flag.slice(2);
    if (!CLI_KEYS.includes(key)) promotionFail(`unknown promotion input ${flag}`);
    if (Object.hasOwn(values, key)) promotionFail(`duplicate promotion input ${flag}`);
    values[key] = value;
  }
  for (const key of ['archive-path', 'manifest-path', 'provenance-path', 'control-root', 'work-root']) {
    if (!path.isAbsolute(values[key])) promotionFail(`${key} must be an absolute path`);
  }
  return {
    input: {
      version: values.version,
      repository: values.repository,
      sourceCommit: values['source-commit'],
      manifestSHA256: values['manifest-sha256'],
      archiveSHA256: values['archive-sha256'],
      executableSHA256: values['executable-sha256'],
      provenanceSHA256: values['provenance-sha256'],
      candidateDescriptorSHA256: values['candidate-descriptor-sha256'],
      controlCommit: values['control-commit'],
      guideCommit: values['guide-commit'],
      guideProofSHA256: values['guide-proof-sha256'],
    },
    paths: { archivePath: values['archive-path'], manifestPath: values['manifest-path'], provenancePath: values['provenance-path'] },
    roots: { controlRoot: values['control-root'], workRoot: values['work-root'] },
  };
}

export async function runCli(argv = process.argv.slice(2), dependencies = {}) {
  const {
    env = process.env,
    createNativeGitHubAdapter: createAdapter = createNativeGitHubAdapter,
    promoteReleaseCandidate: promote = promoteReleaseCandidate,
    stdout = (value) => process.stdout.write(value),
    readFile: readFileImpl = readFile,
    lstat: lstatImpl = lstat,
    mkdir: mkdirImpl = mkdir,
    chmod: chmodImpl = chmod,
  } = dependencies;
  if (typeof env.GH_TOKEN !== 'string' || env.GH_TOKEN.length === 0) promotionFail('GH_TOKEN authentication is required');
  const { input, roots, paths } = parseCliArguments(argv);
  for (const filePath of Object.values(paths)) {
    const metadata = await lstatImpl(filePath);
    if (!metadata.isFile() || metadata.nlink !== 1 || (metadata.mode & 0o777) !== 0o600) promotionFail('local bundle files must be owner-only regular files');
  }
  const localBundle = { archiveBytes: await readFileImpl(paths.archivePath), manifestBytes: await readFileImpl(paths.manifestPath), provenanceBytes: await readFileImpl(paths.provenancePath) };
  await mkdirImpl(roots.workRoot, { mode: 0o700, recursive: false });
  await chmodImpl(roots.workRoot, 0o700);
  const workRootMetadata = await lstatImpl(roots.workRoot);
  if (!workRootMetadata.isDirectory() || (workRootMetadata.mode & 0o777) !== 0o700
    || (typeof process.getuid === 'function' && workRootMetadata.uid !== process.getuid())) {
    promotionFail('work root must be an owner-private directory');
  }
  const github = createAdapter({ token: env.GH_TOKEN, input, ...roots });
  const result = await promote(input, github, { localBundle });
  stdout(`${JSON.stringify(result)}\n`);
  return result;
}

export async function runMain(argv = process.argv.slice(2), dependencies = {}) {
  try { await runCli(argv, dependencies); return 0; }
  catch (error) { (dependencies.stderr ?? ((value) => process.stderr.write(value)))(`${error.message}\n`); return 1; }
}

export async function main({ moduleURL = import.meta.url, argv = process.argv, runMainImpl = runMain } = {}) {
  if (moduleURL !== `file://${argv[1]}`) return false;
  process.exitCode = await runMainImpl(argv.slice(2));
  return true;
}

await main();
