import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const repositoryRoot = path.resolve(import.meta.dirname, '..', '..');
const candidateWorkflow = path.join(repositoryRoot, '.github', 'workflows', 'release-candidate.yml');
const releaseWorkflow = path.join(repositoryRoot, '.github', 'workflows', 'release.yml');

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

function assertOnlyControlTreeOwnersExecute(workflow) {
  const owners = [...workflow.matchAll(/\b(?:node|bash|sh)\s+(?:"([^"\n]+)"|'([^'\n]+)'|([^\s\n]+))/gmu)]
    .map(([, doubleQuoted, singleQuoted, bare]) => doubleQuoted ?? singleQuoted ?? bare);
  assert.ok(owners.length >= 4, 'candidate workflow must execute its reviewed source gates, build, and verification owners');
  for (const owner of owners) {
    assert.match(owner, /^\$\{\{ github\.workspace \}\}\/control\/scripts\/[a-z0-9-]+\.(?:mjs|sh)$/u, `checked-in owner must execute from the control tree: ${owner}`);
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
  assertOnlyControlTreeOwnersExecute(workflow);

  assertBefore(workflow, 'Validate source ancestry', 'Build candidate once');
  assertBefore(workflow, 'Test reviewed source', 'Build candidate once');
  assertBefore(workflow, 'Build candidate once', 'Attest candidate');
  assertBefore(workflow, 'Attest candidate', 'Upload immutable candidate');
  assert.doesNotMatch(workflow, /gh release|create-release|tags:/u);

  for (const summaryValue of ['Artifact ID', 'Service digest', 'Run ID', 'Run attempt', 'Manifest SHA-256', 'Archive SHA-256', 'Executable SHA-256']) {
    assert.match(workflow, new RegExp(`^\\s*echo "${summaryValue}: .+"$`, 'mu'));
  }
  assert.match(workflow, /^          \} >> "\$GITHUB_STEP_SUMMARY"$/mu);
});

test('workflow contract rejects checked-in owners outside the control tree', async () => {
  const workflow = await readFile(candidateWorkflow, 'utf8');
  const sourceOwner = workflow.replace(
    'node "${{ github.workspace }}/control/scripts/build-release-candidate.mjs"',
    'node "${{ github.workspace }}/source/scripts/build-release-candidate.mjs"',
  );
  const repositoryOwner = workflow.replace(
    'node "${{ github.workspace }}/control/scripts/build-release-candidate.mjs"',
    'node "${{ github.workspace }}/scripts/build-release-candidate.mjs"',
  );
  const relativeOwner = workflow.replace(
    'node "${{ github.workspace }}/control/scripts/build-release-candidate.mjs"',
    'node scripts/build-release-candidate.mjs',
  );

  assert.throws(() => assertOnlyControlTreeOwnersExecute(sourceOwner), /control tree/u);
  assert.throws(() => assertOnlyControlTreeOwnersExecute(repositoryOwner), /control tree/u);
  assert.throws(() => assertOnlyControlTreeOwnersExecute(relativeOwner), /control tree/u);
});

