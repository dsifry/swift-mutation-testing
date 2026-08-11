import Testing

@testable import SwiftMutationTesting

@Suite("CommandLineParser")
struct CommandLineParserTests {
    private let parser = CommandLineParser()

    @Test("Given help text, when read, then every cache protocol option is documented")
    func documentsCacheProtocolOptions() {
        let options = [
            "--build-cache-root",
            "--cache-compatibility-id",
            "--project-input-manifest",
            "--prepare-only",
            "--test-enumeration-output",
            "--mutant-inventory-output",
            "--mutant-selection-manifest",
            "--cache-evidence-output",
            "--recover-only",
            "--custody-fd",
            "--invocation-nonce",
        ]

        for option in options {
            #expect(HelpText.usage.contains(option))
        }
    }

    @Test(
        "Given run command with path and required flags, when parsed, then projectPath scheme and destination are set")
    func parsesRunWithPathAndFlags() throws {
        let result = try parser.parse(["run", "/my/project", "--scheme", "MyApp", "--destination", "platform=macOS"])

        #expect(result.projectPath == "/my/project")
        #expect(result.build.scheme == "MyApp")
        #expect(result.build.destination == "platform=macOS")
        #expect(!result.showHelp)
        #expect(!result.showVersion)
    }

    @Test("Given run command without explicit path, when parsed, then projectPath defaults to dot")
    func defaultsProjectPathToDot() throws {
        let result = try parser.parse(["run", "--scheme", "App", "--destination", "platform=macOS"])

        #expect(result.projectPath == ".")
    }

    @Test("Given --help flag, when parsed, then showHelp is true")
    func returnsShowHelpForHelpFlag() throws {
        let result = try parser.parse(["--help"])

        #expect(result.showHelp)
    }

    @Test("Given -h flag, when parsed, then showHelp is true")
    func returnsShowHelpForShortFlag() throws {
        let result = try parser.parse(["-h"])

        #expect(result.showHelp)
    }

    @Test("Given empty arguments, when parsed, then execution is attempted with default project path")
    func attemptsExecutionWhenEmpty() throws {
        let result = try parser.parse([])

        #expect(!result.showHelp)
        #expect(result.projectPath == ".")
    }

    @Test("Given --version flag, when parsed, then showVersion is true")
    func returnsShowVersion() throws {
        let result = try parser.parse(["--version"])

        #expect(result.showVersion)
    }

    @Test("Given --no-cache and --quiet flags, when parsed, then noCache and quiet are true")
    func parsesBooleanFlags() throws {
        let result = try parser.parse(["run", "--scheme", "App", "--destination", "d", "--no-cache", "--quiet"])

        #expect(result.build.noCache)
        #expect(result.reporting.quiet)
    }

    @Test("Given optional string flags, when parsed, then all string values are set")
    func parsesOptionalStringFlags() throws {
        let result = try parser.parse([
            "run", "--scheme", "App", "--destination", "d",
            "--target", "AppTests",
            "--output", "out.json",
            "--html-output", "report.html",
            "--sonar-output", "sonar.json",
        ])

        #expect(result.build.testTarget == "AppTests")
        #expect(result.reporting.output == "out.json")
        #expect(result.reporting.htmlOutput == "report.html")
        #expect(result.reporting.sonarOutput == "sonar.json")
    }

    @Test("Given legacy target without cache options, when parsed, then target remains unchanged")
    func preservesLegacyTargetWithoutCacheOptions() throws {
        let result = try parser.parse(["run", "--target", "AppTests/ExampleTests/testExample"])

        #expect(result.build.testTarget == "AppTests/ExampleTests/testExample")
    }

    @Test("Given complete prepare cache options, when parsed, then prepare mode is accepted")
    func parsesPrepareCacheMode() throws {
        let result = try parser.parse([
            "run",
            "--build-cache-root", "/tmp/swift-mutation-cache",
            "--cache-compatibility-id", String(repeating: "a", count: 64),
            "--project-input-manifest", "/tmp/project-inputs.json",
            "--prepare-only",
            "--test-enumeration-output", "/tmp/tests.json",
            "--mutant-inventory-output", "/tmp/mutants.json",
            "--cache-evidence-output", "/tmp/evidence.json",
            "--custody-fd", "7",
            "--invocation-nonce", "abcdefghijklmnopqrstuv",
        ])

        #expect(result.cache.mode == .prepare)
        #expect(result.cache.buildCacheRoot == "/tmp/swift-mutation-cache")
        #expect(result.cache.compatibilityID == String(repeating: "a", count: 64))
        #expect(result.cache.projectInputManifest == "/tmp/project-inputs.json")
        #expect(result.cache.testEnumerationOutput == "/tmp/tests.json")
        #expect(result.cache.mutantInventoryOutput == "/tmp/mutants.json")
        #expect(result.cache.evidenceOutput == "/tmp/evidence.json")
        #expect(result.cache.custodyFD == 7)
        #expect(result.cache.invocationNonce == "abcdefghijklmnopqrstuv")
    }

