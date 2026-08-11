import CryptoKit
import Darwin
import Foundation

struct CacheEvidenceCodingKey: CodingKey, Equatable {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

struct CacheEvidence: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let invocationNonce: String
    let operation: String
    let outcome: String
    let compatibilitySHA256: String
    let projectInputManifestSHA256: String
    let preparedInventorySHA256: String?
    let runOrdinal: Int?
    let attemptOrdinal: Int?
    let productManifestSHA256: String?
    let fullBuilds: Int
    let incrementalBuilds: Int
    let fallbackBuilds: Int
    let sourceBearingBytesScrubbed: Bool
    let childGroupsQuiescent: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, invocationNonce, operation, outcome, compatibilitySHA256
        case projectInputManifestSHA256, preparedInventorySHA256, runOrdinal, attemptOrdinal
        case productManifestSHA256, fullBuilds, incrementalBuilds, fallbackBuilds
        case sourceBearingBytesScrubbed, childGroupsQuiescent
    }

    init(
        schemaVersion: Int,
        invocationNonce: String,
        operation: String,
        outcome: String,
        compatibilitySHA256: String,
        projectInputManifestSHA256: String,
        preparedInventorySHA256: String?,
        runOrdinal: Int?,
        attemptOrdinal: Int?,
        productManifestSHA256: String?,
        fullBuilds: Int,
        incrementalBuilds: Int,
        fallbackBuilds: Int,
        sourceBearingBytesScrubbed: Bool,
        childGroupsQuiescent: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.invocationNonce = invocationNonce
        self.operation = operation
        self.outcome = outcome
        self.compatibilitySHA256 = compatibilitySHA256
        self.projectInputManifestSHA256 = projectInputManifestSHA256
        self.preparedInventorySHA256 = preparedInventorySHA256
        self.runOrdinal = runOrdinal
        self.attemptOrdinal = attemptOrdinal
        self.productManifestSHA256 = productManifestSHA256
        self.fullBuilds = fullBuilds
        self.incrementalBuilds = incrementalBuilds
        self.fallbackBuilds = fallbackBuilds
        self.sourceBearingBytesScrubbed = sourceBearingBytesScrubbed
        self.childGroupsQuiescent = childGroupsQuiescent
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: CacheEvidenceCodingKey.self)
        let expected = Set(CodingKeys.allCases.map(\.rawValue))
        guard Set(dynamic.allKeys.map(\.stringValue)) == expected else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Cache evidence keys are invalid"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        invocationNonce = try container.decode(String.self, forKey: .invocationNonce)
        operation = try container.decode(String.self, forKey: .operation)
        outcome = try container.decode(String.self, forKey: .outcome)
        compatibilitySHA256 = try container.decode(String.self, forKey: .compatibilitySHA256)
        projectInputManifestSHA256 = try container.decode(String.self, forKey: .projectInputManifestSHA256)
        preparedInventorySHA256 =
            try container.decodeNil(forKey: .preparedInventorySHA256)
            ? nil : container.decode(String.self, forKey: .preparedInventorySHA256)
        runOrdinal =
            try container.decodeNil(forKey: .runOrdinal)
            ? nil : container.decode(Int.self, forKey: .runOrdinal)
        attemptOrdinal =
            try container.decodeNil(forKey: .attemptOrdinal)
            ? nil : container.decode(Int.self, forKey: .attemptOrdinal)
        productManifestSHA256 =
            try container.decodeNil(forKey: .productManifestSHA256)
            ? nil : container.decode(String.self, forKey: .productManifestSHA256)
        fullBuilds = try container.decode(Int.self, forKey: .fullBuilds)
        incrementalBuilds = try container.decode(Int.self, forKey: .incrementalBuilds)
        fallbackBuilds = try container.decode(Int.self, forKey: .fallbackBuilds)
        sourceBearingBytesScrubbed = try container.decode(Bool.self, forKey: .sourceBearingBytesScrubbed)
        childGroupsQuiescent = try container.decode(Bool.self, forKey: .childGroupsQuiescent)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(invocationNonce, forKey: .invocationNonce)
        try container.encode(operation, forKey: .operation)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(compatibilitySHA256, forKey: .compatibilitySHA256)
        try container.encode(projectInputManifestSHA256, forKey: .projectInputManifestSHA256)
        if let preparedInventorySHA256 {
            try container.encode(preparedInventorySHA256, forKey: .preparedInventorySHA256)
        } else {
            try container.encodeNil(forKey: .preparedInventorySHA256)
        }
        if let runOrdinal {
            try container.encode(runOrdinal, forKey: .runOrdinal)
        } else {
            try container.encodeNil(forKey: .runOrdinal)
        }
        if let attemptOrdinal {
            try container.encode(attemptOrdinal, forKey: .attemptOrdinal)
        } else {
            try container.encodeNil(forKey: .attemptOrdinal)
        }
        if let productManifestSHA256 {
            try container.encode(productManifestSHA256, forKey: .productManifestSHA256)
        } else {
            try container.encodeNil(forKey: .productManifestSHA256)
        }
        try container.encode(fullBuilds, forKey: .fullBuilds)
        try container.encode(incrementalBuilds, forKey: .incrementalBuilds)
        try container.encode(fallbackBuilds, forKey: .fallbackBuilds)
        try container.encode(sourceBearingBytesScrubbed, forKey: .sourceBearingBytesScrubbed)
        try container.encode(childGroupsQuiescent, forKey: .childGroupsQuiescent)
    }
}

