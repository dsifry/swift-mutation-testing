import CryptoKit
import Foundation

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
        let store = PreparedBuildStore(root: root, compatibilityID: compatibilityID)
        try store.reset()

        let temporary = try await SandboxFactory().create(
            projectPath: input.projectPath,
            schematizedFiles: input.schematizedFiles,
            supportFileContent: input.supportFileContent
        )
        do {
            try FileManager.default.moveItem(at: temporary.rootURL, to: store.sandboxURL)
            let sandbox = Sandbox(rootURL: store.sandboxURL)
            let artifact = try await BuildStage(launcher: launcher).build(
                sandbox: sandbox,
                scheme: scheme,
                destination: destination,
                timeout: configuration.build.timeout,
                derivedDataURL: store.derivedDataURL
            )
            guard let xctestrunURL = artifact.xctestrunURL else {
                throw PreparedBuildError.preparedBuildMissing
            }
            try store.save(
                PreparedBuildState(
                    sandboxPath: sandbox.rootURL.path,
                    derivedDataPath: artifact.derivedDataPath,
                    xctestrunPath: xctestrunURL.path,
                    inventory: inventory
                )
            )
            try writeJSON(inventory, to: inventoryOutput)
            try Data("[]\n".utf8).write(to: URL(fileURLWithPath: enumerationOutput), options: .atomic)
            try writeEvidence(mode: "prepare", mutantCount: input.mutants.count)
        } catch {
            try? temporary.cleanup()
            throw error
        }
    }

    func target(_ input: RunnerInput) async throws -> [ExecutionResult] {
        guard case .xcode = configuration.build.projectType,
            let root = options.buildCacheRoot,
            let compatibilityID = options.compatibilityID,
            let manifestPath = options.projectInputManifest,
            let selectionPath = options.mutantSelectionManifest,
            let selector = configuration.build.testTarget
        else { throw UsageError(message: "prepared targets currently require an Xcode project and selector") }

        let state = try PreparedBuildStore(root: root, compatibilityID: compatibilityID).load()
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
        let selected = try state.inventory.select(
            mutants: input.mutants,
            ownedSourcePaths: paths,
            projectRoot: configuration.projectPath
        )
        if selected.isEmpty {
            try writeEvidence(mode: "target", mutantCount: 0)
            return []
        }
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
        let results = try await MutantExecutor(configuration: configuration, launcher: launcher).executePrepared(
            selectedInput,
            sandbox: Sandbox(rootURL: URL(fileURLWithPath: state.sandboxPath)),
            artifact: BuildArtifact(
                derivedDataPath: state.derivedDataPath,
                xctestrunURL: xctestrunURL,
                plist: plist
            )
        )
        try writeEvidence(mode: "target", mutantCount: results.count)
        return results
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

    private func writeEvidence(mode: String, mutantCount: Int) throws {
        guard let path = options.evidenceOutput else { return }
        struct Evidence: Encodable {
            let schemaVersion: Int
            let mode: String
            let mutantCount: Int
        }
        try writeJSON(Evidence(schemaVersion: 1, mode: mode, mutantCount: mutantCount), to: path)
    }
}
