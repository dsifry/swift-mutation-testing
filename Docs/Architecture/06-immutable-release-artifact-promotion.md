# Immutable Release Artifact Promotion

## Problem and decision

Issue #51 requires the executable exercised by The Guide's 103-selector cold
and warm proof to be the executable published as `v1.3.1`. Two clean builds of
the same reviewed commit, version injection, Xcode, and Swift toolchain produced
different Mach-O UUID and signature bytes. A fixed linker UUID salt made
re-linking identical object files stable, but it did not make clean Swift
compilation byte reproducible.

The release process will therefore build and package a candidate exactly once,
authenticate it, retain it as an immutable GitHub Actions artifact, and later
promote that same archive to a GitHub release without rebuilding or repacking.
Compiler-flag experiments and post-build binary normalization are out of scope.

## Use cases and success criteria

1. **The Guide release owner** wants to download an authenticated candidate so
   that, when the full mutation proof starts, its evidence binds the exact bytes
   that may ship.
2. **The companion maintainer** wants to publish a proven candidate so that,
   when the signed annotated tag is created, release automation cannot silently
   substitute a rebuild.
3. **A reviewer or future maintainer** wants a closed provenance record so that,
   when a digest, tag, source commit, workflow run, or toolchain differs, the
   process fails before public release.
4. **An operator retrying a failed promotion** wants deterministic recovery so
   that an exact matching draft can be completed, while mismatched or already
   public assets are never overwritten.

Success means all of the following are mechanically verified:

- the candidate source is the requested 40-character commit on `main`;
- the archive contains exactly one regular executable named
  `swift-mutation-testing`, with no links or extra paths;
- the executable prints the requested release version and passes strict code-
  signature validation;
- the candidate manifest, archive, and executable digests match at Guide proof
  time and promotion time;
- the annotated tag is GitHub-verified and targets the candidate source commit;
- the public release archive is byte-identical to the Guide-proven archive;
- any failure before final publication produces no public release.

## Architecture

### 1. Candidate build workflow

A manually dispatched `release-candidate.yml` accepts `version` and
`source_commit`. It has read-only repository permissions plus only the
`id-token: write` and `attestations: write` permissions needed for provenance.
It validates canonical `X.Y.Z` version syntax, resolves the commit through the
GitHub API, and requires the commit to be reachable from current `main`. It then
checks out that exact commit with full history.

The job runs on `macos-26`, uses the full Xcode developer directory, performs no
SwiftPM build-cache restore, and requires Xcode 26.6 build 17F113, Apple Swift
6.3.3, an arm64 Mach-O, and the package's existing macOS 15 minimum deployment
target. The compiler's observed build-host target triple
`arm64-apple-macosx26.0` is recorded as toolchain identity; it does not replace
or raise the Mach-O deployment minimum. This preserves the existing
`-macos.tar.gz` arm64 artifact produced by the current `macos-26` workflow and
the source-build path for other architectures. It also records the runner
image, workflow identity, workflow commit, dispatch trigger commit, run ID, and
run attempt. A toolchain or deployment policy change therefore requires a
reviewed design update rather than silently producing another candidate.

The full focused coverage and exact-union suite replay run against the unchanged
reviewed source, where the existing `Version` tests require `0.0.0-dev`. Only
after they pass may version injection replace exactly one `0.0.0-dev`
occurrence in
`Version.swift`; zero or multiple replacements fail. The job runs the release
specific version and binary checks after injection, performs one clean release
build, verifies
`swift-mutation-testing --version`, and validates the resulting regular file and
code signature, CPU type, and macOS 15 deployment minimum.

Packaging occurs once. The archive has the existing public filename
`swift-mutation-testing-vX.Y.Z-macos.tar.gz` and contains only the executable at
its root. A closed `release-candidate-v1.json` manifest records:

- schema version, repository, workflow path/ref, workflow commit, dispatch
  trigger commit, run ID, run attempt, and Actions artifact name;
- source commit, version, tag, and exact version output;
- runner image/architecture, Xcode version/build, Swift version, compiler target,
  Mach-O CPU type, and deployment minimum;
- archive filename and SHA-256;
- executable filename, mode, byte size, Mach-O UUID, and SHA-256.