enum CacheEvidenceWriter {
    static func write(
        _ evidence: CacheEvidence,
        to url: URL,
        openFile: (String) -> Int32 = { open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600) },
        writeBytes: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) },
        syncFile: (Int32) -> Int32 = { fsync($0) },
        closeFile: (Int32) -> Int32 = { close($0) },
        renameExclusive: (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_EXCL)) },
        openDirectory: (String) -> Int32 = { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) },
        syncDirectory: (Int32) -> Int32 = { fsync($0) }
    ) throws {
        let parent = url.deletingLastPathComponent()
        try CachePathGuard.validateDirectory(parent, containedIn: parent)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw PreparedCacheError.invalidCacheState
        }
        let temporary = parent.appendingPathComponent(".cache-evidence.\(UUID().uuidString)")
        let descriptor = openFile(temporary.path)
        guard descriptor >= 0 else { throw PreparedCacheError.invalidCacheState }
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { _ = closeFile(descriptor) }
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(evidence)
            data.append(0x0A)
            try data.withUnsafeBytes { rawBuffer in
                var base = rawBuffer.baseAddress!
                var remaining = rawBuffer.count
                while remaining > 0 {
                    let count = writeBytes(descriptor, base, remaining)
                    guard count > 0 else { throw PreparedCacheError.invalidCacheState }
                    remaining -= count
                    base = base.advanced(by: count)
                }
            }
            guard syncFile(descriptor) == 0 else {
                throw PreparedCacheError.invalidCacheState
            }
            let closeResult = closeFile(descriptor)
            descriptorIsOpen = false
            guard closeResult == 0 else { throw PreparedCacheError.invalidCacheState }
            guard renameExclusive(temporary.path, url.path) == 0 else {
                throw PreparedCacheError.invalidCacheState
            }
            let parentDescriptor = openDirectory(parent.path)
            guard parentDescriptor >= 0 else { throw PreparedCacheError.invalidCacheState }
            defer { _ = closeFile(parentDescriptor) }
            guard syncDirectory(parentDescriptor) == 0 else { throw PreparedCacheError.invalidCacheState }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }
}

enum CacheFailureEvidenceRecorder {
    static func record(options: ParsedArguments.CacheOptions) throws {
        guard let output = options.evidenceOutput,
            let root = options.buildCacheRoot,
            let compatibilityID = options.compatibilityID,
            let manifestPath = options.projectInputManifest,
            let nonce = options.invocationNonce
        else { return }
        let outputURL = URL(fileURLWithPath: output)
        guard !FileManager.default.fileExists(atPath: outputURL.path) else { return }
        let store = PreparedBuildStore(root: root, compatibilityID: compatibilityID)
        let state = try? store.load()
        let cleanup = cleanup(store: store, collectionRoot: URL(fileURLWithPath: root, isDirectory: true))
        let manifestDigest =
            (try? Data(contentsOf: URL(fileURLWithPath: manifestPath)))
            .map(ProjectInputManifest.sha256) ?? String(repeating: "0", count: 64)
        let selection = options.mutantSelectionManifest.flatMap { try? MutantSelectionManifest.load(from: $0) }
        let operation: String
        switch options.mode {
        case .prepare: operation = "prepare"
        case .target: operation = "target"
        case .recover: operation = "recover"
        case .legacy: return
        }
        try CacheEvidenceWriter.write(
            CacheEvidence(
                schemaVersion: 1,
                invocationNonce: nonce,
                operation: operation,
                outcome: "failed",
                compatibilitySHA256: compatibilityID,
                projectInputManifestSHA256: manifestDigest,
                preparedInventorySHA256: try state?.inventory.sha256,
                runOrdinal: selection?.runOrdinal,
                attemptOrdinal: selection?.attemptOrdinal,
                productManifestSHA256: state?.productManifestSHA256,
                fullBuilds: 0,
                incrementalBuilds: 0,
                fallbackBuilds: 0,
                sourceBearingBytesScrubbed: cleanup.scrubbed,
                childGroupsQuiescent: cleanup.quiescent
            ), to: outputURL)
    }

