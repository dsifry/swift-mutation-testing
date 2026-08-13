import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

import {
  classifyReleaseState,
  parseGuideReleaseProof,
  sha256,
  verifyPromotionAuthority,
  verifyRepositoryControls,
  verifyTagTuple,
} from '../../scripts/release-artifact.mjs';
import { promoteReleaseCandidate } from '../../scripts/promote-release-candidate.mjs';
import * as promotionOwner from '../../scripts/promote-release-candidate.mjs';

const fixtures = path.join(import.meta.dirname, 'fixtures');
const candidateBytes = await readFile(path.join(fixtures, 'candidate-valid.json'));
const candidate = JSON.parse(candidateBytes);
const archiveBytes = Buffer.from('candidate archive bytes');
const executableBytes = Buffer.from('candidate executable bytes');
const archiveSHA256 = sha256(archiveBytes);
const executableSHA256 = sha256(executableBytes);
candidate.archive.sha256 = archiveSHA256;
candidate.executable.sha256 = executableSHA256;
const manifestBytes = Buffer.from(`${JSON.stringify(candidate, null, 2)}\n`);
const manifestSHA256 = sha256(manifestBytes);
const commit = candidate.sourceCommit;
const controlCommit = 'e'.repeat(40);
const guideCommit = 'b'.repeat(40);
const candidateDescriptorSHA256 = 'f'.repeat(64);
const candidateWorkflowCommit = candidate.workflow.commit;
const localProvenance = {
  schemaVersion: 'local-release-provenance-v1', repository: candidate.repository, sourceCommit: commit,
  versionOutput: candidate.release.versionOutput, capability: 'prepared-cache-v1', manifestSHA256,
  archiveSHA256, binarySHA256: executableSHA256, swiftVersionOutput: 'Apple Swift version 6.3.3',
  sdkVersionOutput: '26.0', targetTriple: 'arm64-apple-macosx26.0', configuration: 'release', codesignVerified: true,
};
const localProvenanceBytes = Buffer.from(`${JSON.stringify(localProvenance)}\n`);
const localDescriptorSHA256 = sha256(localProvenanceBytes);
const localBundle = { archiveBytes, manifestBytes, provenanceBytes: localProvenanceBytes };

test('local bundle custody authenticates canonical provenance before any GitHub mutation', async () => {
  const provenance = {
    schemaVersion: 'local-release-provenance-v1', repository: 'dsifry/swift-mutation-testing', sourceCommit: commit,
    versionOutput: candidate.release.versionOutput, capability: 'prepared-cache-v1',
    manifestSHA256, archiveSHA256, binarySHA256: executableSHA256,
    swiftVersionOutput: 'Apple Swift version 6.3.3', sdkVersionOutput: '26.0',
    targetTriple: 'arm64-apple-macosx26.0', configuration: 'release', codesignVerified: true,
  };
  const provenanceBytes = Buffer.from(`${JSON.stringify(provenance)}\n`);
  const verified = promotionOwner.verifyLocalBundleCustody({
    sourceCommit: commit, manifestSHA256, archiveSHA256, executableSHA256,
    provenanceSHA256: sha256(provenanceBytes),
  }, { archiveBytes, manifestBytes, provenanceBytes });
  assert.equal(verified.archiveBytes, archiveBytes);
  assert.equal(verified.manifestBytes, manifestBytes);
  assert.deepEqual(verified.provenance, provenance);
  assert.throws(() => promotionOwner.verifyLocalBundleCustody({
    sourceCommit: commit, manifestSHA256, archiveSHA256, executableSHA256,
    provenanceSHA256: '0'.repeat(64),
  }, { archiveBytes, manifestBytes, provenanceBytes }), /provenance/i);
  assert.throws(() => promotionOwner.verifyLocalBundleCustody({
    sourceCommit: commit, manifestSHA256, archiveSHA256, executableSHA256,
    provenanceSHA256: sha256(provenanceBytes),
  }, { archiveBytes, manifestBytes }), /incomplete/i);
  for (const incomplete of [null, {}, { archiveBytes }, { archiveBytes, manifestBytes: 'not bytes', provenanceBytes }]) {
    assert.throws(() => promotionOwner.verifyLocalBundleCustody({}, incomplete), /incomplete/i);
  }
  assert.throws(() => promotionOwner.verifyLocalBundleCustody({
    sourceCommit: commit, manifestSHA256: '0'.repeat(64), archiveSHA256, executableSHA256,
    provenanceSHA256: sha256(provenanceBytes),
  }, { archiveBytes, manifestBytes, provenanceBytes }), /bundle digest/i);
  assert.throws(() => promotionOwner.verifyLocalBundleCustody({
    sourceCommit: commit, manifestSHA256, archiveSHA256: '0'.repeat(64), executableSHA256,
    provenanceSHA256: sha256(provenanceBytes),
  }, { archiveBytes, manifestBytes, provenanceBytes }), /bundle digest/i);
  const mismatched = Buffer.from(`${JSON.stringify({ ...provenance, sourceCommit: '9'.repeat(40) })}\n`);
  assert.throws(() => promotionOwner.verifyLocalBundleCustody({
    sourceCommit: commit, manifestSHA256, archiveSHA256, executableSHA256,
    provenanceSHA256: sha256(mismatched),
  }, { archiveBytes, manifestBytes, provenanceBytes: mismatched }), /does not bind/i);
});