The workflow re-parses its emitted manifest, extracts the archive into a fresh
directory, and repeats every structural, digest, version, and signature check.
It then creates GitHub artifact attestations for the archive and manifest and
uploads both as one immutable Actions artifact with 30-day retention. The
workflow reports the Actions artifact ID and service-provided artifact digest.
It does not create a tag or release.

### 2. Guide proof consumption

The Guide-side candidate fetch is given the candidate workflow run ID, run
attempt, artifact ID, and artifact name. Before
using any bytes, it verifies through GitHub APIs that the run belongs to this
repository, used the candidate workflow from the default branch, was manually
dispatched, completed successfully, and has the manifest's dispatch trigger
commit and run attempt. The manifest's separate workflow commit must equal the
trusted default-branch revision of the candidate workflow. The separate source
commit is authenticated by the workflow's recorded ancestry check and exact
post-checkout `HEAD`; it is not compared to the workflow run's `head_sha`. The
consumer requires the requested artifact ID/name to belong to that exact run
attempt. It downloads that artifact without following an
operator-supplied URL and verifies both GitHub attestations.

The consumer accepts the exact manifest schema only. It rejects unknown,
missing, duplicate, noncanonical, or incorrectly typed values. Archive listing
is checked before extraction; extraction occurs into a fresh private directory;
and path, file type, link count, mode, size, digest, version output, Mach-O UUID,
and signature are revalidated afterward.

The Guide release-candidate descriptor advances to a closed schema that binds
the source commit, workflow commit, dispatch trigger commit, candidate workflow
run/attempt and artifact ID/name, candidate
manifest SHA-256, archive SHA-256, executable SHA-256, version output, and
capability. The cold/warm proof receipt binds that descriptor digest. Copying the
executable without its authenticated manifest is not a valid candidate.

### 3. Unchanged promotion workflow

`release.yml` becomes a manually dispatched promotion workflow. Automatic tag
pushes no longer build or publish. Inputs are the canonical version, candidate
workflow run ID, run attempt, artifact ID/name, candidate manifest SHA-256,
archive SHA-256, and executable SHA-256 copied from the accepted Guide proof.

Promotion has `actions: read`, `contents: write`, `attestations: read`, and
`id-token: write` permissions. It downloads the candidate artifact from this
repository and repeats all run-provenance, attestation, manifest, archive, and
executable checks. It additionally requires:

- `refs/tags/vX.Y.Z` already exists and resolves to an annotated tag object;
- the GitHub Git Tags API reports the tag signature as verified with reason
  `valid`;
- the tag's peeled commit equals the manifest source commit;
- the candidate version, manifest digest, archive digest, and binary digest
  equal the explicit promotion inputs;
- no public release exists for the tag and no public asset with the release
  filename exists.

Only after every check passes may the workflow create or reuse a draft release
named `swift-mutation-testing X.Y.Z` for `vX.Y.Z`, upload the unchanged candidate
archive, the candidate manifest, and `swift-mutation-testing-vX.Y.Z-SHA256SUMS`,
then download the draft assets and verify their bytes again. The checksum file
contains exactly two lowercase SHA-256 lines in byte-sorted filename order: one
for the archive and one for the extracted executable's published filename. It
then publishes the draft. A
retry may reuse a draft only when every existing asset digest equals the
candidate; otherwise it fails closed. It never uses clobber or replaces a public
asset. The final workflow assertion downloads the public archive and requires
its SHA-256 and extracted executable SHA-256 to equal the manifest and Guide
proof inputs.

## Trust boundaries

- **Trusted:** the reviewed source commit on `main`; repository-controlled
  workflows on the default branch; the protected release environment and its
  approver; GitHub Actions immutable artifact identity and attestations; the
  GitHub-verified annotated tag; SHA-256 comparisons performed by checked-in
  verification code.
- **Untrusted until verified:** manual inputs, tag names, downloaded bytes,
  archive metadata, manifest JSON, workflow-run IDs, draft assets, cache state,
  filenames, and command output.
- **Never trusted for authority:** a local rebuild, a user-provided download
  URL, an unsigned or lightweight tag, an Actions artifact from another
  repository/workflow/commit, or the digest of the Actions service's ZIP wrapper
  in place of the release archive digest.

All third-party actions used by these release-sensitive workflows are pinned to
full commit SHAs. Candidate artifacts have a retention period long enough for
the five-hour proof and review cycle. Environment secrets are never printed or
stored in the manifest, archive, checksum file, or Guide evidence.

