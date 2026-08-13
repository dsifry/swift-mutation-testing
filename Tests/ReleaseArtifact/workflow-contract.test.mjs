import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const repositoryRoot = path.resolve(import.meta.dirname, '..', '..');
const candidateWorkflow = path.join(repositoryRoot, '.github', 'workflows', 'release-candidate.yml');
const releaseWorkflow = path.join(repositoryRoot, '.github', 'workflows', 'release.yml');
const pullRequestWorkflow = path.join(repositoryRoot, '.github', 'workflows', 'pull-request-analysis.yml');

function assertAllActionsAreCommitPinned(workflow) {
  const actionUses = [...workflow.matchAll(/^\s*-?\s*uses:\s+([^\s@]+)@([^\s#]+)(?:\s+#.*)?$/gmu)];
  assert.equal(actionUses.length, 2, 'CI workflow must use exactly checkout and Node provisioning actions');
  for (const [, action, revision] of actionUses) {
    assert.match(revision, /^[0-9a-f]{40}$/u, `${action} must be pinned to a full commit SHA`);
  }
}

test('release candidate workflow is Ubuntu Node-only PR and main CI', async () => {
  const workflow = await readFile(candidateWorkflow, 'utf8');

  assert.match(workflow, /^on:\n  pull_request:\n  push:\n    branches: \[main\]$/mu);
  assert.match(workflow, /^    runs-on: ubuntu-latest$/mu);
  assert.match(workflow, /^permissions:\n  contents: read$/mu);
  assert.equal((workflow.match(/^\s+uses:/gmu) ?? []).length, 2);
  assert.match(workflow, /xargs -0 node --test/u);
  assert.match(workflow, /! -name '\*\.integration\.test\.mjs'/u);
  assert.doesNotMatch(workflow, /workflow_dispatch|macos-|xcodebuild|swift\s+(?:build|test)|build-release-candidate|attest-build-provenance|upload-artifact|download-artifact|gh attestation/u);

  assertAllActionsAreCommitPinned(workflow);
  assert.match(workflow, /^        uses: actions\/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4\.4\.0$/mu);
  assert.match(workflow, /^          node-version: '22'$/mu);
  assert.doesNotMatch(workflow, /actions\/cache|\n\s+cache:/u);
  assert.match(workflow, /^        uses: actions\/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5\.1\.0$/mu);
  assert.equal((workflow.match(/uses: actions\/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5\.1\.0/gmu) ?? []).length, 1);
  assert.match(workflow, /^          persist-credentials: false$/mu);
  assert.doesNotMatch(workflow, /actions\/cache|\n\s+cache:|gh release|create-release|tags:/u);
});

test('there is no remote publication workflow', async () => {
  await assert.rejects(() => readFile(releaseWorkflow, 'utf8'), { code: 'ENOENT' });
});

test('pull request analysis is Ubuntu Node-only contract validation', async () => {
  const workflow = await readFile(pullRequestWorkflow, 'utf8');
  assert.match(workflow, /^  pull_request:$/mu);
  assert.match(workflow, /^    runs-on: ubuntu-latest$/mu);
  assert.match(workflow, /xargs -0 node --test/u);
  assert.match(workflow, /! -name '\*\.integration\.test\.mjs'/u);
  assert.equal((workflow.match(/^\s+uses:/gmu) ?? []).length, 2);
  assert.doesNotMatch(workflow, /macos-|swift\s|xcode|llvm-cov|actions\/cache|coverage|sonar|upload-artifact|download-artifact/iu);
});
