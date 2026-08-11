#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd -P)"
manifest="$repository_root/scripts/focused-coverage-manifest.json"
developer_directory="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$repository_root"
DEVELOPER_DIR="$developer_directory" xcrun swift test \
  --no-parallel \
  --enable-code-coverage \
  --filter 'PreparedBuildRecoveryTests|CacheRetentionTests|PreparedBuildStoreTests|SwiftMutationTestingExecutionPathTests|SwiftMutationTestingRunTests|WriteReportsTests|CommandLineParserTests|ConfigurationResolverTests|BuildStageTests|XcodeProcessLauncherTests'

coverage_path="$(DEVELOPER_DIR="$developer_directory" xcrun swift test --show-codecov-path)"
test -f "$coverage_path"

jq -er --arg root "$repository_root/" --slurpfile policy "$manifest" '
  def percent($summary; $metric):
    if $metric == "conditionalOutcomes" then
      if $summary.branches.count == 0 then 100 else $summary.branches.percent end
    else $summary[$metric].percent end;
  .data[0].files as $files
  | $policy[0] as $p
  | [$p.include[] as $relative | {
      relative: $relative,
      file: ([$files[] | select(.filename == ($root + $relative))] | first // null)
    }] as $included
  | [$included[] | select(.file == null) | .relative] as $missing
  | [
      $included[] | select(.file != null)
      | .relative as $relative
      | .file as $file
      | $p.thresholds | to_entries[]
      | {
          file: $relative,
          metric: .key,
          actual: percent($file.summary; .key),
          required: .value
        }
    ] as $checks
  | ($checks[] | "\(.file) \(.metric): \(.actual)% (required \(.required)%)"),
    ($missing[] | "\(.) missing from LLVM coverage output"),
    (($missing | length) == 0 and ($checks | all(.actual >= .required)))
' "$coverage_path"
