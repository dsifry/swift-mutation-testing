import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const repositoryRoot = path.resolve(import.meta.dirname, '..', '..');
const candidateWorkflow = path.join(repositoryRoot, '.github', 'workflows', 'release-candidate.yml');

function assertBefore(workflow, first, second) {
  const firstIndex = workflow.indexOf(first);
  const secondIndex = workflow.indexOf(second);
  assert.notEqual(firstIndex, -1, `missing step: ${first}`);
  assert.notEqual(secondIndex, -1, `missing step: ${second}`);
  assert.ok(firstIndex < secondIndex, `${first} must precede ${second}`);
}

function assertAllActionsAreCommitPinned(workflow) {
  const actionUses = [...workflow.matchAll(/^\s*-?\s*uses:\s+([^\s@]+)@([^\s#]+)(?:\s+#.*)?$/gmu)];
  assert.equal(actionUses.length, 7, 'candidate workflow must use exactly two checkouts, setup, two attestations, upload, and download actions');
  for (const [, action, revision] of actionUses) {
    assert.match(revision, /^[0-9a-f]{40}$/u, `${action} must be pinned to a full commit SHA`);
  }
}

function assertOnlyControlTreeScriptsExecute(workflow) {
  const scripts = [...workflow.matchAll(/\bnode\s+"(\$\{\{ github\.workspace \}\}\/control\/scripts\/[a-z0-9-]+\.mjs)"/gmu)];
  assert.ok(scripts.length >= 2, 'candidate workflow must execute its build and verification owners');
  for (const [, script] of scripts) {
    assert.match(script, /^\$\{\{ github\.workspace \}\}\/control\/scripts\/[a-z0-9-]+\.mjs$/u, `script must execute from the control tree: ${script}`);
  }
}

test('release candidate workflow preserves immutable candidate authority and custody', async () => {
  const workflow = await readFile(candidateWorkflow, 'utf8');

  assert.match(workflow, /^name: Release candidate$/mu);
  assert.match(workflow, /^on:\n  workflow_dispatch:\n    inputs:\n      version:\n        description: Canonical release version \(X\.Y\.Z\)\n        required: true\n        type: string\n      source_commit:\n        description: Reviewed source commit SHA\n        required: true\n        type: string$/mu);
  assert.match(workflow, /^permissions:\n  contents: read\n  id-token: write\n  attestations: write\n  artifact-metadata: write$/mu);
  assert.match(workflow, /^    runs-on: macos-26$/mu);

  assertAllActionsAreCommitPinned(workflow);
  assert.match(workflow, /^        uses: actions\/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4\.4\.0$/mu);
  assert.match(workflow, /^          node-version: '22'$/mu);
  assert.doesNotMatch(workflow, /actions\/cache|\n\s+cache:/u);
  assert.match(workflow, /^        uses: actions\/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5\.1\.0$/mu);
  assert.equal((workflow.match(/uses: actions\/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5\.1\.0/gmu) ?? []).length, 2);
  assert.match(workflow, /^          path: \$\{\{ github\.workspace \}\}\/control$/mu);
  assert.match(workflow, /^          path: \$\{\{ github\.workspace \}\}\/source$/mu);
  assert.match(workflow, /^          retention-days: 30$/mu);
  assert.match(workflow, /^          overwrite: false$/mu);
  assert.match(workflow, /^          artifact-ids: \$\{\{ steps\.upload\.outputs\.artifact-id \}\}$/mu);
  assert.equal((workflow.match(/uses: actions\/attest-build-provenance@96278af6caaf10aea03fd8d33a09a777ca52d62f # v3\.2\.0/gmu) ?? []).length, 2);

  assert.match(workflow, /^        run: \|\n          set -euo pipefail\n          WORKFLOW_COMMIT="\$\{\{ github\.sha \}\}"\n          DISPATCH_TRIGGER_COMMIT="\$\{\{ github\.sha \}\}"$/mu);
  assert.match(workflow, /\[ "\$WORKFLOW_COMMIT" = "\$DISPATCH_TRIGGER_COMMIT" \]/u);
  assert.match(workflow, /\[ "\$WORKFLOW_COMMIT" = "\$MAIN_ANCHOR_COMMIT" \]/u);
  assert.match(workflow, /gh api "repos\/\$GITHUB_REPOSITORY\/git\/ref\/heads\/main"/u);
  assert.match(workflow, /gh api "repos\/\$GITHUB_REPOSITORY\/compare\/\$SOURCE_COMMIT\.\.\.\$MAIN_ANCHOR_COMMIT"/u);
  assert.match(workflow, /test "\$\(git -C "\$\{\{ github\.workspace \}\}\/control" rev-parse HEAD\)" = "\$WORKFLOW_COMMIT"/u);
  assert.match(workflow, /test "\$\(git -C "\$\{\{ github\.workspace \}\}\/source" rev-parse HEAD\)" = "\$SOURCE_COMMIT"/u);
  assert.match(workflow, /swift-mutation-testing-v\$\{VERSION\}-candidate-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}/u);
  assertOnlyControlTreeScriptsExecute(workflow);

  assertBefore(workflow, 'Validate source ancestry', 'Build candidate once');
  assertBefore(workflow, 'Build candidate once', 'Attest candidate');
  assertBefore(workflow, 'Attest candidate', 'Upload immutable candidate');
  assert.doesNotMatch(workflow, /gh release|create-release|tags:/u);

  for (const summaryValue of ['Artifact ID', 'Service digest', 'Run ID', 'Run attempt', 'Manifest SHA-256', 'Archive SHA-256', 'Executable SHA-256']) {
    assert.match(workflow, new RegExp(`^\\s*echo "${summaryValue}: .+"$`, 'mu'));
  }
  assert.match(workflow, /^          \} >> "\$GITHUB_STEP_SUMMARY"$/mu);
});