    private static func cleanup(store: PreparedBuildStore, collectionRoot: URL) -> (scrubbed: Bool, quiescent: Bool) {
        guard FileManager.default.fileExists(atPath: store.directory.path) else { return (true, true) }
        guard let lock = try? CacheLock(identityDirectory: store.directory) else { return (false, false) }
        defer { try? lock.release() }
        var quiescent = true
        let registry = store.directory.appendingPathComponent("process-custody.json")
        if FileManager.default.fileExists(atPath: registry.path) {
            do {
                let custody = try ProcessCustody.system(registrationURL: registry)
                try custody.handleEngineTermination()
                quiescent = custody.isQuiescent
            } catch {
                quiescent = false
            }
        }
        let scrubbed =
            (try? CacheRecovery(
                identityDirectory: store.directory,
                collectionRoot: collectionRoot
            ).scrubAfterCommand()) != nil
        return (scrubbed, quiescent)
    }
}

struct PreparedBuildCoordinator: Sendable {
    let configuration: RunnerConfiguration
    let options: ParsedArguments.CacheOptions
    let launcher: any ProcessLaunching

    func prepare(_ input: RunnerInput) async throws {
        guard case .xcode(let scheme, let destination) = configuration.build.projectType,
            let root = options.buildCacheRoot,
            let compatibilityID = options.compatibilityID,
            let manifestPath = options.projectInputManifest,
            let inventoryOutput = options.mutantInventoryOutput,
            let enumerationOutput = options.testEnumerationOutput
        else { throw UsageError(message: "prepared builds currently require an Xcode project") }

        let manifestHash = try sha256(at: manifestPath)
        let inventory = try PreparedMutantInventory(
            projectRoot: configuration.projectPath,
            projectInputManifestSHA256: manifestHash,
            mutants: input.mutants
        )
        let inventoryHash = try inventory.sha256
        let store = PreparedBuildStore(root: root, compatibilityID: compatibilityID)
        try store.prepareDirectory()
        let lock = try CacheLock(identityDirectory: store.directory)
        defer { try? lock.release() }
        let custodyRuntime = try makeCustodyRuntime(store: store)
        defer { custodyRuntime?.monitor.cancel() }
        let observedLauncher = ObservedBuildCountingLauncher(
            base: commandLauncher(custodyRuntime: custodyRuntime)
        )
        let commandLauncher: any ProcessLaunching = observedLauncher
        let recovery = CacheRecovery(
            identityDirectory: store.directory,
            collectionRoot: URL(fileURLWithPath: root, isDirectory: true)
        )
        var previousProduct = try? store.load().productManifestSHA256
        if let currentProduct = previousProduct {
            do {
                _ = try recovery.recover(expectedProductManifestSHA256: currentProduct)
            } catch PreparedCacheError.productManifestMismatch {
                try recovery.invalidateDivergentPreparedBuild()
                previousProduct = nil
            }
        }
        try recovery.writeRetentionMetadata(lastUsedAt: Date())
        _ = try CacheRetention(collectionRoot: URL(fileURLWithPath: root, isDirectory: true)).enforce()
        try recovery.markDirty(previousReadyProductManifestSHA256: previousProduct)
        var evidenceWritten = false
        defer {
            let scrubbed = (try? recovery.scrubAfterCommand()) != nil
            let quiescent = Self.custodyIsQuiescent(custodyRuntime)
            if !evidenceWritten {
                try? writeEvidence(
                    CacheEvidence(
                        schemaVersion: 1,
                        invocationNonce: options.invocationNonce ?? "",
                        operation: "prepare",
                        outcome: "failed",
                        compatibilitySHA256: compatibilityID,
                        projectInputManifestSHA256: manifestHash,
                        preparedInventorySHA256: inventoryHash,
                        runOrdinal: nil,
                        attemptOrdinal: nil,
                        productManifestSHA256: previousProduct,
                        fullBuilds: observedLauncher.buildForTestingAttempts,
                        incrementalBuilds: 0,
                        fallbackBuilds: 0,
                        sourceBearingBytesScrubbed: scrubbed,
                        childGroupsQuiescent: quiescent
                    ))
            }
        }

        do {
            let sourceRoot = try Self.canonicalSourceRoot(configuration.projectPath)
            let projectURL = try ProjectInputMaterializer(
                sourceRoot: sourceRoot,
                identityDirectory: store.directory,
                collectionRoot: URL(fileURLWithPath: root, isDirectory: true)
            ).materialize(
                manifestAt: URL(fileURLWithPath: manifestPath),
                schematizedFiles: input.schematizedFiles,
                supportFileContent: input.supportFileContent
            )
            let sandbox = Sandbox(rootURL: projectURL)
            let artifact = try await BuildStage(launcher: commandLauncher).build(
                sandbox: sandbox,
                scheme: scheme,
                destination: destination,
                timeout: configuration.build.timeout,
                derivedDataURL: store.derivedDataURL
            )
            let xctestrunURL = try Self.requireXCTestRun(from: artifact)
            try await PreparedTestEnumerator(launcher: commandLauncher).enumerate(
                xctestrunURL: xctestrunURL,
                destination: destination,
                timeout: configuration.build.timeout,
                outputURL: URL(fileURLWithPath: enumerationOutput)
            )
            let productManifestSHA256 = try RetainedProductManifest.sha256(derivedDataURL: store.derivedDataURL)
            try store.save(
                PreparedBuildState(
                    sandboxPath: sandbox.rootURL.path,
                    derivedDataPath: artifact.derivedDataPath,
                    xctestrunPath: xctestrunURL.path,
                    productManifestSHA256: productManifestSHA256,
                    inventory: inventory
                )
            )
            try writeJSON(inventory, to: inventoryOutput)
            try recovery.markReady(productManifestSHA256: productManifestSHA256)
            try recovery.writeRetentionMetadata(lastUsedAt: Date())
            try custodyRuntime?.monitor.checkFailure()
            try Self.requireCustodyQuiescence(custodyRuntime)
            try writeEvidence(
                CacheEvidence(
                    schemaVersion: 1,
                    invocationNonce: options.invocationNonce ?? "",
                    operation: "prepare",
                    outcome: "ready",
                    compatibilitySHA256: compatibilityID,
                    projectInputManifestSHA256: manifestHash,
                    preparedInventorySHA256: inventoryHash,
                    runOrdinal: nil,
                    attemptOrdinal: nil,
                    productManifestSHA256: productManifestSHA256,
                    fullBuilds: observedLauncher.buildForTestingAttempts,
                    incrementalBuilds: 0,
                    fallbackBuilds: 0,
                    sourceBearingBytesScrubbed: true,
                    childGroupsQuiescent: Self.custodyIsQuiescent(custodyRuntime)
                )
            )
            evidenceWritten = true
        } catch {
            throw error
        }
    }