test('promotion primary local path never downloads or substitutes candidate bytes', async () => {
  const provenance = {
    schemaVersion: 'local-release-provenance-v1', repository: candidate.repository, sourceCommit: commit,
    versionOutput: candidate.release.versionOutput, capability: 'prepared-cache-v1', manifestSHA256,
    archiveSHA256, binarySHA256: executableSHA256, swiftVersionOutput: 'Apple Swift version 6.3.3',
    sdkVersionOutput: '26.0', targetTriple: 'arm64-apple-macosx26.0', configuration: 'release', codesignVerified: true,
  };
  const provenanceBytes = Buffer.from(`${JSON.stringify(provenance)}\n`);
  const value = state();
  const mutations = [];
  const github = githubFor(value, mutations);
  github.downloadCandidate = async () => { throw new Error('remote candidate download forbidden'); };
  const input = promotionInput({ provenanceSHA256: sha256(provenanceBytes) });
  const result = await promoteReleaseCandidate(input, github, {
    localBundle: { archiveBytes, manifestBytes, provenanceBytes },
    verifyCandidateBundle: async () => ({ archiveSHA256, manifestSHA256, executableSHA256, manifest: candidate }),
  });
  assert.equal(result.mutations.includes(`upload:${candidate.archive.filename}`), true);
});

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function canonicalProof(overrides = {}) {
  const value = {
    schemaVersion: 'guide-release-proof-v1',
    repository: 'dsifry/theguide',
    guideCommit,
    candidate: {
      descriptorSHA256: localDescriptorSHA256,
      repository: candidate.repository,
      sourceCommit: commit,
      versionOutput: localProvenance.versionOutput,
      capability: localProvenance.capability,
      manifestSHA256,
      archiveSHA256,
      executableSHA256,
      swiftVersionOutput: localProvenance.swiftVersionOutput,
      sdkVersionOutput: localProvenance.sdkVersionOutput,
      targetTriple: localProvenance.targetTriple,
      configuration: 'release',
      codesignVerified: true,
    },
    result: {
      status: 'pass',
      selectors: { count: 1, coldTupleSHA256: 'a'.repeat(64), warmTupleSHA256: 'a'.repeat(64) },
      cacheReuse: { uncachedBuilds: 10, warmFullBuilds: 0, warmIncrementalBuilds: 1, warmFallbackBuilds: 1, zeroResidue: true, receiptSHA256: '1'.repeat(64) },
      lightweightGate: { receiptSHA256: '5'.repeat(64) },
      drills: {
        recovery: { receiptSHA256: '2'.repeat(64) },
        privacy: { receiptSHA256: '3'.repeat(64) },
        retention: { receiptSHA256: '4'.repeat(64) },
        'literal-kill': { receiptSHA256: '6'.repeat(64) },
      },
    },
  };
  return Object.assign(value, overrides);
}

function proofBytes(value = canonicalProof()) {
  return Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
}

function promotionInput(overrides = {}) {
  const bytes = proofBytes();
  return {
    version: '1.3.1',
    repository: candidate.repository,
    sourceCommit: commit,
    manifestSHA256,
    archiveSHA256,
    executableSHA256,
    provenanceSHA256: localDescriptorSHA256,
    candidateDescriptorSHA256: localDescriptorSHA256,
    controlCommit,
    guideCommit,
    guideProofSHA256: sha256(bytes),
    ...overrides,
  };
}

function attestation(subjectName, digest) {
  return [{
    attestation: { mediaType: 'application/vnd.dev.sigstore.bundle.v0.3+json' },
    verificationResult: {
      signature: { certificate: { sourceRepository: `https://github.com/${candidate.repository}` } },
      verifiedTimestamps: [{ type: 'transparency-log' }],
      statement: {
        _type: 'https://in-toto.io/Statement/v1',
        subject: [{ name: subjectName, digest: { sha256: digest } }],
        predicateType: 'https://slsa.dev/provenance/v1',
        predicate: {
          runDetails: { metadata: { invocationId: `https://github.com/${candidate.repository}/actions/runs/${candidate.run.id}/attempts/${candidate.run.attempt}` } },
        },
      },
    },
  }];
}

function state(overrides = {}) {
  return {
    controlHead: controlCommit,
    guideProofBytes: proofBytes(),
    provenanceBytes: localProvenanceBytes,
    run: {
      repository: candidate.repository,
      workflowPath: candidate.workflow.path,
      headBranch: 'main',
      headSha: candidate.workflow.commit,
      event: 'workflow_dispatch',
      status: 'completed',
      conclusion: 'success',
      runAttempt: candidate.run.attempt,
    },
    artifact: { id: 444, name: candidate.artifactName, workflowRunId: candidate.run.id, expired: false, deleted: false },
    attestations: {
      archive: attestation(candidate.archive.filename, archiveSHA256),
      manifest: attestation('release-candidate-v2.json', manifestSHA256),
    },
    manifestBytes,
    tagTuple: {
      ref: 'refs/tags/v1.3.1',
      refSha: 'c'.repeat(40),
      tag: { sha: 'c'.repeat(40), tag: 'v1.3.1', object: { type: 'commit', sha: commit }, verification: { verified: true, reason: 'valid' } },
    },
    repositoryControls: {
      rulesets: [{ name: 'immutable-release-tags', enforcement: 'active', targets: ['refs/tags/v*'], restrictsUpdates: true, restrictsDeletions: true, bypassActors: [] }],
      environment: { name: 'release-production', requiredApprovals: 1, preventSelfReview: true },
    },
    release: null,
    ...overrides,
  };
}

