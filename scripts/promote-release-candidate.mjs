#!/usr/bin/env node

import { execFile as execFileCallback } from 'node:child_process';
import { chmod, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';

import {
  classifyReleaseState,
  createNativeCandidateVerificationInput,
  parseCandidateManifest,
  sha256,
  verifyCandidateBundle,
  verifyPromotionAuthority,
  verifyRepositoryControls,
  verifyTagTuple,
} from './release-artifact.mjs';

const execFile = promisify(execFileCallback);
const CLI_KEYS = Object.freeze([
  'version', 'repository', 'run-id', 'run-attempt', 'artifact-id', 'artifact-name',
  'source-commit', 'candidate-workflow-commit', 'manifest-sha256', 'archive-sha256', 'executable-sha256',
  'candidate-descriptor-sha256', 'control-commit', 'guide-commit', 'guide-proof-sha256',
  'control-root', 'candidate-control-root', 'source-root', 'work-root',
]);

function promotionFail(message) {
  throw new Error(`promotion: ${message}`);
}

function checksumBytes(input, manifest) {
  return Buffer.from(`${input.executableSHA256}  ${manifest.executable.filename}\n${input.archiveSHA256}  ${manifest.archive.filename}\n`);
}

function expectedAssets(input, manifest, checksums) {
  return [
    { name: manifest.archive.filename, sha256: input.archiveSHA256 },
    { name: 'release-candidate-v1.json', sha256: input.manifestSHA256 },
    { name: `swift-mutation-testing-v${input.version}-SHA256SUMS`, sha256: sha256(checksums) },
  ];
}

function verifyDownloadedCandidate(input, downloaded) {
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
    || manifest.sourceCommit !== input.sourceCommit
    || manifest.run.id !== input.runId
    || manifest.run.attempt !== input.runAttempt
    || manifest.artifactName !== input.artifactName) {
    promotionFail('candidate download manifest does not match promotion input');
  }
  return manifest;
}

function verifyAssetDownloads(downloaded, expected) {
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

function requireAdapter(github) {
  const methods = [
    'readState', 'downloadCandidate', 'createDraft', 'uploadAsset',
    'downloadDraftAssets', 'getTagTuple', 'publishDraft',
    'downloadPublicArchive', 'extractPublicExecutable',
  ];
  if (!github || methods.some((method) => typeof github[method] !== 'function')) {
    promotionFail('GitHub adapter is incomplete');
  }
}

async function nativeRun(command, arguments_, options = {}) {
  const { stdout = '' } = await execFile(command, arguments_, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, ...options });
  return stdout;
}

function parseJSONBytes(bytes, scope) {
  try {
    return JSON.parse(Buffer.isBuffer(bytes) ? bytes.toString('utf8') : bytes);
  } catch {
    promotionFail(`${scope} returned malformed JSON`);
  }
}

