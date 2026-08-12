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

Release candidates are built once by `release-candidate.yml`, retained for 30
days, proven by The Guide, and promoted unchanged by `release.yml`. Before a
candidate dispatch, verify the protected environment and tag ruleset read-only:

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

Dispatch `release-candidate.yml` with a canonical version and reviewed source
commit. Record the run ID, run attempt, artifact ID/name, manifest/archive/
executable digests, and workflow/source commits in the Guide candidate
descriptor. The Guide proof returns its commit, descriptor digest, and
content-free release-proof digest for promotion.

Retry promotion only against the same nonpublic draft whose three assets match
byte-for-byte. An expired candidate must be rebuilt and fully reproven. A
mismatched draft, public release, public asset, or tag collision is terminal for
automation: stop and investigate; never clobber, replace, or reconstruct bytes.
