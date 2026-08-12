enum HelpText {
    static let usage = """
        USAGE: swift-mutation-testing [<project-path>] [options]
               swift-mutation-testing init [<project-path>]

        COMMANDS:
          init                          Generate a .swift-mutation-testing.yml config file

        ARGUMENTS:
          <project-path>                Path to the Xcode project root (default: .)

        OPTIONS:
          --scheme <scheme>             Xcode scheme to build and test (Xcode projects only)
          --destination <destination>   xcodebuild destination specifier (Xcode projects only)
          --testing-framework <fw>       Testing framework: xctest or swift-testing (default: swift-testing)
          --target <test-target>        Test target name
          --timeout <seconds>           Per-mutant test timeout in seconds (default: 120 Xcode, 30 SPM)
          --concurrency <n>             Number of parallel test workers (default: CPUs - 1)
          --no-cache                    Disable the result cache
          --output <json-path>          Write mutation report JSON to path
          --html-output <html-path>     Write HTML report to path
          --sonar-output <json-path>    Write Sonar Generic Coverage report to path
          --quiet                       Suppress progress output
          --sources-path <path>         Root directory to discover Swift source files (default: project path)
          --exclude <pattern>           Exclude files matching pattern (repeatable)
          --operator <id>               Mutation operator to apply (repeatable, default: all)
          --disable-mutator <id>        Disable a specific mutation operator (repeatable)
          --build-cache-root <path>     Absolute root for prepared Xcode build state
          --cache-compatibility-id <id> 64-character lowercase hexadecimal compatibility ID
          --project-input-manifest <p>  Absolute path to the authenticated project-input manifest
          --prepare-only                Prepare the Xcode build and canonical mutant inventory, then exit
          --test-enumeration-output <p> Absolute path for prepared test enumeration JSON
          --mutant-inventory-output <p> Absolute path for the canonical mutant inventory JSON
          --mutant-selection-manifest <p>
                                        Absolute path to the target mutant-selection manifest
          --cache-evidence-output <p>   Absolute path for cache-operation evidence JSON
          --recover-only                Recover stale prepared-build state, then exit
          --custody-fd <fd>             Nonnegative wrapper-custody file descriptor
          --invocation-nonce <nonce>    22-character unpadded base64url invocation nonce
          --prepare-gate-simulator      Create the private gate-wide simulator
          --cleanup-gate-simulator      Delete the private gate-wide simulator
          --simulator-registration <p>  Absolute gate simulator registration path
          --build-count-evidence-output <p>
                                        Absolute benchmark build-count evidence path
          --guide-lock-fd <fd>          Guide lock descriptor (must be 4)
          --wrapper-lease-fd <fd>       Wrapper lease descriptor (must be 5)
          --run-ordinal <n>             Benchmark schedule ordinal
          --attempt-ordinal <0|1>       Benchmark attempt ordinal
          --version                     Print version and exit
          --help                        Print this help and exit
        """
}
