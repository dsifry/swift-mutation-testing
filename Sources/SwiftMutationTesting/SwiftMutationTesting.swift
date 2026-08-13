import Foundation
import Darwin

public struct SwiftMutationTesting {

    public static func main(args: [String] = Array(CommandLine.arguments.dropFirst())) async -> Int32 {
        if args.first == "--process-custody-identity-status" {
            let result = processIdentityStatus(arguments: Array(args.dropFirst()))
            if let output = result.1 { print(output) }
            return result.0
        }
        if args.first == "--gate-simulator-supervisor" {
            return await GateSimulatorSupervisor.run(Array(args.dropFirst()))
        }
        if args.first == "--gate-simulator-prepare-supervisor" {
            return await GateSimulatorSupervisor.runPreparing(Array(args.dropFirst()))
        }
        SandboxCleaner.installSignalHandlers()
        SandboxCleaner.removeOrphaned()
        return await run(args: args).rawValue
    }

    static func processIdentityStatus(arguments: [String]) -> (Int32, String?) {
        guard arguments.count == 3,
            let pid = Int32(arguments[0]), pid > 0,
            let pgid = Int32(arguments[1]), pgid > 0,
            arguments[2].range(
                of: #"^[0-9]{1,20}:[0-9]{1,6}$"#, options: .regularExpression) != nil
        else { return (64, nil) }
        switch SystemProcessIdentity.status(of: .init(
            pid: pid, processGroupID: pgid, birthIdentity: arguments[2])) {
        case .matching: return (0, "exact")
        case .absent: return (0, "absent")
        case .mismatched: return (0, "mismatch")
        }
    }

    static func run(args: [String], launcher: (any ProcessLaunching)? = nil) async -> ExitCode {
        do {
            let parsed = try CommandLineParser().parse(args)
            do {
                return try await execute(parsed: parsed, launcher: launcher)
            } catch {
                await cleanupBoundSimulatorAfterFailure(parsed: parsed, launcher: launcher)
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

    static func cleanupBoundSimulatorAfterFailure(
        parsed: ParsedArguments,
        launcher: (any ProcessLaunching)?,
        defaultLauncher: any ProcessLaunching = XcodeProcessLauncher()
    ) async {
        guard parsed.cache.mode == .legacyBenchmark
                || parsed.cache.mode == .prepare
                || parsed.cache.mode == .target,
            let registration = parsed.cache.simulatorRegistration,
            let descriptor = parsed.cache.guideLockFD,
            let inode = try? descriptorInode(descriptor)
        else { return }
        guard let invocationNonce = parsed.cache.invocationNonce,
            let bound = try? GateSimulatorRegistration.load(
                from: URL(fileURLWithPath: registration)),
            bound.state == .active,
            bound.activeInvocationNonce == invocationNonce,
            bound.guideLockInode == inode
        else { return }
        try? await SimulatorManager(launcher: launcher ?? defaultLauncher).cleanupGateSimulator(
            registrationURL: URL(fileURLWithPath: registration),
            expectedGateRunNonce: nil,
            expectedGuideLockInode: inode,
            expectedCacheRoot: parsed.cache.buildCacheRoot.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        )
    }

    static func execute(
        parsed: ParsedArguments,
        launcher: (any ProcessLaunching)?,
        defaultXcodeLauncher: any ProcessLaunching = XcodeProcessLauncher(),
        gateSupervisorExecutableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
        xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun")
    ) async throws -> ExitCode {
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

        if parsed.cache.mode == .simulatorPrepare || parsed.cache.mode == .simulatorCleanup {
            guard let root = parsed.cache.buildCacheRoot,
                let registrationPath = parsed.cache.simulatorRegistration,
                let nonce = parsed.cache.invocationNonce,
                let guideLockFD = parsed.cache.guideLockFD
            else { throw UsageError(message: "gate simulator protocol options are incomplete") }
            let inode = try descriptorInode(guideLockFD)
            let manager = SimulatorManager(launcher: launcher ?? defaultXcodeLauncher)
            if parsed.cache.mode == .simulatorPrepare {
                guard let destination = parsed.build.destination else {
                    throw UsageError(message: "--prepare-gate-simulator requires --destination")
                }
                if launcher == nil, defaultXcodeLauncher is XcodeProcessLauncher {
                    let custody = try GateSimulatorCustodySession.startPreparing(
                        destination: destination,
                        registrationURL: URL(fileURLWithPath: registrationPath),
                        cacheRoot: URL(fileURLWithPath: root, isDirectory: true),
                        gateRunNonce: nonce, guideLockInode: inode,
                        guideLockFD: guideLockFD,
                        executableURL: gateSupervisorExecutableURL, xcrunURL: xcrunURL)
                    try custody.acknowledgePreparation()
                } else {
                    _ = try await manager.prepareGateSimulator(
                        destination: destination,
                        cacheRoot: URL(fileURLWithPath: root, isDirectory: true),
                        registrationURL: URL(fileURLWithPath: registrationPath),
                        gateRunNonce: nonce,
                        guideLockInode: inode
                    )
                }
            } else {
                try await manager.cleanupGateSimulator(
                    registrationURL: URL(fileURLWithPath: registrationPath),
                    expectedGateRunNonce: nonce,
                    expectedGuideLockInode: inode,
                    expectedCacheRoot: URL(fileURLWithPath: root, isDirectory: true)
                )
            }
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

        var executionLauncher: any ProcessLaunching = launcher
            ?? defaultLauncher(for: configuration.build.projectType)
        var registeredSimulatorUDID: String?
        var activeSimulator: (manager: SimulatorManager, url: URL, inode: UInt64, nonce: String)?
        var simulatorCustody: GateSimulatorCustodySession?
        if let registrationPath = parsed.cache.simulatorRegistration,
            let guideLockFD = parsed.cache.guideLockFD,
            let cacheRoot = parsed.cache.buildCacheRoot,
            let invocationNonce = parsed.cache.invocationNonce
        {
            let manager = SimulatorManager(launcher: executionLauncher)
            let registrationURL = URL(fileURLWithPath: registrationPath)
            let inode = try descriptorInode(guideLockFD)
            let registration = try await manager.activateRegistration(
                at: registrationURL,
                expectedCacheRoot: URL(fileURLWithPath: cacheRoot, isDirectory: true),
                expectedGuideLockInode: inode,
                invocationNonce: invocationNonce
            )
            registeredSimulatorUDID = registration.udid
            activeSimulator = (manager, registrationURL, inode, invocationNonce)
            if let wrapperLeaseFD = parsed.cache.wrapperLeaseFD {
                simulatorCustody = try GateSimulatorCustodySession.startIfNeeded(
                    enabled: launcher == nil,
                    registrationURL: registrationURL,
                    cacheRoot: URL(fileURLWithPath: cacheRoot, isDirectory: true),
                    guideLockInode: inode, invocationNonce: invocationNonce,
                    wrapperLeaseFD: wrapperLeaseFD, guideLockFD: guideLockFD)
            }
        }
        let legacyBuildCounter: ObservedBuildCountingLauncher?
        if parsed.cache.mode == .legacyBenchmark {
            let counter = ObservedBuildCountingLauncher(base: executionLauncher)
            executionLauncher = counter
            legacyBuildCounter = counter
        } else {
            legacyBuildCounter = nil
        }

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
                launcher: executionLauncher,
                registeredSimulatorUDID: registeredSimulatorUDID
            ).prepare(input)
            try finishActiveSimulator(activeSimulator)
            try simulatorCustody?.finish()
            return .success
        }

        let start = Date()
        let results: [ExecutionResult]
        if parsed.cache.mode == .target {
            results = try await PreparedBuildCoordinator(
                configuration: configuration,
                options: parsed.cache,
                launcher: executionLauncher,
                registeredSimulatorUDID: registeredSimulatorUDID
            ).target(input)
        } else {
            results = try await MutantExecutor(
                configuration: configuration,
                launcher: executionLauncher,
                registeredSimulatorUDID: registeredSimulatorUDID
            ).execute(input)
        }
        try finishActiveSimulator(activeSimulator)
        try simulatorCustody?.finish()
        let duration = Date().timeIntervalSince(start)

        let summary = RunnerSummary(results: results, totalDuration: duration)
        TextReporter(projectRoot: configuration.projectPath).report(summary)
        writeReports(summary, configuration: configuration)

        if let legacyBuildCounter,
            let path = parsed.cache.buildCountEvidenceOutput,
            let nonce = parsed.cache.invocationNonce
        {
            try writeLegacyBuildCountEvidence(
                to: URL(fileURLWithPath: path),
                nonce: nonce,
                selector: configuration.build.testTarget,
                runOrdinal: parsed.cache.runOrdinal,
                attemptOrdinal: parsed.cache.attemptOrdinal,
                projectPath: configuration.projectPath,
                fullBuilds: legacyBuildCounter.fullBuildAttempts,
                fallbackBuilds: legacyBuildCounter.fallbackBuildAttempts,
                testWithoutBuildingRuns: legacyBuildCounter.testWithoutBuildingRuns
            )
        }

        return .success
    }

    static func descriptorInode(_ descriptor: Int) throws -> UInt64 {
        var metadata = stat()
        guard fstat(Int32(descriptor), &metadata) == 0 else {
            throw UsageError(message: "guide lock descriptor is not open")
        }
        return UInt64(metadata.st_ino)
    }

    private static func finishActiveSimulator(
        _ active: (manager: SimulatorManager, url: URL, inode: UInt64, nonce: String)?
    ) throws {
        guard let active else { return }
        try active.manager.finishRegistration(
            at: active.url, expectedGuideLockInode: active.inode,
            invocationNonce: active.nonce)
    }

    static func writeLegacyBuildCountEvidence(
        to url: URL,
        nonce: String,
        selector: String?,
        runOrdinal: Int?,
        attemptOrdinal: Int?,
        projectPath: String,
        fullBuilds: Int,
        fallbackBuilds: Int,
        testWithoutBuildingRuns: Int
    ) throws {
        try BuildCountEvidenceWriter.write(
            try BuildCountEvidenceWriter.make(
                nonce: nonce,
                projectPath: projectPath,
                projectInputManifestSHA256: nil,
                inventorySHA256: nil,
                compatibilitySHA256: nil,
                mode: "legacy_no_cache",
                selector: selector,
                runOrdinal: runOrdinal,
                attemptOrdinal: attemptOrdinal,
                counters: .init(
                    fullBuilds: fullBuilds, incrementalBuilds: 0,
                    testWithoutBuildingRuns: testWithoutBuildingRuns,
                    fallbackBuilds: fallbackBuilds)
            ),
            to: url
        )
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