    static func requireXCTestRun(from artifact: BuildArtifact) throws -> URL {
        guard let xctestrunURL = artifact.xctestrunURL else {
            throw PreparedBuildError.preparedBuildMissing
        }
        return xctestrunURL
    }

    func target(_ input: RunnerInput) async throws -> [ExecutionResult] {
        guard case .xcode = configuration.build.projectType,
            let root = options.buildCacheRoot,
            let compatibilityID = options.compatibilityID,
            let manifestPath = options.projectInputManifest,
            let selectionPath = options.mutantSelectionManifest,
            let selector = configuration.build.testTarget
        else { throw UsageError(message: "prepared targets currently require an Xcode project and selector") }

        let store = PreparedBuildStore(root: root, compatibilityID: compatibilityID)
        let lock = try CacheLock(identityDirectory: store.directory)
        defer { try? lock.release() }
        let custodyRuntime = try makeCustodyRuntime(store: store)
        defer { custodyRuntime?.monitor.cancel() }
        let observedLauncher = ObservedBuildCountingLauncher(
            base: commandLauncher(custodyRuntime: custodyRuntime), countAsFallback: true
        )
        let commandLauncher: any ProcessLaunching = observedLauncher
        let state = try store.load()
        let recovery = CacheRecovery(
            identityDirectory: store.directory,
            collectionRoot: URL(fileURLWithPath: root, isDirectory: true)
        )
        guard try recovery.recover(expectedProductManifestSHA256: state.productManifestSHA256) == .ready,
            try RetainedProductManifest.sha256(derivedDataURL: store.derivedDataURL) == state.productManifestSHA256
        else { throw PreparedCacheError.productManifestMismatch }
        let currentManifestHash = try sha256(at: manifestPath)
        guard currentManifestHash == state.inventory.projectInputManifestSHA256 else {
            throw PreparedBuildError.inventoryMismatch
        }
        try state.inventory.validate(mutants: input.mutants, projectRoot: configuration.projectPath)
        let inventoryHash = try state.inventory.sha256
        let selection = try MutantSelectionManifest.load(from: selectionPath)
        guard selection.projectInputManifestSHA256 == currentManifestHash else {
            throw PreparedBuildError.selectionMismatch
        }
        let paths = try selection.validatedSourcePaths(
            selector: selector,
            inventorySHA256: inventoryHash,
            inventorySourcePaths: state.inventory.mutants.map(\.sourcePath)
        )
        let selected = state.inventory.selectValidated(
            mutants: input.mutants,
            ownedSourcePaths: paths
        )
        var evidenceWritten = false
        defer {
            let scrubbed = (try? recovery.scrubAfterCommand()) != nil
            let quiescent = Self.custodyIsQuiescent(custodyRuntime)
            if !evidenceWritten {
                try? writeEvidence(
                    CacheEvidence(
                        schemaVersion: 1,
                        invocationNonce: options.invocationNonce ?? "",
                        operation: "target",
                        outcome: "failed",
                        compatibilitySHA256: compatibilityID,
                        projectInputManifestSHA256: currentManifestHash,
                        preparedInventorySHA256: inventoryHash,
                        runOrdinal: selection.runOrdinal,
                        attemptOrdinal: selection.attemptOrdinal,
                        productManifestSHA256: state.productManifestSHA256,
                        fullBuilds: 0,
                        incrementalBuilds: 0,
                        fallbackBuilds: observedLauncher.fallbackBuildAttempts,
                        sourceBearingBytesScrubbed: scrubbed,
                        childGroupsQuiescent: quiescent
                    ))
            }
        }
        if selected.isEmpty {
            try recovery.writeRetentionMetadata(lastUsedAt: Date())
            try Self.requireCustodyQuiescence(custodyRuntime)
            try writeEvidence(
                targetEvidence(
                    compatibilityID: compatibilityID,
                    manifestHash: currentManifestHash,
                    inventoryHash: inventoryHash,
                    selection: selection,
                    productManifestSHA256: state.productManifestSHA256,
                    fallbackBuilds: observedLauncher.fallbackBuildAttempts,
                    childGroupsQuiescent: Self.custodyIsQuiescent(custodyRuntime)
                )
            )
            evidenceWritten = true
            return []
        }
        let sourceRoot = try Self.canonicalSourceRoot(configuration.projectPath)
        let projectURL = try ProjectInputMaterializer(
            sourceRoot: sourceRoot,
            identityDirectory: store.directory,
            collectionRoot: URL(fileURLWithPath: root, isDirectory: true)
        ).materialize(
            manifestAt: URL(fileURLWithPath: manifestPath),
            schematizedFiles: input.schematizedFiles,
            supportFileContent: input.supportFileContent
        )
        var scrubbed = false
        defer { if !scrubbed { try? recovery.recordMutationOrTestFailure() } }
        let xctestrunURL = URL(fileURLWithPath: state.xctestrunPath)
        guard let plist = XCTestRunPlist(try Data(contentsOf: xctestrunURL)) else {
            throw PreparedBuildError.preparedBuildMissing
        }
        let selectedInput = RunnerInput(
            projectPath: input.projectPath,
            projectType: input.projectType,
            timeout: input.timeout,
            concurrency: input.concurrency,
            noCache: input.noCache,
            schematizedFiles: input.schematizedFiles,
            supportFileContent: input.supportFileContent,
            mutants: selected
        )
        let results = try await MutantExecutor(configuration: configuration, launcher: commandLauncher).executePrepared(
            selectedInput,
            sandbox: Sandbox(rootURL: projectURL),
            artifact: BuildArtifact(
                derivedDataPath: state.derivedDataPath,
                xctestrunURL: xctestrunURL,
                plist: plist
            )
        )
        try recovery.recordMutationOrTestFailure()
        scrubbed = true
        try recovery.writeRetentionMetadata(lastUsedAt: Date())
        try custodyRuntime?.monitor.checkFailure()
        try Self.requireCustodyQuiescence(custodyRuntime)
        try writeEvidence(
            targetEvidence(
                compatibilityID: compatibilityID,
                manifestHash: currentManifestHash,
                inventoryHash: inventoryHash,
                selection: selection,
                productManifestSHA256: state.productManifestSHA256,
                fallbackBuilds: observedLauncher.fallbackBuildAttempts,
                childGroupsQuiescent: Self.custodyIsQuiescent(custodyRuntime)
            )
        )
        evidenceWritten = true
        return results
    }