function parseAttestationFile(bytes) {
  const line = bytes.toString('utf8').split('\n').find((value) => value.trim().length > 0);
  if (!line) promotionFail('candidate attestation bundle is empty');
  return parseJSONBytes(line, 'candidate attestation');
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
  if (![controlRoot, candidateControlRoot, sourceRoot, workRoot].every((root) => typeof root === 'string' && path.isAbsolute(root))) {
    promotionFail('native GitHub adapter roots must be absolute');
  }
  const ghEnvironment = { ...process.env, GH_TOKEN: token };
  const gh = async (arguments_, options = {}) => runCommand('gh', ['api', ...arguments_], { env: ghEnvironment, ...options });
  const ghJSON = async (arguments_) => parseJSONBytes(await gh(arguments_), `gh api ${arguments_[0]}`);
  const ghBytes = async (arguments_) => {
    const output = await gh(arguments_, { encoding: 'buffer' });
    return Buffer.isBuffer(output) ? output : Buffer.from(output);
  };
  let candidateDownload;
  let workReady = false;

  const prepareWorkRoot = async () => {
    if (workReady) return;
    await mkdirImpl(workRoot, { mode: 0o700, recursive: false });
    await chmodImpl(workRoot, 0o700);
    workReady = true;
  };

  const ensureCandidate = async () => {
    if (candidateDownload) return candidateDownload;
    await prepareWorkRoot();
    const zipPath = path.join(workRoot, 'candidate.zip');
    const artifactRoot = path.join(workRoot, 'candidate');
    await writeFileImpl(zipPath, await ghBytes([`repos/${input.repository}/actions/artifacts/${input.artifactId}/zip`]), { flag: 'wx', mode: 0o600 });
    await mkdirImpl(artifactRoot, { mode: 0o700, recursive: false });
    await runCommand('unzip', ['-q', zipPath, '-d', artifactRoot]);
    const archivePath = path.join(artifactRoot, `swift-mutation-testing-v${input.version}-macos.tar.gz`);
    const manifestPath = path.join(artifactRoot, 'release-candidate-v1.json');
    candidateDownload = {
      archiveBytes: await readFileImpl(archivePath),
      manifestBytes: await readFileImpl(manifestPath),
      verificationInput: createNativeCandidateVerificationInput({
        controlRoot: candidateControlRoot,
        sourceRoot,
        artifactRoot,
        archivePath,
        manifestPath,
        privateDirectory: path.join(workRoot, 'candidate-verification'),
        runCommand,
      }),
      attestations: {
        archive: parseAttestationFile(await readFileImpl(path.join(artifactRoot, 'archive-attestation-bundle-v1.jsonl'))),
        manifest: parseAttestationFile(await readFileImpl(path.join(artifactRoot, 'manifest-attestation-bundle-v1.jsonl'))),
      },
    };
    return candidateDownload;
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
    return { id: release.id, draft: release.draft, assets, rawAssets: release.assets ?? [] };
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
      const downloaded = await ensureCandidate();
      const run = await ghJSON([`repos/${input.repository}/actions/runs/${input.runId}`]);
      const artifact = await ghJSON([`repos/${input.repository}/actions/artifacts/${input.artifactId}`]);
      const controlHead = (await runCommand('git', ['rev-parse', 'HEAD'], { cwd: controlRoot })).trim();
      return {
        controlHead,
        guideProofBytes: await readFileImpl(path.join(controlRoot, 'Docs', 'ReleaseEvidence', 'v1.3.1-guide-proof.json')),
        run: {
          repository: run.repository?.full_name,
          workflowPath: run.path,
          headBranch: run.head_branch,
          headSha: run.head_sha,
          event: run.event,
          status: run.status,
          conclusion: run.conclusion,
          runAttempt: run.run_attempt,
        },
        artifact: {
          id: artifact.id,
          name: artifact.name,
          workflowRunId: artifact.workflow_run?.id,
          expired: artifact.expired,
          deleted: artifact.deleted_at !== null && artifact.deleted_at !== undefined,
        },
        attestations: downloaded.attestations,
        manifestBytes: downloaded.manifestBytes,
        tagTuple: await getTagTuple(),
        repositoryControls: await repositoryControls(),
        release: await normalizeRelease(await findRelease()),
      };
    },
    downloadCandidate: ensureCandidate,
    getTagTuple,
    createDraft: async ({ tag, name, targetCommitish }) => ghJSON([
      '--method', 'POST', `repos/${input.repository}/releases`,
      '-f', `tag_name=${tag}`, '-f', `name=${name}`, '-f', `target_commitish=${targetCommitish}`, '-F', 'draft=true',
    ]),
    uploadAsset: async (release, asset) => {
      const assetPath = path.join(workRoot, `upload-${asset.name}`);
      await writeFileImpl(assetPath, asset.bytes, { flag: 'wx', mode: 0o600 });
      try {
        await gh([
          '--method', 'POST', `repos/${input.repository}/releases/${release.id}/assets?name=${encodeURIComponent(asset.name)}`,
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

export async function promoteReleaseCandidate(input, github) {
  requireAdapter(github);
  const githubState = await github.readState(input);
  const authority = verifyPromotionAuthority(input, githubState);
  const originalTagTuple = verifyTagTuple(githubState.tagTuple, input);
  verifyRepositoryControls(githubState.repositoryControls);

  const candidateDownload = await github.downloadCandidate({
    repository: input.repository,
    runId: input.runId,
    runAttempt: input.runAttempt,
    artifactId: input.artifactId,
    artifactName: input.artifactName,
  });
  const manifest = verifyDownloadedCandidate(input, candidateDownload);
  if (!candidateDownload.verificationInput) promotionFail('candidate verification input is absent');
  const verifiedCandidate = await verifyCandidateBundle(candidateDownload.verificationInput);
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
    if (JSON.stringify(current) !== JSON.stringify(originalTagTuple)) {
      promotionFail('tag tuple changed during promotion');
    }
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
      { name: 'release-candidate-v1.json', bytes: candidateDownload.manifestBytes },
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

function parseCliArguments(argv) {
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
  if (CLI_KEYS.some((key) => !Object.hasOwn(values, key))) promotionFail('usage: exact promotion inputs are required');
  for (const key of ['control-root', 'candidate-control-root', 'source-root', 'work-root']) {
    if (!path.isAbsolute(values[key])) promotionFail(`${key} must be an absolute path`);
  }
  const parseInteger = (key) => {
    if (!/^[1-9]\d*$/u.test(values[key])) promotionFail(`${key} must be a positive integer`);
    const parsed = Number(values[key]);
    if (!Number.isSafeInteger(parsed)) promotionFail(`${key} must be a positive safe integer`);
    return parsed;
  };
  return {
    input: {
      version: values.version,
      repository: values.repository,
      runId: parseInteger('run-id'),
      runAttempt: parseInteger('run-attempt'),
      artifactId: parseInteger('artifact-id'),
      artifactName: values['artifact-name'],
      sourceCommit: values['source-commit'],
      candidateWorkflowCommit: values['candidate-workflow-commit'],
      manifestSHA256: values['manifest-sha256'],
      archiveSHA256: values['archive-sha256'],
      executableSHA256: values['executable-sha256'],
      candidateDescriptorSHA256: values['candidate-descriptor-sha256'],
      controlCommit: values['control-commit'],
      guideCommit: values['guide-commit'],
      guideProofSHA256: values['guide-proof-sha256'],
    },
    roots: { controlRoot: values['control-root'], candidateControlRoot: values['candidate-control-root'], sourceRoot: values['source-root'], workRoot: values['work-root'] },
  };
}

export async function runCli(argv = process.argv.slice(2), dependencies = {}) {
  const {
    env = process.env,
    createNativeGitHubAdapter: createAdapter = createNativeGitHubAdapter,
    promoteReleaseCandidate: promote = promoteReleaseCandidate,
    stdout = (value) => process.stdout.write(value),
  } = dependencies;
  if (typeof env.GH_TOKEN !== 'string' || env.GH_TOKEN.length === 0) promotionFail('GH_TOKEN authentication is required');
  const { input, roots } = parseCliArguments(argv);
  const github = createAdapter({ token: env.GH_TOKEN, input, ...roots });
  const result = await promote(input, github);
  stdout(`${JSON.stringify(result)}\n`);
  return result;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  runCli().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
