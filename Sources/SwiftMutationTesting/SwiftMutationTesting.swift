import Foundation

public struct SwiftMutationTesting {

    public static func main(args: [String] = Array(CommandLine.arguments.dropFirst())) async -> Int32 {
        SandboxCleaner.installSignalHandlers()
        SandboxCleaner.removeOrphaned()
        return await run(args: args).rawValue
    }

    static func run(args: [String], launcher: (any ProcessLaunching)? = nil) async -> ExitCode {
        do {
            let parsed = try CommandLineParser().parse(args)
            do {
                return try await execute(parsed: parsed, launcher: launcher)
            } catch {
                if parsed.cache.mode != .legacy {
                    try? CacheFailureEvidenceRecorder.record(options: parsed.cache)
                }
                throw error
            }
        } catch let error as UsageError {
            fputs(error.message + "\n", stderr)
            return .error
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return .error
        }
    }

    private static func execute(parsed: ParsedArguments, launcher: (any ProcessLaunching)?) async throws -> ExitCode {
        if parsed.showHelp {
            print(HelpText.usage)
            return .success
        }

        if parsed.showVersion {
            print(Version.current)
            return .success
        }

        if parsed.showInit {
            let initLauncher = launcher ?? XcodeProcessLauncher()
            let detected = await ProjectDetector(launcher: initLauncher).detect(at: parsed.projectPath)
            try ConfigurationFileWriter().write(to: parsed.projectPath, project: detected)
            return .success
        }

        if parsed.cache.mode == .recover {
            try PreparedBuildCoordinator.recover(options: parsed.cache, enableCustody: launcher == nil)
            return .success
        }

        let fileValues = try ConfigurationFileParser().parse(at: parsed.projectPath)
        let configuration = try ConfigurationResolver().resolve(
            cliArguments: parsed,
            fileValues: fileValues
        )

        let executionLauncher: any ProcessLaunching = launcher
            ?? defaultLauncher(for: configuration.build.projectType)

        let (input, discoveryDuration) = try await discover(configuration: configuration)

        if !configuration.reporting.quiet {
            let schematizable = input.mutants.filter { $0.isSchematizable }.count
            let incompatible = input.mutants.count - schematizable
            await ConsoleProgressReporter().report(
                .discoveryFinished(
                    mutantCount: input.mutants.count,
                    schematizableCount: schematizable,
                    incompatibleCount: incompatible,
                    duration: discoveryDuration
                ))
        }

        if parsed.cache.mode == .prepare {
            try await PreparedBuildCoordinator(
                configuration: configuration,
                options: parsed.cache,
                launcher: executionLauncher
            ).prepare(input)
            return .success
        }

        let start = Date()
        let results: [ExecutionResult]
        if parsed.cache.mode == .target {
            results = try await PreparedBuildCoordinator(
                configuration: configuration,
                options: parsed.cache,
                launcher: executionLauncher
            ).target(input)
        } else {
            results = try await MutantExecutor(configuration: configuration, launcher: executionLauncher).execute(input)
        }
        let duration = Date().timeIntervalSince(start)

        let summary = RunnerSummary(results: results, totalDuration: duration)
        TextReporter(projectRoot: configuration.projectPath).report(summary)
        writeReports(summary, configuration: configuration)

        return .success
    }


    private static func discover(configuration: RunnerConfiguration) async throws -> (RunnerInput, TimeInterval) {
        let start = Date()
        let discoveryInput = DiscoveryInput(
            projectPath: configuration.projectPath,
            projectType: configuration.build.projectType,
            timeout: configuration.build.timeout,
            concurrency: configuration.build.concurrency,
            noCache: configuration.build.noCache,
            sourcesPath: configuration.filter.sourcesPath ?? configuration.projectPath,
            excludePatterns: configuration.filter.excludePatterns,
            operators: configuration.filter.operators
        )
        let input = try await DiscoveryPipeline().run(input: discoveryInput)
        return (input, Date().timeIntervalSince(start))
    }

    static func writeReports(_ summary: RunnerSummary, configuration: RunnerConfiguration) {
        let hasReports =
            configuration.reporting.output != nil
            || configuration.reporting.htmlOutput != nil
            || configuration.reporting.sonarOutput != nil
        guard hasReports else { return }
        print("")

        if let output = configuration.reporting.output {
            writeReport(label: "JSON", to: output) {
                try JsonReporter(outputPath: output, projectRoot: configuration.projectPath).report(summary)
            }
        }

        if let htmlOutput = configuration.reporting.htmlOutput {
            writeReport(label: "HTML", to: htmlOutput) {
                try HtmlReporter(outputPath: htmlOutput, projectRoot: configuration.projectPath).report(summary)
            }
        }

        if let sonarOutput = configuration.reporting.sonarOutput {
            writeReport(label: "Sonar", to: sonarOutput) {
                try SonarReporter(outputPath: sonarOutput, projectRoot: configuration.projectPath).report(summary)
            }
        }
    }

    static func defaultLauncher(for projectType: ProjectType) -> any ProcessLaunching {
        switch projectType {
        case .xcode: XcodeProcessLauncher()
        case .spm: SPMProcessLauncher()
        }
    }

    private static func writeReport(label: String, to path: String, _ write: () throws -> Void) {
        do {
            try write()
            print("  ✓ \(label) report: \(path)")
        } catch {
            fputs("Warning: could not write \(label) report to '\(path)': \(error.localizedDescription)\n", stderr)
        }
    }
}
