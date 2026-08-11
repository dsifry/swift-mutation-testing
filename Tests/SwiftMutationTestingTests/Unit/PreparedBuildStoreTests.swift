import Darwin
import Foundation
import Testing

@testable import SwiftMutationTesting

@Suite("Prepared build store")
struct PreparedBuildStoreTests {
    @Test("Cache evidence encodes explicit nulls for absent and failed non-target operations")
    func cacheEvidenceExplicitNullContract() throws {
        for (operation, outcome) in [("recover", "absent"), ("prepare", "failed")] {
            let evidence = CacheEvidence(
                schemaVersion: 1,
                invocationNonce: "abcdefghijklmnopqrstuv",
                operation: operation,
                outcome: outcome,
                compatibilitySHA256: String(repeating: "a", count: 64),
                projectInputManifestSHA256: String(repeating: "b", count: 64),
                preparedInventorySHA256: nil,
                runOrdinal: nil,
                attemptOrdinal: nil,
                productManifestSHA256: nil,
                fullBuilds: 0,
                incrementalBuilds: 0,
                fallbackBuilds: 0,
                sourceBearingBytesScrubbed: operation == "prepare",
                childGroupsQuiescent: true
            )
            let data = try JSONEncoder().encode(evidence)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object.count == 15)
            #expect(object["preparedInventorySHA256"] is NSNull)
            #expect(object["runOrdinal"] is NSNull)
            #expect(object["attemptOrdinal"] is NSNull)
            #expect(object["productManifestSHA256"] is NSNull)
            #expect(try JSONDecoder().decode(CacheEvidence.self, from: data) == evidence)
        }
    }

    @Test("Cache evidence decoding rejects unknown missing and wrongly typed fields")
    func cacheEvidenceStrictDecodeContract() throws {
        #expect(CacheEvidenceCodingKey(stringValue: "field")?.intValue == nil)
        #expect(CacheEvidenceCodingKey(intValue: 7)?.stringValue == "7")
        let evidence = CacheEvidence(
            schemaVersion: 1,
            invocationNonce: "abcdefghijklmnopqrstuv",
            operation: "recover",
            outcome: "absent",
            compatibilitySHA256: String(repeating: "a", count: 64),
            projectInputManifestSHA256: String(repeating: "b", count: 64),
            preparedInventorySHA256: nil,
            runOrdinal: nil,
            attemptOrdinal: nil,
            productManifestSHA256: nil,
            fullBuilds: 0,
            incrementalBuilds: 0,
            fallbackBuilds: 0,
            sourceBearingBytesScrubbed: false,
            childGroupsQuiescent: true
        )
        let original = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any])
        for mutate in [
            { (object: inout [String: Any]) in object["unknown"] = true },
            { (object: inout [String: Any]) in object.removeValue(forKey: "runOrdinal") },
            { (object: inout [String: Any]) in object["fullBuilds"] = "zero" },
        ] {
            var object = original
            mutate(&object)
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: Error.self) { try JSONDecoder().decode(CacheEvidence.self, from: data) }
        }
    }

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
        let encoded = try JSONEncoder().encode(evidence)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(
            Set(object.keys) == [
                "schemaVersion", "invocationNonce", "operation", "outcome", "compatibilitySHA256",
                "projectInputManifestSHA256", "preparedInventorySHA256", "runOrdinal", "attemptOrdinal",
                "productManifestSHA256", "fullBuilds", "incrementalBuilds", "fallbackBuilds",
                "sourceBearingBytesScrubbed", "childGroupsQuiescent",
            ])
        #expect(try JSONDecoder().decode(CacheEvidence.self, from: encoded) == evidence)
        let directory = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(
            UUID().uuidString)
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
            try CacheEvidenceWriter.write(
                evidence, to: directory.appendingPathComponent("open-fail"),
                openFile: { _ in -1 })
        }
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try CacheEvidenceWriter.write(
                evidence, to: directory.appendingPathComponent("write-fail"),
                writeBytes: { _, _, _ in 0 })
        }
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try CacheEvidenceWriter.write(
                evidence, to: directory.appendingPathComponent("sync-fail"),
                syncFile: { _ in -1 })
        }
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try CacheEvidenceWriter.write(
                evidence, to: directory.appendingPathComponent("close-fail"),
                closeFile: { _ in -1 })
        }
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try CacheEvidenceWriter.write(
                evidence, to: directory.appendingPathComponent("rename-fail"),
                renameExclusive: { _, _ in -1 })
        }
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try CacheEvidenceWriter.write(
                evidence, to: directory.appendingPathComponent("directory-open-fail"),
                openDirectory: { _ in -1 })
        }
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try CacheEvidenceWriter.write(
                evidence, to: directory.appendingPathComponent("directory-sync-fail"),
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
            var closedDescriptors: [Int32] = []
            #expect(throws: PreparedCacheError.invalidCacheState) {
                try CacheEvidenceWriter.write(
                    evidence,
                    to: directory.appendingPathComponent("\(failure).json"),
                    openFile: { path in
                        _ = FileManager.default.createFile(
                            atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]
                        )
                        return 101
                    },
                    writeBytes: { _, _, count in count },
                    syncFile: { _ in 0 },
                    closeFile: { descriptor in
                        closedDescriptors.append(descriptor)
                        return 0
                    },
                    renameExclusive: failure == "rename" ? { _, _ in -1 } : { renamex_np($0, $1, UInt32(RENAME_EXCL)) },
                    openDirectory: { _ in 202 },
                    syncDirectory: { _ in failure == "parent-sync" ? -1 : 0 }
                )
            }
            let expectedDescriptors: [Int32] = failure == "rename" ? [101] : [101, 202]
            #expect(closedDescriptors == expectedDescriptors)
        }
    }

    @Test("Failure evidence covers mode dispatch, duplicate suppression, locks, and corrupt custody")
    func cacheFailureEvidenceBranches() throws {
        let root = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, 0o700)
        let manifest = root.appendingPathComponent("manifest.json")
        try Data("manifest".utf8).write(to: manifest)
        let identity = String(repeating: "7", count: 64)
        func options(_ mode: ParsedArguments.CacheOptions.Mode, output: URL?) -> ParsedArguments.CacheOptions {
            .init(
                mode: mode, buildCacheRoot: root.path, compatibilityID: identity,
                projectInputManifest: manifest.path, evidenceOutput: output?.path,
                invocationNonce: "abcdefghijklmnopqrstuv")
        }
        try CacheFailureEvidenceRecorder.record(options: .init(mode: .prepare))
        try CacheFailureEvidenceRecorder.record(
            options: options(.legacy, output: root.appendingPathComponent("legacy.json")))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("legacy.json").path))

        let recoverEvidence = root.appendingPathComponent("recover.json")
        try CacheFailureEvidenceRecorder.record(options: options(.recover, output: recoverEvidence))
        let recover = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: recoverEvidence)) as? [String: Any])
        #expect(recover["operation"] as? String == "recover")
        try CacheFailureEvidenceRecorder.record(options: options(.recover, output: recoverEvidence))
        let missingManifestEvidence = root.appendingPathComponent("missing-manifest.json")
        try CacheFailureEvidenceRecorder.record(
            options: .init(
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

        let collectionLock = try CacheLock.collection(collectionRoot: root)
        let collectionBusyEvidence = root.appendingPathComponent("collection-busy.json")
        try CacheFailureEvidenceRecorder.record(options: options(.prepare, output: collectionBusyEvidence))
        let collectionBusy = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: collectionBusyEvidence)) as? [String: Any])
        #expect(collectionBusy["sourceBearingBytesScrubbed"] as? Bool == false)
        #expect(collectionBusy["childGroupsQuiescent"] as? Bool == false)
        try collectionLock.release()

        let store = PreparedBuildStore(root: root.path, compatibilityID: identity)
        _ = try store.prepareDirectory()
        let lock = try CacheLock(identityDirectory: store.directory)
        let lockedEvidence = root.appendingPathComponent("locked.json")
        try CacheFailureEvidenceRecorder.record(options: options(.prepare, output: lockedEvidence))
        let locked = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: lockedEvidence)) as? [String: Any])
        #expect(locked["sourceBearingBytesScrubbed"] as? Bool == false)
        #expect(locked["childGroupsQuiescent"] as? Bool == false)
        try lock.release()

        let registry = store.directory.appendingPathComponent("process-custody.json")
        try Data("bad registry".utf8).write(to: registry)
        chmod(registry.path, 0o600)
        let corruptEvidence = root.appendingPathComponent("corrupt.json")
        try CacheFailureEvidenceRecorder.record(options: options(.target, output: corruptEvidence))
        let corrupt = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: corruptEvidence)) as? [String: Any])
        #expect(corrupt["childGroupsQuiescent"] as? Bool == false)

        try Data("[]".utf8).write(to: registry)
        chmod(registry.path, 0o600)
        let cleanEvidence = root.appendingPathComponent("clean-registry.json")
        try CacheFailureEvidenceRecorder.record(options: options(.prepare, output: cleanEvidence))
        let clean = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: cleanEvidence)) as? [String: Any])
        #expect(clean["childGroupsQuiescent"] as? Bool == true)

        let raceStore = PreparedBuildStore(
            root: root.path, compatibilityID: String(repeating: "5", count: 64))
        _ = try raceStore.prepareDirectory()
        try FileManager.default.createDirectory(
            at: raceStore.sandboxURL, withIntermediateDirectories: false)
        try Data("source".utf8).write(to: raceStore.sandboxURL.appendingPathComponent("marker"))
        let moved = root.appendingPathComponent("moved-failure-identity")
        let raceEvidence = root.appendingPathComponent("race-failure.json")
        try CacheFailureEvidenceRecorder.record(
            options: .init(
                mode: .prepare, buildCacheRoot: root.path,
                compatibilityID: String(repeating: "5", count: 64),
                projectInputManifest: manifest.path, evidenceOutput: raceEvidence.path,
                invocationNonce: "abcdefghijklmnopqrstuv"),
            afterIdentityClaimed: { directory in
                try! FileManager.default.moveItem(at: directory, to: moved)
                try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                chmod(directory.path, 0o700)
            })
        let race = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: raceEvidence)) as? [String: Any])
        #expect(race["sourceBearingBytesScrubbed"] as? Bool == false)
        #expect(FileManager.default.fileExists(atPath: moved.path))

        let unsafeStore = PreparedBuildStore(
            root: root.path, compatibilityID: String(repeating: "4", count: 64))
        _ = try unsafeStore.prepareDirectory()
        chmod(unsafeStore.directory.path, 0o755)
        let unsafeEvidence = root.appendingPathComponent("unsafe-failure.json")
        try CacheFailureEvidenceRecorder.record(
            options: .init(
                mode: .prepare, buildCacheRoot: root.path,
                compatibilityID: String(repeating: "4", count: 64),
                projectInputManifest: manifest.path, evidenceOutput: unsafeEvidence.path,
                invocationNonce: "abcdefghijklmnopqrstuv"))
        let unsafe = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: unsafeEvidence)) as? [String: Any])
        #expect(unsafe["sourceBearingBytesScrubbed"] as? Bool == false)

        let postLockStore = PreparedBuildStore(
            root: root.path, compatibilityID: String(repeating: "3", count: 64))
        _ = try postLockStore.prepareDirectory()
        let movedPostLock = root.appendingPathComponent("moved-post-lock-failure")
        let postLockEvidence = root.appendingPathComponent("post-lock-failure.json")
        try CacheFailureEvidenceRecorder.record(
            options: .init(
                mode: .prepare, buildCacheRoot: root.path,
                compatibilityID: String(repeating: "3", count: 64),
                projectInputManifest: manifest.path, evidenceOutput: postLockEvidence.path,
                invocationNonce: "abcdefghijklmnopqrstuv"),
            afterCleanupLockAcquired: { directory in
                try! FileManager.default.moveItem(at: directory, to: movedPostLock)
                try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                chmod(directory.path, 0o700)
            })
        let postLock = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: postLockEvidence)) as? [String: Any])
        #expect(postLock["sourceBearingBytesScrubbed"] as? Bool == false)
    }

    @Test("Prepared test enumeration runs the retained product without building")
    func preparedTestEnumeration() async throws {
        let directory = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(
            UUID().uuidString)
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
        let directory = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(
            UUID().uuidString)
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
            try await PreparedTestEnumerator(launcher: EnumerationLauncher(output: output, bytes: Data("[]".utf8)))
                .enumerate(
                    xctestrunURL: xctestrun, destination: "platform=macOS", timeout: 1, outputURL: output
                )
        }
    }

    @Test("Preparing an existing identity preserves its DerivedData")
    func prepareDirectoryPreservesDerivedData() throws {
        let root = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, 0o700)
        let store = PreparedBuildStore(root: root.path, compatibilityID: String(repeating: "8", count: 64))
        _ = try store.prepareDirectory()
        let product = store.derivedDataURL.appendingPathComponent("Build/Products/product")
        try FileManager.default.createDirectory(
            at: product.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("compiled".utf8).write(to: product)

        _ = try store.prepareDirectory()

        #expect(FileManager.default.fileExists(atPath: product.path))
    }

    @Test("Atomic identity creation accepts a concurrently created private directory")
    func prepareDirectoryHandlesAtomicClaimRace() throws {
        let root = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, 0o700)
        let store = PreparedBuildStore(
            root: root.path, compatibilityID: String(repeating: "a", count: 64))

        _ = try store.prepareDirectory(createDirectory: { path, _ in
            try! FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path), withIntermediateDirectories: false)
            chmod(path, 0o700)
            errno = EEXIST
            return -1
        })

        try CachePathGuard.validateDirectory(store.directory, containedIn: root)

        let failedStore = PreparedBuildStore(
            root: root.path, compatibilityID: String(repeating: "b", count: 64))
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try failedStore.prepareDirectory(createDirectory: { _, _ in
                errno = EIO
                return -1
            })
        }

        let missingAfterCreate = PreparedBuildStore(
            root: root.path, compatibilityID: String(repeating: "c", count: 64))
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try missingAfterCreate.prepareDirectory(metadataOf: { _ in nil })
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try store.prepareDirectory(metadataOf: { _ in nil })
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try store.directoryIdentity(metadataOf: { _ in nil })
        }
        #expect(try store.directoryIdentity().kind == S_IFDIR)
    }

    @Test("Prepared identity and state use private filesystem modes")
    func privateFilesystemModes() throws {
        let root = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(
            UUID().uuidString)
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
                projectInputManifestSHA256: inventory.projectInputManifestSHA256,
                preparedInventorySHA256: try inventory.sha256
            )
        )

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        let stateAttributes = try FileManager.default.attributesOfItem(atPath: store.stateURL.path)
        #expect(directoryAttributes[.posixPermissions] as? Int == 0o700)
        #expect(stateAttributes[.posixPermissions] as? Int == 0o600)
        #expect(store.sandboxURL.lastPathComponent == "project")
    }

    @Test("Reset rejects an identity reached through a symlink")
    func resetRejectsSymlinkIdentity() throws {
        let root = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, 0o700)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        chmod(outside.path, 0o700)
        let marker = outside.appendingPathComponent("marker")
        try Data("keep".utf8).write(to: marker)
        let store = PreparedBuildStore(root: root.path, compatibilityID: String(repeating: "7", count: 64))
        try FileManager.default.createSymbolicLink(at: store.directory, withDestinationURL: outside)

        #expect(throws: PreparedCacheError.unsafeCachePath) { try store.reset() }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Prepared state round trips through the compatibility root")
    func stateRoundTrips() throws {
        let root = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(
            UUID().uuidString)
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
            projectInputManifestSHA256: inventory.projectInputManifestSHA256,
            preparedInventorySHA256: try inventory.sha256
        )

        _ = try store.prepareDirectory()
        try store.save(state)

        let product = store.derivedDataURL.appendingPathComponent("Build/Products/App")
        try FileManager.default.createDirectory(
            at: product.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("compiled".utf8).write(to: product)
        let xctestrun = URL(fileURLWithPath: state.xctestrunPath)
        try Data("plist".utf8).write(to: xctestrun)
        chmod(xctestrun.path, 0o600)

        #expect(try store.load() == state)

        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.stateURL)) as? [String: Any])
        #expect(object["inventory"] == nil)
        #expect(
            Set(object.keys) == [
                "schemaVersion", "sandboxPath", "derivedDataPath", "xctestrunPath",
                "productManifestSHA256", "projectInputManifestSHA256", "preparedInventorySHA256",
            ])
        object["preparedInventorySHA256"] = "not-a-digest"
        try JSONSerialization.data(withJSONObject: object).write(to: store.stateURL)
        chmod(store.stateURL.path, 0o600)
        #expect(throws: PreparedBuildError.preparedBuildMissing) { try store.load() }

        try store.save(state)
        object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.stateURL)) as? [String: Any])
        object["projectInputManifestSHA256"] = "not-a-digest"
        try JSONSerialization.data(withJSONObject: object).write(to: store.stateURL)
        chmod(store.stateURL.path, 0o600)
        #expect(throws: PreparedBuildError.preparedBuildMissing) { try store.load() }

        #expect(throws: PreparedBuildError.inventoryMismatch) {
            try inventory.validate(
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
        #expect(
            try retry.validatedSourcePaths(
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

    func launch(
        executableURL: URL, arguments: [String], workingDirectoryURL: URL, timeout: Double
    ) async throws -> Int32 {
        0
    }

    func launchCapturing(_ request: ProcessRequest) async throws -> (exitCode: Int32, output: String) {
        self.request = request
        try bytes.write(to: output)
        return (exitCode, "failure")
    }
}