function expectedAssets() {
  const checksum = Buffer.from(`${executableSHA256}  swift-mutation-testing\n${archiveSHA256}  ${candidate.archive.filename}\n`);
  return [
    { name: candidate.archive.filename, sha256: archiveSHA256 },
    { name: 'release-candidate-v2.json', sha256: manifestSHA256 },
    { name: 'swift-mutation-testing-v1.3.1-SHA256SUMS', sha256: sha256(checksum) },
  ];
}

function candidateVerificationInput(overrides = {}) {
  const records = [];
  const input = {
    controlRoot: '/candidate-control',
    sourceRoot: '/source',
    artifactRoot: '/candidate',
    archivePath: `/candidate/${candidate.archive.filename}`,
    manifestPath: '/candidate/release-candidate-v2.json',
    privateDirectory: '/private',
    fs: {
      readOwnedRegularFile: async (filePath) => {
        records.push(`read:${filePath}`);
        if (filePath.endsWith('.json')) return manifestBytes;
        if (filePath.endsWith('.tar.gz') || filePath.endsWith('.candidate-archive')) return archiveBytes;
        return executableBytes;
      },
      mkdirFreshPrivate: async (directory) => { records.push(`mkdir:${directory}`); },
      stageOwnedArchive: async () => ({ path: '/private/.candidate-archive', bytes: archiveBytes }),
    },
    commands: {
      tar: {
        list: async () => [{ path: candidate.executable.filename, type: 'file', linkCount: 1, mode: candidate.executable.mode, size: candidate.executable.size }],
        extract: async () => { records.push('extract'); },
      },
      codesign: { verify: async () => true },
      file: { inspect: async () => ({ type: 'Mach-O 64-bit executable arm64' }) },
      otool: { inspect: async () => ({ uuid: candidate.executable.uuid, cpuType: candidate.toolchain.cpuType, deploymentTarget: candidate.toolchain.deploymentTarget }) },
      executable: { version: async () => candidate.release.versionOutput },
    },
    git: {
      controlHead: async () => candidate.workflow.commit,
      sourceHead: async () => candidate.sourceCommit,
      isAncestor: async () => true,
    },
  };
  return { input: Object.assign(input, overrides), records };
}

test('Guide proof accepts only canonical content-free evidence', () => {
  const bytes = proofBytes();
  assert.deepEqual(parseGuideReleaseProof(bytes), canonicalProof());
  assert.throws(() => parseGuideReleaseProof(Buffer.from(JSON.stringify(canonicalProof()))), /Guide proof.*canonical/i);
});

test('Guide proof binds a distinct Guide repository and commit plus all receipt digests', () => {
  const proof = parseGuideReleaseProof(proofBytes());
  assert.equal(proof.repository, 'dsifry/theguide');
  assert.equal(proof.guideCommit, guideCommit);
  assert.notEqual(proof.guideCommit, controlCommit);
  assert.equal(proof.candidate.descriptorSHA256, localDescriptorSHA256);
  assert.match(proof.result.cacheReuse.receiptSHA256, /^[a-f0-9]{64}$/u);
  for (const drill of Object.values(proof.result.drills)) {
    assert.match(drill.receiptSHA256, /^[a-f0-9]{64}$/u);
  }
});

for (const [name, mutate] of [
  ['input digest mismatch', (value) => { value.manifestBytes = Buffer.from(JSON.stringify(candidate)); }],
  ['wrong proof digest', (value) => { value.guideProofBytes = proofBytes(); }],
]) {
  test(`promotion authority rejects ${name}`, () => {
    const input = promotionInput();
    const value = state();
    mutate(value);
    if (name === 'wrong proof digest') input.guideProofSHA256 = 'd'.repeat(64);
    assert.throws(() => verifyPromotionAuthority(input, value), /promotion|Guide proof|attestation|candidate/i);
  });
}

test('promotion authority rejects absent and malformed Guide proof', () => {
  assert.throws(() => verifyPromotionAuthority(promotionInput(), state({ guideProofBytes: undefined })), /Guide proof|promotion/i);
  const malformed = Buffer.from('{"schemaVersion":');
  assert.throws(() => verifyPromotionAuthority(
    promotionInput({ guideProofSHA256: sha256(malformed) }),
    state({ guideProofBytes: malformed }),
  ), /Guide proof|promotion/i);
});

for (const [name, mutate] of [
  ['wrong proof commit', (proof) => { proof.guideCommit = 'd'.repeat(40); }],
  ['wrong Guide repository', (proof) => { proof.repository = 'dsifry/swift-mutation-testing'; }],
  ['wrong candidate descriptor digest', (proof) => { proof.candidate.descriptorSHA256 = 'd'.repeat(64); }],
  ['wrong candidate descriptor', (proof) => { proof.candidate.capability = 'other'; }],
  ['failed result', (proof) => { proof.result.status = 'failed'; }],
  ['wrong selector count', (proof) => { proof.result.selectors.count = 0; }],
  ['unequal tuple digests', (proof) => { proof.result.selectors.warmTupleSHA256 = 'b'.repeat(64); }],
  ['invalid cache evidence', (proof) => { proof.result.cacheReuse.zeroResidue = false; }],
  ['missing benchmark receipt digest', (proof) => { delete proof.result.cacheReuse.receiptSHA256; }],
  ['failed recovery drill', (proof) => { proof.result.drills.recovery.receiptSHA256 = 'bad'; }],
  ['failed privacy drill', (proof) => { proof.result.drills.privacy.receiptSHA256 = 'bad'; }],
  ['failed retention drill', (proof) => { proof.result.drills.retention.receiptSHA256 = 'bad'; }],
  ['malformed lightweight receipt digest', (proof) => { proof.result.lightweightGate.receiptSHA256 = 'invalid'; }],
]) {
  test(`promotion authority rejects ${name}`, () => {
    const proof = canonicalProof();
    mutate(proof);
    const bytes = proofBytes(proof);
    const input = promotionInput({ guideProofSHA256: sha256(bytes), ...(name === 'wrong proof commit' ? { guideCommit: 'a'.repeat(40) } : {}) });
    assert.throws(() => verifyPromotionAuthority(input, state({ guideProofBytes: bytes })), /Guide proof|promotion/i);
  });
}