    static func recover(options: ParsedArguments.CacheOptions, enableCustody: Bool = true) throws {
        guard let root = options.buildCacheRoot, let compatibilityID = options.compatibilityID else {
            throw UsageError(message: "cache recovery requires a root and compatibility ID")
        }
        let store = PreparedBuildStore(root: root, compatibilityID: compatibilityID)
        guard FileManager.default.fileExists(atPath: store.directory.path) else {
            try writeRecoveryEvidence(options: options, outcome: "absent", state: nil)
            return
        }
        let lock = try CacheLock(identityDirectory: store.directory)
        defer { try? lock.release() }
        let registry = store.directory.appendingPathComponent("process-custody.json")
        let custody = enableCustody ? try ProcessCustody.system(registrationURL: registry) : nil
        let monitor = try custody.flatMap { custody in
            try options.custodyFD.map { try CustodyFDMonitor(descriptor: $0, custody: custody) }
        }
        defer { monitor?.cancel() }
        let recovery = CacheRecovery(
            identityDirectory: store.directory,
            collectionRoot: URL(fileURLWithPath: root, isDirectory: true)
        )
        try custody?.handleEngineTermination()
        let expected = (try? store.load().productManifestSHA256) ?? String(repeating: "0", count: 64)
        let outcome = try recovery.recover(expectedProductManifestSHA256: expected)
        if outcome == .ready { try recovery.writeRetentionMetadata(lastUsedAt: Date()) }
        try monitor?.checkFailure()
        try writeRecoveryEvidence(
            options: options,
            outcome: String(describing: outcome),
            state: try? store.load(),
            childGroupsQuiescent: custody?.isQuiescent ?? true
        )
    }

