# Immutable Release Artifact Promotion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one authenticated `swift-mutation-testing` v1.3.1 candidate archive, prove those exact bytes in The Guide, and promote the unchanged archive to the public GitHub release.

**Architecture:** A default-branch candidate workflow runs trusted control code from an immutable control checkout while testing and compiling an independently pinned source checkout. Small dependency-free Node decision owners authenticate, build, and promote the candidate, and a separate protected promotion workflow publishes only the already-proven archive. The Guide fetches the service-identified artifact itself, executes only the verified private extraction, and binds its proof receipt to the closed provenance descriptor.

**Tech Stack:** GitHub Actions, dependency-free Node.js >=22 (`node:test` and V8 coverage; candidate CI pins 22), macOS 26, GitHub CLI/API, SwiftPM/Xcode 26.6, SHA-256 and GitHub artifact attestations.

## Global Constraints

- Candidate control code executes only from the control tree pinned to `workflow_commit`; Swift tests, version injection, and compilation occur only in the source tree pinned to `source_commit`.
- The canonical candidate, attestation, tag, and v1.3.1 release repository is `dsifry/swift-mutation-testing`; the existing `ericodx/swift-mutation-testing` v1.3.0 release and Guide pin remain historical and unchanged.
- `workflow_commit`, `dispatch_trigger_commit`, and `main_anchor_commit` are equal; `source_commit` is that commit or an authenticated ancestor.
- Runner/toolchain identity is exactly macOS 26, Xcode 26.6 build 17F113, Apple Swift 6.3.3, arm64 Mach-O, and the package's existing macOS 15 deployment minimum.
- The candidate archive is packaged once, retained 30 days, and never rebuilt, repacked, normalized, clobbered, or overwritten during Guide proof or promotion.
- Candidate and promotion workflows use only third-party actions pinned to full commit SHAs and the minimum permissions in the approved design.
- The promotion job uses `release-production`, explicit approval by the repository's authenticated maintainer, and noncancelling `release-${canonical_tag}` concurrency.
- The `immutable-release-tags` ruleset protects `refs/tags/v*` from update/deletion with no bypass actors.
- Every executable decision owner is a dependency-free Node module included in exact 100% focused line, branch, and function coverage. Workflow YAML is declarative orchestration covered by static contract tests and `actionlint`; no shell production owners are introduced. Existing Swift focused coverage and exact-union replay remain green.
- The existing `v1.3.0` release, public archive filename, source-build installation path, prepared-cache protocol, and legacy CLI behavior remain unchanged.
- No public release is created unless the Guide's 103-selector tuples are equivalent, warm elapsed time is at most 80% of uncached time, warm fallback builds are at most 10% of uncached builds, and recovery/privacy/retention drills pass.

## File map

Companion repository (`swift-mutation-testing`):

- Create `.github/workflows/release-candidate.yml`: manual build-once orchestration with distinct control/source checkouts.
- Modify `.github/workflows/release.yml`: manual, protected, promotion-only orchestration.
- Create `scripts/release-artifact.mjs`: closed manifest, provenance, archive, binary, attestation, tag, and draft-state verification library.
- Create `scripts/build-release-candidate.mjs`: source-confined test, version-injection, build, one-time package, and manifest CLI.
- Create `scripts/promote-release-candidate.mjs`: GitHub API coordinator CLI that never builds or repackages.
- Create `scripts/configure-release-controls.mjs`: idempotent check/apply owner for the feasible protected environment and immutable-tag controls in the canonical repository.
- Create `scripts/check-release-artifact-coverage.sh`: exact focused Node coverage and shell/workflow contract gate.
- Create `scripts/release-artifact-coverage-manifest.json`: explicit production include list and exact thresholds.
- Create `scripts/check-exact-test-replay.mjs`: enumerate current Swift tests, run deterministic nonoverlapping shards, and prove exact set equality.
- Create `Tests/ReleaseArtifact/release-artifact.test.mjs`: verifier and API-state behavior tests.
- Create `Tests/ReleaseArtifact/build-release-candidate.test.mjs`: injected-command build-owner tests.
- Create `Tests/ReleaseArtifact/promote-release-candidate.test.mjs`: promotion API-state tests.
- Create `Tests/ReleaseArtifact/configure-release-controls.test.mjs`: injected GitHub configuration/preflight tests.
- Create `Tests/ReleaseArtifact/workflow-contract.test.mjs`: static workflow trust/order/permission tests.
- Create `Tests/ReleaseArtifact/fixtures/`: canonical and adversarial manifest, attestation, archive-listing, run, tag, ruleset, draft, and release fixtures.
- Modify `Docs/INSTALLATION.MD`: arm64 prebuilt archive and checksum/attestation verification.
- Modify `Docs/BUILDING.md`: candidate creation, evidence handoff, promotion, retry, and terminal collision runbook.
- Modify `Docs/Architecture/README.md`: link the approved artifact-promotion design.
- Modify `.github/CODEOWNERS`: release-sensitive owners and tests.