for (const [name, mutate] of [
  ['missing tag', (value) => { value.tagTuple = null; }],
  ['lightweight tag', (value) => { value.tagTuple.tag = null; }],
  ['unverified tag', (value) => { value.tagTuple.tag.verification.verified = false; }],
  ['wrong signature reason', (value) => { value.tagTuple.tag.verification.reason = 'expired_key'; }],
  ['tag-to-tag target', (value) => { value.tagTuple.tag.object.type = 'tag'; }],
  ['wrong target commit', (value) => { value.tagTuple.tag.object.sha = 'e'.repeat(40); }],
]) {
  test(`tag verifier rejects ${name}`, () => {
    const value = state();
    mutate(value);
    assert.throws(() => verifyTagTuple(value.tagTuple, promotionInput()), /tag/i);
  });
}

for (const [name, mutate] of [
  ['missing ruleset', (value) => { value.repositoryControls.rulesets = []; }],
  ['weak ruleset', (value) => { value.repositoryControls.rulesets[0].restrictsDeletions = false; }],
  ['bypassed ruleset', (value) => { value.repositoryControls.rulesets[0].bypassActors = ['maintainer']; }],
  ['approval-free environment', (value) => { value.repositoryControls.environment.requiredApprovals = 0; }],
  ['self-approvable environment', (value) => { value.repositoryControls.environment.preventSelfReview = false; }],
  ['missing environment', (value) => { value.repositoryControls.environment = null; }],
]) {
  test(`repository controls reject ${name}`, () => {
    const value = state();
    mutate(value);
    assert.throws(() => verifyRepositoryControls(value.repositoryControls), /repository controls|environment|ruleset/i);
  });
}

test('release state allows only an absent release or exact matching draft', () => {
  assert.equal(classifyReleaseState(null, expectedAssets()), 'absent');
  assert.equal(classifyReleaseState({ draft: true, assets: expectedAssets() }, expectedAssets()), 'exact-draft');
  assert.throws(() => classifyReleaseState({ draft: true, assets: expectedAssets().slice(1) }, expectedAssets()), /draft/i);
  assert.throws(() => classifyReleaseState({ draft: false, assets: [] }, expectedAssets()), /public/i);
});

function githubFor(value, mutations) {
  return {
    readState: async () => value,
    downloadCandidate: async ({ repository }) => {
      assert.equal(repository, candidate.repository);
      return { archiveBytes, manifestBytes, provenanceBytes: localProvenanceBytes, verificationInput: candidateVerificationInput().input };
    },
    createDraft: async () => { mutations.push('create-draft'); return { draft: true, assets: [] }; },
    uploadAsset: async (_release, asset) => { mutations.push(`upload:${asset.name}`); },
    downloadDraftAssets: async () => ({
      [candidate.archive.filename]: archiveBytes,
      'release-candidate-v2.json': manifestBytes,
      'swift-mutation-testing-v1.3.1-SHA256SUMS': Buffer.from(`${executableSHA256}  swift-mutation-testing\n${archiveSHA256}  ${candidate.archive.filename}\n`),
    }),
    getTagTuple: async () => value.tagTuple,
    publishDraft: async () => { mutations.push('publish-existing-draft'); },
    downloadPublicArchive: async () => archiveBytes,
    extractPublicExecutable: async () => executableBytes,
  };
}

async function assertNoMutation(value) {
  const mutations = [];
  await assert.rejects(() => promoteReleaseCandidate(promotionInput(), githubFor(value, mutations), { localBundle }), /promotion|Guide proof|tag|repository|draft|public|candidate/i);
  assert.deepEqual(mutations, []);
}

test('rejected authority stops before its first GitHub mutation', async () => {
  const value = state();
  value.guideProofBytes = Buffer.from('invalid');
  await assertNoMutation(value);
});

test('rejected tag or repository controls stop before the first GitHub mutation', async () => {
  await assertNoMutation(state({ tagTuple: null }));
  await assertNoMutation(state({ repositoryControls: { rulesets: [], environment: null } }));
});

test('candidate download mismatch stops before the first GitHub mutation', async () => {
  const value = state();
  const mutations = [];
  const github = githubFor(value, mutations);
  github.downloadCandidate = async () => ({ archiveBytes: Buffer.from('substituted'), manifestBytes });
  await assert.rejects(() => promoteReleaseCandidate(promotionInput(), github), /promotion|candidate/i);
  assert.deepEqual(mutations, []);
});

test('Task 1 candidate bundle verification rejects a bad executable before the first GitHub mutation', async () => {
  const value = state();
  const mutations = [];
  const github = githubFor(value, mutations);
  const verification = candidateVerificationInput();
  verification.input.commands.codesign.verify = async () => false;
  github.downloadCandidate = async () => ({ archiveBytes, manifestBytes, provenanceBytes: localProvenanceBytes, verificationInput: verification.input });
  await assert.rejects(() => promoteReleaseCandidate(promotionInput(), github, { localBundle, verifyCandidateBundle: async () => { throw new Error('candidate bundle signature'); } }), /signature|candidate bundle/i);
  assert.deepEqual(mutations, []);
});