    struct CustodyRuntime {
        let custody: ProcessCustody
        let monitor: CustodyFDMonitor
        let launcher: XcodeProcessLauncher
    }

    func makeCustodyRuntime(store: PreparedBuildStore) throws -> CustodyRuntime? {
        guard launcher is XcodeProcessLauncher, let descriptor = options.custodyFD else { return nil }
        let custody = try ProcessCustody.system(
            registrationURL: store.directory.appendingPathComponent("process-custody.json")
        )
        try custody.handleEngineTermination()
        return try CustodyRuntime(
            custody: custody,
            monitor: CustodyFDMonitor(descriptor: descriptor, custody: custody),
            launcher: XcodeProcessLauncher(custody: custody, captureRoot: activeRunRoot())
        )
    }

    func commandLauncher(custodyRuntime: CustodyRuntime?) -> any ProcessLaunching {
        if launcher is XcodeProcessLauncher {
            return XcodeProcessLauncher(
                custody: custodyRuntime?.custody,
                captureRoot: activeRunRoot()
            )
        }
        return custodyRuntime?.launcher ?? launcher
    }

    func activeRunRoot() -> URL? {
        options.evidenceOutput.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
    }

    static func canonicalSourceRoot(
        _ path: String,
        resolver: (URL) -> URL? = { CachePathGuard.canonicalURL($0) }
    ) throws -> URL {
        guard let root = resolver(URL(fileURLWithPath: path, isDirectory: true)) else {
            throw PreparedCacheError.unsafeCachePath
        }
        return root
    }

