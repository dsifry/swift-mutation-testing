import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  parseCandidateManifest,
  sha256,
  verifyAttestationBundle,
  verifyCandidateBundle,
} from '../../scripts/release-artifact.mjs';

const fixtures = path.join(import.meta.dirname, 'fixtures');
const validCandidateBytes = await readFile(path.join(fixtures, 'candidate-valid.json'));
const validCandidate = JSON.parse(validCandidateBytes);
const validAttestation = JSON.parse(await readFile(path.join(fixtures, 'attestation-valid.json')));
const manifestSHA256 = sha256(validCandidateBytes);

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function manifestBytes(mutator) {
  const value = clone(validCandidate);
  mutator(value);
  return Buffer.from(JSON.stringify(value));
}

function candidateExpected() {
  return {
    archiveSHA256: validCandidate.archive.sha256,
    manifestSHA256,
    repository: validCandidate.repository,
    workflowPath: validCandidate.workflow.path,
    workflowRef: validCandidate.workflow.ref,
    workflowCommit: validCandidate.workflow.commit,
    event: validCandidate.dispatch.event,
    runId: validCandidate.run.id,
    runAttempt: validCandidate.run.attempt,
  };
}

test('candidate manifest accepts exactly the closed v1 schema', () => {
  assert.deepEqual(parseCandidateManifest(validCandidateBytes), validCandidate);
});

test('candidate manifest rejects a missing nested key', () => {
  assert.throws(() => parseCandidateManifest(manifestBytes((value) => delete value.toolchain.swiftVersion)), /candidate manifest/i);
});

test('candidate manifest rejects an unknown nested key', () => {
  assert.throws(() => parseCandidateManifest(manifestBytes((value) => { value.archive.extra = true; })), /candidate manifest/i);
});

test('candidate manifest rejects a wrongly typed nested value', () => {
  assert.throws(() => parseCandidateManifest(manifestBytes((value) => { value.run.id = '123456789'; })), /candidate manifest/i);
});

test('candidate manifest rejects duplicate JSON keys', () => {
  const duplicated = validCandidateBytes.toString().replace('"schemaVersion": "release-candidate-v1",', '"schemaVersion": "release-candidate-v1",\n  "schemaVersion": "release-candidate-v1",');
  assert.throws(() => parseCandidateManifest(Buffer.from(duplicated)), /candidate manifest/i);
});

for (const [name, mutate] of [
  ['wrong repository', (value) => { value.repository = 'ericodx/swift-mutation-testing'; }],
  ['wrong workflow path', (value) => { value.workflow.path = '.github/workflows/release.yml'; }],
  ['wrong workflow ref', (value) => { value.workflow.ref = 'main'; }],
  ['unequal workflow anchor', (value) => { value.dispatch.mainAnchorCommit = value.sourceCommit; }],
  ['unsupported event', (value) => { value.dispatch.event = 'push'; }],
  ['unsafe run identifier', (value) => { value.run.id = Number.MAX_SAFE_INTEGER + 1; }],
  ['wrong artifact attempt suffix', (value) => { value.artifactName = 'swift-mutation-testing-v1.3.1-candidate-123456789-1'; }],
  ['noncanonical version', (value) => { value.release.version = '01.3.1'; }],
  ['wrong tag', (value) => { value.release.tag = 'v1.3.2'; }],
  ['wrong version output', (value) => { value.release.versionOutput = 'swift-mutation-testing 1.3.1'; }],
  ['wrong runner', (value) => { value.toolchain.runnerImage = 'macos-15'; }],
  ['wrong cpu', (value) => { value.toolchain.cpuType = 'x86_64'; }],
  ['wrong deployment minimum', (value) => { value.toolchain.deploymentTarget = '26.0'; }],
  ['wrong archive filename', (value) => { value.archive.filename = 'other.tar.gz'; }],
  ['uppercase archive digest', (value) => { value.archive.sha256 = value.archive.sha256.toUpperCase(); }],
  ['wrong executable filename', (value) => { value.executable.filename = 'other'; }],
  ['unsafe executable size', (value) => { value.executable.size = 0; }],
  ['wrong executable mode', (value) => { value.executable.mode = '0777'; }],
  ['uppercase executable digest', (value) => { value.executable.sha256 = value.executable.sha256.toUpperCase(); }],
]) {
  test(`candidate manifest rejects ${name}`, () => {
    assert.throws(() => parseCandidateManifest(manifestBytes(mutate)), /candidate manifest/i);
  });
}