test('absent release uploads the unchanged candidate and canonical checksums before publishing', async () => {
  const value = state();
  const mutations = [];
  const uploads = [];
  const github = githubFor(value, mutations);
  github.uploadAsset = async (_release, asset) => {
    mutations.push(`upload:${asset.name}`);
    uploads.push(asset);
  };
  const result = await promoteReleaseCandidate(promotionInput(), github, { localBundle });
  assert.deepEqual(result.mutations, [
    'create-draft',
    `upload:${candidate.archive.filename}`,
    'upload:release-candidate-v2.json',
    'upload:swift-mutation-testing-v1.3.1-SHA256SUMS',
    'publish-existing-draft',
  ]);
  assert.equal(uploads[0].bytes, archiveBytes);
  assert.equal(uploads[1].bytes, manifestBytes);
  assert.deepEqual(uploads[2].bytes, Buffer.from(`${executableSHA256}  swift-mutation-testing\n${archiveSHA256}  ${candidate.archive.filename}\n`));
});

test('exact draft retry is idempotent', async () => {
  const value = state({ release: { draft: true, assets: expectedAssets() } });
  const mutations = [];
  const result = await promoteReleaseCandidate(promotionInput(), githubFor(value, mutations), { localBundle });
  assert.deepEqual(result.mutations, ['publish-existing-draft']);
  assert.deepEqual(mutations, ['publish-existing-draft']);
});

test('mismatched draft and any public collision fail closed', async () => {
  await assertNoMutation(state({ release: { draft: true, assets: expectedAssets().slice(1) } }));
  await assertNoMutation(state({ release: { draft: false, assets: [] } }));
});

test('tag substitution before upload, publish, or public verification fails closed', async () => {
  for (const position of [1, 2, 3, 4, 5]) {
    const value = state();
    const mutations = [];
    const github = githubFor(value, mutations);
    let reads = 0;
    github.getTagTuple = async () => {
      reads += 1;
      return reads === position ? { ...value.tagTuple, refSha: 'd'.repeat(40) } : value.tagTuple;
    };
    await assert.rejects(() => promoteReleaseCandidate(promotionInput(), github, { localBundle }), /tag/i);
    assert.equal(mutations.includes('publish-existing-draft'), position === 5);
  }
});

test('tag substitution after draft creation stops before the first asset upload', async () => {
  const value = state();
  const mutations = [];
  const github = githubFor(value, mutations);
  let draftCreated = false;
  github.createDraft = async () => {
    draftCreated = true;
    mutations.push('create-draft');
    return { draft: true, assets: [] };
  };
  github.getTagTuple = async () => draftCreated
    ? { ...value.tagTuple, refSha: 'd'.repeat(40) }
    : value.tagTuple;
  await assert.rejects(() => promoteReleaseCandidate(promotionInput(), github, { localBundle }), /tag/i);
  assert.deepEqual(mutations, ['create-draft']);
});

function validCliArguments() {
  return [
    '--version', '1.3.1', '--repository', candidate.repository,
    '--source-commit', commit,
    '--manifest-sha256', manifestSHA256,
    '--archive-sha256', archiveSHA256, '--executable-sha256', executableSHA256,
    '--provenance-sha256', localDescriptorSHA256,
    '--candidate-descriptor-sha256', localDescriptorSHA256,
    '--control-commit', controlCommit, '--guide-commit', guideCommit,
    '--guide-proof-sha256', sha256(proofBytes()),
    '--archive-path', '/bundle/archive.tar.gz', '--manifest-path', '/bundle/release-candidate-v2.json',
    '--provenance-path', '/bundle/local-release-provenance-v1.json',
    '--control-root', '/control', '--work-root', '/work',
  ];
}

test('CLI parses the exact proof-bound inputs and executes promotion with GH_TOKEN', async () => {
  const output = [];
  let observed;
  await promotionOwner.runCli(validCliArguments(), {
    env: { GH_TOKEN: 'secret' },
    createNativeGitHubAdapter: (options) => ({ options }),
    promoteReleaseCandidate: async (input, github) => {
      observed = { input, github };
      return { mutations: ['publish-existing-draft'] };
    },
    lstat: async () => ({ isFile: () => true, nlink: 1, mode: 0o100600 }),
    readFile: async (filePath) => filePath.endsWith('tar.gz') ? archiveBytes : filePath.endsWith('v2.json') ? manifestBytes : localProvenanceBytes,
    stdout: (value) => output.push(value),
  });
  assert.deepEqual(observed.input, promotionInput());
  assert.equal(observed.github.options.token, 'secret');
  assert.equal(observed.github.options.controlRoot, '/control');
  assert.deepEqual(output, ['{"mutations":["publish-existing-draft"]}\n']);
});

test('CLI fails closed for absent auth or any missing, duplicate, or unknown input', async () => {
  const valid = validCliArguments();
  const dependencies = { env: { GH_TOKEN: 'secret' }, createNativeGitHubAdapter: () => ({}), promoteReleaseCandidate: async () => ({ mutations: [] }) };
  await assert.rejects(() => promotionOwner.runCli(valid, { ...dependencies, env: {} }), /GH_TOKEN|auth/i);
  await assert.rejects(() => promotionOwner.runCli(valid.slice(2), dependencies), /usage|input/i);
  await assert.rejects(() => promotionOwner.runCli([...valid, '--version', '1.3.1'], dependencies), /usage|duplicate/i);
  await assert.rejects(() => promotionOwner.runCli([...valid, '--unknown', 'value'], dependencies), /usage|unknown/i);
  for (const metadata of [
    { isFile: () => false, nlink: 1, mode: 0o100600 },
    { isFile: () => true, nlink: 2, mode: 0o100600 },
    { isFile: () => true, nlink: 1, mode: 0o100644 },
  ]) await assert.rejects(() => promotionOwner.runCli(valid, { ...dependencies, lstat: async () => metadata }), /owner-only/i);
});

