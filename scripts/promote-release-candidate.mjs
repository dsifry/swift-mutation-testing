#!/usr/bin/env node

import {
  classifyReleaseState,
  parseCandidateManifest,
  sha256,
  verifyPromotionAuthority,
  verifyRepositoryControls,
  verifyTagTuple,
} from './release-artifact.mjs';

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

if (import.meta.url === `file://${process.argv[1]}`) {
  process.stderr.write('promotion: native GitHub adapter is supplied by the protected release workflow\n');
  process.exitCode = 1;
}