function validListing() {
  return [{ path: validCandidate.executable.filename, type: 'file', linkCount: 1, mode: '0755', size: validCandidate.executable.size }];
}

function validCommands(overrides = {}) {
  return {
    tar: {
      list: async () => validListing(),
      extract: async () => {},
      ...(overrides.tar ?? {}),
    },
    codesign: { verify: async () => true, ...(overrides.codesign ?? {}) },
    file: { inspect: async () => ({ type: 'Mach-O 64-bit executable arm64' }), ...(overrides.file ?? {}) },
    otool: {
      inspect: async () => ({ uuid: validCandidate.executable.uuid, cpuType: 'arm64', deploymentTarget: '15.0' }),
      ...(overrides.otool ?? {}),
    },
    executable: { version: async () => validCandidate.release.versionOutput, ...(overrides.executable ?? {}) },
  };
}

async function withBundle(overrides, assertion) {
  const privateRoot = await mkdtemp(path.join(os.tmpdir(), 'release-artifact-test-'));
  const archiveBytes = Buffer.from('archive bytes');
  const executableBytes = Buffer.from('executable bytes');
  const candidate = clone(validCandidate);
  candidate.archive.sha256 = sha256(archiveBytes);
  candidate.executable.sha256 = sha256(executableBytes);
  const candidateBytes = Buffer.from(JSON.stringify(candidate));
  const records = [];
  const input = {
    controlRoot: '/control',
    sourceRoot: '/source',
    archivePath: '/control/output/swift-mutation-testing-v1.3.1-macos.tar.gz',
    manifestPath: '/control/output/release-candidate-v1.json',
    privateDirectory: privateRoot,
    fs: {
      readOwnedRegularFile: async (filePath) => {
        records.push(`read:${filePath}`);
        if (filePath.endsWith('.json')) return candidateBytes;
        if (filePath.endsWith('.tar.gz')) return archiveBytes;
        return executableBytes;
      },
      mkdirFreshPrivate: async (directory) => {
        records.push(`mkdir:${directory}`);
        return directory;
      },
    },
    commands: validCommands({
      tar: {
        extract: async (_archivePath, destination) => {
          records.push(`extract:${destination}`);
        },
      },
    }),
  };
  Object.assign(input, overrides);
  try {
    await assertion(input, records, candidate, archiveBytes, executableBytes);
  } finally {
    await rm(privateRoot, { recursive: true, force: true });
  }
}

for (const [name, listing] of [
  ['extra archive path', () => [...validListing(), { path: 'extra', type: 'file', linkCount: 1, mode: '0644', size: 1 }]],
  ['absolute archive path', () => [{ ...validListing()[0], path: '/swift-mutation-testing' }]],
  ['parent archive path', () => [{ ...validListing()[0], path: '../swift-mutation-testing' }]],
  ['symbolic link', () => [{ ...validListing()[0], type: 'symlink' }]],
  ['hard link', () => [{ ...validListing()[0], linkCount: 2 }]],
  ['nonregular entry', () => [{ ...validListing()[0], type: 'directory' }]],
  ['wrong archive mode', () => [{ ...validListing()[0], mode: '0777' }]],
  ['wrong archive size', () => [{ ...validListing()[0], size: 1 }]],
]) {
  test(`candidate bundle rejects ${name} before extraction`, async () => {
    await withBundle({}, async (input, records) => {
      input.commands.tar.list = async () => listing();
      await assert.rejects(() => verifyCandidateBundle(input), /archive/i);
      assert.equal(records.some((record) => record.startsWith('extract:')), false);
    });
  });
}