## Failure and recovery

- Candidate validation failure uploads no candidate artifact.
- An expired or deleted candidate cannot be reconstructed. A new candidate must
  be built, and the complete Guide cold/warm proof must be rerun for its new
  digests.
- A mismatch at Guide download or promotion stops before mutation execution or
  public release respectively.
- A promotion failure before draft creation leaves no release. A failure after
  draft creation leaves a nonpublic draft for inspection or an exact-matching
  retry. Mismatched drafts require explicit maintainer cleanup; automation does
  not delete or overwrite them.
- A public release or asset collision is terminal for automation and requires
  maintainer investigation. No rollback rewrites immutable release bytes.
- The existing `v1.3.0` release and legacy non-cache CLI behavior are unchanged.

## Implementation boundaries

The implementation is limited to:

- a candidate workflow and a promotion-only replacement for the current release
  workflow;
- small checked-in build/verify/promotion scripts whose responsibilities do not
  overlap;
- fixture-driven tests for those scripts and static workflow-contract tests;
- documentation of the operator commands and evidence handoff;
- the corresponding closed Guide candidate descriptor and verifier update.

No compiler, linker, mutation engine, cache protocol, Homebrew, or general CI
architecture changes are included.

The intended owners are `.github/workflows/release-candidate.yml` for candidate
orchestration, `.github/workflows/release.yml` for promotion orchestration,
`scripts/release-artifact.mjs` for closed manifest/archive verification,
`scripts/build-release-candidate.sh` for the single build/package operation,
and `scripts/promote-release-candidate.sh` for GitHub API coordination. Node is
used only for the dependency-free verifier because its built-in test runner and
coverage make exact JSON and filesystem failure branches measurable; shell
owners remain thin and are exercised with injected command shims.

## TDD and acceptance tests

Implementation proceeds in independently reviewable RED/GREEN batches:

1. **Closed manifest verifier:** RED Node fixtures for every missing/unknown/type-
   invalid field, wrong source/version/toolchain/run binding, unsafe archive
   entry, symlink/hardlink, wrong mode/size/UUID/signature, and digest mismatch;
   GREEN with exact parsing and private extraction.
   The verifier requires exact 100% line, branch, and function coverage.
2. **Build-once candidate:** RED workflow-contract tests proving no candidate
   artifact can be uploaded before tests, version, archive, manifest, and
   attestation checks; GREEN candidate workflow and build script. A fixture
   records that the archive is created once and its digest is unchanged through
   upload/download verification.
3. **Promotion:** RED tests for another repository/workflow/commit, failed or
   expired run, unverifiable/lightweight/wrong-target tag, input mismatch,
   missing attestation, public collision, mismatched draft, and any build or
   repackaging command; GREEN promotion-only workflow. A success fixture proves
   the published archive bytes are the downloaded candidate bytes.
4. **Failure recovery:** RED/GREEN tests for no-artifact candidate failure,
   pre-draft promotion failure, exact draft retry, mismatched draft refusal, and
   post-public verification failure reporting.
5. **Real release rehearsal:** build one `v1.3.1` candidate from the reviewed
   commit, download and verify it, run the full Guide proof against the extracted
   executable, create the verified annotated tag, promote the same archive, and
   compare the public archive and executable digests to the Guide receipt.

Shell behavior is tested through isolated fixture directories and injected
command shims; workflow YAML is checked with a checksum-pinned `actionlint` and
contract tests. The release validation command runs the focused 100% production
coverage gate plus the checked-in exact-union suite replay, avoiding the known
monolithic Swift Testing output-capture deadlock while proving every currently
listed test exactly once.
Tests must cover every normal path and credible failure branch in the checked-in
scripts. Existing Swift focused coverage and the exact full-test manifest remain
green because this design does not waive product-code gates.

## Delivery decision

Release `v1.3.1` only if the Guide's 103-selector result tuples are equivalent,
warm elapsed time is at most 80% of uncached elapsed time, warm fallback builds
are at most 10% of uncached builds, recovery/privacy/retention drills pass, all
design and code reviewers approve, and the public archive and executable
digests exactly equal the candidate proven by The Guide. Otherwise publish no
release and preserve only content-free failure evidence.