    @Test("Given complete target cache options, when parsed, then target mode is accepted")
    func parsesTargetCacheMode() throws {
        let result = try parser.parse([
            "run",
            "--build-cache-root", "/tmp/swift-mutation-cache",
            "--cache-compatibility-id", String(repeating: "b", count: 64),
            "--project-input-manifest", "/tmp/project-inputs.json",
            "--target", "AppTests/ExampleTests/testExample",
            "--mutant-selection-manifest", "/tmp/selection.json",
            "--cache-evidence-output", "/tmp/evidence.json",
            "--output", "/tmp/report.json",
            "--custody-fd", "8",
            "--invocation-nonce", "ABCDEFGHIJKLMNOPQRSTUV",
        ])

        #expect(result.cache.mode == .target)
        #expect(result.build.testTarget == "AppTests/ExampleTests/testExample")
        #expect(result.cache.mutantSelectionManifest == "/tmp/selection.json")
    }

    @Test("Given complete recovery cache options, when parsed, then recovery mode is accepted")
    func parsesRecoveryCacheMode() throws {
        let result = try parser.parse([
            "run",
            "--build-cache-root", "/tmp/swift-mutation-cache",
            "--cache-compatibility-id", String(repeating: "c", count: 64),
            "--project-input-manifest", "/tmp/project-inputs.json",
            "--recover-only",
            "--cache-evidence-output", "/tmp/evidence.json",
            "--custody-fd", "0",
            "--invocation-nonce", "0123456789_-abcdefghij",
        ])

        #expect(result.cache.mode == .recover)
        #expect(result.cache.custodyFD == 0)
    }