test('release workflow is protected manual promotion of proof-bound candidate bytes only', async () => {
  const workflow = await readFile(releaseWorkflow, 'utf8');

  assert.match(workflow, /^name: Promote release candidate$/mu);
  assert.match(workflow, /^on:\n  workflow_dispatch:\n    inputs:/mu);
  assert.doesNotMatch(workflow, /^\s{2}(?:push|pull_request|schedule|workflow_run|release):/mu);

  const requiredInputs = [
    ['version', 'string'],
    ['canonical_tag', 'string'],
    ['candidate_run_id', 'number'],
    ['candidate_run_attempt', 'number'],
    ['candidate_artifact_id', 'number'],
    ['candidate_artifact_name', 'string'],
    ['source_commit', 'string'],
    ['manifest_sha256', 'string'],
    ['archive_sha256', 'string'],
    ['executable_sha256', 'string'],
    ['candidate_descriptor_sha256', 'string'],
    ['proof_commit', 'string'],
    ['guide_commit', 'string'],
    ['guide_proof_sha256', 'string'],
  ];
  for (const [name, type] of requiredInputs) {
    assert.match(workflow, new RegExp(`^      ${name}:\\n        description: [^\\n]+\\n        required: true\\n        type: ${type}$`, 'mu'));
  }

  assert.match(workflow, /^permissions:\n  actions: read\n  contents: write\n  attestations: read$/mu);
  assert.doesNotMatch(workflow, /id-token:/u);
  assert.match(workflow, /^concurrency:\n  group: release-\$\{\{ inputs\.canonical_tag \}\}\n  cancel-in-progress: false$/mu);
  assert.match(workflow, /^    environment: release-production$/mu);

  const actionUses = [...workflow.matchAll(/^\s*-?\s*uses:\s+([^\s@]+)@([^\s#]+)(?:\s+#.*)?$/gmu)];
  assert.equal(actionUses.length, 3, 'promotion workflow needs only control/source checkouts and Node provisioning actions');
  for (const [, action, revision] of actionUses) {
    assert.match(revision, /^[0-9a-f]{40}$/u, `${action} must be pinned to a full commit SHA`);
  }
  assert.match(workflow, /^        uses: actions\/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4\.4\.0$/mu);
  assert.match(workflow, /^          node-version: '22'$/mu);
  assert.match(workflow, /^        uses: actions\/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5\.1\.0$/mu);
  assert.match(workflow, /^          ref: \$\{\{ inputs\.proof_commit \}\}$/mu);
  assert.match(workflow, /^          path: \$\{\{ github\.workspace \}\}\/control$/mu);
  assert.match(workflow, /^          ref: \$\{\{ inputs\.source_commit \}\}$/mu);
  assert.match(workflow, /^          path: \$\{\{ github\.workspace \}\}\/source$/mu);
  assert.equal((workflow.match(/uses: actions\/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5\.1\.0/gmu) ?? []).length, 2);
  assert.match(workflow, /^          persist-credentials: false$/mu);

  assertBefore(workflow, 'Validate canonical promotion inputs', 'Preflight protected repository controls');
  assertBefore(workflow, 'Preflight protected repository controls', 'Checkout proof-bearing control tree');
  assertBefore(workflow, 'Checkout proof-bearing control tree', 'Verify proof checkout and bytes');
  assertBefore(workflow, 'Verify proof checkout and bytes', 'Promote exact candidate bytes');
  assert.match(workflow, /repos\/\$GITHUB_REPOSITORY\/actions\/runs\/\$CANDIDATE_RUN_ID/u);
  assert.match(workflow, /repos\/\$GITHUB_REPOSITORY\/actions\/artifacts\/\$CANDIDATE_ARTIFACT_ID/u);
  assert.match(workflow, /immutable-release-tags/u);
  assert.match(workflow, /release-production/u);
  assert.match(workflow, /test "\$\(git -C "\$\{\{ github\.workspace \}\}\/control" rev-parse HEAD\)" = "\$PROOF_COMMIT"/u);
  assert.match(workflow, /shasum -a 256 "\$\{\{ github\.workspace \}\}\/control\/Docs\/ReleaseEvidence\/v1\.3\.1-guide-proof\.json"/u);
  assert.match(workflow, /test "\$OBSERVED_PROOF_SHA256" = "\$GUIDE_PROOF_SHA256"/u);
  assert.match(workflow, /node "\$\{\{ github\.workspace \}\}\/control\/scripts\/promote-release-candidate\.mjs"/u);
  assert.match(workflow, /--artifact-id "\$CANDIDATE_ARTIFACT_ID"/u);
  assert.match(workflow, /--control-commit "\$PROOF_COMMIT"/u);
  assert.match(workflow, /--guide-proof-sha256 "\$GUIDE_PROOF_SHA256"/u);

  assert.doesNotMatch(workflow, /swift\s+build|xcodebuild|tar\s+-c|gzip|zip\s|actions\/cache|\bcache:|git\s+tag|gh\s+(?:api\s+[^\n]*git\/refs|release\s+(?:create|upload))|--clobber/u);
});