test('promotion decision seams reject incomplete downloads, assets, adapters, and malformed JSON', () => {
  assert.throws(() => promotionOwner.verifyDownloadedCandidate(promotionInput(), null), /incomplete/);
  assert.throws(() => promotionOwner.verifyDownloadedCandidate(promotionInput(), { archiveBytes, manifestBytes: 'bad' }), /incomplete/);
  assert.throws(() => promotionOwner.verifyDownloadedCandidate({ ...promotionInput(), archiveSHA256: '0'.repeat(64) }, { archiveBytes, manifestBytes }), /digest/);
  assert.throws(() => promotionOwner.verifyDownloadedCandidate({ ...promotionInput(), manifestSHA256: '0'.repeat(64) }, { archiveBytes, manifestBytes }), /digest/);
  const wrong = structuredClone(candidate); wrong.run.id += 1; const wrongBytes=Buffer.from(JSON.stringify(wrong)); const wrongInput={...promotionInput(),manifestSHA256:sha256(wrongBytes)};
  assert.throws(() => promotionOwner.verifyDownloadedCandidate(wrongInput, { archiveBytes, manifestBytes: wrongBytes }), /manifest/);
  assert.throws(() => promotionOwner.verifyDownloadedCandidate({...promotionInput(),sourceCommit:'d'.repeat(40)}, {archiveBytes,manifestBytes}),/manifest/);
  assert.throws(() => promotionOwner.verifyAssetDownloads(null, expectedAssets()), /absent/);
  assert.throws(() => promotionOwner.verifyAssetDownloads([], expectedAssets()), /absent/);
  assert.throws(() => promotionOwner.verifyAssetDownloads({}, expectedAssets()), /exactly/);
  const badAssets = Object.fromEntries(expectedAssets().map(({name}) => [name, Buffer.from('bad')]));
  assert.throws(() => promotionOwner.verifyAssetDownloads(badAssets, expectedAssets()), /digest/);
  assert.throws(() => promotionOwner.requireAdapter({}), /incomplete/);
  assert.throws(() => promotionOwner.requireSameTag({a:1},{a:2}), /tag tuple/);
  assert.doesNotThrow(() => promotionOwner.requireSameTag({a:1},{a:1}));
  assert.throws(() => promotionOwner.parseJSONBytes(Buffer.from('{'), 'api'), /malformed/);
});

test('native runner and native adapter validate authentication and roots', async () => {
  assert.equal(await promotionOwner.nativeRun('x',[],{},async()=>({})), '');
  assert.throws(()=>promotionOwner.createNativeGitHubAdapter({token:'',controlRoot:'/c',candidateControlRoot:'/cc',sourceRoot:'/s',workRoot:'/w'}),/auth/);
  assert.throws(()=>promotionOwner.createNativeGitHubAdapter({token:'x',controlRoot:'c',candidateControlRoot:'/cc',sourceRoot:'/s',workRoot:'/w'}),/absolute/);
});

test('promotion rejects absent verification and changed/public bytes', async () => {
  const value=state();
  let github=githubFor(value,[]);
  await assert.rejects(()=>promoteReleaseCandidate(promotionInput(),github,{localBundle,verifyCandidateBundle:async()=>({archiveSHA256:'0'.repeat(64),manifestSHA256,executableSHA256,manifest:candidate})}),/Task 1/);
  github=githubFor(value,[]); github.downloadPublicArchive=async()=>Buffer.from('wrong');
  await assert.rejects(()=>promoteReleaseCandidate(promotionInput(),github,{localBundle}),/public archive/);
  github=githubFor(value,[]); github.extractPublicExecutable=async()=>Buffer.from('wrong');
  await assert.rejects(()=>promoteReleaseCandidate(promotionInput(),github,{localBundle}),/public executable/);
});

test('CLI rejects malformed values and main covers both dispatch paths', async () => {
  const valid=validCliArguments(), dependencies={env:{GH_TOKEN:'secret'},createNativeGitHubAdapter:()=>({}),promoteReleaseCandidate:async()=>({mutations:[]}),stdout() {},lstat:async()=>({isFile:()=>true,nlink:1,mode:0o100600}),readFile:async(filePath)=>filePath.endsWith('tar.gz')?archiveBytes:filePath.endsWith('v2.json')?manifestBytes:localProvenanceBytes};
  const mutate=(flag,value)=>{const copy=[...valid];copy[copy.indexOf(flag)+1]=value;return copy;};
  await assert.rejects(()=>promotionOwner.runCli(mutate('--control-root','relative'),dependencies),/absolute/);
  await assert.rejects(()=>promotionOwner.runCli(mutate('--archive-path','relative'),dependencies),/absolute/);
  const malformed=[...valid]; malformed[0]='version'; await assert.rejects(()=>promotionOwner.runCli(malformed,dependencies),/usage/);
  const duplicate=[...valid]; duplicate[2]='--version'; await assert.rejects(()=>promotionOwner.runCli(duplicate,dependencies),/duplicate/);
  const unknown=[...valid]; unknown[0]='--wat'; await assert.rejects(()=>promotionOwner.runCli(unknown,dependencies),/unknown/);
  const originalWrite=process.stdout.write; process.stdout.write=()=>true;
  try { await promotionOwner.runCli(valid,{...dependencies,stdout:undefined}); } finally { process.stdout.write=originalWrite; }
  assert.equal(await promotionOwner.runMain(valid,dependencies),0);
  const errors=[]; assert.equal(await promotionOwner.runMain([], {stderr:(v)=>errors.push(v)}),1);
  const originalError=process.stderr.write; process.stderr.write=()=>true; try { assert.equal(await promotionOwner.runMain([]),1); } finally {process.stderr.write=originalError;}
  assert.equal(await promotionOwner.main({moduleURL:'file:///a',argv:['node','/b']}),false);
  const old=process.exitCode; try {assert.equal(await promotionOwner.main({moduleURL:'file:///a',argv:['node','/a','x'],runMainImpl:async()=>4}),true);assert.equal(process.exitCode,4);} finally {process.exitCode=old;}
});