    static func custodyIsQuiescent(_ runtime: CustodyRuntime?) -> Bool {
        guard let runtime else { return true }
        do {
            try runtime.monitor.checkFailure()
            return runtime.custody.isQuiescent
        } catch {
            return false
        }
    }

    static func requireCustodyQuiescence(_ runtime: CustodyRuntime?) throws {
        guard custodyIsQuiescent(runtime) else { throw PreparedCacheError.unverifiableProcessIdentity }
    }

    static func writeRecoveryEvidence(
        options: ParsedArguments.CacheOptions,
        outcome: String,
        state: PreparedBuildState?,
        childGroupsQuiescent: Bool = true
    ) throws {
        guard let path = options.evidenceOutput else { return }
        guard let nonce = options.invocationNonce,
            let compatibilityID = options.compatibilityID,
            let manifestPath = options.projectInputManifest
        else { throw PreparedCacheError.invalidCacheState }
        let projectDigest = ProjectInputManifest.sha256(try Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        try CacheEvidenceWriter.write(
            CacheEvidence(
                schemaVersion: 1,
                invocationNonce: nonce,
                operation: "recover",
                outcome: outcome,
                compatibilitySHA256: compatibilityID,
                projectInputManifestSHA256: projectDigest,
                preparedInventorySHA256: try state?.inventory.sha256,
                runOrdinal: nil,
                attemptOrdinal: nil,
                productManifestSHA256: state?.productManifestSHA256,
                fullBuilds: 0,
                incrementalBuilds: 0,
                fallbackBuilds: 0,
                sourceBearingBytesScrubbed: outcome != "absent",
                childGroupsQuiescent: childGroupsQuiescent
            ), to: URL(fileURLWithPath: path))
    }

    private func sha256(at path: String) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func writeEvidence(_ evidence: CacheEvidence) throws {
        guard let path = options.evidenceOutput else { return }
        try CacheEvidenceWriter.write(evidence, to: URL(fileURLWithPath: path))
    }

    private func targetEvidence(
        compatibilityID: String,
        manifestHash: String,
        inventoryHash: String,
        selection: MutantSelectionManifest,
        productManifestSHA256: String,
        fallbackBuilds: Int,
        childGroupsQuiescent: Bool
    ) -> CacheEvidence {
        CacheEvidence(
            schemaVersion: 1,
            invocationNonce: options.invocationNonce ?? "",
            operation: "target",
            outcome: "reused",
            compatibilitySHA256: compatibilityID,
            projectInputManifestSHA256: manifestHash,
            preparedInventorySHA256: inventoryHash,
            runOrdinal: selection.runOrdinal,
            attemptOrdinal: selection.attemptOrdinal,
            productManifestSHA256: productManifestSHA256,
            fullBuilds: 0,
            incrementalBuilds: 0,
            fallbackBuilds: fallbackBuilds,
            sourceBearingBytesScrubbed: true,
            childGroupsQuiescent: childGroupsQuiescent
        )
    }
}

struct PreparedTestEnumerator: Sendable {
    let launcher: any ProcessLaunching

    func enumerate(
        xctestrunURL: URL,
        destination: String,
        timeout: Double,
        outputURL: URL
    ) async throws {
        let (exitCode, output) = try await launcher.launchCapturing(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                arguments: [
                    "test-without-building",
                    "-xctestrun", xctestrunURL.path,
                    "-destination", destination,
                    "-enumerate-tests",
                    "-test-enumeration-format", "json",
                    "-test-enumeration-style", "hierarchical",
                    "-test-enumeration-output-path", outputURL.path,
                    "CODE_SIGNING_ALLOWED=NO",
                ],
                environment: nil,
                additionalEnvironment: [:],
                workingDirectoryURL: xctestrunURL.deletingLastPathComponent(),
                timeout: timeout
            )
        )
        guard exitCode == 0 else { throw BuildError.compilationFailed(output: output) }
        guard let data = try? Data(contentsOf: outputURL),
            (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
        else { throw PreparedBuildError.preparedBuildMissing }
    }
}