    @Test("Given one cache option without a complete mode, when parsed, then throws UsageError")
    func rejectsIncompleteCacheMode() {
        #expect(throws: UsageError.self) {
            try parser.parse(["run", "--build-cache-root", "/tmp/cache"])
        }
    }

    @Test("Given prepare and target cache options together, when parsed, then throws UsageError")
    func rejectsMixedPrepareAndTargetModes() {
        #expect(throws: UsageError.self) {
            try parser.parse([
                "run",
                "--build-cache-root", "/tmp/cache",
                "--cache-compatibility-id", String(repeating: "d", count: 64),
                "--project-input-manifest", "/tmp/inputs.json",
                "--prepare-only",
                "--target", "AppTests/testExample",
                "--test-enumeration-output", "/tmp/tests.json",
                "--mutant-inventory-output", "/tmp/mutants.json",
                "--mutant-selection-manifest", "/tmp/selection.json",
                "--cache-evidence-output", "/tmp/evidence.json",
                "--output", "/tmp/report.json",
                "--custody-fd", "3",
                "--invocation-nonce", "abcdefghijklmnopqrstuv",
            ])
        }
    }

    @Test("Given malformed cache identities, when parsed, then throws UsageError")
    func rejectsMalformedCacheIdentities() {
        #expect(throws: UsageError.self) {
            try parser.parse([
                "run",
                "--build-cache-root", "/tmp/cache",
                "--cache-compatibility-id", "ABC",
                "--project-input-manifest", "/tmp/inputs.json",
                "--recover-only",
                "--cache-evidence-output", "/tmp/evidence.json",
                "--custody-fd", "-1",
                "--invocation-nonce", "short",
            ])
        }
    }

    @Test("Given --timeout and --concurrency flags, when parsed, then numeric values are set")
    func parsesNumericFlags() throws {
        let result = try parser.parse([
            "run", "--scheme", "App", "--destination", "d",
            "--timeout", "90.5",
            "--concurrency", "3",
        ])

        #expect(result.build.timeout == 90.5)
        #expect(result.build.concurrency == 3)
    }

    @Test("Given init command without path, when parsed, then showInit is true and projectPath defaults to dot")
    func parsesInitWithDefaultPath() throws {
        let result = try parser.parse(["init"])

        #expect(result.showInit)
        #expect(result.projectPath == ".")
    }

    @Test("Given init command with explicit path, when parsed, then showInit is true and projectPath is set")
    func parsesInitWithExplicitPath() throws {
        let result = try parser.parse(["init", "/my/project"])

        #expect(result.showInit)
        #expect(result.projectPath == "/my/project")
    }

    @Test("Given flags without run command, when parsed, then projectPath scheme and destination are set")
    func parsesDirectFlagsWithoutRunCommand() throws {
        let result = try parser.parse(["--scheme", "MyApp", "--destination", "platform=macOS"])

        #expect(result.projectPath == ".")
        #expect(result.build.scheme == "MyApp")
        #expect(result.build.destination == "platform=macOS")
    }

    @Test("Given project path without run command, when parsed, then projectPath is set")
    func parsesProjectPathWithoutRunCommand() throws {
        let result = try parser.parse(["/my/project", "--scheme", "App", "--destination", "platform=macOS"])

        #expect(result.projectPath == "/my/project")
        #expect(result.build.scheme == "App")
    }

    @Test("Given an unknown flag, when parsed, then throws UsageError")
    func throwsForUnknownFlag() {
        #expect(throws: UsageError.self) {
            try parser.parse(["run", "--unknown"])
        }
    }

    @Test("Given a flag without its required value, when parsed, then throws UsageError")
    func throwsWhenFlagMissingValue() {
        #expect(throws: UsageError.self) {
            try parser.parse(["run", "--scheme"])
        }
    }

    @Test("Given a non-numeric timeout value, when parsed, then throws UsageError")
    func throwsForInvalidTimeout() {
        #expect(throws: UsageError.self) {
            try parser.parse(["run", "--timeout", "abc"])
        }
    }

    @Test("Given a non-numeric concurrency value, when parsed, then throws UsageError")
    func throwsForInvalidConcurrency() {
        #expect(throws: UsageError.self) {
            try parser.parse(["run", "--concurrency", "abc"])
        }
    }

    @Test("Given --sources-path flag, when parsed, then sourcesPath is set")
    func parsesSourcesPath() throws {
        let result = try parser.parse([
            "run", "--scheme", "App", "--destination", "d", "--sources-path", "/my/sources",
        ])

        #expect(result.filter.sourcesPath == "/my/sources")
    }

    @Test("Given repeated --exclude flags, when parsed, then all patterns are collected")
    func parsesMultipleExcludePatterns() throws {
        let result = try parser.parse([
            "run", "--scheme", "App", "--destination", "d",
            "--exclude", "/Generated/",
            "--exclude", "/Pods/",
        ])

        #expect(result.filter.excludePatterns == ["/Generated/", "/Pods/"])
    }

    @Test("Given repeated --operator flags, when parsed, then all operators are collected")
    func parsesMultipleOperators() throws {
        let result = try parser.parse([
            "run", "--scheme", "App", "--destination", "d",
            "--operator", "BooleanLiteralReplacement",
            "--operator", "NegateConditional",
        ])

        #expect(result.filter.operators == ["BooleanLiteralReplacement", "NegateConditional"])
    }

    @Test("Given no --exclude or --operator flags, when parsed, then defaults are empty arrays")
    func defaultsToEmptyArraysForListFlags() throws {
        let result = try parser.parse(["run", "--scheme", "App", "--destination", "d"])

        #expect(result.filter.excludePatterns.isEmpty)
        #expect(result.filter.operators.isEmpty)
    }

    @Test("Given --testing-framework xctest, when parsed, then testingFramework is xctest")
    func parsesTestingFrameworkXCTest() throws {
        let result = try parser.parse([
            "run", "--scheme", "App", "--destination", "d",
            "--testing-framework", "xctest",
        ])

        #expect(result.build.testingFramework == "xctest")
    }

    @Test("Given --testing-framework swift-testing, when parsed, then testingFramework is swift-testing")
    func parsesTestingFrameworkSwiftTesting() throws {
        let result = try parser.parse([
            "run", "--scheme", "App", "--destination", "d",
            "--testing-framework", "swift-testing",
        ])

        #expect(result.build.testingFramework == "swift-testing")
    }

    @Test("Given no --testing-framework flag, when parsed, then testingFramework is nil")
    func testingFrameworkDefaultsToNil() throws {
        let result = try parser.parse(["run", "--scheme", "App", "--destination", "d"])

        #expect(result.build.testingFramework == nil)
    }

    @Test("Given repeated --disable-mutator flags, when parsed, then all disabled mutators are collected")
    func disabledMutatorsAreCollected() throws {
        let result = try parser.parse([
            "run",
            "--scheme", "App",
            "--destination", "d",
            "--disable-mutator", "RemoveSideEffects",
            "--disable-mutator", "SwapTernary",
        ])

        #expect(result.filter.disabledMutators == ["RemoveSideEffects", "SwapTernary"])
    }
}
