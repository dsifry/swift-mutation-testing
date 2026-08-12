#!/bin/bash
set -euo pipefail

control_root="$(cd "$(dirname "$0")/.." && pwd -P)"
manifest="$control_root/scripts/release-artifact-coverage-manifest.json"
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
  node --test --experimental-test-coverage \
    --test-coverage-include="$owner" \
    --test-coverage-lines=100 \
    --test-coverage-branches=100 \
    --test-coverage-functions=100 \
    Tests/ReleaseArtifact/*.test.mjs
done < <(node -e 'for (const owner of JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).includes) console.log(owner)' "$manifest")
