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

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function canonicalProof(overrides = {}) {
  const value = {
    schemaVersion: 'guide-release-proof-v1',
    guideCommit: commit,
    candidate: {
      version: '1.3.1',
      repository: candidate.repository,
      run: { id: candidate.run.id, attempt: candidate.run.attempt },
      artifact: { id: 444, name: candidate.artifactName },
      sourceCommit: commit,
      manifestSHA256,
      archiveSHA256,
      executableSHA256,
    },
    result: {
      status: 'passed',
      selectors: { count: 103, coldTupleSHA256: 'a'.repeat(64), warmTupleSHA256: 'a'.repeat(64) },
      performance: { uncachedElapsedSeconds: 100, warmElapsedSeconds: 80, uncachedBuilds: 10, warmFallbackBuilds: 1 },
      drills: { recovery: 'passed', privacy: 'passed', retention: 'passed' },
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
    runId: candidate.run.id,
    runAttempt: candidate.run.attempt,
    artifactId: 444,
    artifactName: candidate.artifactName,
    sourceCommit: commit,
    manifestSHA256,
    archiveSHA256,
    executableSHA256,
    controlCommit: commit,
    guideProofSHA256: sha256(bytes),
    ...overrides,
  };
}

function attestation(subjectName, digest) {
  return {
    statement: {
      _type: 'https://in-toto.io/Statement/v1',
      subject: subjectName === candidate.archive.filename
        ? [{ name: candidate.archive.filename, digest: { sha256: archiveSHA256 } }, { name: 'release-candidate-v1.json', digest: { sha256: manifestSHA256 } }]
        : [{ name: candidate.archive.filename, digest: { sha256: archiveSHA256 } }, { name: 'release-candidate-v1.json', digest: { sha256: manifestSHA256 } }],
      predicateType: 'https://slsa.dev/provenance/v1',
      predicate: {
        repository: candidate.repository,
        workflowPath: candidate.workflow.path,
        workflowRef: candidate.workflow.ref,
        workflowCommit: candidate.workflow.commit,
        event: 'workflow_dispatch',
        runnerInvocationUri: `https://github.com/${candidate.repository}/actions/runs/${candidate.run.id}/attempts/${candidate.run.attempt}`,
      },
    },
  };
}

function state(overrides = {}) {
  return {
    controlHead: commit,
    guideProofBytes: proofBytes(),
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
      manifest: attestation('release-candidate-v1.json', manifestSHA256),
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
    { name: 'release-candidate-v1.json', sha256: manifestSHA256 },
    { name: 'swift-mutation-testing-v1.3.1-SHA256SUMS', sha256: sha256(checksum) },
  ];
}

test('Guide proof accepts only canonical content-free evidence', () => {
  const bytes = proofBytes();
  assert.deepEqual(parseGuideReleaseProof(bytes), canonicalProof());
  assert.throws(() => parseGuideReleaseProof(Buffer.from(JSON.stringify(canonicalProof()))), /Guide proof.*canonical/i);
});

for (const [name, mutate] of [
  ['wrong repository', (value) => { value.run.repository = 'other/repository'; }],
  ['wrong workflow', (value) => { value.run.workflowPath = '.github/workflows/release.yml'; }],
  ['wrong commit', (value) => { value.run.headSha = commit.replace(/^./u, 'd'); }],
  ['wrong event', (value) => { value.run.event = 'push'; }],
  ['incomplete run', (value) => { value.run.status = 'in_progress'; }],
  ['failed run', (value) => { value.run.conclusion = 'failure'; }],
  ['expired artifact', (value) => { value.artifact.expired = true; }],
  ['deleted artifact', (value) => { value.artifact.deleted = true; }],
  ['wrong artifact run', (value) => { value.artifact.workflowRunId = 99; }],
  ['wrong attestation attempt', (value) => { value.attestations.archive.statement.predicate.runnerInvocationUri = value.attestations.archive.statement.predicate.runnerInvocationUri.replace('/attempts/2', '/attempts/3'); }],
  ['missing attestation', (value) => { delete value.attestations.manifest; }],
  ['input digest mismatch', (value) => { value.manifestBytes = Buffer.from(JSON.stringify(candidate)); }],
  ['wrong proof digest', (value) => { value.guideProofBytes = proofBytes(); }],
  ['untrusted download URL', (value) => { value.artifact.downloadUrl = 'https://attacker.example/candidate.zip'; }],
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
  ['wrong candidate descriptor', (proof) => { proof.candidate.artifact.id = 445; }],
  ['failed result', (proof) => { proof.result.status = 'failed'; }],
  ['wrong selector count', (proof) => { proof.result.selectors.count = 102; }],
  ['unequal tuple digests', (proof) => { proof.result.selectors.warmTupleSHA256 = 'b'.repeat(64); }],
  ['slow warm result', (proof) => { proof.result.performance.warmElapsedSeconds = 81; }],
  ['high fallback result', (proof) => { proof.result.performance.warmFallbackBuilds = 2; }],
  ['failed recovery drill', (proof) => { proof.result.drills.recovery = 'failed'; }],
  ['failed privacy drill', (proof) => { proof.result.drills.privacy = 'failed'; }],
  ['failed retention drill', (proof) => { proof.result.drills.retention = 'failed'; }],
]) {
  test(`promotion authority rejects ${name}`, () => {
    const proof = canonicalProof();
    mutate(proof);
    const bytes = proofBytes(proof);
    const input = promotionInput({ guideProofSHA256: sha256(bytes) });
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
    downloadCandidate: async ({ repository, artifactId }) => {
      assert.equal(repository, candidate.repository);
      assert.equal(artifactId, 444);
      return { archiveBytes, manifestBytes };
    },
    createDraft: async () => { mutations.push('create-draft'); return { draft: true, assets: [] }; },
    uploadAsset: async (_release, asset) => { mutations.push(`upload:${asset.name}`); },
    downloadDraftAssets: async () => ({
      [candidate.archive.filename]: archiveBytes,
      'release-candidate-v1.json': manifestBytes,
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
  await assert.rejects(() => promoteReleaseCandidate(promotionInput(), githubFor(value, mutations)), /promotion|Guide proof|tag|repository|draft|public|candidate/i);
  assert.deepEqual(mutations, []);
}

test('rejected authority stops before its first GitHub mutation', async () => {
  const value = state();
  value.run.conclusion = 'failure';
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

test('absent release uploads the unchanged candidate and canonical checksums before publishing', async () => {
  const value = state();
  const mutations = [];
  const uploads = [];
  const github = githubFor(value, mutations);
  github.uploadAsset = async (_release, asset) => {
    mutations.push(`upload:${asset.name}`);
    uploads.push(asset);
  };
  const result = await promoteReleaseCandidate(promotionInput(), github);
  assert.deepEqual(result.mutations, [
    'create-draft',
    `upload:${candidate.archive.filename}`,
    'upload:release-candidate-v1.json',
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
  const result = await promoteReleaseCandidate(promotionInput(), githubFor(value, mutations));
  assert.deepEqual(result.mutations, ['publish-existing-draft']);
  assert.deepEqual(mutations, ['publish-existing-draft']);
});

test('mismatched draft and any public collision fail closed', async () => {
  await assertNoMutation(state({ release: { draft: true, assets: expectedAssets().slice(1) } }));
  await assertNoMutation(state({ release: { draft: false, assets: [] } }));
});

test('tag substitution before upload, publish, or public verification fails closed', async () => {
  for (const position of [1, 2, 3, 4]) {
    const value = state();
    const mutations = [];
    const github = githubFor(value, mutations);
    let reads = 0;
    github.getTagTuple = async () => {
      reads += 1;
      return reads === position ? { ...value.tagTuple, refSha: 'd'.repeat(40) } : value.tagTuple;
    };
    await assert.rejects(() => promoteReleaseCandidate(promotionInput(), github), /tag/i);
    assert.equal(mutations.includes('publish-existing-draft'), position === 4);
  }
});
