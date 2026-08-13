import assert from 'node:assert/strict';
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { canonicalLocalProvenance, sha256, verifyPromotionAuthority } from '../../scripts/release-artifact.mjs';
import { runCli, verifyLocalBundleCustody } from '../../scripts/promote-release-candidate.mjs';
import { loadMutationReleaseCandidate } from '/Users/dsifry/Developer/theguide/.worktrees/issue-51-warm-mutation-builds/tools/coverage/swift-mutation-release-candidate.mjs';

test('local producer descriptor passes Guide verifier and promotion dry-run unchanged', async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'local-release-path-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const archiveBytes = Buffer.from('prebuilt archive');
  const candidate = JSON.parse(await readFile(new URL('./fixtures/candidate-valid.json', import.meta.url)));
  candidate.archive.sha256 = sha256(archiveBytes);
  const manifestBytes = Buffer.from(`${JSON.stringify(candidate, null, 2)}\n`);
  const provenanceBytes = canonicalLocalProvenance({
    schemaVersion: 'local-release-provenance-v1', repository: candidate.repository,
    sourceCommit: candidate.sourceCommit, versionOutput: candidate.release.versionOutput,
    capability: 'prepared-cache-v1', manifestSHA256: sha256(manifestBytes), archiveSHA256: sha256(archiveBytes),
    binarySHA256: candidate.executable.sha256, swiftVersionOutput: 'Apple Swift version 6.3.3',
    sdkVersionOutput: '26.0', targetTriple: 'arm64-apple-macosx26.0', configuration: 'release', codesignVerified: true,
  });
  const paths = {
    archive: path.join(root, candidate.archive.filename),
    manifest: path.join(root, 'release-candidate-v2.json'),
    provenance: path.join(root, 'local-release-provenance-v1.json'),
  };
  await Promise.all([writeFile(paths.archive, archiveBytes), writeFile(paths.manifest, manifestBytes), writeFile(paths.provenance, provenanceBytes)]);
  await Promise.all(Object.values(paths).map((filePath) => chmod(filePath, 0o600)));
  const guide = await loadMutationReleaseCandidate(paths.provenance);
  const descriptorSHA256 = sha256(provenanceBytes);
  assert.equal(guide.descriptorSHA256, descriptorSHA256);
  const proof = {
    schemaVersion: 'guide-release-proof-v1', repository: 'dsifry/theguide', guideCommit: 'b'.repeat(40),
    candidate: {
      descriptorSHA256, repository: candidate.repository, sourceCommit: candidate.sourceCommit,
      versionOutput: guide.candidate.versionOutput, capability: guide.candidate.capability,
      manifestSHA256: guide.candidate.manifestSHA256, archiveSHA256: guide.candidate.archiveSHA256,
      executableSHA256: guide.candidate.binarySHA256, swiftVersionOutput: guide.candidate.swiftVersionOutput,
      sdkVersionOutput: guide.candidate.sdkVersionOutput, targetTriple: guide.candidate.targetTriple,
      configuration: guide.candidate.configuration, codesignVerified: guide.candidate.codesignVerified,
    },
    result: {
      status: 'pass', selectors: { count: 1, coldTupleSHA256: '7'.repeat(64), warmTupleSHA256: '7'.repeat(64) },
      cacheReuse: { uncachedBuilds: 1, warmFullBuilds: 0, warmIncrementalBuilds: 1, warmFallbackBuilds: 0, zeroResidue: true, receiptSHA256: '8'.repeat(64) },
      lightweightGate: { receiptSHA256: '9'.repeat(64) },
      drills: Object.fromEntries(['recovery', 'privacy', 'retention', 'literal-kill'].map((name, index) => [name, { receiptSHA256: String(index + 1).repeat(64) }])),
    },
  };
  const proofBytes = Buffer.from(`${JSON.stringify(proof, null, 2)}\n`);
  const argv = [
    '--version', '1.3.1', '--repository', candidate.repository, '--source-commit', candidate.sourceCommit,
    '--manifest-sha256', sha256(manifestBytes), '--archive-sha256', sha256(archiveBytes),
    '--executable-sha256', candidate.executable.sha256, '--provenance-sha256', descriptorSHA256,
    '--candidate-descriptor-sha256', descriptorSHA256, '--control-commit', 'e'.repeat(40),
    '--guide-commit', 'b'.repeat(40), '--guide-proof-sha256', sha256(proofBytes),
    '--archive-path', paths.archive, '--manifest-path', paths.manifest, '--provenance-path', paths.provenance,
    '--control-root', root, '--work-root', path.join(root, 'work'),
  ];
  await runCli(argv, {
    env: { GH_TOKEN: 'dry-run' }, createNativeGitHubAdapter: () => ({}), stdout() {},
    promoteReleaseCandidate: async (input, _github, { localBundle }) => {
      const verified = verifyLocalBundleCustody(input, localBundle);
      assert.equal(sha256(verified.archiveBytes), guide.candidate.archiveSHA256);
      assert.equal(input.candidateDescriptorSHA256, guide.descriptorSHA256);
      const authority = verifyPromotionAuthority(input, {
        controlHead: 'e'.repeat(40), guideProofBytes: proofBytes,
        manifestBytes: verified.manifestBytes, provenanceBytes: verified.provenanceBytes,
      });
      assert.deepEqual(authority.proof, proof);
      return { mutations: [] };
    },
  });
});
