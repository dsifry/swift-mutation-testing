#!/bin/bash
set -euo pipefail

control_root="$(cd "$(dirname "$0")/.." && pwd -P)"
manifest="${RELEASE_ARTIFACT_COVERAGE_MANIFEST:-$control_root/scripts/release-artifact-coverage-manifest.json}"
cd "$control_root"

node -e '
  const manifest = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  const expected = ["lines", "branches", "functions"];
  if (!Array.isArray(manifest.includes) || manifest.includes.length === 0) throw new Error("coverage includes must be nonempty");
  if (!Array.isArray(manifest.excludes) || manifest.excludes.length !== 0) throw new Error("coverage excludes must be empty");
  if (new Set(manifest.includes).size !== manifest.includes.length) throw new Error("coverage includes must be unique");
  if (Object.keys(manifest.thresholds ?? {}).sort().join(",") !== expected.sort().join(",") || expected.some((metric) => manifest.thresholds[metric] !== 100)) throw new Error("coverage thresholds must be exact 100");
  for (const owner of manifest.includes) {
    if (typeof owner !== "string" || !owner.startsWith("scripts/") || !owner.endsWith(".mjs") || !require("node:fs").existsSync(owner)) throw new Error(`coverage owner missing: ${owner}`);
  }
' "$manifest"

while IFS= read -r owner; do
  coverage_root="$(mktemp -d)"
  RELEASE_ARTIFACT_COVERAGE_CHILD=1 NODE_V8_COVERAGE="$coverage_root" node --test --experimental-test-coverage \
    --test-coverage-include="$owner" \
    --test-coverage-lines=100 \
    --test-coverage-branches=100 \
    --test-coverage-functions=100 \
    Tests/ReleaseArtifact/*.test.mjs
  node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const [directory, expected] = process.argv.slice(1);
    const expectedURL = new URL(expected, `file://${process.cwd()}/`).href;
    const present = fs.readdirSync(directory).some((filename) => JSON.parse(fs.readFileSync(path.join(directory, filename), "utf8")).result.some(({ url }) => url === expectedURL));
    if (!present) throw new Error(`coverage owner absent from V8 output: ${expected}`);
  ' "$coverage_root" "$owner"
  rm -rf "$coverage_root"
done < <(node -e 'for (const owner of JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).includes) console.log(owner)' "$manifest")
