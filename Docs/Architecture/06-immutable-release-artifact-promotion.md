# Immutable Release Artifact Promotion

## Approved local-candidate authority

Candidate construction is a local, owner-custodied macOS operation. GitHub PR
and `main` automation is Ubuntu/Node contract CI only: it never runs Swift,
Xcode, candidate construction, signing, attestation, or publication. There is
no remote candidate artifact and no publication workflow.

The local builder emits exactly the prebuilt archive, its closed manifest, and
canonical `local-release-provenance-v1.json`. The provenance object has exactly
`schemaVersion`, `repository`, `sourceCommit`, `versionOutput`, `capability`,
`manifestSHA256`, `archiveSHA256`, `binarySHA256`, `swiftVersionOutput`,
`sdkVersionOutput`, `targetTriple`, `configuration`, and `codesignVerified`, in
that positional order. Compact JSON plus one LF is canonical; reordered,
missing, or additional keys are rejected. The descriptor SHA-256 binds the
campaign and promotion. `codesignVerified` becomes true only after strict local
macOS code-signature verification. No additional PKI is introduced.

The authenticated local owner retains the archive, manifest, and provenance as
owner-only regular files. Publication opens each input once, authenticates its
metadata through that handle, and reads through the same handle. It creates and
authenticates a fresh owner-private work root before upload or extraction.

The Guide verifies those exact local bytes and binds the canonical descriptor
digest into its content-free proof. Promotion accepts that proof and the parsed
provenance explicitly; it does not mutate caller-owned input. Before any GitHub
mutation it verifies the descriptor, manifest, archive, executable, Guide proof,
annotated tag, repository ruleset, and protected release authority.

Publication uploads only the already-proven archive, manifest, and generated
checksums, without rebuilding or repacking. It downloads draft assets and the
public archive again, verifies their hashes, privately extracts the executable,
and requires its digest to equal the proven executable digest. Exact matching
draft retries are idempotent; mismatched drafts or public collisions fail
closed. Prebuilt binaries are never committed to this repository.

## Ownership and verification

- `scripts/build-release-candidate.mjs` owns local build, signing observations,
  packaging, and canonical provenance production.
- `scripts/release-artifact.mjs` owns closed schemas, archive verification,
  Guide proof binding, and promotion authority decisions.
- `scripts/promote-release-candidate.mjs` owns authenticated local publication,
  exact upload/redownload verification, and fail-closed retry behavior.
- `.github/workflows/release-candidate.yml`, `pull-request-analysis.yml`, and
  `main-analysis.yml` run Ubuntu/Node contract tests only.

Focused Node coverage must remain 100% for changed release owners. Local real
integration additionally exercises producer to Guide verifier to promotion
dry-run without placing machine-specific paths in CI.