test('native publication adapter uploads and redownloads exact local candidate bytes', async () => {
  const heads = [];
  const ghCalls = [];
  let releaseResponse = null;
  let rulesetsResponse;
  let environmentResponse;
  let draftAssets = [];
  const files = new Map([
    ['/control/Docs/ReleaseEvidence/v1.3.1-guide-proof.json', proofBytes()],
    [`/work/candidate/${candidate.archive.filename}`, archiveBytes],
    ['/work/candidate/release-candidate-v2.json', manifestBytes],
    ['/work/candidate/archive-attestation-bundle-v1.jsonl', Buffer.from(`${JSON.stringify(attestation(candidate.archive.filename, archiveSHA256))}\n`)],
    ['/work/candidate/manifest-attestation-bundle-v1.jsonl', Buffer.from(`${JSON.stringify(attestation('release-candidate-v2.json', manifestSHA256))}\n`)],
  ]);
  const api = new Map([
    [`repos/${candidate.repository}/actions/runs/${candidate.run.id}`, { repository: { full_name: candidate.repository }, path: candidate.workflow.path, head_branch: 'main', head_sha: candidateWorkflowCommit, event: 'workflow_dispatch', status: 'completed', conclusion: 'success', run_attempt: candidate.run.attempt }],
    [`repos/${candidate.repository}/actions/artifacts/444`, { id: 444, name: candidate.artifactName, workflow_run: { id: candidate.run.id }, expired: false, deleted_at: null }],
    [`repos/${candidate.repository}/git/ref/tags/v1.3.1`, { ref: 'refs/tags/v1.3.1', object: { sha: 'c'.repeat(40) } }],
    [`repos/${candidate.repository}/git/tags/${'c'.repeat(40)}`, state().tagTuple.tag],
    [`repos/${candidate.repository}/rulesets`, [{ name: 'immutable-release-tags', enforcement: 'active', conditions: { ref_name: { include: ['refs/tags/v*'] } }, rules: [{ type: 'update' }, { type: 'deletion' }], bypass_actors: [] }]],
    [`repos/${candidate.repository}/environments/release-production`, { name: 'release-production', protection_rules: [{ type: 'required_reviewers', prevent_self_review: true, reviewers: [{}] }] }],
  ]);
  const adapter = promotionOwner.createNativeGitHubAdapter({
    token: 'secret', input: promotionInput(), controlRoot: '/control', candidateControlRoot: '/candidate-control', sourceRoot: '/source', workRoot: '/work',
    runCommand: async (executable, argv, options = {}) => {
      if (executable === 'git' && argv[0] === 'rev-parse') {
        heads.push(options.cwd);
        if (options.cwd === '/control') return `${controlCommit}\n`;
        if (options.cwd === '/candidate-control') return `${candidateWorkflowCommit}\n`;
        if (options.cwd === '/source') return `${commit}\n`;
      }
      if (executable === 'git' && argv[0] === 'merge-base') return '';
      if (executable === 'gh') {
        ghCalls.push(argv);
        if (argv[0] === 'attestation' && argv[1] === 'verify') {
          return JSON.stringify(argv[2].endsWith('.tar.gz')
            ? attestation(candidate.archive.filename, archiveSHA256)
            : attestation('release-candidate-v2.json', manifestSHA256));
        }
        const endpoint = argv.find((value) => value.startsWith('repos/') || value.startsWith('https://'));
        if (endpoint.endsWith('/zip')) return 'zip';
        if (endpoint.includes('/releases/tags/')) {
          if (releaseResponse) return JSON.stringify(releaseResponse);
          throw Object.assign(new Error('404 Not Found'), { stderr: '404' });
        }
        if (argv.includes('POST') && endpoint.includes('/releases')) return JSON.stringify({id:99,draft:true,assets:[],upload_url:'https://uploads.github.com/repos/dsifry/swift-mutation-testing/releases/99/assets{?name,label}'});
        if (argv.includes('PATCH')) return JSON.stringify({id:99,draft:false});
        if (endpoint.includes('/releases/99')) return JSON.stringify({id:99,draft:true,assets:draftAssets});
        if (endpoint.startsWith('https://asset/')) return Buffer.from(endpoint.endsWith('/archive') ? archiveBytes : 'asset');
        if (endpoint.startsWith('https://text/')) return 'asset';
        if(endpoint.endsWith('/rulesets')&&rulesetsResponse!==undefined) return JSON.stringify(rulesetsResponse);
        if(endpoint.includes('/environments/')&&environmentResponse!==undefined) return JSON.stringify(environmentResponse);
        return JSON.stringify(api.get(endpoint));
      }
      if (executable === 'unzip') return '';
      if (executable === 'tar') { files.set('/work/public-extraction/swift-mutation-testing', executableBytes); return ''; }
      throw new Error(`unexpected command ${executable} ${argv.join(' ')}`);
    },
    readFileImpl: async (filePath) => files.get(filePath),
    writeFileImpl: async (filePath, bytes) => { files.set(filePath, bytes); }, mkdirImpl: async () => {}, chmodImpl: async () => {}, rmImpl: async () => {},
  });
  const githubState = await adapter.readState();
  assert.equal(githubState.controlHead, controlCommit);
  assert.deepEqual(heads, ['/control']);
  const draft=await adapter.createDraft({tag:'v1.3.1',name:'release',targetCommitish:commit});
  await assert.rejects(() => adapter.uploadAsset({ ...draft, upload_url: undefined }, {name:'asset',bytes:Buffer.from('asset')}), /upload URL.*authoritative/i);
  await assert.rejects(() => adapter.uploadAsset({ ...draft, upload_url: 'https://api.github.com/wrong{?name,label}' }, {name:'asset',bytes:Buffer.from('asset')}), /upload URL.*authoritative/i);
  await adapter.uploadAsset(draft,{name:'asset',bytes:Buffer.from('asset')});
  const uploadCall=ghCalls.find((argv)=>argv.includes('Content-Type: application/octet-stream'));
  assert.equal(uploadCall.some((value)=>value==='https://uploads.github.com/repos/dsifry/swift-mutation-testing/releases/99/assets?name=asset'),true);
  assert.equal(uploadCall.some((value)=>value.includes('api.github.com')||value.startsWith('repos/dsifry/swift-mutation-testing/releases/99/assets?')),false);
  assert.equal(files.has('/work/upload-asset'), true);
  assert.deepEqual(await adapter.downloadDraftAssets(draft),{});
  draftAssets=[{name:'asset',url:'https://asset/other'}];
  assert.deepEqual(await adapter.downloadDraftAssets(draft),{asset:Buffer.from('asset')});
  draftAssets=[{name:'text-asset',url:'https://text/asset'}];
  assert.deepEqual(await adapter.downloadDraftAssets(draft),{'text-asset':Buffer.from('asset')});
  assert.equal((await adapter.publishDraft(draft)).draft,false);
  await assert.rejects(()=>adapter.downloadPublicArchive(),/absent/);
  releaseResponse={id:99,draft:false,assets:[{name:candidate.archive.filename,url:'https://asset/archive'}]};
  assert.deepEqual(await adapter.downloadPublicArchive(),archiveBytes);
  assert.equal((await adapter.readState()).release.assets[0].sha256,archiveSHA256);
  releaseResponse={id:99,draft:false};
  assert.deepEqual((await adapter.readState()).release.assets,[]);
  rulesetsResponse={}; environmentResponse={name:'release-production'};
  const weakState=await adapter.readState();
  assert.deepEqual(weakState.repositoryControls.rulesets,[]);
  rulesetsResponse=[{name:'weak'}];
  const weakRuleState=await adapter.readState();
  assert.deepEqual(weakRuleState.repositoryControls.rulesets[0].targets,[]);
  assert.deepEqual(weakRuleState.repositoryControls.rulesets[0].bypassActors,[]);
  draftAssets=undefined;
  assert.deepEqual(await adapter.downloadDraftAssets(draft),{});
  assert.deepEqual(await adapter.extractPublicExecutable(archiveBytes),executableBytes);
});

