import Darwin
import Foundation

struct CommandLineParser: Sendable {
    private struct FlagValues {
        var scheme: String?
        var destination: String?
        var testTarget: String?
        var timeout: Double?
        var concurrency: Int?
        var noCache = false
        var testingFramework: String?
        var output: String?
        var htmlOutput: String?
        var sonarOutput: String?
        var quiet = false
        var sourcesPath: String?
        var excludePatterns: [String] = []
        var operators: [String] = []
        var disabledMutators: [String] = []
        var buildCacheRoot: String?
        var cacheCompatibilityID: String?
        var projectInputManifest: String?
        var prepareOnly = false
        var testEnumerationOutput: String?
        var mutantInventoryOutput: String?
        var mutantSelectionManifest: String?
        var cacheEvidenceOutput: String?
        var recoverOnly = false
        var custodyFD: Int?
        var invocationNonce: String?
        var prepareGateSimulator = false
        var cleanupGateSimulator = false
        var simulatorRegistration: String?
        var buildCountEvidenceOutput: String?
        var guideLockFD: Int?
        var wrapperLeaseFD: Int?
        var runOrdinal: Int?
        var attemptOrdinal: Int?
    }

    func parse(_ arguments: [String]) throws -> ParsedArguments {
        guard !arguments.isEmpty else {
            return ParsedArguments()
        }

        switch arguments[0] {
        case "--help", "-h":
            return ParsedArguments(showHelp: true)

        case "--version":
            return ParsedArguments(showVersion: true)

        default:
            break
        }

        var remaining = arguments
        var projectPath = "."

        if remaining[0] == "init" {
            remaining.removeFirst()
            if let next = remaining.first, !next.hasPrefix("-") {
                projectPath = next
            }

            return ParsedArguments(projectPath: projectPath, showInit: true)
        }

        if remaining[0] == "run" {
            remaining.removeFirst()
        }

        if let next = remaining.first, !next.hasPrefix("-") {
            projectPath = next
            remaining.removeFirst()
        }

        let flags = try parseFlags(remaining)
        return try parsedArguments(projectPath: projectPath, flags: flags)
    }

    private func parsedArguments(projectPath: String, flags: FlagValues) throws -> ParsedArguments {
        let cache = try validatedCacheOptions(flags)
        return ParsedArguments(
            projectPath: projectPath,
            build: .init(
                scheme: flags.scheme,
                destination: flags.destination,
                testTarget: flags.testTarget,
                timeout: flags.timeout,
                concurrency: flags.concurrency,
                noCache: flags.noCache,
                testingFramework: flags.testingFramework
            ),
            reporting: .init(
                output: flags.output,
                htmlOutput: flags.htmlOutput,
                sonarOutput: flags.sonarOutput,
                quiet: flags.quiet
            ),
            filter: .init(
                sourcesPath: flags.sourcesPath,
                excludePatterns: flags.excludePatterns,
                operators: flags.operators,
                disabledMutators: flags.disabledMutators
            ),
            cache: cache
        )
    }

