import Darwin
import Foundation
import Testing

@testable import SwiftMutationTesting

@Suite("Prepared build store")
struct PreparedBuildStoreTests {
    @Test("Cache evidence encodes the exact v1 contract")
    func cacheEvidenceContract() throws {
        let evidence = CacheEvidence(
            schemaVersion: 1,
            invocationNonce: "abcdefghijklmnopqrstuv",
            operation: "target",
            outcome: "reused",
            compatibilitySHA256: String(repeating: "a", count: 64),
            projectInputManifestSHA256: String(repeating: "b", count: 64),
            preparedInventorySHA256: String(repeating: "c", count: 64),
            runOrdinal: 3,
            attemptOrdinal: 1,
            productManifestSHA256: String(repeating: "d", count: 64),
            fullBuilds: 0,
            incrementalBuilds: 0,
            fallbackBuilds: 2,
            sourceBearingBytesScrubbed: true,
            childGroupsQuiescent: true
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any])
        #expect(Set(object.keys) == [
            "schemaVersion", "invocationNonce", "operation", "outcome", "compatibilitySHA256",
            "projectInputManifestSHA256", "preparedInventorySHA256", "runOrdinal", "attemptOrdinal",
            "productManifestSHA256", "fullBuilds", "incrementalBuilds", "fallbackBuilds",
            "sourceBearingBytesScrubbed", "childGroupsQuiescent",
        ])
        let directory = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        chmod(directory.path, 0o700)
        let output = directory.appendingPathComponent("evidence.json")
        try CacheEvidenceWriter.write(evidence, to: output)
        #expect(try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int == 0o600)
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try CacheEvidenceWriter.write(evidence, to: output)
        }
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try CacheEvidenceWriter.write(evidence, to: directory.appendingPathComponent("open-fail"),
                                          openFile: { _ in -1 })
        }
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try CacheEvidenceWriter.write(evidence, to: directory.appendingPathComponent("write-fail"),
                                          writeBytes: { _, _, _ in 0 })
        }
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try CacheEvidenceWriter.write(evidence, to: directory.appendingPathComponent("sync-fail"),
                                          syncFile: { _ in -1 })
        }
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try CacheEvidenceWriter.write(evidence, to: directory.appendingPathComponent("close-fail"),
                                          closeFile: { _ in -1 })
        }
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try CacheEvidenceWriter.write(evidence, to: directory.appendingPathComponent("rename-fail"),
                                          renameExclusive: { _, _ in -1 })
        }
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try CacheEvidenceWriter.write(evidence, to: directory.appendingPathComponent("directory-open-fail"),
                                          openDirectory: { _ in -1 })
        }
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try CacheEvidenceWriter.write(evidence, to: directory.appendingPathComponent("directory-sync-fail"),
                                          syncDirectory: { _ in -1 })
        }
    }

    @Test("Evidence writer never closes a successfully closed descriptor again")
    func evidenceDescriptorSingleOwnership() throws {
        let directory = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        chmod(directory.path, 0o700)
        let evidence = CacheEvidence(
            schemaVersion: 1,
            invocationNonce: "abcdefghijklmnopqrstuv",
            operation: "target",
            outcome: "failed",
            compatibilitySHA256: String(repeating: "a", count: 64),
            projectInputManifestSHA256: String(repeating: "b", count: 64),
            preparedInventorySHA256: nil,
            runOrdinal: nil,
            attemptOrdinal: nil,
            productManifestSHA256: nil,
            fullBuilds: 0,
            incrementalBuilds: 0,
            fallbackBuilds: 0,
            sourceBearingBytesScrubbed: true,
            childGroupsQuiescent: true
        )

        for failure in ["rename", "parent-sync"] {
            let sourceDescriptor = open("/dev/null", O_RDONLY)
            #expect(sourceDescriptor >= 0)
            defer { close(sourceDescriptor) }
            var replacementDescriptor: Int32 = -1
            var firstClose = true
            #expect(throws: PreparedCacheError.invalidCacheState) {
                try CacheEvidenceWriter.write(
                    evidence,
                    to: directory.appendingPathComponent("\(failure).json"),
                    closeFile: { descriptor in
                        let result = Darwin.close(descriptor)
                        if firstClose {
                            firstClose = false
                            replacementDescriptor = dup2(sourceDescriptor, descriptor)
                        }
                        return result
                    },
                    renameExclusive: failure == "rename" ? { _, _ in -1 } : { renamex_np($0, $1, UInt32(RENAME_EXCL)) },
                    syncDirectory: failure == "parent-sync" ? { _ in -1 } : { fsync($0) }
                )
            }
            #expect(replacementDescriptor >= 0)
            #expect(fcntl(replacementDescriptor, F_GETFD) >= 0)
            if replacementDescriptor >= 0 { close(replacementDescriptor) }
        }
    }

    @Test("Failure evidence covers mode dispatch, duplicate suppression, locks, and corrupt custody")
    func cacheFailureEvidenceBranches() throws {
        let root = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, 0o700)
        let manifest = root.appendingPathComponent("manifest.json")
        try Data("manifest".utf8).write(to: manifest)
        let identity = String(repeating: "7", count: 64)
        func options(_ mode: ParsedArguments.CacheOptions.Mode, output: URL?) -> ParsedArguments.CacheOptions {
            .init(mode: mode, buildCacheRoot: root.path, compatibilityID: identity,
                  projectInputManifest: manifest.path, evidenceOutput: output?.path,
                  invocationNonce: "abcdefghijklmnopqrstuv")
        }
        try CacheFailureEvidenceRecorder.record(options: .init(mode: .prepare))
        try CacheFailureEvidenceRecorder.record(options: options(.legacy, output: root.appendingPathComponent("legacy.json")))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("legacy.json").path))

        let recoverEvidence = root.appendingPathComponent("recover.json")
        try CacheFailureEvidenceRecorder.record(options: options(.recover, output: recoverEvidence))
        let recover = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recoverEvidence)) as? [String: Any])
        #expect(recover["operation"] as? String == "recover")
        try CacheFailureEvidenceRecorder.record(options: options(.recover, output: recoverEvidence))
        let missingManifestEvidence = root.appendingPathComponent("missing-manifest.json")
        try CacheFailureEvidenceRecorder.record(options: .init(
            mode: .prepare,
            buildCacheRoot: root.path,
            compatibilityID: String(repeating: "6", count: 64),
            projectInputManifest: root.appendingPathComponent("absent-manifest").path,
            evidenceOutput: missingManifestEvidence.path,
            invocationNonce: "abcdefghijklmnopqrstuv"
        ))
        let missingManifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: missingManifestEvidence)) as? [String: Any]
        )
        #expect(missingManifest["projectInputManifestSHA256"] as? String == String(repeating: "0", count: 64))

        let store = PreparedBuildStore(root: root.path, compatibilityID: identity)
        try store.prepareDirectory()
        let lock = try CacheLock(identityDirectory: store.directory)
        let lockedEvidence = root.appendingPathComponent("locked.json")
        try CacheFailureEvidenceRecorder.record(options: options(.prepare, output: lockedEvidence))
        let locked = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: lockedEvidence)) as? [String: Any])
        #expect(locked["sourceBearingBytesScrubbed"] as? Bool == false)
        #expect(locked["childGroupsQuiescent"] as? Bool == false)
        try lock.release()

        let registry = store.directory.appendingPathComponent("process-custody.json")
        try Data("bad registry".utf8).write(to: registry)
        chmod(registry.path, 0o600)
        let corruptEvidence = root.appendingPathComponent("corrupt.json")
        try CacheFailureEvidenceRecorder.record(options: options(.target, output: corruptEvidence))
        let corrupt = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: corruptEvidence)) as? [String: Any])
        #expect(corrupt["childGroupsQuiescent"] as? Bool == false)

        try Data("[]".utf8).write(to: registry)
        chmod(registry.path, 0o600)
        let cleanEvidence = root.appendingPathComponent("clean-registry.json")
        try CacheFailureEvidenceRecorder.record(options: options(.prepare, output: cleanEvidence))
        let clean = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: cleanEvidence)) as? [String: Any])
        #expect(clean["childGroupsQuiescent"] as? Bool == true)
    }

    @Test("Prepared test enumeration runs the retained product without building")
    func preparedTestEnumeration() async throws {
        let directory = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let xctestrun = directory.appendingPathComponent("App.xctestrun")
        try Data("plist".utf8).write(to: xctestrun)
        let output = directory.appendingPathComponent("tests.json")
        let launcher = EnumerationLauncher(output: output)

        try await PreparedTestEnumerator(launcher: launcher).enumerate(
            xctestrunURL: xctestrun,
            destination: "platform=iOS Simulator,name=iPhone 16",
            timeout: 30,
            outputURL: output
        )

        let request = try #require(launcher.request)
        #expect(request.arguments.contains("test-without-building"))
        #expect(request.arguments.contains("-enumerate-tests"))
        #expect(request.arguments.contains("-test-enumeration-style"))
        #expect(request.arguments.contains("hierarchical"))
        #expect(request.arguments.contains("CODE_SIGNING_ALLOWED=NO"))
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: output)) is [String: Any])
    }

    @Test("Prepared enumeration fails closed on xcodebuild and malformed output")
    func preparedTestEnumerationFailures() async throws {
        let directory = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let xctestrun = directory.appendingPathComponent("App.xctestrun")
        try Data("plist".utf8).write(to: xctestrun)
        let output = directory.appendingPathComponent("tests.json")
        await #expect(throws: BuildError.self) {
            try await PreparedTestEnumerator(launcher: EnumerationLauncher(output: output, exitCode: 1)).enumerate(
                xctestrunURL: xctestrun, destination: "platform=macOS", timeout: 1, outputURL: output
            )
        }
        await #expect(throws: PreparedBuildError.preparedBuildMissing) {
            try await PreparedTestEnumerator(launcher: EnumerationLauncher(output: output, bytes: Data("[]".utf8))).enumerate(
                xctestrunURL: xctestrun, destination: "platform=macOS", timeout: 1, outputURL: output
            )
        }
    }

    @Test("Preparing an existing identity preserves its DerivedData")
    func prepareDirectoryPreservesDerivedData() throws {
        let root = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, 0o700)
        let store = PreparedBuildStore(root: root.path, compatibilityID: String(repeating: "8", count: 64))
        try store.prepareDirectory()
        let product = store.derivedDataURL.appendingPathComponent("Build/Products/product")
        try FileManager.default.createDirectory(at: product.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("compiled".utf8).write(to: product)

        try store.prepareDirectory()

        #expect(FileManager.default.fileExists(atPath: product.path))
    }

    @Test("Prepared identity and state use private filesystem modes")
    func privateFilesystemModes() throws {
        let root = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, 0o700)
        let store = PreparedBuildStore(root: root.path, compatibilityID: String(repeating: "9", count: 64))
        try store.reset()
        try store.reset()

        let inventory = try PreparedMutantInventory(
            projectRoot: "/repo",
            projectInputManifestSHA256: String(repeating: "a", count: 64),
            mutants: [makeMutantDescriptor(filePath: "/repo/Sources/A.swift")]
        )
        try store.save(
            PreparedBuildState(
                sandboxPath: store.sandboxURL.path,
                derivedDataPath: store.derivedDataURL.path,
                xctestrunPath: store.directory.appendingPathComponent("tests.xctestrun").path,
                productManifestSHA256: String(repeating: "b", count: 64),
                inventory: inventory
            )
        )

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        let stateAttributes = try FileManager.default.attributesOfItem(atPath: store.stateURL.path)
        #expect(directoryAttributes[.posixPermissions] as? Int == 0o700)
        #expect(stateAttributes[.posixPermissions] as? Int == 0o600)
        #expect(store.sandboxURL.lastPathComponent == "project")
    }

    @Test("Prepared state round trips through the compatibility root")
    func stateRoundTrips() throws {
        let root = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, 0o700)
        let inventory = try PreparedMutantInventory(
            projectRoot: "/repo",
            projectInputManifestSHA256: String(repeating: "a", count: 64),
            mutants: [makeMutantDescriptor(filePath: "/repo/Sources/A.swift")]
        )
        let store = PreparedBuildStore(root: root.path, compatibilityID: String(repeating: "b", count: 64))
        let state = PreparedBuildState(
            sandboxPath: store.sandboxURL.path,
            derivedDataPath: store.derivedDataURL.path,
            xctestrunPath: store.derivedDataURL.appendingPathComponent("tests.xctestrun").path,
            productManifestSHA256: String(repeating: "b", count: 64),
            inventory: inventory
        )

        try store.save(state)

        let product = store.derivedDataURL.appendingPathComponent("Build/Products/App")
        try FileManager.default.createDirectory(at: product.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("compiled".utf8).write(to: product)
        let xctestrun = URL(fileURLWithPath: state.xctestrunPath)
        try Data("plist".utf8).write(to: xctestrun)
        chmod(xctestrun.path, 0o600)

        #expect(try store.load() == state)

        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.stateURL)) as? [String: Any])
        var inventoryObject = try #require(object["inventory"] as? [String: Any])
        inventoryObject["unknown"] = true
        object["inventory"] = inventoryObject
        try JSONSerialization.data(withJSONObject: object).write(to: store.stateURL)
        chmod(store.stateURL.path, 0o600)
        #expect(throws: PreparedBuildError.preparedBuildMissing) { try store.load() }

        try store.save(state)
        object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.stateURL)) as? [String: Any])
        inventoryObject = try #require(object["inventory"] as? [String: Any])
        var rows = try #require(inventoryObject["mutants"] as? [[String: Any]])
        rows[0]["unknown"] = true
        inventoryObject["mutants"] = rows
        object["inventory"] = inventoryObject
        try JSONSerialization.data(withJSONObject: object).write(to: store.stateURL)
        chmod(store.stateURL.path, 0o600)
        #expect(throws: PreparedBuildError.preparedBuildMissing) { try store.load() }

        try store.save(state)
        object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.stateURL)) as? [String: Any])
        inventoryObject = try #require(object["inventory"] as? [String: Any])
        rows = try #require(inventoryObject["mutants"] as? [[String: Any]])
        rows[0]["sourceUTF8Offset"] = -1
        inventoryObject["mutants"] = rows
        object["inventory"] = inventoryObject
        try JSONSerialization.data(withJSONObject: object).write(to: store.stateURL)
        chmod(store.stateURL.path, 0o600)
        #expect(throws: PreparedBuildError.preparedBuildMissing) { try store.load() }

        #expect(throws: PreparedBuildError.inventoryMismatch) {
            try state.inventory.validate(
                mutants: [makeMutantDescriptor(id: "different", filePath: "/repo/Sources/A.swift")],
                projectRoot: "/repo"
            )
        }
        #expect(throws: PreparedBuildError.invalidSourcePath) {
            _ = try PreparedMutantInventory(
                projectRoot: "/repo",
                projectInputManifestSHA256: String(repeating: "a", count: 64),
                mutants: [makeMutantDescriptor(filePath: "/outside/A.swift")]
            )
        }

        try store.save(state)
        object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.stateURL)) as? [String: Any])
        object["unknown"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: store.stateURL)
        chmod(store.stateURL.path, 0o600)
        #expect(throws: PreparedBuildError.preparedBuildMissing) { try store.load() }

        try store.save(state)
        chmod(store.stateURL.path, 0o644)
        #expect(throws: PreparedBuildError.preparedBuildMissing) { try store.load() }
        chmod(store.stateURL.path, 0o600)

        let stateAlias = store.directory.appendingPathComponent("prepared-build-alias.json")
        #expect(linkat(AT_FDCWD, store.stateURL.path, AT_FDCWD, stateAlias.path, 0) == 0)
        #expect(throws: PreparedBuildError.preparedBuildMissing) { try store.load() }
        try FileManager.default.removeItem(at: stateAlias)

        let xctestrunAlias = store.derivedDataURL.appendingPathComponent("tests-alias.xctestrun")
        #expect(linkat(AT_FDCWD, xctestrun.path, AT_FDCWD, xctestrunAlias.path, 0) == 0)
        #expect(throws: PreparedBuildError.preparedBuildMissing) { try store.load() }
        try FileManager.default.removeItem(at: xctestrunAlias)

        let outside = root.appendingPathComponent("outside.xctestrun")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: xctestrun)
        try FileManager.default.createSymbolicLink(at: xctestrun, withDestinationURL: outside)
        #expect(throws: PreparedBuildError.preparedBuildMissing) { try store.load() }
        try FileManager.default.removeItem(at: xctestrun)
        try Data("plist".utf8).write(to: xctestrun)

        try FileManager.default.removeItem(at: store.derivedDataURL)
        let outsideDerivedData = root.appendingPathComponent("outside-derived")
        try FileManager.default.createDirectory(at: outsideDerivedData, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: store.derivedDataURL, withDestinationURL: outsideDerivedData)
        #expect(throws: PreparedBuildError.preparedBuildMissing) { try store.load() }
        try FileManager.default.removeItem(at: store.derivedDataURL)

        try Data("not a directory".utf8).write(to: store.derivedDataURL)
        #expect(throws: PreparedBuildError.preparedBuildMissing) { try store.load() }
        try FileManager.default.removeItem(at: store.derivedDataURL)

        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        chmod(store.stateURL.path, 0o700)
        #expect(throws: PreparedBuildError.preparedBuildMissing) { try store.load() }
    }

    @Test("Selection manifest rejects a selector or inventory mismatch")
    func selectionManifestValidatesBindings() throws {
        let digest = String(repeating: "c", count: 64)
        let manifest = MutantSelectionManifest(
            schemaVersion: 1,
            projectInputManifestSHA256: String(repeating: "d", count: 64),
            preparedInventorySHA256: digest,
            selector: "TheGuideTests/ExampleTests",
            runOrdinal: 0,
            attemptOrdinal: 0,
            ownedSourcePaths: ["Sources/A.swift"]
        )

        #expect(
            try manifest.validatedSourcePaths(
                selector: "TheGuideTests/ExampleTests",
                inventorySHA256: digest,
                inventorySourcePaths: ["Sources/A.swift"]
            ) == ["Sources/A.swift"]
        )
        let retry = MutantSelectionManifest(
            schemaVersion: 1,
            projectInputManifestSHA256: manifest.projectInputManifestSHA256,
            preparedInventorySHA256: digest,
            selector: manifest.selector,
            runOrdinal: 1,
            attemptOrdinal: 1,
            ownedSourcePaths: manifest.ownedSourcePaths
        )
        #expect(try retry.validatedSourcePaths(
            selector: retry.selector, inventorySHA256: digest, inventorySourcePaths: ["Sources/A.swift"]
        ) == ["Sources/A.swift"])
        #expect(throws: PreparedBuildError.selectionMismatch) {
            try manifest.validatedSourcePaths(
                selector: "TheGuideTests/OtherTests",
                inventorySHA256: digest,
                inventorySourcePaths: ["Sources/A.swift"]
            )
        }
        let url = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        encoded["unknown"] = true
        try JSONSerialization.data(withJSONObject: encoded).write(to: url)
        #expect(throws: PreparedBuildError.selectionMismatch) { try MutantSelectionManifest.load(from: url.path) }
        encoded.removeValue(forKey: "unknown")
        encoded["preparedInventorySHA256"] = "bad"
        try JSONSerialization.data(withJSONObject: encoded).write(to: url)
        #expect(throws: PreparedBuildError.selectionMismatch) { try MutantSelectionManifest.load(from: url.path) }
    }

    @Test("Empty selection remains valid for a selector with no mutants for the active operator")
    func emptySelectionIsValid() throws {
        let digest = String(repeating: "e", count: 64)
        let manifest = MutantSelectionManifest(
            schemaVersion: 1,
            projectInputManifestSHA256: String(repeating: "f", count: 64),
            preparedInventorySHA256: digest,
            selector: "TheGuideTests/NoLogicalMutantsTests",
            runOrdinal: 0,
            attemptOrdinal: 0,
            ownedSourcePaths: []
        )

        #expect(
            try manifest.validatedSourcePaths(
                selector: manifest.selector,
                inventorySHA256: digest,
                inventorySourcePaths: []
            ).isEmpty
        )
    }
}

private final class EnumerationLauncher: @unchecked Sendable, ProcessLaunching {
    private(set) var request: ProcessRequest?
    let output: URL
    let exitCode: Int32
    let bytes: Data

    init(output: URL, exitCode: Int32 = 0, bytes: Data = Data("{\"values\":[]}".utf8)) {
        self.output = output
        self.exitCode = exitCode
        self.bytes = bytes
    }

    func launch(executableURL: URL, arguments: [String], workingDirectoryURL: URL, timeout: Double) async throws -> Int32 {
        0
    }

    func launchCapturing(_ request: ProcessRequest) async throws -> (exitCode: Int32, output: String) {
        self.request = request
        try bytes.write(to: output)
        return (exitCode, "failure")
    }
}