test('native adapter rethrows non-404 release lookup failures', async () => {
  const adapter=promotionOwner.createNativeGitHubAdapter({token:'x',input:promotionInput(),controlRoot:'/c',candidateControlRoot:'/cc',sourceRoot:'/s',workRoot:'/w',mkdirImpl:async()=>{},chmodImpl:async()=>{},writeFileImpl:async()=>{},readFileImpl:async(filePath)=>filePath.endsWith('.jsonl')?Buffer.from(`${JSON.stringify(attestation(filePath.includes('archive-')?candidate.archive.filename:'release-candidate-v2.json',filePath.includes('archive-')?archiveSHA256:manifestSHA256))}\n`):filePath.endsWith('.json')?manifestBytes:filePath.endsWith('.tar.gz')?archiveBytes:proofBytes(),runCommand:async(executable,argv)=>{
    if(executable==='gh'&&argv.some((v)=>v.includes('/releases/tags/'))) throw {};
    if(executable==='gh'&&argv.some((v)=>v.endsWith('/zip'))) return Buffer.from('zip');
    if(executable==='unzip') return '';
    if(executable==='git') return `${controlCommit}\n`;
    const endpoint=argv.find((v)=>v.startsWith('repos/'));
    if(endpoint?.includes('/actions/runs/')) return JSON.stringify({});
    if(endpoint?.includes('/actions/artifacts/')) return JSON.stringify({deleted_at:null});
    if(endpoint?.includes('/git/ref/')) return JSON.stringify({ref:'refs/tags/v1.3.1',object:{sha:'c'.repeat(40)}});
    if(endpoint?.includes('/git/tags/')) return JSON.stringify(state().tagTuple.tag);
    if(endpoint?.endsWith('/rulesets')) return '[]';
    if(endpoint?.includes('/environments/')) return '{}';
    return '{}';
  }});
  await assert.rejects(()=>adapter.readState(),()=>true);
});