    private func parseFlags(_ arguments: [String]) throws -> FlagValues {
        var values = FlagValues()
        var index = 0

        while index < arguments.count {
            try applyFlag(arguments[index], to: &values, at: &index, in: arguments)
            index += 1
        }

        return values
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func applyFlag(
        _ flag: String,
        to values: inout FlagValues,
        at index: inout Int,
        in arguments: [String]
    ) throws {
        switch flag {
        case "--scheme":
            values.scheme = try nextValue(for: flag, at: &index, in: arguments)

        case "--destination":
            values.destination = try nextValue(for: flag, at: &index, in: arguments)

        case "--target":
            values.testTarget = try nextValue(for: flag, at: &index, in: arguments)

        case "--timeout":
            values.timeout = try nextDouble(for: flag, at: &index, in: arguments)

        case "--concurrency":
            values.concurrency = try nextInt(for: flag, at: &index, in: arguments)

        case "--no-cache":
            values.noCache = true

        case "--testing-framework":
            values.testingFramework = try nextValue(for: flag, at: &index, in: arguments)

        case "--output":
            values.output = try nextValue(for: flag, at: &index, in: arguments)

        case "--html-output":
            values.htmlOutput = try nextValue(for: flag, at: &index, in: arguments)

        case "--sonar-output":
            values.sonarOutput = try nextValue(for: flag, at: &index, in: arguments)

        case "--quiet":
            values.quiet = true

        case "--sources-path":
            values.sourcesPath = try nextValue(for: flag, at: &index, in: arguments)

        case "--exclude":
            values.excludePatterns.append(try nextValue(for: flag, at: &index, in: arguments))

        case "--operator":
            values.operators.append(try nextValue(for: flag, at: &index, in: arguments))

        case "--disable-mutator":
            values.disabledMutators.append(try nextValue(for: flag, at: &index, in: arguments))

        case "--build-cache-root":
            values.buildCacheRoot = try nextValue(for: flag, at: &index, in: arguments)

        case "--cache-compatibility-id":
            values.cacheCompatibilityID = try nextValue(for: flag, at: &index, in: arguments)

        case "--project-input-manifest":
            values.projectInputManifest = try nextValue(for: flag, at: &index, in: arguments)

        case "--prepare-only":
            values.prepareOnly = true

        case "--test-enumeration-output":
            values.testEnumerationOutput = try nextValue(for: flag, at: &index, in: arguments)

        case "--mutant-inventory-output":
            values.mutantInventoryOutput = try nextValue(for: flag, at: &index, in: arguments)

        case "--mutant-selection-manifest":
            values.mutantSelectionManifest = try nextValue(for: flag, at: &index, in: arguments)

        case "--cache-evidence-output":
            values.cacheEvidenceOutput = try nextValue(for: flag, at: &index, in: arguments)

        case "--recover-only":
            values.recoverOnly = true

        case "--custody-fd":
            values.custodyFD = try nextNonnegativeInt(for: flag, at: &index, in: arguments)

        case "--invocation-nonce":
            values.invocationNonce = try nextValue(for: flag, at: &index, in: arguments)

        case "--prepare-gate-simulator":
            values.prepareGateSimulator = true

        case "--cleanup-gate-simulator":
            values.cleanupGateSimulator = true

        case "--simulator-registration":
            values.simulatorRegistration = try nextValue(for: flag, at: &index, in: arguments)

        case "--build-count-evidence-output":
            values.buildCountEvidenceOutput = try nextValue(for: flag, at: &index, in: arguments)

        case "--guide-lock-fd":
            values.guideLockFD = try nextNonnegativeInt(for: flag, at: &index, in: arguments)

        case "--wrapper-lease-fd":
            values.wrapperLeaseFD = try nextNonnegativeInt(for: flag, at: &index, in: arguments)

        case "--run-ordinal":
            values.runOrdinal = try nextNonnegativeInt(for: flag, at: &index, in: arguments)

        case "--attempt-ordinal":
            values.attemptOrdinal = try nextNonnegativeInt(for: flag, at: &index, in: arguments)

        default:
            throw UsageError(message: "unknown option '\(flag)'")
        }
    }

    private func nextValue(for flag: String, at index: inout Int, in arguments: [String]) throws -> String {
        let next = index + 1
        guard next < arguments.count else {
            throw UsageError(message: "\(flag) requires a value")
        }
        index = next
        return arguments[next]
    }

    private func nextDouble(for flag: String, at index: inout Int, in arguments: [String]) throws -> Double {
        let raw = try nextValue(for: flag, at: &index, in: arguments)
        guard let value = Double(raw), value > 0 else {
            throw UsageError(message: "\(flag) must be a positive number")
        }
        return value
    }

    private func nextInt(for flag: String, at index: inout Int, in arguments: [String]) throws -> Int {
        let raw = try nextValue(for: flag, at: &index, in: arguments)
        guard let value = Int(raw) else {
            throw UsageError(message: "\(flag) must be an integer")
        }
        return value
    }

    private func nextNonnegativeInt(for flag: String, at index: inout Int, in arguments: [String]) throws -> Int {
        let value = try nextInt(for: flag, at: &index, in: arguments)
        guard value >= 0 else {
            throw UsageError(message: "\(flag) must be a nonnegative integer")
        }
        return value
    }

    private func validatedCacheOptions(_ flags: FlagValues) throws -> ParsedArguments.CacheOptions {
        let hasCacheOption =
            flags.buildCacheRoot != nil
            || flags.cacheCompatibilityID != nil
            || flags.projectInputManifest != nil
            || flags.prepareOnly
            || flags.testEnumerationOutput != nil
            || flags.mutantInventoryOutput != nil
            || flags.mutantSelectionManifest != nil
            || flags.cacheEvidenceOutput != nil
            || flags.recoverOnly
            || flags.custodyFD != nil
            || flags.invocationNonce != nil
            || flags.prepareGateSimulator
            || flags.cleanupGateSimulator
            || flags.simulatorRegistration != nil
            || flags.buildCountEvidenceOutput != nil
            || flags.guideLockFD != nil
            || flags.wrapperLeaseFD != nil
            || flags.runOrdinal != nil
            || flags.attemptOrdinal != nil

        guard hasCacheOption else { return .init() }

        let requestedModes = [
            flags.prepareOnly, flags.mutantSelectionManifest != nil, flags.recoverOnly,
            flags.prepareGateSimulator, flags.cleanupGateSimulator,
        ]
            .filter { $0 }.count
        guard requestedModes == 1 || (requestedModes == 0 && flags.buildCountEvidenceOutput != nil) else {
            throw UsageError(message: "protocol options must select exactly one operation mode")
        }

        if flags.prepareGateSimulator || flags.cleanupGateSimulator {
            return try validatedSimulatorOptions(flags)
        }

        if requestedModes == 0, flags.buildCountEvidenceOutput != nil {
            return try validatedLegacyBenchmarkOptions(flags)
        }

        let hasGateSimulatorBinding =
            flags.simulatorRegistration != nil || flags.guideLockFD != nil || flags.wrapperLeaseFD != nil
        guard !hasGateSimulatorBinding
            || (flags.simulatorRegistration != nil && flags.guideLockFD == 4 && flags.wrapperLeaseFD == 5)
        else { throw UsageError(message: "prepared simulator binding requires registration, fd 4, and fd 5") }
        guard flags.buildCountEvidenceOutput == nil || hasGateSimulatorBinding else {
            throw UsageError(message: "prepared build-count evidence requires gate simulator binding")
        }

        guard let root = flags.buildCacheRoot,
            let compatibilityID = flags.cacheCompatibilityID,
            let projectManifest = flags.projectInputManifest,
            let evidenceOutput = flags.cacheEvidenceOutput,
            let custodyFD = flags.custodyFD,
            let invocationNonce = flags.invocationNonce
        else {
            throw UsageError(
                message:
                    "cache mode requires root, compatibility ID, project manifest, evidence output, custody fd, and invocation nonce"
            )
        }

        try validateAbsolutePath(root, flag: "--build-cache-root")
        try validateAbsolutePath(projectManifest, flag: "--project-input-manifest")
        try validateAbsolutePath(evidenceOutput, flag: "--cache-evidence-output")
        if let simulatorRegistration = flags.simulatorRegistration {
            try validateAbsolutePath(simulatorRegistration, flag: "--simulator-registration")
        }
        if let buildCountEvidenceOutput = flags.buildCountEvidenceOutput {
            try validateAbsolutePath(buildCountEvidenceOutput, flag: "--build-count-evidence-output")
        }
        try validateCompatibilityID(compatibilityID)
        try validateInvocationNonce(invocationNonce)

        let mode: ParsedArguments.CacheOptions.Mode
        if flags.prepareOnly {
            guard flags.testTarget == nil,
                flags.mutantSelectionManifest == nil,
                flags.output == nil,
                let enumerationOutput = flags.testEnumerationOutput,
                let inventoryOutput = flags.mutantInventoryOutput
            else {
                throw UsageError(
                    message: "prepare mode requires enumeration and inventory outputs and rejects target-only options")
            }
            try validateAbsolutePath(enumerationOutput, flag: "--test-enumeration-output")
            try validateAbsolutePath(inventoryOutput, flag: "--mutant-inventory-output")
            mode = .prepare
        } else if flags.recoverOnly {
            guard flags.testTarget == nil,
                flags.mutantSelectionManifest == nil,
                flags.testEnumerationOutput == nil,
                flags.mutantInventoryOutput == nil,
                flags.output == nil
            else {
                throw UsageError(message: "recover mode rejects prepare and target outputs")
            }
            mode = .recover
        } else {
            guard let target = flags.testTarget, !target.isEmpty,
                let selectionManifest = flags.mutantSelectionManifest,
                let output = flags.output,
                flags.noCache,
                flags.testEnumerationOutput == nil,
                flags.mutantInventoryOutput == nil
            else {
                throw UsageError(
                    message: "target cache mode requires one target, selection manifest, JSON output, and --no-cache"
                )
            }
            try validateAbsolutePath(selectionManifest, flag: "--mutant-selection-manifest")
            try validateAbsolutePath(output, flag: "--output")
            mode = .target
        }

        try validateDistinctPaths([
            ("--project-input-manifest", projectManifest),
            ("--cache-evidence-output", evidenceOutput),
            ("--test-enumeration-output", flags.testEnumerationOutput),
            ("--mutant-inventory-output", flags.mutantInventoryOutput),
            ("--mutant-selection-manifest", flags.mutantSelectionManifest),
            ("--output", flags.output),
            ("--simulator-registration", flags.simulatorRegistration),
            ("--build-count-evidence-output", flags.buildCountEvidenceOutput),
        ])

        return .init(
            mode: mode,
            buildCacheRoot: root,
            compatibilityID: compatibilityID,
            projectInputManifest: projectManifest,
            testEnumerationOutput: flags.testEnumerationOutput,
            mutantInventoryOutput: flags.mutantInventoryOutput,
            mutantSelectionManifest: flags.mutantSelectionManifest,
            evidenceOutput: evidenceOutput,
            custodyFD: custodyFD,
            invocationNonce: invocationNonce,
            simulatorRegistration: flags.simulatorRegistration,
            buildCountEvidenceOutput: flags.buildCountEvidenceOutput,
            guideLockFD: flags.guideLockFD,
            wrapperLeaseFD: flags.wrapperLeaseFD
        )
    }

    private func validatedSimulatorOptions(_ flags: FlagValues) throws -> ParsedArguments.CacheOptions {
        guard let root = flags.buildCacheRoot,
            let registration = flags.simulatorRegistration,
            let nonce = flags.invocationNonce,
            let guideLockFD = flags.guideLockFD, guideLockFD == 4,
            flags.wrapperLeaseFD == nil,
            flags.cacheCompatibilityID == nil,
            flags.projectInputManifest == nil,
            flags.testEnumerationOutput == nil,
            flags.mutantInventoryOutput == nil,
            flags.mutantSelectionManifest == nil,
            flags.cacheEvidenceOutput == nil,
            flags.buildCountEvidenceOutput == nil,
            flags.runOrdinal == nil,
            flags.attemptOrdinal == nil,
            flags.noCache == false,
            flags.custodyFD == nil,
            flags.testTarget == nil,
            flags.output == nil
        else { throw UsageError(message: "gate simulator mode has invalid or missing protocol options") }
        try validateAbsolutePath(root, flag: "--build-cache-root")
        try validateAbsolutePath(registration, flag: "--simulator-registration")
        try validateInvocationNonce(nonce)
        return .init(
            mode: flags.prepareGateSimulator ? .simulatorPrepare : .simulatorCleanup,
            buildCacheRoot: root,
            invocationNonce: nonce,
            simulatorRegistration: registration,
            guideLockFD: guideLockFD
        )
    }

    private func validatedLegacyBenchmarkOptions(_ flags: FlagValues) throws -> ParsedArguments.CacheOptions {
        guard flags.noCache,
            let root = flags.buildCacheRoot,
            let registration = flags.simulatorRegistration,
            let evidence = flags.buildCountEvidenceOutput,
            let output = flags.output,
            let nonce = flags.invocationNonce,
            let guideLockFD = flags.guideLockFD, guideLockFD == 4,
            let wrapperLeaseFD = flags.wrapperLeaseFD, wrapperLeaseFD == 5,
            let runOrdinal = flags.runOrdinal,
            let attemptOrdinal = flags.attemptOrdinal, attemptOrdinal == 0 || attemptOrdinal == 1,
            flags.cacheCompatibilityID == nil,
            flags.projectInputManifest == nil,
            flags.prepareOnly == false,
            flags.recoverOnly == false,
            flags.custodyFD == nil,
            flags.testTarget != nil,
            flags.testEnumerationOutput == nil,
            flags.mutantInventoryOutput == nil,
            flags.cacheEvidenceOutput == nil
        else { throw UsageError(message: "legacy build-count mode has invalid or missing protocol options") }
        try validateAbsolutePath(root, flag: "--build-cache-root")
        try validateAbsolutePath(registration, flag: "--simulator-registration")
        try validateAbsolutePath(evidence, flag: "--build-count-evidence-output")
        try validateAbsolutePath(output, flag: "--output")
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        let safeOutputURL = outputURL.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(outputURL.lastPathComponent)
        guard safeOutputURL.path.hasPrefix(rootURL.path + "/") else {
            throw UsageError(message: "--output must be beneath --build-cache-root")
        }
        try validateDistinctPaths([
            ("--build-count-evidence-output", evidence),
            ("--output", output),
        ])
        try validateInvocationNonce(nonce)
        return .init(
            mode: .legacyBenchmark,
            buildCacheRoot: root,
            invocationNonce: nonce,
            simulatorRegistration: registration,
            buildCountEvidenceOutput: evidence,
            guideLockFD: guideLockFD,
            wrapperLeaseFD: wrapperLeaseFD
            , runOrdinal: runOrdinal,
            attemptOrdinal: attemptOrdinal
        )
    }

    private func validateAbsolutePath(_ path: String, flag: String) throws {
        guard path.hasPrefix("/") else {
            throw UsageError(message: "\(flag) requires an absolute path")
        }
    }

    private func validateDistinctPaths(_ paths: [(flag: String, path: String?)]) throws {
        var seen: [String: String] = [:]
        for (flag, path) in paths {
            guard let path else { continue }
            let normalized = try protocolPathIdentity(path)
            if let previous = seen[normalized] {
                throw UsageError(message: "\(flag) must not match \(previous)")
            }
            seen[normalized] = flag
        }
    }

    private func protocolPathIdentity(_ path: String) throws -> String {
        var metadata = stat()
        if stat(path, &metadata) == 0 {
            return "inode:\(metadata.st_dev):\(metadata.st_ino)"
        }
        var leafMetadata = stat()
        if lstat(path, &leafMetadata) == 0, leafMetadata.st_mode & S_IFMT == S_IFLNK {
            throw UsageError(message: "cache protocol paths must not be dangling symbolic links")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let canonicalParent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return "path:" + canonicalParent.appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
    }

    private func validateCompatibilityID(_ value: String) throws {
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        guard value.utf8.count == 64, value.unicodeScalars.allSatisfy(lowercaseHex.contains) else {
            throw UsageError(message: "--cache-compatibility-id must be 64 lowercase hexadecimal characters")
        }
    }

    private func validateInvocationNonce(_ value: String) throws {
        let base64URL = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        guard value.utf8.count == 22, value.unicodeScalars.allSatisfy(base64URL.contains) else {
            throw UsageError(message: "--invocation-nonce must be 22 unpadded base64url characters")
        }
    }

}
