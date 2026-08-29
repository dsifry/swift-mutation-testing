# Building for Contributors

This guide is for contributors who need to build, test, and smoke-test
`swift-mutation-testing` from a local checkout. Installation options for users
are covered in [Installation](INSTALLATION.MD).

## Prerequisites

- macOS 15 or later
- Xcode 16 or later
- Swift 6.2 or later
- Git
- pre-commit, for local repository hooks

Verify the Swift toolchain before running package commands:

```bash
swift --version
```

## Build and Test

Run a debug build for day-to-day development:

```bash
swift build
```

Run the Swift Package Manager test suite:

```bash
swift test
```

The suite includes unit tests and fixture-backed integration coverage. If the
toolchain is older than the version required by `Package.swift`, upgrade Swift
before trusting the result.

## CLI Smoke Checks

Use `swift run` so the executable comes from the checkout under test:

```bash
swift run swift-mutation-testing --help
swift run swift-mutation-testing --version
swift run swift-mutation-testing init Fixtures/CalcLibrary
```

The `init` command should generate a `.swift-mutation-testing.yml` file for the
fixture project. Remove that generated file before committing if you create it
inside the repository.

## Fixture Projects

The repository includes two small projects for local validation:

- `Fixtures/CalcLibrary` is a Swift Package Manager fixture.
- `Fixtures/CalcApp` is an Xcode project fixture.

Run the SPM fixture without a scheme or destination:

```bash
swift run swift-mutation-testing Fixtures/CalcLibrary
```

Run the Xcode fixture with its scheme and macOS destination:

```bash
swift run swift-mutation-testing Fixtures/CalcApp \
  --scheme CalcApp \
  --destination "platform=macOS"
```

## Repository Hooks

Install the configured hooks before preparing commits:

```bash
pre-commit install
pre-commit install --hook-type commit-msg
```

The hook set includes conventional commit validation, common file checks,
codespell, SwiftLint, swift-format, Swift code duplication detection,
Swift Marshal, and Gitleaks. Swift source changes should pass SwiftLint and
swift-format before review.

To run all hooks on the current checkout:

```bash
pre-commit run --all-files
```

## Immutable release operations

Release candidates are built once on an owner-custodied macOS host, proven by
The Guide, and promoted unchanged. GitHub workflows run contract CI only and do
not construct or retain candidate binaries. Before local construction, verify
the protected environment and tag ruleset read-only:

```bash
node scripts/configure-release-controls.mjs \
  --repository dsifry/swift-mutation-testing --check
```

An authenticated repository administrator performs initial setup explicitly:

```bash
node scripts/configure-release-controls.mjs \
  --repository dsifry/swift-mutation-testing \
  --apply --maintainer GITHUB_LOGIN
```

The exact reread requires `release-production` to have one authenticated user
reviewer with self-review prevented, and the active `immutable-release-tags`
ruleset to protect `refs/tags/v*` from updates and deletion with no bypass.

Use separate control and source checkouts and invoke the local candidate owner
with the canonical version and reviewed source commit. The output directory
must not already exist. Record the canonical builder receipt and preserve the
three owner-only outputs: archive, manifest, and local provenance descriptor.

```bash
node scripts/build-release-candidate.mjs \
  --control-root CONTROL_ROOT --source-root SOURCE_ROOT \
  --output-root FRESH_OUTPUT_ROOT --version VERSION \
  --source-commit SOURCE_COMMIT --workflow-commit CONTROL_COMMIT \
  --run-id LOCAL_BUILD_ID --run-attempt 1 \
  --artifact-name swift-mutation-testing-vVERSION-candidate-LOCAL_BUILD_ID-1
```

Copy the canonical local provenance descriptor and its sibling archive and
manifest into The Guide's owner-private candidate directory. The Guide verifies
those exact bytes, executable digest and version, and strict code signature.
After The Guide produces and reviewers merge its content-free proof, copy that
proof into `Docs/ReleaseEvidence/v1.3.3-guide-proof.json` and record its Guide
commit, descriptor digest, and proof SHA-256.

Create the already-reviewed release tag as a signed annotated tag and push it
without rewriting any existing tag:

```bash
git tag -s v1.3.3 SOURCE_COMMIT -m 'swift-mutation-testing 1.3.3'
git push origin refs/tags/v1.3.3
```

Dispatch promotion using every required field shown by the workflow interface:

```bash
gh workflow run release.yml --repo dsifry/swift-mutation-testing \
  -f version=1.3.3 -f canonical_tag=v1.3.3 \
  -f candidate_run_id=RUN_ID -f candidate_run_attempt=ATTEMPT \
  -f candidate_artifact_id=ARTIFACT_ID -f candidate_artifact_name=ARTIFACT_NAME \
  -f candidate_workflow_commit=WORKFLOW_COMMIT -f source_commit=SOURCE_COMMIT \
  -f manifest_sha256=MANIFEST_SHA256 -f archive_sha256=ARCHIVE_SHA256 \
  -f executable_sha256=EXECUTABLE_SHA256 \
  -f candidate_descriptor_sha256=DESCRIPTOR_SHA256 \
  -f proof_commit=PROOF_COMMIT -f guide_commit=GUIDE_COMMIT \
  -f guide_proof_sha256=GUIDE_PROOF_SHA256
```

Retry promotion only against the same nonpublic draft whose three assets match
byte-for-byte. An expired candidate must be rebuilt and fully reproven. A
mismatched draft, public release, public asset, or tag collision is terminal for
automation: stop and investigate; never clobber, replace, or reconstruct bytes.
For a transient failure with the exact same candidate and matching draft, rerun
the same workflow attempt and inputs: `gh run rerun PROMOTION_RUN_ID --failed`.