for (const [name, override] of [
  ['archive digest mismatch', (input) => { input.fs.readOwnedRegularFile = async (filePath) => filePath.endsWith('.json') ? Buffer.from(JSON.stringify(validCandidate)) : Buffer.from('wrong archive'); }],
  ['executable digest mismatch', (input) => { input.fs.readOwnedRegularFile = async (filePath) => filePath.endsWith('.json') ? Buffer.from(JSON.stringify(validCandidate)) : Buffer.from('wrong executable'); }],
  ['wrong Mach-O UUID', (input) => { input.commands.otool.inspect = async () => ({ uuid: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', cpuType: 'arm64', deploymentTarget: '15.0' }); }],
  ['wrong Mach-O CPU', (input) => { input.commands.otool.inspect = async () => ({ uuid: validCandidate.executable.uuid, cpuType: 'x86_64', deploymentTarget: '15.0' }); }],
  ['wrong deployment minimum', (input) => { input.commands.otool.inspect = async () => ({ uuid: validCandidate.executable.uuid, cpuType: 'arm64', deploymentTarget: '26.0' }); }],
  ['wrong version output', (input) => { input.commands.executable.version = async () => 'swift-mutation-testing 1.3.1'; }],
  ['failed code signature', (input) => { input.commands.codesign.verify = async () => false; }],
]) {
  test(`candidate bundle rejects ${name}`, async () => {
    await withBundle({}, async (input) => {
      override(input);
      await assert.rejects(() => verifyCandidateBundle(input), /candidate|archive|executable/i);
    });
  });
}

test('candidate bundle verifies listing before private 0700 extraction and returns only closed observed digests', async () => {
  await withBundle({}, async (input, records, candidate, archiveBytes, executableBytes) => {
    const result = await verifyCandidateBundle(input);
    assert.deepEqual(result, {
      manifest: candidate,
      archiveSHA256: sha256(archiveBytes),
      manifestSHA256: sha256(Buffer.from(JSON.stringify(candidate))),
      executableSHA256: sha256(executableBytes),
    });
    assert.equal(records[0], `read:${input.manifestPath}`);
    assert.equal(records.some((record) => record === `mkdir:${input.privateDirectory}`), true);
    assert.equal(records.some((record) => record === `extract:${input.privateDirectory}`), true);
  });
});

test('attestation bundle accepts both authenticated subjects and exact provenance', () => {
  assert.deepEqual(verifyAttestationBundle(validAttestation, candidateExpected()), validAttestation.statement);
});

for (const [name, mutate] of [
  ['missing manifest subject', (value) => { value.statement.subject.pop(); }],
  ['other repository', (value) => { value.statement.predicate.repository = 'other/repository'; }],
  ['other workflow', (value) => { value.statement.predicate.workflowPath = '.github/workflows/release.yml'; }],
  ['other workflow commit', (value) => { value.statement.predicate.workflowCommit = '3333333333333333333333333333333333333333'; }],
  ['other event', (value) => { value.statement.predicate.event = 'push'; }],
  ['other run', (value) => { value.statement.predicate.runnerInvocationUri = value.statement.predicate.runnerInvocationUri.replace('/123456789/', '/987654321/'); }],
  ['other attempt', (value) => { value.statement.predicate.runnerInvocationUri = value.statement.predicate.runnerInvocationUri.replace('/2', '/3'); }],
]) {
  test(`attestation bundle rejects ${name}`, () => {
    const bundle = clone(validAttestation);
    mutate(bundle);
    assert.throws(() => verifyAttestationBundle(bundle, candidateExpected()), /attestation/i);
  });
}
