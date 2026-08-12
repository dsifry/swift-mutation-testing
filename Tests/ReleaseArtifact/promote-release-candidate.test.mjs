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

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function canonicalProof(overrides = {}) {
  const value = {
    schemaVersion: 'guide-release-proof-v1',
    repository: 'dsifry/theguide',
    guideCommit,
    candidate: {
      descriptorSHA256: candidateDescriptorSHA256,
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
      status: 'pass',
      selectors: { count: 103, coldTupleSHA256: 'a'.repeat(64), warmTupleSHA256: 'a'.repeat(64) },
      performance: { uncachedElapsedSeconds: 100, warmElapsedSeconds: 80, uncachedBuilds: 10, warmFallbackBuilds: 1, receiptSHA256: '1'.repeat(64) },
      drills: {
        recovery: { receiptSHA256: '2'.repeat(64), passed: true },
        privacy: { receiptSHA256: '3'.repeat(64), passed: true },
        retention: { receiptSHA256: '4'.repeat(64), passed: true },
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
    runId: candidate.run.id,
    runAttempt: candidate.run.attempt,
    artifactId: 444,
    artifactName: candidate.artifactName,
    sourceCommit: commit,
    candidateWorkflowCommit,
    manifestSHA256,
    archiveSHA256,
    executableSHA256,
    candidateDescriptorSHA256,
    controlCommit,
    guideCommit,
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
    controlHead: controlCommit,
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

function candidateVerificationInput(overrides = {}) {
  const records = [];
  const input = {
    controlRoot: '/candidate-control',
    sourceRoot: '/source',
    artifactRoot: '/candidate',
    archivePath: `/candidate/${candidate.archive.filename}`,
    manifestPath: '/candidate/release-candidate-v1.json',
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
  assert.equal(proof.candidate.descriptorSHA256, candidateDescriptorSHA256);
  assert.match(proof.result.performance.receiptSHA256, /^[a-f0-9]{64}$/u);
  for (const drill of Object.values(proof.result.drills)) {
    assert.match(drill.receiptSHA256, /^[a-f0-9]{64}$/u);
    assert.equal(drill.passed, true);
  }
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
  ['wrong Guide repository', (proof) => { proof.repository = 'dsifry/swift-mutation-testing'; }],
  ['wrong candidate descriptor digest', (proof) => { proof.candidate.descriptorSHA256 = 'd'.repeat(64); }],
  ['wrong candidate descriptor', (proof) => { proof.candidate.artifact.id = 445; }],
  ['failed result', (proof) => { proof.result.status = 'failed'; }],
  ['wrong selector count', (proof) => { proof.result.selectors.count = 102; }],
  ['unequal tuple digests', (proof) => { proof.result.selectors.warmTupleSHA256 = 'b'.repeat(64); }],
  ['slow warm result', (proof) => { proof.result.performance.warmElapsedSeconds = 81; }],
  ['high fallback result', (proof) => { proof.result.performance.warmFallbackBuilds = 2; }],
  ['missing benchmark receipt digest', (proof) => { delete proof.result.performance.receiptSHA256; }],
  ['failed recovery drill', (proof) => { proof.result.drills.recovery.passed = false; }],
  ['failed privacy drill', (proof) => { proof.result.drills.privacy.passed = false; }],
  ['failed retention drill', (proof) => { proof.result.drills.retention.passed = false; }],
  ['malformed recovery receipt digest', (proof) => { proof.result.drills.recovery.receiptSHA256 = 'invalid'; }],
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
    downloadCandidate: async ({ repository, artifactId }) => {
      assert.equal(repository, candidate.repository);
      assert.equal(artifactId, 444);
      return { archiveBytes, manifestBytes, verificationInput: candidateVerificationInput().input };
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

test('Task 1 candidate bundle verification rejects a bad executable before the first GitHub mutation', async () => {
  const value = state();
  const mutations = [];
  const github = githubFor(value, mutations);
  const verification = candidateVerificationInput();
  verification.input.commands.codesign.verify = async () => false;
  github.downloadCandidate = async () => ({ archiveBytes, manifestBytes, verificationInput: verification.input });
  await assert.rejects(() => promoteReleaseCandidate(promotionInput(), github), /signature|candidate bundle/i);
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
  for (const position of [1, 2, 3, 4, 5]) {
    const value = state();
    const mutations = [];
    const github = githubFor(value, mutations);
    let reads = 0;
    github.getTagTuple = async () => {
      reads += 1;
      return reads === position ? { ...value.tagTuple, refSha: 'd'.repeat(40) } : value.tagTuple;
    };
    await assert.rejects(() => promoteReleaseCandidate(promotionInput(), github), /tag/i);
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
  await assert.rejects(() => promoteReleaseCandidate(promotionInput(), github), /tag/i);
  assert.deepEqual(mutations, ['create-draft']);
});

function validCliArguments() {
  return [
    '--version', '1.3.1', '--repository', candidate.repository,
    '--run-id', String(candidate.run.id), '--run-attempt', String(candidate.run.attempt),
    '--artifact-id', '444', '--artifact-name', candidate.artifactName,
    '--source-commit', commit, '--candidate-workflow-commit', candidateWorkflowCommit,
    '--manifest-sha256', manifestSHA256,
    '--archive-sha256', archiveSHA256, '--executable-sha256', executableSHA256,
    '--candidate-descriptor-sha256', candidateDescriptorSHA256,
    '--control-commit', controlCommit, '--guide-commit', guideCommit,
    '--guide-proof-sha256', sha256(proofBytes()),
    '--control-root', '/control', '--candidate-control-root', '/candidate-control',
    '--source-root', '/source', '--work-root', '/work',
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
    stdout: (value) => output.push(value),
  });
  assert.deepEqual(observed.input, promotionInput());
  assert.equal(observed.github.options.token, 'secret');
  assert.equal(observed.github.options.controlRoot, '/control');
  assert.equal(observed.github.options.candidateControlRoot, '/candidate-control');
  assert.deepEqual(output, ['{"mutations":["publish-existing-draft"]}\n']);
});

test('CLI fails closed for absent auth or any missing, duplicate, or unknown input', async () => {
  const valid = validCliArguments();
  const dependencies = { env: { GH_TOKEN: 'secret' }, createNativeGitHubAdapter: () => ({}), promoteReleaseCandidate: async () => ({ mutations: [] }) };
  await assert.rejects(() => promotionOwner.runCli(valid, { ...dependencies, env: {} }), /GH_TOKEN|auth/i);
  await assert.rejects(() => promotionOwner.runCli(valid.slice(2), dependencies), /usage|input/i);
  await assert.rejects(() => promotionOwner.runCli([...valid, '--version', '1.3.1'], dependencies), /usage|duplicate/i);
  await assert.rejects(() => promotionOwner.runCli([...valid, '--unknown', 'value'], dependencies), /usage|unknown/i);
});

test('native adapter authenticates distinct promotion and candidate control checkouts', async () => {
  const heads = [];
  const files = new Map([
    ['/control/Docs/ReleaseEvidence/v1.3.1-guide-proof.json', proofBytes()],
    [`/work/candidate/${candidate.archive.filename}`, archiveBytes],
    ['/work/candidate/release-candidate-v1.json', manifestBytes],
    ['/work/candidate/archive-attestation-bundle-v1.jsonl', Buffer.from(`${JSON.stringify(attestation(candidate.archive.filename, archiveSHA256))}\n`)],
    ['/work/candidate/manifest-attestation-bundle-v1.jsonl', Buffer.from(`${JSON.stringify(attestation('release-candidate-v1.json', manifestSHA256))}\n`)],
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
        const endpoint = argv[1];
        if (endpoint.endsWith('/zip')) return Buffer.from('zip');
        if (endpoint.includes('/releases/tags/')) throw Object.assign(new Error('404 Not Found'), { stderr: '404' });
        return JSON.stringify(api.get(endpoint));
      }
      if (executable === 'unzip') return '';
      throw new Error(`unexpected command ${executable} ${argv.join(' ')}`);
    },
    readFileImpl: async (filePath) => files.get(filePath),
    writeFileImpl: async () => {}, mkdirImpl: async () => {}, chmodImpl: async () => {}, rmImpl: async () => {},
  });
  const githubState = await adapter.readState();
  assert.equal(githubState.controlHead, controlCommit);
  const downloaded = await adapter.downloadCandidate();
  assert.equal(await downloaded.verificationInput.git.controlHead(downloaded.verificationInput.controlRoot), candidateWorkflowCommit);
  assert.deepEqual(heads, ['/control', '/candidate-control']);
});