Guide repository (`theguide`, Issue #51 worktree):

- Modify `tools/coverage/run-swift-mutations.mjs`: closed candidate descriptor parsing and byte/provenance binding.
- Modify `tools/coverage/run-swift-mutations.test.mjs`: exact schema and candidate dispatch tests.
- Create `tools/coverage/swift-mutation-release-candidate.mjs`: fetch the authenticated Actions artifact and return only its verified extracted executable plus descriptor digest.
- Create `tools/coverage/swift-mutation-release-candidate.test.mjs`: injected GitHub/artifact/attestation/archive custody tests.
- Modify `tools/coverage/swift-mutation-adapter.mjs`: bind `candidateDescriptorSHA256` into the closed mutation receipt tool identity.
- Modify `tools/coverage/swift-mutation-adapter.test.mjs`: candidate descriptor receipt tests and strict schema cases.
- Modify `tools/coverage/collect-swift-coverage.test.mjs`: update closed receipt fixtures.
- Modify `tools/coverage/swift-coverage-adapter.test.mjs`: update closed receipt fixtures.
- Modify `tools/coverage/swift-mutation-benchmark.mjs`: emit the closed content-free Guide release-proof receipt after real threshold/drill validation.
- Modify `tools/coverage/swift-mutation-benchmark.test.mjs`: exact proof schema, binding, threshold, and content-exclusion tests.
- Modify `tools/coverage/swift-mutation-release-candidate.json`: accepted v1.3.1 candidate identity after the real candidate exists.
- Modify `scripts/check-swift-closure-tools.sh`: include any newly split Guide production verifier owner if splitting is required for focus; otherwise keep the existing owner included.
- Modify `docs/SERVICE_INVENTORY.md`: materially expanded release-candidate verification boundary and validation evidence.
- Modify `docs/superpowers/specs/2026-08-11-swift-mutation-warm-cache-delivery-design.md`: replace reproducible-rebuild wording with authenticated build-once promotion.

---

### Task 1: Closed candidate manifest and local artifact verifier

**Files:**
- Create: `scripts/release-artifact.mjs`
- Create: `Tests/ReleaseArtifact/release-artifact.test.mjs`
- Create: `Tests/ReleaseArtifact/fixtures/candidate-valid.json`
- Create: `Tests/ReleaseArtifact/fixtures/attestation-valid.json`

**Interfaces:**
- Produces: `parseCandidateManifest(bytes: Buffer): CandidateManifest`
- Produces: `verifyCandidateBundle(input: CandidateBundleInput): Promise<VerifiedCandidate>`
- Produces: `verifyAttestationBundle(bundle, expected): VerifiedAttestation`
- Produces: CLI commands `candidate-manifest`, `candidate-bundle`, and `attestation`
- `CandidateBundleInput` contains canonical control/source roots, archive path, manifest path, extracted private directory, and injected command adapters for `tar`, `codesign`, `file`, `otool`, and the executable.
- `VerifiedCandidate` contains only the closed manifest plus observed archive, manifest, and executable SHA-256 digests.

- [ ] **Step 1: Write failing exact-schema and canonical-value tests**

```js
test('candidate manifest accepts exactly the closed v1 schema', () => {
  const bytes = Buffer.from(JSON.stringify(validCandidate));
  assert.deepEqual(parseCandidateManifest(bytes), validCandidate);
});

for (const mutate of [removeKey, addUnknownKey, wrongType, duplicateJSONKey]) {
  test(`candidate manifest rejects ${mutate.name}`, () => {
    assert.throws(() => parseCandidateManifest(mutate(validCandidateBytes)), /manifest/i);
  });
}
```

Cover every nested key and closed value: repository, workflow path/ref/commit, dispatch trigger, main anchor, run ID/attempt, artifact name, source commit, canonical version/tag/output, runner/toolchain/CPU/deployment, archive metadata, and executable metadata. The Actions artifact ID is service-issued after upload and belongs in the Guide descriptor and promotion inputs, not in this pre-upload manifest.

- [ ] **Step 2: Run the focused test and confirm RED**

Run: `node --test Tests/ReleaseArtifact/release-artifact.test.mjs`

Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `scripts/release-artifact.mjs`.

- [ ] **Step 3: Implement the minimal closed parser and digest primitives**

```js
export function parseCandidateManifest(bytes) {
  const value = parseJSONRejectingDuplicateKeys(bytes);
  assertExactKeys(value, CANDIDATE_KEYS, 'candidate manifest');
  assertCandidateValues(value);
  return Object.freeze(value);
}

export function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}
```

Use explicit validators rather than coercion. Reject unsafe integers, noncanonical versions, uppercase digests, wrong filenames, wrong run/attempt suffixes, and any mismatched derived field.

- [ ] **Step 4: Add RED tests for archive and executable safety**

Fixtures must cover extra paths, absolute/parent paths, symlinks, hardlinks, nonregular entries, wrong mode, size, digest, UUID, CPU, deployment minimum, version output, and failed code signature. Assert listing validation happens before extraction and extraction uses a fresh `0700` directory.

- [ ] **Step 5: Implement minimal bundle verification**

```js
export async function verifyCandidateBundle(input) {
  const manifestBytes = await input.fs.readOwnedRegularFile(input.manifestPath);
  const manifest = parseCandidateManifest(manifestBytes);
  await verifyArchiveListing(input.archivePath, manifest, input.commands);
  const executablePath = await extractPrivately(input, manifest);
  const observed = await inspectExecutable(executablePath, input.commands);
  assertObservedCandidate(manifest, manifestBytes, input.archivePath, observed);
  return Object.freeze({ manifest, ...observed });
}
```

- [ ] **Step 6: Add RED/GREEN attestation tests**

Require both subjects, repository, workflow path/ref, workflow commit, event, and exact Runner Invocation URI `/actions/runs/{run_id}/attempts/{run_attempt}`. Reject a matching digest from another repository, workflow, commit, event, run, or attempt.

- [ ] **Step 7: Run Task 1 GREEN**

Run: `node --test Tests/ReleaseArtifact/release-artifact.test.mjs`

Expected: PASS, including all adversarial fixtures.

- [ ] **Step 8: Commit Task 1**

```bash
git add scripts/release-artifact.mjs Tests/ReleaseArtifact
git commit -m "feat: verify immutable release candidates"
```

### Task 2: Source-confined build-once candidate owner

**Files:**
- Create: `scripts/build-release-candidate.mjs`
- Create: `scripts/check-exact-test-replay.mjs`
- Create: `Tests/ReleaseArtifact/build-release-candidate.test.mjs`
- Create: `Tests/ReleaseArtifact/exact-test-replay.test.mjs`
- Modify: `scripts/release-artifact.mjs`

**Interfaces:**
- Consumes: Task 1 `candidate-manifest` and `candidate-bundle` CLI commands from the control tree.
- Produces: `node build-release-candidate.mjs --control-root ... --source-root ... --output-root ... --version ... --source-commit ... --workflow-commit ... --run-id ... --run-attempt ... --artifact-name ...`
- Produces: output directory containing exactly the stable archive, `release-candidate-v1.json`, and two attestation input files; stdout contains one canonical JSON receipt with their digests.
- Produces: `node check-exact-test-replay.mjs --package-path SOURCE_ROOT`, which proves sorted expected/executed test set equality with no duplicates or omissions.

- [ ] **Step 1: Write the failing deterministic replay tests**

Use injected process results for a passing partition, duplicate test, omitted test, unknown executed test, failing shard, timeout, and malformed `swift test list` output. Confirm RED because `check-exact-test-replay.mjs` is absent, then implement stable suite-level filters, `--no-parallel`, bounded watchdogs, and exact sorted-set comparison.

Run: `node --test Tests/ReleaseArtifact/exact-test-replay.test.mjs`

Expected: PASS after GREEN, with every mismatch failing closed.

- [ ] **Step 2: Write failing build-command harness tests**

Use temporary control/source/output trees and prepend injected `swift`, `codesign`, `file`, `otool`, `tar`, and `shasum` shims to `PATH`. Record every invocation as NUL-delimited argv.

```js
test('all control scripts execute from workflow_commit tree', async () => {
  const result = await runBuild({ sourceCommitIsOlder: true });
  assert.equal(result.exitCode, 0);
  assert.equal(result.invocations.some(({ executable }) => executable.startsWith(sourceScripts)), false);
});
```

Cover unequal checkout heads, source outside the canonical source root, output under either checkout, source attempting to replace control code, wrong toolchain, cache flags, zero/multiple version replacements, test failure, build failure, wrong binary observations, second packaging attempt, and partial output cleanup.

- [ ] **Step 3: Run and confirm RED**

Run: `node --test Tests/ReleaseArtifact/build-release-candidate.test.mjs`

Expected: FAIL because the build owner does not exist.

- [ ] **Step 4: Implement canonical roots and two-checkout enforcement**

```js
const controlRoot = await realpath(input.controlRoot);
const sourceRoot = await realpath(input.sourceRoot);
const outputRoot = await canonicalOutputRoot(input.outputRoot);
assertDistinctAndDisjoint(controlRoot, sourceRoot, outputRoot);
await assertHead(controlRoot, input.workflowCommit);
await assertHead(sourceRoot, input.sourceCommit);
```

Invoke every checked-in owner with an absolute path below `CONTROL_ROOT`; use `swift --package-path "$SOURCE_ROOT"` and explicit source-local scratch paths. Do not `cd` into the source tree to locate a script.

- [ ] **Step 5: Implement test, injection, clean build, inspection, and one package call**

Run the current focused gate and exact-union replay before injection. Replace exactly one version token, build once with no cache restore, validate observations, invoke `tar` once, generate the closed manifest, and call the Task 1 verifier against a fresh extraction.

- [ ] **Step 6: Run Task 2 GREEN and prove archive immutability**

Run: `node --test Tests/ReleaseArtifact/build-release-candidate.test.mjs`

Expected: PASS; the fixture's archive digest is identical before verification and after simulated upload/download.

- [ ] **Step 7: Commit Task 2**

```bash
git add scripts/build-release-candidate.mjs scripts/check-exact-test-replay.mjs scripts/release-artifact.mjs Tests/ReleaseArtifact/build-release-candidate.test.mjs Tests/ReleaseArtifact/exact-test-replay.test.mjs
git commit -m "feat: build release candidate once"
```

### Task 3: Candidate GitHub Actions workflow

**Files:**
- Create: `.github/workflows/release-candidate.yml`
- Create: `Tests/ReleaseArtifact/workflow-contract.test.mjs`

**Interfaces:**
- Consumes: Task 2 build receipt and Task 1 attestation verifier.
- Produces: immutable Actions artifact named `swift-mutation-testing-vX.Y.Z-candidate-{run_id}-{run_attempt}` containing the stable archive, manifest, and attestation bundles.
- Produces: workflow summary values for artifact ID, service digest, run ID/attempt, manifest SHA-256, archive SHA-256, and executable SHA-256.

- [ ] **Step 1: Write failing workflow contract tests**

Parse YAML as text with strict anchored assertions. Require manual inputs, `macos-26`, exact permissions, full-SHA actions, checksum-pinned `actions/setup-node` provisioning Node 22, 30-day retention, no cache restore, two checkout paths, and ordering edges:

```js
assertBefore(workflow, 'Validate source ancestry', 'Build candidate once');
assertBefore(workflow, 'Build candidate once', 'Attest candidate');
assertBefore(workflow, 'Attest candidate', 'Upload immutable candidate');
assert.doesNotMatch(workflow, /gh release|create-release|tags:/u);
```

Also require `workflow_commit == dispatch_trigger_commit == main_anchor_commit`, exact control/source HEAD checks, artifact name run/attempt suffix, and execution of scripts only from `${{ github.workspace }}/control`.

- [ ] **Step 2: Run and confirm RED**

Run: `node --test Tests/ReleaseArtifact/workflow-contract.test.mjs`

Expected: FAIL because `release-candidate.yml` is absent.

- [ ] **Step 3: Implement the candidate workflow**

Use the GitHub API before checkout to resolve the immutable main anchor and authenticate ancestry. Checkout control at the workflow commit and source at the requested commit into distinct paths. Provision Node 22, invoke only control-tree `.mjs` owners, build once, attest archive and manifest with checksum-pinned `actions/attest`, upload without overwrite, download by artifact ID, and reverify with control-tree code.

- [ ] **Step 4: Run workflow validation GREEN**

Run: `node --test Tests/ReleaseArtifact/workflow-contract.test.mjs`

Run: `actionlint .github/workflows/release-candidate.yml`

Expected: both PASS.

- [ ] **Step 5: Commit Task 3**

```bash
git add .github/workflows/release-candidate.yml Tests/ReleaseArtifact/workflow-contract.test.mjs
git commit -m "ci: create immutable release candidate"
```

### Task 4: Fail-closed promotion coordinator

**Files:**
- Create: `scripts/promote-release-candidate.mjs`
- Create: `Tests/ReleaseArtifact/promote-release-candidate.test.mjs`
- Modify: `scripts/release-artifact.mjs`

**Interfaces:**
- Consumes: explicit canonical version, candidate run ID/attempt, artifact ID/name, manifest/archive/executable SHA-256, promotion control/Guide-proof commit, `guide-release-proof-v1.json` SHA-256, and `GH_TOKEN`.
- Produces: draft release state transitions only after `verifyPromotionAuthority(input, githubState)` succeeds.
- Produces: unchanged archive, candidate manifest, and canonical two-line `SHA256SUMS`; never invokes build or archive creation commands.

- [ ] **Step 1: Write RED tests for candidate/run authority**

Test wrong repository/workflow/commit/event/status, expired/deleted artifact, wrong artifact run ID, wrong attestation attempt URI, absent attestation, input digest mismatch, and untrusted download URL. Also test absent/malformed/noncanonical Guide proof; wrong proof commit/digest/candidate descriptor; failed status; selector count other than 103; unequal tuple digests; elapsed ratio above 0.80; fallback ratio above 0.10; and any failed recovery/privacy/retention drill. Each must stop before the first mutating API call.

- [ ] **Step 2: Write RED tests for tag and repository authority**

Test missing/lightweight/unverified/wrong-reason tags, tag-to-tag targets, wrong source commit, absent/weak/bypassed `immutable-release-tags`, absent or approval-free `release-production`, and tag tuple substitution before upload, before publish, and after publish.

- [ ] **Step 3: Write RED tests for draft/public state machine**

```js
test('exact draft retry is idempotent', async () => {
  const result = await promote({ draftAssets: exactCandidateAssets });
  assert.deepEqual(result.mutations, ['publish-existing-draft']);
});

test('mismatched draft and any public collision fail closed', async () => {
  await assertNoMutation(promote({ draftAssets: mismatchedAssets }));
  await assertNoMutation(promote({ publicRelease: true }));
});
```

- [ ] **Step 4: Run and confirm RED**

Run: `node --test Tests/ReleaseArtifact/promote-release-candidate.test.mjs`

Expected: FAIL because the promotion owner and verifier functions are absent.

- [ ] **Step 5: Implement the minimal verifier and coordinator**

Add `parseGuideReleaseProof`, `verifyPromotionAuthority`, `verifyTagTuple`, `verifyRepositoryControls`, and `classifyReleaseState` to the Node owner. Read the proof only from `Docs/ReleaseEvidence/v1.3.1-guide-proof.json` in the exact promotion control checkout; require its bytes/digest, Guide commit, candidate descriptor/digests, 103-selector equality, performance ratios, and drill results to match explicit inputs before any mutation. The injected GitHub adapter uses `gh api` only through those decisions, creates a draft if absent, uploads without clobber, downloads and verifies draft assets, revalidates the tag tuple, publishes, then downloads and verifies the public archive.

- [ ] **Step 6: Run Task 4 GREEN**

Run: `node --test Tests/ReleaseArtifact/promote-release-candidate.test.mjs Tests/ReleaseArtifact/release-artifact.test.mjs`

Expected: PASS with zero mutation calls on every rejected state.

- [ ] **Step 7: Commit Task 4**

```bash
git add scripts/promote-release-candidate.mjs scripts/release-artifact.mjs Tests/ReleaseArtifact/promote-release-candidate.test.mjs
git commit -m "feat: promote authenticated release archive"
```

### Task 5: Protected promotion-only workflow

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `Tests/ReleaseArtifact/workflow-contract.test.mjs`

**Interfaces:**
- Consumes: Task 4 explicit proof-bound inputs.
- Produces: protected manual promotion invocation; no build artifacts.

- [ ] **Step 1: Add failing release workflow contract tests**

Require `workflow_dispatch` only, typed required candidate and Guide-proof inputs, `actions: read`, `contents: write`, `attestations: read`, no `id-token`, `environment: release-production`, `concurrency.group: release-${canonical_tag}`, `cancel-in-progress: false`, full-SHA actions, checksum-pinned `actions/setup-node` provisioning Node 22, control checkout at the proof commit, exact proof-file digest verification, and invocation of `node scripts/promote-release-candidate.mjs`. Reject `swift build`, `xcodebuild`, `tar -c`, compression, cache, tag creation, `--clobber`, or automatic tag triggers.

- [ ] **Step 2: Run and confirm RED**

Run: `node --test Tests/ReleaseArtifact/workflow-contract.test.mjs`

Expected: FAIL against the current tag-triggered build-and-upload workflow.

- [ ] **Step 3: Replace with the minimal promotion workflow**

Validate inputs before downloading. Preflight environment/ruleset settings, download the exact artifact by ID from the supplied run, verify, then call the promotion coordinator. Keep all public mutations behind the protected environment.

- [ ] **Step 4: Run GREEN workflow checks**

Run: `node --test Tests/ReleaseArtifact/workflow-contract.test.mjs`

Run: `actionlint .github/workflows/release-candidate.yml .github/workflows/release.yml`

Expected: PASS.

- [ ] **Step 5: Commit Task 5**

```bash
git add .github/workflows/release.yml Tests/ReleaseArtifact/workflow-contract.test.mjs
git commit -m "ci: promote proven release bytes"
```

### Task 6: Exact release-owner coverage gate and companion documentation

**Files:**
- Create: `scripts/check-release-artifact-coverage.sh`
- Create: `scripts/release-artifact-coverage-manifest.json`
- Modify: `Tests/ReleaseArtifact/release-artifact.test.mjs`
- Modify: `Tests/ReleaseArtifact/build-release-candidate.test.mjs`
- Modify: `Tests/ReleaseArtifact/promote-release-candidate.test.mjs`
- Create: `Tests/ReleaseArtifact/configure-release-controls.test.mjs`
- Create: `scripts/configure-release-controls.mjs`
- Modify: `Docs/INSTALLATION.MD`
- Modify: `Docs/BUILDING.md`
- Modify: `Docs/Architecture/README.md`
- Modify: `.github/CODEOWNERS`

**Interfaces:**
- Produces: `scripts/check-release-artifact-coverage.sh`, returning nonzero unless every included production owner appears and has 100% lines, branches, and functions.
- Produces: operator runbook for candidate dispatch, Guide evidence handoff, tag/ruleset/environment setup, exact retry, and collision investigation.

- [ ] **Step 1: Write the coverage manifest and failing gate tests**

```json
{
  "includes": [
    "scripts/release-artifact.mjs",
    "scripts/build-release-candidate.mjs",
    "scripts/promote-release-candidate.mjs",
    "scripts/check-exact-test-replay.mjs",
    "scripts/configure-release-controls.mjs"
  ],
  "thresholds": {"lines": 100, "branches": 100, "functions": 100},
  "excludes": []
}
```

The gate must fail if an include is missing from V8 output, a metric is below 100, the include list is empty, or an exclude is added.

- [ ] **Step 2: Close coverage with behavioral tests**

Run: `scripts/check-release-artifact-coverage.sh`

Expected final result: all release test suites PASS and all five included Node decision owners report exactly 100% lines/branches/functions. Do not add ignore directives or weaken the manifest.

- [ ] **Step 3: Add RED/GREEN repository-control setup tests**

With an injected GitHub adapter, cover the current empty environment/ruleset state, exact already-configured state, weaker/malformed settings, wrong repository, lost admin authority, partial apply failure, and idempotent retry. Implement `node scripts/configure-release-controls.mjs --repository dsifry/swift-mutation-testing --check` as the default read-only preflight and require explicit `--apply` to create/update `release-production` with authenticated-maintainer approval and active `immutable-release-tags` protection for `refs/tags/v*` with no bypass actors. Re-read exact settings after apply; a weaker or unobservable result fails.

Run: `node --test Tests/ReleaseArtifact/configure-release-controls.test.mjs`

Expected: PASS with no mutations in check mode, the minimal expected API mutations in apply mode, and a clean no-op on exact retry.

- [ ] **Step 4: Document installation verification and operations**

Add commands that download the stable archive and SHA256SUMS, run `shasum -a 256 -c`, identify the prebuilt artifact as arm64/macOS 15+, and point other architectures to source build. Document exact API preflight for the protected environment and no-bypass tag ruleset, candidate expiry, matching draft retry, and terminal collision escalation.

- [ ] **Step 5: Run companion validation**

Run:

```bash
scripts/check-release-artifact-coverage.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/check-focused-coverage.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer node scripts/check-exact-test-replay.mjs
actionlint .github/workflows/release-candidate.yml .github/workflows/release.yml
git diff --check
bash -n scripts/check-release-artifact-coverage.sh
```

Expected: exact coverage PASS, every current Swift test listed and executed once, workflow validation PASS, and clean diff checks.

- [ ] **Step 6: Commit Task 6**

```bash
git add scripts/check-release-artifact-coverage.sh scripts/release-artifact-coverage-manifest.json scripts/configure-release-controls.mjs Tests/ReleaseArtifact Docs/INSTALLATION.MD Docs/BUILDING.md Docs/Architecture/README.md .github/CODEOWNERS
git commit -m "docs: document immutable artifact promotion"
```

### Task 7: Guide candidate provenance consumption

**Files (Guide Issue #51 worktree):**
- Create: `tools/coverage/swift-mutation-release-candidate.mjs`
- Create: `tools/coverage/swift-mutation-release-candidate.test.mjs`
- Modify: `tools/coverage/run-swift-mutations.mjs`
- Modify: `tools/coverage/run-swift-mutations.test.mjs`
- Modify: `tools/coverage/swift-mutation-adapter.mjs`
- Modify: `tools/coverage/swift-mutation-adapter.test.mjs`
- Modify: `tools/coverage/collect-swift-coverage.test.mjs`
- Modify: `tools/coverage/swift-coverage-adapter.test.mjs`
- Modify: `tools/coverage/swift-mutation-benchmark.mjs`
- Modify: `tools/coverage/swift-mutation-benchmark.test.mjs`
- Modify: `tools/coverage/swift-mutation-benchmark-corpus.json`
- Modify: `scripts/check-swift-closure-tools.sh`
- Modify: `docs/SERVICE_INVENTORY.md`
- Modify: `docs/superpowers/specs/2026-08-11-swift-mutation-warm-cache-delivery-design.md`

**Interfaces:**
- Replaces current six-key release-candidate schema with the closed provenance descriptor from the approved design.
- Produces: `fetchAndVerifyMutationReleaseCandidate({ descriptorPath, privateRoot, github, commands }): Promise<{ candidate, descriptorSHA256, binaryPath }>`.
- The fetcher resolves the supplied run/attempt/artifact ID through injected GitHub APIs, downloads by service identity rather than URL, authenticates both attestations and commits, validates the archive before private extraction, and returns the only binary path candidate mode may execute.
- `loadMutationReleaseCandidate(path): Promise<{ candidate, canonicalBytes, descriptorSHA256 }>` rejects unknown, missing, duplicate, noncanonical, or inconsistent fields.
- `mutationToolIdentity(pin, verifiedCandidate)` produces the companion cache identity plus `candidateDescriptorSHA256` from the verified fetch result.
- `verifySwiftMutationReceipt` requires the closed tool identity to bind `candidateDescriptorSHA256`; legacy immutable-pin runs bind the canonical pin-file SHA-256 in the same field so receipt schema remains singular.
- `createGuideReleaseProof({ candidate, benchmark, drills, guideCommit }): GuideReleaseProofV1` emits content-free canonical JSON only when all acceptance conditions pass; otherwise it emits no pass receipt.

- [ ] **Step 1: Write failing descriptor and download-custody tests**

Update the valid fixture to bind `sourceCommit`, `workflowCommit`, `dispatchTriggerCommit`, `mainAnchorCommit`, run ID/attempt, artifact ID/name, manifest/archive/binary SHA-256, exact version output, and capability. Generate one malformed case per key plus cross-field mismatches. Add injected GitHub fixtures for wrong repository/workflow/event/status/commit/run/attempt/artifact, ancestry failure, missing/wrong attestations, unsafe ZIP/archive members, symlink/hardlink, digest/version/signature mismatch, and cleanup on failure.

Add an end-to-end test that supplies a different `SWIFT_MUTATION_TESTING_RC_BIN` path and proves candidate mode ignores/rejects it: the executable given to `runSwiftMutationGate` must be exactly the private path returned by the authenticated fetcher, with matching descriptor/archive/binary digests.

- [ ] **Step 2: Run and confirm RED**

Run: `node --test tools/coverage/run-swift-mutations.test.mjs --test-name-pattern='release candidate'`

Expected: FAIL because the fetch owner is absent and the current parser accepts only `schemaVersion`, `commit`, `archiveSHA256`, `binarySHA256`, `versionOutput`, and `capability`.

- [ ] **Step 3: Implement authenticated fetch, private extraction, and runner binding**

```js
const releaseCandidateKeys = Object.freeze([
  'schemaVersion', 'sourceCommit', 'workflowCommit', 'dispatchTriggerCommit',
  'mainAnchorCommit', 'runId', 'runAttempt', 'artifactId', 'artifactName',
  'manifestSHA256', 'archiveSHA256', 'binarySHA256', 'versionOutput', 'capability',
]);
```

Require workflow/trigger/anchor equality, positive safe run/artifact integers, run/attempt suffix in the artifact name, exact v1.3.1 output, lowercase digests, and prepared-cache capability. Remove candidate-mode authority from the free `SWIFT_MUTATION_TESTING_RC_BIN` path. Download the artifact into the authenticated active-run root, verify the service identity, attestations, manifest, archive structure and digest, privately extract exactly one executable, verify its digest/version/signature/metadata, and pass that returned path directly into the prepared gate. Cleanup retains no source-bearing candidate bytes after the run.

- [ ] **Step 4: Write receipt-binding RED/GREEN tests**

First assert that the current closed receipt rejects or drops `candidateDescriptorSHA256`. Then extend the singular tool schema and every affected fixture so `adaptSwiftMutationReport`, `verifySwiftMutationReceipt`, collection, and coverage adaptation preserve and validate the descriptor digest. Candidate runs use the verified descriptor digest; legacy pin runs use the SHA-256 of canonical pin bytes. Reject any report where the descriptor digest is absent, malformed, or differs from the fetch result.

- [ ] **Step 5: Write Guide release-proof RED/GREEN tests**

Extend the real benchmark owner to consume the candidate-bound uncached/warm receipts plus canonical recovery, privacy/scrub, and retention drill receipts. The closed proof contains exactly: schema/version, `dsifry/theguide`, Guide commit, candidate descriptor/manifest/archive/binary digests, selector count, uncached/warm semantic tuple digests, elapsed/build counters, benchmark receipt digest, three drill receipt digests/pass booleans, and `status: pass`. Reject source paths, source/replacement bytes, logs, arbitrary diagnostics, unequal tuple digests, selector count other than 103, time ratio above 0.80, fallback ratio above 0.10, or any failed/mismatched drill. Assert canonical bytes and stable SHA-256.

Write RED corpus tests proving the current ten-unit truncation and 12-selector committed corpus are rejected. Change `benchmarkCorpus` to derive all 101 unique sorted `TheGuideTests/` selectors from the authenticated ownership manifest, append exactly the two fixed UI selectors, and require an exact sorted unique total of 103. Regenerate `tools/coverage/swift-mutation-benchmark-corpus.json` from that function and require its ownership-manifest path, digest, and selector array to match the runtime derivation byte-for-byte. Add negative tests for 100 or 102 unit selectors, a missing/extra/reordered/duplicate UI selector, stale corpus digest, and committed/runtime corpus drift.

- [ ] **Step 6: Run Guide GREEN and exact coverage**

Run:

```bash
node --test tools/coverage/swift-mutation-release-candidate.test.mjs tools/coverage/run-swift-mutations.test.mjs tools/coverage/swift-mutation-adapter.test.mjs tools/coverage/collect-swift-coverage.test.mjs tools/coverage/swift-coverage-adapter.test.mjs tools/coverage/swift-mutation-benchmark.test.mjs
npm run test:swift-closure-tools
npm run validate:service-inventory
git diff --check
```

Expected: the existing lightweight closure plus new candidate tests remain green; every included Guide production owner, including the new fetcher and changed adapter/runner, is exact 100% lines/branches/functions; inventory validation passes.

- [ ] **Step 7: Commit Guide code separately after work-unit review**

Stage only the declared Guide files and commit without `--no-verify` after the Guide work-unit review gate.

### Task 8: Real candidate, Guide proof, and unchanged promotion rehearsal

**Files:**
- Modify with real authenticated values: Guide `tools/coverage/swift-mutation-release-candidate.json`
- Create after passing real proof: companion `Docs/ReleaseEvidence/v1.3.1-guide-proof.json`
- Create as uncommitted/release evidence: candidate workflow summary, attestation bundles, Guide cold/warm receipts, promotion summary, and public digest comparison.

**Interfaces:**
- Consumes: merged candidate/promotion implementation, configured protected environment/ruleset, reviewed source commit, and ready host preflight.
- Produces: public `v1.3.1` only after every acceptance threshold passes.

- [ ] **Step 1: Merge the reviewed companion implementation before candidate creation**

Run companion task-done and PR-ready reviews, address all valid findings with TDD, rerun exact coverage/full replay, commit without bypassing hooks, push, obtain green CI, and squash-merge. Do not dispatch the candidate workflow from an unmerged branch. The Guide verifier code may be reviewed and committed before the candidate exists because all behavior is fixture-driven; its descriptor data is not finalized or merged yet.

- [ ] **Step 2: Configure and verify canonical repository controls**

Run `node scripts/configure-release-controls.mjs --repository dsifry/swift-mutation-testing --apply` with the authenticated repository administrator, approve the explicit API changes, then run the default `--check` mode. Require an exact `release-production` approval gate and active no-bypass `immutable-release-tags` protection before continuing. The setup owner never changes source, workflows, tags, releases, or assets.

- [ ] **Step 3: Dispatch one candidate**

Dispatch `release-candidate.yml` in `dsifry/swift-mutation-testing` with version `1.3.1` and the reviewed source commit. Record workflow commit, trigger/main anchor, source commit, run ID/attempt, artifact ID/name, service digest, manifest/archive/binary digests, toolchain, and attestation invocation URIs.

- [ ] **Step 4: Download and independently verify exact candidate bytes**

Use the checked-in Guide fetcher against the downloaded artifact, not a local rebuild or free binary path. Confirm `swift-mutation-testing --version` is exactly `swift-mutation-testing 1.3.1 [arm64-macos26]`, and write the accepted Guide descriptor from the verified values.

- [ ] **Step 5: Run the authoritative Guide proof once under ready-host discipline**

Require the existing Guide host-resource preflight, no unrelated booted simulator, one authenticated simulator, and custody cleanup. Execute the 103-selector uncached baseline and warm prepared lane. Require exact selector/result tuple equivalence, warm elapsed `<= 0.80 * uncached`, warm fallback builds `<= 0.10 * uncached`, and passing kill/recovery/privacy/retention drills. On OOM, timeout, custody residue, or threshold failure: publish nothing, preserve content-free evidence, fix the Guide/runtime issue, and rerun the proof against the same candidate bytes. Each candidate run/attempt packages exactly once. Only an invalid, corrupt, or expired candidate may be abandoned for a new run/attempt, and that replacement requires a complete fresh proof; evidence from different candidates is never combined.

- [ ] **Step 6: Finalize and merge the Guide proof binding**

After the proof passes, rerun Guide task-done/PR-ready gates with the real descriptor and receipts, commit only intended Issue #51 files without bypassing hooks, push, obtain green CI, and squash-merge. Re-download and reverify the candidate after merge; any descriptor or byte change invalidates the proof.

- [ ] **Step 7: Review and merge the content-free promotion proof**

Copy only the canonical `guide-release-proof-v1.json` bytes emitted by the passing Guide benchmark into companion `Docs/ReleaseEvidence/v1.3.1-guide-proof.json`. Verify its digest and candidate binding with `release-artifact.mjs`, open a focused evidence-only companion PR, require normal CI/review, and squash-merge. The promotion control checkout must be this exact merge commit; unmerged/local proof files have no authority.

- [ ] **Step 8: Create the protected annotated tag and promote**

Create signed annotated `v1.3.1` in `dsifry/swift-mutation-testing` pointing directly to the manifest source commit. Dispatch `release.yml` from the exact proof merge commit with the candidate values, Guide proof commit, and Guide proof SHA-256. Approve through `release-production`. Require the workflow to authenticate the checked-in proof and publish the existing candidate archive unchanged.

- [ ] **Step 9: Verify public bytes and installation path**

Download all public assets afresh. Require public archive SHA-256 and extracted executable SHA-256 to equal the Guide proof, verify SHA256SUMS, version, code signature, CPU, and deployment minimum, and perform the documented installation smoke test.

- [ ] **Step 10: Complete thread audit and capture post-merge learning**

Audit all review bodies, outside-diff comments, unresolved threads, and mandatory PR checks. Squash-merge only after green gates, then run the supported post-merge learning mechanism. Close Issue #51 only after the public-byte equality and performance evidence are attached; Issue #50 begins afterward using the released system.

## Self-review record

- Spec coverage: every candidate, Guide-consumer, promotion, failure/retry, repository-control, coverage, and real-proof requirement maps to Tasks 1-8.
- Placeholder scan: every code and validation step names its exact owner, interface, command, and expected result; no deferred implementation markers remain.
- Type consistency: candidate provenance field names are identical in Tasks 1, 3, 4, 5, and 7; `source_commit`/workflow metadata use snake case in the artifact manifest and corresponding camel case only in the Guide JavaScript descriptor, with explicit mapping in Task 7.
- Scope: compiler/linker reproducibility work, mutation/cache changes, Homebrew, generalized CI refactors, and non-arm64 binary production are excluded.
