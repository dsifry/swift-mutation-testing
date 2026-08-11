import Darwin
import Foundation
import Testing

@testable import SwiftMutationTesting

@Suite("Prepared build recovery", .serialized)
struct PreparedBuildRecoveryTests {
    @Test("Coordinator guards invalid modes and records absent recovery")
    func coordinatorGuardAndAbsentRecovery() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let launcher = PreparedCoordinatorLauncher()
        await #expect(throws: UsageError.self) {
            try await PreparedBuildCoordinator(
                configuration: makeRunnerConfiguration(projectType: .spm),
                options: .init(mode: .prepare),
                launcher: launcher
            ).prepare(makeRunnerInput(mutants: []))
        }
        await #expect(throws: UsageError.self) {
            try await PreparedBuildCoordinator(
                configuration: makeRunnerConfiguration(testTarget: nil),
                options: .init(mode: .target),
                launcher: launcher
            ).target(makeRunnerInput(mutants: []))
        }
        #expect(throws: UsageError.self) {
            try PreparedBuildCoordinator.recover(options: .init(mode: .recover), enableCustody: false)
        }

        let manifest = fixture.root.appendingPathComponent("absent-manifest.json")
        try Data("manifest".utf8).write(to: manifest)
        let evidence = fixture.root.appendingPathComponent("absent-evidence.json")
        try PreparedBuildCoordinator.recover(
            options: .init(
                mode: .recover,
                buildCacheRoot: fixture.root.path,
                compatibilityID: String(repeating: "f", count: 64),
                projectInputManifest: manifest.path,
                evidenceOutput: evidence.path,
                invocationNonce: "abcdefghijklmnopqrstuv"
            ), enableCustody: false)
        let receipt = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: evidence)) as? [String: Any])
        #expect(receipt["outcome"] as? String == "absent")

        let runtimeStore = PreparedBuildStore(
            root: fixture.root.path, compatibilityID: String(repeating: "e", count: 64))
        try runtimeStore.prepareDirectory()
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let runtimeCoordinator = PreparedBuildCoordinator(
            configuration: makeRunnerConfiguration(),
            options: .init(mode: .prepare, custodyFD: Int(descriptors[0])),
            launcher: XcodeProcessLauncher()
        )
        let possibleRuntime = try runtimeCoordinator.makeCustodyRuntime(store: runtimeStore)
        let runtime = try #require(possibleRuntime)
        defer { runtime.monitor.cancel() }
        #expect(PreparedBuildCoordinator.custodyIsQuiescent(runtime))
        #expect(runtimeCoordinator.activeRunRoot() == nil)
        #expect(runtimeCoordinator.commandLauncher(custodyRuntime: runtime) is XcodeProcessLauncher)
        let evidenceCoordinator = PreparedBuildCoordinator(
            configuration: makeRunnerConfiguration(),
            options: .init(mode: .prepare, evidenceOutput: evidence.path),
            launcher: XcodeProcessLauncher()
        )
        #expect(evidenceCoordinator.activeRunRoot()?.path == fixture.root.path)
        #expect(evidenceCoordinator.commandLauncher(custodyRuntime: nil) is XcodeProcessLauncher)
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try PreparedBuildCoordinator.canonicalSourceRoot("/missing") { _ in nil }
        }
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try PreparedBuildCoordinator.writeRecoveryEvidence(
                options: .init(
                    mode: .recover, evidenceOutput: fixture.root.appendingPathComponent("invalid-recovery.json").path),
                outcome: "failed",
                state: nil
            )
        }
        #expect(throws: PreparedBuildError.preparedBuildMissing) {
            try PreparedBuildCoordinator.requireXCTestRun(
                from: BuildArtifact(derivedDataPath: "/tmp", xctestrunURL: nil, plist: nil)
            )
        }
    }

    @Test("Coordinator records conservative builds, recovers cold, and reuses an empty target")
    func coordinatorPrepareIncrementalAndEmptyTarget() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        let project = fixture.root.appendingPathComponent("source-project")
        let projectFile = project.appendingPathComponent("App.xcodeproj/project.pbxproj")
        try FileManager.default.createDirectory(
            at: projectFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let projectBytes = Data("// project".utf8)
        try projectBytes.write(to: projectFile)
        chmod(projectFile.path, 0o644)
        let digest = ProjectInputManifest.sha256(projectBytes)
        let sourceFile = project.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: sourceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceBytes = Data("let enabled = true\n".utf8)
        try sourceBytes.write(to: sourceFile)
        chmod(sourceFile.path, 0o644)
        let sourceDigest = ProjectInputManifest.sha256(sourceBytes)
        let manifest = ProjectInputManifest(
            schemaVersion: 1,
            entries: [
                .init(
                    path: "App.xcodeproj/project.pbxproj",
                    mode: 0o644,
                    byteSize: projectBytes.count,
                    sha256: digest,
                    deterministicMTime: ProjectInputManifest.deterministicMTime(forSHA256: digest)
                ),
                .init(
                    path: "Sources/App.swift",
                    mode: 0o644,
                    byteSize: sourceBytes.count,
                    sha256: sourceDigest,
                    deterministicMTime: ProjectInputManifest.deterministicMTime(forSHA256: sourceDigest)
                ),
            ]
        )
        let manifestURL = fixture.root.appendingPathComponent("project-inputs.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let manifestDigest = ProjectInputManifest.sha256(try Data(contentsOf: manifestURL))
        let compatibilityID = String(repeating: "4", count: 64)
        let launcher = PreparedCoordinatorLauncher()
        let configuration = makeRunnerConfiguration(
            projectPath: project.path,
            projectType: .xcode(scheme: "App", destination: "platform=macOS"),
            testTarget: "AppTests/Empty"
        )
        let mutant = makeMutantDescriptor(
            id: "m0", filePath: sourceFile.path, isSchematizable: true
        )
        let input = makeRunnerInput(projectPath: project.path, mutants: [mutant])

        for (index, expectedFull, expectedIncremental) in [(0, 1, 0), (1, 1, 0)] {
            let evidence = fixture.root.appendingPathComponent("prepare-evidence-\(index).json")
            let coordinator = PreparedBuildCoordinator(
                configuration: configuration,
                options: .init(
                    mode: .prepare,
                    buildCacheRoot: fixture.root.path,
                    compatibilityID: compatibilityID,
                    projectInputManifest: manifestURL.path,
                    testEnumerationOutput: fixture.root.appendingPathComponent("tests-\(index).json").path,
                    mutantInventoryOutput: fixture.root.appendingPathComponent("inventory-\(index).json").path,
                    evidenceOutput: evidence.path,
                    custodyFD: 0,
                    invocationNonce: index == 1 ? nil : "abcdefghijklmnopqrstuv"
                ),
                launcher: launcher
            )
            do {
                try await coordinator.prepare(input)
            } catch {
                Issue.record("prepare iteration \(index) failed: \(error)")
                return
            }
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: evidence)) as? [String: Any])
            #expect(object["fullBuilds"] as? Int == expectedFull)
            #expect(object["incrementalBuilds"] as? Int == expectedIncremental)
        }

        let preparedStore = PreparedBuildStore(root: fixture.root.path, compatibilityID: compatibilityID)
        let rawState = try Data(contentsOf: preparedStore.stateURL)
        let stateObject = try #require(JSONSerialization.jsonObject(with: rawState) as? [String: Any])
        #expect(
            Set(stateObject.keys) == [
                "schemaVersion", "sandboxPath", "derivedDataPath", "xctestrunPath",
                "productManifestSHA256", "inventory",
            ])
        let recordedXCTestRun = try #require(stateObject["xctestrunPath"] as? String)
        #expect(FileManager.default.fileExists(atPath: recordedXCTestRun))
        let decodedState = try JSONDecoder().decode(PreparedBuildState.self, from: rawState)
        #expect(decodedState.schemaVersion == 1)
        #expect(decodedState.sandboxPath == preparedStore.sandboxURL.path)
        #expect(decodedState.derivedDataPath == preparedStore.derivedDataURL.path)
        #expect(
            CachePathGuard.isContained(
                URL(fileURLWithPath: decodedState.xctestrunPath), in: preparedStore.derivedDataURL))
        #expect(decodedState.productManifestSHA256.count == 64)
        #expect(decodedState.productManifestSHA256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        var stateMetadata = stat()
        #expect(lstat(preparedStore.stateURL.path, &stateMetadata) == 0)
        #expect(stateMetadata.st_mode & 0o777 == 0o600)
        var xctestrunMetadata = stat()
        #expect(lstat(recordedXCTestRun, &xctestrunMetadata) == 0)
        #expect(xctestrunMetadata.st_mode & S_IFMT == S_IFREG)
        #expect(xctestrunMetadata.st_nlink == 1)
        #expect(xctestrunMetadata.st_uid == getuid())
        try CachePathGuard.validateDirectory(fixture.root, containedIn: fixture.root)
        try CachePathGuard.validateDirectory(preparedStore.directory, containedIn: fixture.root)
        try CachePathGuard.validateRegularFile(preparedStore.stateURL, containedIn: preparedStore.directory)
        try CachePathGuard.validateNoSymlinkComponents(
            preparedStore.derivedDataURL, containedIn: preparedStore.directory)
        var derivedMetadata = stat()
        #expect(lstat(preparedStore.derivedDataURL.path, &derivedMetadata) == 0)
        #expect(derivedMetadata.st_uid == getuid())
        #expect(derivedMetadata.st_mode & S_IFMT == S_IFDIR)
        try CachePathGuard.validateNoSymlinkComponents(
            URL(fileURLWithPath: recordedXCTestRun), containedIn: preparedStore.derivedDataURL)
        let state = try preparedStore.load()
        let selection = MutantSelectionManifest(
            schemaVersion: 1,
            projectInputManifestSHA256: manifestDigest,
            preparedInventorySHA256: try state.inventory.sha256,
            selector: "AppTests/Empty",
            runOrdinal: 0,
            attemptOrdinal: 0,
            ownedSourcePaths: []
        )
        let selectionURL = fixture.root.appendingPathComponent("selection.json")
        try JSONEncoder().encode(selection).write(to: selectionURL)
        func targetOptions(manifest: URL = manifestURL, selection: URL = selectionURL) -> ParsedArguments.CacheOptions {
            .init(
                mode: .target,
                buildCacheRoot: fixture.root.path,
                compatibilityID: compatibilityID,
                projectInputManifest: manifest.path,
                mutantSelectionManifest: selection.path,
                custodyFD: 0,
                invocationNonce: "abcdefghijklmnopqrstuv"
            )
        }
        let product = URL(fileURLWithPath: state.derivedDataPath).appendingPathComponent("Build/Products/App")
        try Data("tampered".utf8).write(to: product)
        await #expect(throws: PreparedCacheError.productManifestMismatch) {
            try await PreparedBuildCoordinator(
                configuration: configuration, options: targetOptions(), launcher: launcher
            ).target(input)
        }
        let mismatchRecoveryEvidence = fixture.root.appendingPathComponent("prepare-after-product-mismatch.json")
        try await PreparedBuildCoordinator(
            configuration: configuration,
            options: .init(
                mode: .prepare,
                buildCacheRoot: fixture.root.path,
                compatibilityID: compatibilityID,
                projectInputManifest: manifestURL.path,
                testEnumerationOutput: fixture.root.appendingPathComponent("tests-after-product-mismatch.json").path,
                mutantInventoryOutput: fixture.root.appendingPathComponent("inventory-after-product-mismatch.json")
                    .path,
                evidenceOutput: mismatchRecoveryEvidence.path,
                custodyFD: 0,
                invocationNonce: "abcdefghijklmnopqrstuv"
            ),
            launcher: launcher
        ).prepare(input)
        #expect(try Data(contentsOf: product) == Data("compiled".utf8))
        let mismatchRecoveryReceipt = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: mismatchRecoveryEvidence)) as? [String: Any]
        )
        #expect(mismatchRecoveryReceipt["outcome"] as? String == "ready")
        #expect(mismatchRecoveryReceipt["fullBuilds"] as? Int == 1)

        let lockURL = preparedStore.directory.appendingPathComponent("engine.lock")
        let lockInode = try #require(CachePathGuard.metadata(at: lockURL)?.st_ino)
        let cacheStateURL = preparedStore.directory.appendingPathComponent("cache-state.json")
        var divergentCacheState = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: cacheStateURL)) as? [String: Any]
        )
        divergentCacheState["productManifestSHA256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: divergentCacheState).write(to: cacheStateURL)
        chmod(cacheStateURL.path, 0o600)
        let divergentEvidence = fixture.root.appendingPathComponent("prepare-after-journal-mismatch.json")
        try await PreparedBuildCoordinator(
            configuration: configuration,
            options: .init(
                mode: .prepare,
                buildCacheRoot: fixture.root.path,
                compatibilityID: compatibilityID,
                projectInputManifest: manifestURL.path,
                testEnumerationOutput: fixture.root.appendingPathComponent("tests-after-journal-mismatch.json").path,
                mutantInventoryOutput: fixture.root.appendingPathComponent("inventory-after-journal-mismatch.json")
                    .path,
                evidenceOutput: divergentEvidence.path,
                custodyFD: 0,
                invocationNonce: "abcdefghijklmnopqrstuv"
            ),
            launcher: launcher
        ).prepare(input)
        #expect(CachePathGuard.metadata(at: lockURL)?.st_ino == lockInode)
        let repairedProduct = try PreparedBuildStore(root: fixture.root.path, compatibilityID: compatibilityID).load()
            .productManifestSHA256
        let actualProduct = try RetainedProductManifest.sha256(derivedDataURL: preparedStore.derivedDataURL)
        #expect(repairedProduct == actualProduct)

        let changedManifest = fixture.root.appendingPathComponent("changed-manifest.json")
        try Data("changed".utf8).write(to: changedManifest)
        await #expect(throws: PreparedBuildError.inventoryMismatch) {
            try await PreparedBuildCoordinator(
                configuration: configuration,
                options: targetOptions(manifest: changedManifest),
                launcher: launcher
            ).target(input)
        }

        let invalidSelection = fixture.root.appendingPathComponent("invalid-selection.json")
        try Data("invalid".utf8).write(to: invalidSelection)
        await #expect(throws: (any Error).self) {
            try await PreparedBuildCoordinator(
                configuration: configuration,
                options: targetOptions(selection: invalidSelection),
                launcher: launcher
            ).target(input)
        }
        let mismatchedSelection = fixture.root.appendingPathComponent("mismatched-selection.json")
        try JSONEncoder().encode(
            MutantSelectionManifest(
                schemaVersion: 1,
                projectInputManifestSHA256: String(repeating: "0", count: 64),
                preparedInventorySHA256: try state.inventory.sha256,
                selector: selection.selector,
                runOrdinal: 0,
                attemptOrdinal: 0,
                ownedSourcePaths: []
            )
        ).write(to: mismatchedSelection)
        await #expect(throws: PreparedBuildError.selectionMismatch) {
            try await PreparedBuildCoordinator(
                configuration: configuration,
                options: targetOptions(selection: mismatchedSelection),
                launcher: launcher
            ).target(input)
        }
        let wrongSelector = fixture.root.appendingPathComponent("wrong-selector.json")
        try JSONEncoder().encode(
            MutantSelectionManifest(
                schemaVersion: 1,
                projectInputManifestSHA256: manifestDigest,
                preparedInventorySHA256: try state.inventory.sha256,
                selector: "OtherTests",
                runOrdinal: 0,
                attemptOrdinal: 0,
                ownedSourcePaths: []
            )
        ).write(to: wrongSelector)
        await #expect(throws: PreparedBuildError.selectionMismatch) {
            try await PreparedBuildCoordinator(
                configuration: configuration,
                options: targetOptions(selection: wrongSelector),
                launcher: launcher
            ).target(input)
        }
        let targetEvidence = fixture.root.appendingPathComponent("target-evidence.json")
        let results = try await PreparedBuildCoordinator(
            configuration: configuration,
            options: .init(
                mode: .target,
                buildCacheRoot: fixture.root.path,
                compatibilityID: compatibilityID,
                projectInputManifest: manifestURL.path,
                mutantSelectionManifest: selectionURL.path,
                evidenceOutput: targetEvidence.path,
                custodyFD: 0,
                invocationNonce: "abcdefghijklmnopqrstuv"
            ),
            launcher: launcher
        ).target(input)
        #expect(results.isEmpty)
        let targetObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: targetEvidence)) as? [String: Any])
        #expect(targetObject["outcome"] as? String == "reused")
        let nonceFreeEvidence = fixture.root.appendingPathComponent("target-no-nonce-evidence.json")
        _ = try await PreparedBuildCoordinator(
            configuration: configuration,
            options: .init(
                mode: .target,
                buildCacheRoot: fixture.root.path,
                compatibilityID: compatibilityID,
                projectInputManifest: manifestURL.path,
                mutantSelectionManifest: selectionURL.path,
                evidenceOutput: nonceFreeEvidence.path,
                custodyFD: 0
            ),
            launcher: launcher
        ).target(input)

        let nonemptySelection = MutantSelectionManifest(
            schemaVersion: 1,
            projectInputManifestSHA256: manifestDigest,
            preparedInventorySHA256: try state.inventory.sha256,
            selector: "AppTests/Empty",
            runOrdinal: 1,
            attemptOrdinal: 0,
            ownedSourcePaths: ["Sources/App.swift"]
        )
        let nonemptySelectionURL = fixture.root.appendingPathComponent("selection-nonempty.json")
        try JSONEncoder().encode(nonemptySelection).write(to: nonemptySelectionURL)
        let nonemptyEvidence = fixture.root.appendingPathComponent("target-nonempty-evidence.json")
        let nonemptyResults = try await PreparedBuildCoordinator(
            configuration: configuration,
            options: .init(
                mode: .target,
                buildCacheRoot: fixture.root.path,
                compatibilityID: compatibilityID,
                projectInputManifest: manifestURL.path,
                mutantSelectionManifest: nonemptySelectionURL.path,
                evidenceOutput: nonemptyEvidence.path,
                custodyFD: 0,
                invocationNonce: "abcdefghijklmnopqrstuv"
            ),
            launcher: launcher
        ).target(input)
        #expect(nonemptyResults.count == 1)
        let xctestrun = URL(fileURLWithPath: state.xctestrunPath)
        let validXCTestRun = try Data(contentsOf: xctestrun)
        try Data("invalid plist".utf8).write(to: xctestrun)
        let storeForInvalidPlist = PreparedBuildStore(root: fixture.root.path, compatibilityID: compatibilityID)
        let invalidProductDigest = try RetainedProductManifest.sha256(
            derivedDataURL: storeForInvalidPlist.derivedDataURL)
        try storeForInvalidPlist.save(
            .init(
                sandboxPath: state.sandboxPath,
                derivedDataPath: state.derivedDataPath,
                xctestrunPath: state.xctestrunPath,
                productManifestSHA256: invalidProductDigest,
                inventory: state.inventory
            ))
        try CacheRecovery(identityDirectory: storeForInvalidPlist.directory, collectionRoot: fixture.root)
            .markReady(productManifestSHA256: invalidProductDigest)
        let invalidPlistEvidence = fixture.root.appendingPathComponent("target-invalid-plist-evidence.json")
        await #expect(throws: PreparedBuildError.preparedBuildMissing) {
            try await PreparedBuildCoordinator(
                configuration: configuration,
                options: .init(
                    mode: .target,
                    buildCacheRoot: fixture.root.path,
                    compatibilityID: compatibilityID,
                    projectInputManifest: manifestURL.path,
                    mutantSelectionManifest: nonemptySelectionURL.path,
                    evidenceOutput: invalidPlistEvidence.path,
                    custodyFD: 0,
                    invocationNonce: nil
                ),
                launcher: launcher
            ).target(input)
        }
        try validXCTestRun.write(to: xctestrun)
        try storeForInvalidPlist.save(state)
        try CacheRecovery(identityDirectory: storeForInvalidPlist.directory, collectionRoot: fixture.root)
            .markReady(productManifestSHA256: state.productManifestSHA256)

        try await PreparedBuildCoordinator(
            configuration: configuration,
            options: .init(
                mode: .prepare,
                buildCacheRoot: fixture.root.path,
                compatibilityID: compatibilityID,
                projectInputManifest: manifestURL.path,
                testEnumerationOutput: fixture.root.appendingPathComponent("tests-no-evidence.json").path,
                mutantInventoryOutput: fixture.root.appendingPathComponent("inventory-no-evidence.json").path,
                custodyFD: 0,
                invocationNonce: "abcdefghijklmnopqrstuv"
            ),
            launcher: launcher
        ).prepare(input)

        launcher.enumerationExitCode = 1
        let failedEvidence = fixture.root.appendingPathComponent("prepare-failed-evidence.json")
        await #expect(throws: BuildError.self) {
            try await PreparedBuildCoordinator(
                configuration: configuration,
                options: .init(
                    mode: .prepare,
                    buildCacheRoot: fixture.root.path,
                    compatibilityID: compatibilityID,
                    projectInputManifest: manifestURL.path,
                    testEnumerationOutput: fixture.root.appendingPathComponent("tests-failed.json").path,
                    mutantInventoryOutput: fixture.root.appendingPathComponent("inventory-failed.json").path,
                    evidenceOutput: failedEvidence.path,
                    custodyFD: 0,
                    invocationNonce: "abcdefghijklmnopqrstuv"
                ),
                launcher: launcher
            ).prepare(input)
        }
        let failed = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: failedEvidence)) as? [String: Any])
        #expect(failed["outcome"] as? String == "failed")
        #expect(failed["fullBuilds"] as? Int == 1)
        #expect(failed["incrementalBuilds"] as? Int == 0)

        let recoveredEvidence = fixture.root.appendingPathComponent("recovered-evidence.json")
        let recoveryOptions = ParsedArguments.CacheOptions(
            mode: .recover,
            buildCacheRoot: fixture.root.path,
            compatibilityID: compatibilityID,
            projectInputManifest: manifestURL.path,
            evidenceOutput: recoveredEvidence.path,
            custodyFD: 0,
            invocationNonce: "abcdefghijklmnopqrstuv"
        )
        try PreparedBuildCoordinator.recover(options: recoveryOptions, enableCustody: false)
        let recoveredReceipt = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: recoveredEvidence)) as? [String: Any]
        )
        #expect(recoveredReceipt["outcome"] as? String == "recovered")

        launcher.enumerationExitCode = 0
        let postRecoveryEvidence = fixture.root.appendingPathComponent("post-recovery-prepare.json")
        try await PreparedBuildCoordinator(
            configuration: configuration,
            options: .init(
                mode: .prepare,
                buildCacheRoot: fixture.root.path,
                compatibilityID: compatibilityID,
                projectInputManifest: manifestURL.path,
                testEnumerationOutput: fixture.root.appendingPathComponent("post-recovery-tests.json").path,
                mutantInventoryOutput: fixture.root.appendingPathComponent("post-recovery-inventory.json").path,
                evidenceOutput: postRecoveryEvidence.path,
                custodyFD: 0,
                invocationNonce: "abcdefghijklmnopqrstuv"
            ),
            launcher: launcher
        ).prepare(input)
        let postRecovery = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: postRecoveryEvidence)) as? [String: Any]
        )
        #expect(postRecovery["fullBuilds"] as? Int == 1)
        #expect(postRecovery["incrementalBuilds"] as? Int == 0)
        let latestState = try PreparedBuildStore(root: fixture.root.path, compatibilityID: compatibilityID).load()
        try CacheRecovery(
            identityDirectory: fixture.root.appendingPathComponent(compatibilityID),
            collectionRoot: fixture.root
        ).markReady(productManifestSHA256: latestState.productManifestSHA256)
        var recoveryDescriptors: [Int32] = [0, 0]
        #expect(pipe(&recoveryDescriptors) == 0)
        defer {
            close(recoveryDescriptors[0])
            close(recoveryDescriptors[1])
        }
        let readyEvidence = fixture.root.appendingPathComponent("ready-recovery-evidence.json")
        try PreparedBuildCoordinator.recover(
            options: .init(
                mode: .recover,
                buildCacheRoot: fixture.root.path,
                compatibilityID: compatibilityID,
                projectInputManifest: manifestURL.path,
                evidenceOutput: readyEvidence.path,
                custodyFD: Int(recoveryDescriptors[0]),
                invocationNonce: "abcdefghijklmnopqrstuv"
            ), enableCustody: true)
        let readyReceipt = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: readyEvidence)) as? [String: Any]
        )
        #expect(readyReceipt["outcome"] as? String == "ready")
        try PreparedBuildCoordinator.recover(
            options: .init(
                mode: .recover,
                buildCacheRoot: fixture.root.path,
                compatibilityID: compatibilityID,
                projectInputManifest: manifestURL.path,
                custodyFD: 0,
                invocationNonce: "abcdefghijklmnopqrstuv"
            ), enableCustody: false)

        launcher.omitBuildProducts = true
        let missingProductEvidence = fixture.root.appendingPathComponent("missing-product-evidence.json")
        await #expect(throws: BuildError.xctestrunNotFound) {
            try await PreparedBuildCoordinator(
                configuration: configuration,
                options: .init(
                    mode: .prepare,
                    buildCacheRoot: fixture.root.path,
                    compatibilityID: String(repeating: "3", count: 64),
                    projectInputManifest: manifestURL.path,
                    testEnumerationOutput: fixture.root.appendingPathComponent("missing-tests.json").path,
                    mutantInventoryOutput: fixture.root.appendingPathComponent("missing-inventory.json").path,
                    evidenceOutput: missingProductEvidence.path,
                    custodyFD: 0,
                    invocationNonce: nil
                ),
                launcher: launcher
            ).prepare(input)
        }
        let failedBeforeArtifact = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: missingProductEvidence)) as? [String: Any]
        )
        #expect(failedBeforeArtifact["fullBuilds"] as? Int == 1)
        #expect(failedBeforeArtifact["incrementalBuilds"] as? Int == 0)
    }

    @Test("Retained product manifest binds canonical compiled product bytes")
    func retainedProductManifestBinding() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let products = fixture.identityA.appendingPathComponent("DerivedData/Build/Products")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        let binary = products.appendingPathComponent("App.app/App")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary-a".utf8).write(to: binary)
        chmod(binary.path, 0o755)
        let xctestrun = products.appendingPathComponent("App.xctestrun")
        try Data("plist".utf8).write(to: xctestrun)
        chmod(xctestrun.path, 0o644)

        let first = try RetainedProductManifest.sha256(
            derivedDataURL: fixture.identityA.appendingPathComponent("DerivedData"))
        let second = try RetainedProductManifest.sha256(
            derivedDataURL: fixture.identityA.appendingPathComponent("DerivedData"))
        #expect(first == second)
        try Data("binary-b".utf8).write(to: binary)
        #expect(
            try RetainedProductManifest.sha256(derivedDataURL: fixture.identityA.appendingPathComponent("DerivedData"))
                != first)
        #expect(throws: PreparedCacheError.productManifestMismatch) {
            try RetainedProductManifest.sha256(
                derivedDataURL: fixture.identityA.appendingPathComponent("DerivedData"),
                metadataProvider: { url in
                    url.lastPathComponent == "Products" ? nil : CachePathGuard.metadata(at: url)
                }
            )
        }
        #expect(RetainedProductManifest.metadata(at: fixture.root.appendingPathComponent("missing")) == nil)
    }

    @Test("Recovery and retained products fail closed for malformed state and filesystem attacks")
    func recoveryFailureBranches() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let recovery = CacheRecovery(identityDirectory: fixture.identityA, collectionRoot: fixture.root)
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try recovery.markReady(productManifestSHA256: "bad")
        }
        #expect(throws: (any Error).self) {
            try recovery.recordMutationOrTestFailure()
        }
        #expect(!(RetainedArtifactClass.derivedData < .derivedData))
        let state = fixture.identityA.appendingPathComponent("cache-state.json")
        try Data("not-json".utf8).write(to: state)
        chmod(state.path, 0o600)
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try recovery.recover(expectedProductManifestSHA256: fixture.productA)
        }
        try Data("{\"schemaVersion\":2,\"phase\":\"dirty\"}".utf8).write(to: state)
        chmod(state.path, 0o600)
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try recovery.recover(expectedProductManifestSHA256: fixture.productA)
        }
        try Data("unexpected".utf8).write(to: fixture.identityA.appendingPathComponent("unexpected.txt"))
        #expect(throws: PreparedCacheError.invalidCacheState) { try recovery.inspectRetainedArtifacts() }
        try FileManager.default.removeItem(at: fixture.identityA.appendingPathComponent("unexpected.txt"))

        let retention = fixture.identityA.appendingPathComponent("retention.json")
        try Data("{\"schemaVersion\":2,\"lastUsedAt\":0}".utf8).write(to: retention)
        chmod(retention.path, 0o600)
        #expect(throws: PreparedCacheError.invalidCacheState) { try recovery.retentionLastUsedAt() }
        try Data("{\"schemaVersion\":1,\"lastUsedAt\":\"nope\"}".utf8).write(to: retention)
        #expect(throws: PreparedCacheError.invalidCacheState) { try recovery.retentionLastUsedAt() }

        let sourceTarget = fixture.root.appendingPathComponent("outside-source")
        try Data("raw".utf8).write(to: sourceTarget)
        let sourceLink = fixture.identityA.appendingPathComponent("raw-link")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: sourceTarget)
        #expect(throws: PreparedCacheError.unsafeCachePath) { try recovery.scrubAfterCommand() }
        try FileManager.default.removeItem(at: sourceLink)

        let derived = fixture.identityA.appendingPathComponent("DerivedData")
        #expect(throws: PreparedCacheError.productManifestMismatch) {
            try RetainedProductManifest.sha256(derivedDataURL: derived)
        }
        let products = derived.appendingPathComponent("Build/Products")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        #expect(throws: PreparedCacheError.productManifestMismatch) {
            try RetainedProductManifest.sha256(derivedDataURL: derived)
        }
        #expect(throws: PreparedCacheError.productManifestMismatch) {
            try RetainedProductManifest.sha256(derivedDataURL: derived, makeEnumerator: { _ in nil })
        }
        let outside = fixture.root.appendingPathComponent("outside-product")
        try Data("product".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: products.appendingPathComponent("linked"), withDestinationURL: outside)
        #expect(throws: PreparedCacheError.productManifestMismatch) {
            try RetainedProductManifest.sha256(derivedDataURL: derived)
        }

        let emptyFixture = try RecoveryFixture()
        defer { emptyFixture.cleanup() }
        try emptyFixture.makeIdentity(emptyFixture.identityA)
        let emptyRecovery = CacheRecovery(identityDirectory: emptyFixture.identityA, collectionRoot: emptyFixture.root)
        #expect(try emptyRecovery.inspectRetainedArtifacts().isEmpty)
        try emptyRecovery.markDirty()
        #expect(throws: PreparedCacheError.invalidCacheState) { try emptyRecovery.recordMutationOrTestFailure() }

        let failingWrite = CacheRecovery(
            identityDirectory: emptyFixture.identityA,
            collectionRoot: emptyFixture.root,
            createPrivateFile: { _, _ in false }
        )
        #expect(throws: PreparedCacheError.unsafeCachePath) { try failingWrite.markDirty() }
        try FileManager.default.removeItem(at: emptyFixture.identityA.appendingPathComponent("cache-state.json"))
        let stateDirectory = emptyFixture.identityA.appendingPathComponent("cache-state.json")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: false)
        try Data("occupied".utf8).write(to: stateDirectory.appendingPathComponent("child"))
        #expect(throws: PreparedCacheError.unsafeCachePath) { try emptyRecovery.markDirty() }
        try FileManager.default.removeItem(at: products.appendingPathComponent("linked"))
        let product = products.appendingPathComponent("product")
        try Data("product".utf8).write(to: product)
        let alias = products.appendingPathComponent("alias")
        #expect(linkat(AT_FDCWD, product.path, AT_FDCWD, alias.path, 0) == 0)
        #expect(throws: PreparedCacheError.productManifestMismatch) {
            try RetainedProductManifest.sha256(derivedDataURL: derived)
        }
    }

    @Test("Recovery journals replace atomically and sync file plus parent")
    func recoveryJournalDurability() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)

        let syncCalls = LockedCounter()
        let durable = CacheRecovery(
            identityDirectory: fixture.identityA,
            collectionRoot: fixture.root,
            syncDescriptor: { _ in
                syncCalls.increment()
                return 0
            }
        )
        try durable.markDirty(previousReadyProductManifestSHA256: fixture.productA)
        #expect(syncCalls.value == 2)

        let stateURL = fixture.identityA.appendingPathComponent("cache-state.json")
        let prior = try Data(contentsOf: stateURL)
        let replacementFailure = CacheRecovery(
            identityDirectory: fixture.identityA,
            collectionRoot: fixture.root,
            replaceJournal: { _, _ in
                errno = EIO
                return -1
            }
        )
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try replacementFailure.markReady(productManifestSHA256: fixture.productB)
        }
        #expect(try Data(contentsOf: stateURL) == prior)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.identityA.path)
                .filter { $0.hasPrefix(".cache-state.json.") }.isEmpty
        )

        let syncFailure = CacheRecovery(
            identityDirectory: fixture.identityA,
            collectionRoot: fixture.root,
            syncDescriptor: { _ in
                errno = EIO
                return -1
            }
        )
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try syncFailure.writeRetentionMetadata(lastUsedAt: .distantPast)
        }
        let openFileFailure = CacheRecovery(
            identityDirectory: fixture.identityA,
            collectionRoot: fixture.root,
            openJournalFile: { _ in -1 }
        )
        #expect(throws: PreparedCacheError.unsafeCachePath) { try openFileFailure.markDirty() }
        let openDirectoryFailure = CacheRecovery(
            identityDirectory: fixture.identityA,
            collectionRoot: fixture.root,
            openJournalDirectory: { _ in -1 }
        )
        #expect(throws: PreparedCacheError.unsafeCachePath) { try openDirectoryFailure.markDirty() }
        let parentSyncCalls = LockedCounter()
        let parentSyncFailure = CacheRecovery(
            identityDirectory: fixture.identityA,
            collectionRoot: fixture.root,
            syncDescriptor: { _ in
                parentSyncCalls.increment()
                return parentSyncCalls.value == 1 ? 0 : -1
            }
        )
        #expect(throws: PreparedCacheError.unsafeCachePath) { try parentSyncFailure.markDirty() }
    }

    @Test("Closed project manifests materialize identical private trees across source roots")
    func projectInputMaterializationIsStable() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        try fixture.makeIdentity(fixture.identityB)
        let sourceA = fixture.root.appendingPathComponent("source-a")
        let sourceB = fixture.root.appendingPathComponent("source-b")
        try FileManager.default.createDirectory(at: sourceA, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: sourceB, withIntermediateDirectories: false)
        let bytes = Data("let enabled = true\n".utf8)
        for source in [sourceA, sourceB] {
            let file = source.appendingPathComponent("Sources/Nested/Feature.swift")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
            chmod(file.path, 0o644)
        }
        let digest = ProjectInputManifest.sha256(bytes)
        let manifest = ProjectInputManifest(
            schemaVersion: 1,
            entries: [
                .init(
                    path: "Sources/Nested/Feature.swift",
                    mode: 0o644,
                    byteSize: bytes.count,
                    sha256: digest,
                    deterministicMTime: ProjectInputManifest.deterministicMTime(forSHA256: digest)
                )
            ]
        )
        let manifestURL = fixture.root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)

        let outputA = try ProjectInputMaterializer(
            sourceRoot: sourceA,
            identityDirectory: fixture.identityA,
            collectionRoot: fixture.root
        ).materialize(manifestAt: manifestURL)
        let outputB = try ProjectInputMaterializer(
            sourceRoot: sourceB,
            identityDirectory: fixture.identityB,
            collectionRoot: fixture.root
        ).materialize(manifestAt: manifestURL)
        let fileA = outputA.appendingPathComponent("Sources/Nested/Feature.swift")
        let fileB = outputB.appendingPathComponent("Sources/Nested/Feature.swift")
        #expect(try Data(contentsOf: fileA) == bytes)
        #expect(try Data(contentsOf: fileB) == bytes)
        #expect(
            try FileManager.default.attributesOfItem(atPath: fileA.path)[.modificationDate] as? Date
                == FileManager.default.attributesOfItem(atPath: fileB.path)[.modificationDate] as? Date)
        #expect(
            try FileManager.default.attributesOfItem(atPath: outputA.appendingPathComponent("Sources").path)[
                .posixPermissions] as? Int == 0o700)
        #expect(
            try FileManager.default.attributesOfItem(atPath: outputA.appendingPathComponent("Sources/Nested").path)[
                .posixPermissions] as? Int == 0o700)
    }

    @Test("Project materialization rejects forbidden paths, symlinks, and manifest drift")
    func projectInputMaterializationFailsClosed() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let source = fixture.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let real = source.appendingPathComponent("real.swift")
        try Data("value".utf8).write(to: real)
        chmod(real.path, 0o644)
        let link = source.appendingPathComponent("linked.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let materializer = ProjectInputMaterializer(
            sourceRoot: source,
            identityDirectory: fixture.identityA,
            collectionRoot: fixture.root
        )

        for path in [".git/config", ".env", "linked.swift"] {
            let manifest = ProjectInputManifest(
                schemaVersion: 1,
                entries: [
                    .init(
                        path: path,
                        mode: 0o644,
                        byteSize: 5,
                        sha256: String(repeating: "a", count: 64),
                        deterministicMTime: 1
                    )
                ]
            )
            let manifestURL = fixture.root.appendingPathComponent("bad-\(UUID().uuidString).json")
            try JSONEncoder().encode(manifest).write(to: manifestURL)
            #expect(throws: PreparedCacheError.invalidProjectInputManifest) {
                try materializer.materialize(manifestAt: manifestURL)
            }
        }

        let bytes = try Data(contentsOf: real)
        let digest = ProjectInputManifest.sha256(bytes)
        let drifted = ProjectInputManifest(
            schemaVersion: 1,
            entries: [
                .init(
                    path: "real.swift",
                    mode: 0o644,
                    byteSize: bytes.count,
                    sha256: digest,
                    deterministicMTime: ProjectInputManifest.deterministicMTime(forSHA256: digest)
                )
            ]
        )
        let driftURL = fixture.root.appendingPathComponent("drift.json")
        try JSONEncoder().encode(drifted).write(to: driftURL)
        try Data("changed".utf8).write(to: real)
        #expect(throws: PreparedCacheError.projectInputDrift) {
            try materializer.materialize(manifestAt: driftURL)
        }

        let realDirectory = source.appendingPathComponent("Real")
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false)
        let nested = realDirectory.appendingPathComponent("Nested.swift")
        let nestedBytes = Data("nested".utf8)
        try nestedBytes.write(to: nested)
        chmod(nested.path, 0o644)
        let linkedDirectory = source.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: realDirectory)
        let nestedDigest = ProjectInputManifest.sha256(nestedBytes)
        let intermediateLinkManifest = ProjectInputManifest(
            schemaVersion: 1,
            entries: [
                .init(
                    path: "Linked/Nested.swift",
                    mode: 0o644,
                    byteSize: nestedBytes.count,
                    sha256: nestedDigest,
                    deterministicMTime: ProjectInputManifest.deterministicMTime(forSHA256: nestedDigest)
                )
            ]
        )
        let intermediateLinkURL = fixture.root.appendingPathComponent("intermediate-link.json")
        try JSONEncoder().encode(intermediateLinkManifest).write(to: intermediateLinkURL)
        #expect(throws: PreparedCacheError.invalidProjectInputManifest) {
            try materializer.materialize(manifestAt: intermediateLinkURL)
        }
    }

    @Test("Project manifests reject malformed metadata and unsafe overrides")
    func projectInputManifestBranchTable() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let source = fixture.root.appendingPathComponent("branch-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("switch value {\ncase \"a\":\ncase \"b\": print(1)\n}\n".utf8)
        try bytes.write(to: file)
        chmod(file.path, 0o644)
        let digest = ProjectInputManifest.sha256(bytes)
        let mtime = ProjectInputManifest.deterministicMTime(forSHA256: digest)
        let materializer = ProjectInputMaterializer(
            sourceRoot: source,
            identityDirectory: fixture.identityA,
            collectionRoot: fixture.root
        )
        func write(_ object: Any) throws -> URL {
            let url = fixture.root.appendingPathComponent("branches-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            return url
        }
        func entry(
            path: String = "Sources/App.swift", mode: Int = 0o644, size: Int? = nil,
            hash: String? = nil, time: Int64? = nil
        ) -> [String: Any] {
            [
                "path": path, "mode": mode, "byteSize": size ?? bytes.count,
                "sha256": hash ?? digest, "deterministicMTime": time ?? mtime,
            ]
        }
        let invalidRoots: [[String: Any]] = [
            ["schemaVersion": 2, "entries": [entry()]],
            ["schemaVersion": 1, "entries": []],
            ["schemaVersion": 1, "entries": [entry()], "unknown": true],
            ["schemaVersion": 1, "entries": [["path": "Sources/App.swift"]]],
            ["schemaVersion": 1, "entries": [entry(path: "/absolute")]],
            ["schemaVersion": 1, "entries": [entry(path: "a\\b")]],
            ["schemaVersion": 1, "entries": [entry(path: "a/../b")]],
            ["schemaVersion": 1, "entries": [entry(path: "a//b")]],
            ["schemaVersion": 1, "entries": [entry(path: "cert.p12")]],
            ["schemaVersion": 1, "entries": [entry(mode: 0o666)]],
            ["schemaVersion": 1, "entries": [entry(size: -1)]],
            ["schemaVersion": 1, "entries": [entry(hash: "ABC")]],
            ["schemaVersion": 1, "entries": [entry(time: 0)]],
            ["schemaVersion": 1, "entries": [entry(path: "z"), entry(path: "a")]],
        ]
        for object in invalidRoots {
            let url = try write(object)
            #expect(throws: PreparedCacheError.invalidProjectInputManifest) {
                try materializer.materialize(manifestAt: url)
            }
        }
        let invalidJSON = fixture.root.appendingPathComponent("invalid-json")
        try Data("not json".utf8).write(to: invalidJSON)
        #expect(throws: PreparedCacheError.invalidProjectInputManifest) {
            try materializer.materialize(manifestAt: invalidJSON)
        }

        let valid = try write(["schemaVersion": 1, "entries": [entry()]])
        #expect(ProjectInputMaterializer.isForbidden(""))
        try ProjectInputMaterializer.requireNoUnusedOverrides([:])
        #expect(throws: PreparedCacheError.invalidProjectInputManifest) {
            try ProjectInputMaterializer.requireNoUnusedOverrides(["Sources/Missing.swift": ""])
        }
        let sibling = source.appendingPathComponent("Sources/B.swift")
        try bytes.write(to: sibling)
        chmod(sibling.path, 0o644)
        let directoryPreparations = LockedCounter()
        let cachedDirectoryMaterializer = ProjectInputMaterializer(
            sourceRoot: source,
            identityDirectory: fixture.identityA,
            collectionRoot: fixture.root,
            didPrepareOutputDirectory: { _ in directoryPreparations.increment() }
        )
        let siblingManifest = try write([
            "schemaVersion": 1,
            "entries": [entry(), entry(path: "Sources/B.swift")],
        ])
        _ = try cachedDirectoryMaterializer.materialize(manifestAt: siblingManifest)
        #expect(directoryPreparations.value == 1)

        let externalDirectory = fixture.root.appendingPathComponent("external-materialization")
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: false)
        chmod(externalDirectory.path, 0o700)
        let entryCounter = LockedCounter()
        let swappedDirectoryMaterializer = ProjectInputMaterializer(
            sourceRoot: source,
            identityDirectory: fixture.identityA,
            collectionRoot: fixture.root,
            willMaterializeEntry: { _ in
                entryCounter.increment()
                guard entryCounter.value == 2 else { return }
                let directory = fixture.identityA.appendingPathComponent("project/Sources")
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.createSymbolicLink(
                    at: directory, withDestinationURL: externalDirectory)
            }
        )
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try swappedDirectoryMaterializer.materialize(manifestAt: siblingManifest)
        }
        #expect(!FileManager.default.fileExists(atPath: externalDirectory.appendingPathComponent("B.swift").path))

        let override = SchematizedFile(
            originalPath: file.path, schematizedContent: String(decoding: bytes, as: UTF8.self))
        let project = try materializer.materialize(
            manifestAt: valid,
            schematizedFiles: [override],
            supportFileContent: SchematizationStage.supportFileContent
        )
        let output = try String(contentsOf: project.appendingPathComponent("Sources/App.swift"), encoding: .utf8)
        #expect(output.contains("break"))
        #expect(output.contains("nonisolated(unsafe) var __swiftMutationTestingID"))
        let outputMetadata = try #require(
            CachePathGuard.metadata(at: project.appendingPathComponent("Sources/App.swift")))
        #expect(outputMetadata.st_mode & 0o777 == 0o644)
        #expect(outputMetadata.st_mtimespec.tv_sec == mtime)
        let missingMaterializedTarget = ProjectInputMaterializer(
            sourceRoot: source,
            identityDirectory: fixture.identityA,
            collectionRoot: fixture.root,
            outputFileExists: { _ in false }
        )
        #expect(throws: PreparedCacheError.invalidProjectInputManifest) {
            try missingMaterializedTarget.materialize(
                manifestAt: valid,
                schematizedFiles: [override],
                supportFileContent: "support"
            )
        }
        let noBreakOverride = SchematizedFile(
            originalPath: file.path,
            schematizedContent: "switch value {\ncase \"a\":\n    print(value)\n}"
        )
        _ = try materializer.materialize(manifestAt: valid, schematizedFiles: [noBreakOverride])
        #expect(throws: PreparedCacheError.invalidProjectInputManifest) {
            try materializer.materialize(manifestAt: valid, schematizedFiles: [override, override])
        }
        #expect(throws: PreparedCacheError.invalidProjectInputManifest) {
            try materializer.materialize(
                manifestAt: valid,
                schematizedFiles: [
                    .init(
                        originalPath: fixture.root.appendingPathComponent("outside.swift").path,
                        schematizedContent: "")
                ]
            )
        }

        chmod(file.path, 0o600)
        #expect(throws: PreparedCacheError.projectInputDrift) {
            try materializer.materialize(manifestAt: valid)
        }

        chmod(file.path, 0o644)
        try Data(repeating: 0x78, count: bytes.count).write(to: file)
        #expect(throws: PreparedCacheError.projectInputDrift) {
            try materializer.materialize(manifestAt: valid)
        }

        try bytes.write(to: file)
        chmod(file.path, 0o644)
        let missingOverride = SchematizedFile(
            originalPath: source.appendingPathComponent("Sources/Missing.swift").path,
            schematizedContent: ""
        )
        #expect(throws: PreparedCacheError.invalidProjectInputManifest) {
            try materializer.materialize(
                manifestAt: valid,
                schematizedFiles: [missingOverride],
                supportFileContent: "support"
            )
        }
        #expect(throws: PreparedCacheError.invalidProjectInputManifest) {
            try materializer.materialize(
                manifestAt: valid,
                schematizedFiles: [missingOverride],
                supportFileContent: ""
            )
        }

        let unsafeProject = fixture.identityA.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: unsafeProject, withIntermediateDirectories: false)
        chmod(unsafeProject.path, 0o755)
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try materializer.materialize(manifestAt: valid)
        }
        try FileManager.default.removeItem(at: unsafeProject)

        let absentSource = ProjectInputMaterializer(
            sourceRoot: fixture.root.appendingPathComponent("absent-source"),
            identityDirectory: fixture.identityA,
            collectionRoot: fixture.root
        )
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try absentSource.materialize(manifestAt: valid)
        }
        #expect(ProjectInputManifest.deterministicMTime(forSHA256: "not-hex") == 946_684_800)
        let emptyIdentity = stat()
        #expect(throws: PreparedCacheError.projectInputDrift) {
            try materializer.assertDirectoryIdentity(emptyIdentity, at: source)
        }
        let failingCreator = ProjectInputMaterializer(
            sourceRoot: source,
            identityDirectory: fixture.identityA,
            collectionRoot: fixture.root,
            createOutputFile: { _, _, _ in false }
        )
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try failingCreator.materialize(manifestAt: valid)
        }

        let linked = source.appendingPathComponent("linked.swift")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: file)
        let linkEntry = entry(path: "linked.swift", size: bytes.count, hash: digest, time: mtime)
        #expect(throws: PreparedCacheError.invalidProjectInputManifest) {
            try materializer.materialize(manifestAt: try write(["schemaVersion": 1, "entries": [linkEntry]]))
        }
    }

    @Test("Tracked source names containing secret or credential remain valid inputs")
    func projectInputMaterializationAllowsDomainNames() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let source = fixture.root.appendingPathComponent("source")
        let file = source.appendingPathComponent("Sources/HumanReadableSecretCodec.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("struct HumanReadableSecretCodec {}\n".utf8)
        try bytes.write(to: file)
        chmod(file.path, 0o644)
        let digest = ProjectInputManifest.sha256(bytes)
        let manifest = ProjectInputManifest(
            schemaVersion: 1,
            entries: [
                .init(
                    path: "Sources/HumanReadableSecretCodec.swift",
                    mode: 0o644,
                    byteSize: bytes.count,
                    sha256: digest,
                    deterministicMTime: ProjectInputManifest.deterministicMTime(forSHA256: digest)
                )
            ]
        )
        let manifestURL = fixture.root.appendingPathComponent("domain-name.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)

        let output = try ProjectInputMaterializer(
            sourceRoot: source,
            identityDirectory: fixture.identityA,
            collectionRoot: fixture.root
        ).materialize(manifestAt: manifestURL)

        #expect(try Data(contentsOf: output.appendingPathComponent("Sources/HumanReadableSecretCodec.swift")) == bytes)
    }

    @Test("Engine lock is private, exclusive, and removed only by its owner")
    func engineLockLifecycle() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)

        let lock = try CacheLock(identityDirectory: fixture.identityA)
        let attributes = try FileManager.default.attributesOfItem(atPath: lock.url.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(throws: PreparedCacheError.lockBusy) {
            try CacheLock(identityDirectory: fixture.identityA)
        }

        try lock.release()
        try lock.release()
        let reacquired = try CacheLock(identityDirectory: fixture.identityA)
        try reacquired.release()

        // A lock inode left behind by a SIGKILL must not make the cache permanently busy.
        #expect(FileManager.default.fileExists(atPath: fixture.identityA.appendingPathComponent("engine.lock").path))
        let afterCrash = try CacheLock(identityDirectory: fixture.identityA)
        try afterCrash.release()

        do { _ = try CacheLock(identityDirectory: fixture.identityA) }
        #expect(FileManager.default.fileExists(atPath: fixture.identityA.appendingPathComponent("engine.lock").path))

        let closeRecorder = CloseRecorder()
        let brokenRelease = try CacheLock(
            identityDirectory: fixture.identityA,
            closeLock: { descriptor in closeRecorder.close(descriptor) }
        )
        #expect(throws: PreparedCacheError.unsafeCachePath) { try brokenRelease.release() }
        try brokenRelease.release()
        #expect(closeRecorder.count == 1)

        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheLock(
                identityDirectory: fixture.identityA,
                openLock: { path in
                    open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o000)
                })
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheLock(
                identityDirectory: fixture.identityA,
                openLock: { _ in
                    errno = EACCES
                    return -1
                })
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheLock(
                identityDirectory: fixture.identityA,
                openLock: { path in
                    _ = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
                    return open("/dev/null", O_RDONLY)
                })
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheLock(
                identityDirectory: fixture.identityA,
                acquireLock: { _ in
                    errno = EIO
                    return -1
                })
        }
    }

    @Test("Cold, warm, incremental, and incompatible identities preserve only verified products")
    func identityLifecycle() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }

        let cold = CacheRecovery(identityDirectory: fixture.identityA, collectionRoot: fixture.root)
        #expect(try cold.recover(expectedProductManifestSHA256: fixture.productA) == .absent)

        try fixture.makeIdentity(fixture.identityA)
        try cold.markDirty()
        #expect(try cold.recover(expectedProductManifestSHA256: fixture.productA) == .recovered)

        try fixture.makeMaterializedSource(in: fixture.identityA)
        try cold.markReady(productManifestSHA256: fixture.productA)
        #expect(try cold.recover(expectedProductManifestSHA256: fixture.productA) == .ready)
        #expect(!FileManager.default.fileExists(atPath: fixture.identityA.appendingPathComponent("project").path))

        // A narrow content change keeps the same compatibility identity.
        try cold.markDirty(previousReadyProductManifestSHA256: fixture.productA)
        try cold.markReady(productManifestSHA256: fixture.productB)
        #expect(try cold.recover(expectedProductManifestSHA256: fixture.productB) == .ready)

        // An incompatible graph/toolchain identity lives in a distinct directory.
        let incompatible = CacheRecovery(identityDirectory: fixture.identityB, collectionRoot: fixture.root)
        #expect(try incompatible.recover(expectedProductManifestSHA256: fixture.productB) == .absent)
        #expect(throws: PreparedCacheError.productManifestMismatch) {
            try cold.recover(expectedProductManifestSHA256: fixture.productA)
        }
    }

    @Test("Recovery preserves ready state after a test failure and scrubs dirty source state")
    func readyPreservationAndDirtyScrub() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let recovery = CacheRecovery(identityDirectory: fixture.identityA, collectionRoot: fixture.root)

        try recovery.markReady(productManifestSHA256: fixture.productA)
        try fixture.makeMaterializedSource(in: fixture.identityA)
        try recovery.recordMutationOrTestFailure()

        #expect(try recovery.recover(expectedProductManifestSHA256: fixture.productA) == .ready)
        #expect(!FileManager.default.fileExists(atPath: fixture.identityA.appendingPathComponent("project").path))

        try recovery.markDirty()
        try fixture.makeMaterializedSource(in: fixture.identityA)
        let dirtyProduct = fixture.identityA.appendingPathComponent("DerivedData/Build/Products/App")
        try FileManager.default.createDirectory(
            at: dirtyProduct.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: dirtyProduct)
        let dirtyPreparedState = fixture.identityA.appendingPathComponent("prepared-build.json")
        try Data("partial".utf8).write(to: dirtyPreparedState)
        chmod(dirtyPreparedState.path, 0o600)
        #expect(try recovery.recover(expectedProductManifestSHA256: fixture.productA) == .recovered)
        #expect(!FileManager.default.fileExists(atPath: fixture.identityA.appendingPathComponent("project").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.identityA.appendingPathComponent("DerivedData").path))
        #expect(!FileManager.default.fileExists(atPath: dirtyPreparedState.path))
    }

    @Test("Cache path validation rejects mode, uid, symlink, link count, and containment attacks")
    func pathAttacksFailClosed() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.identityA.path)
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CachePathGuard.validateDirectory(fixture.identityA, containedIn: fixture.root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.identityA.path)

        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CachePathGuard.validateDirectory(
                fixture.identityA,
                containedIn: fixture.root,
                expectedUID: getuid() &+ 1
            )
        }

        let link = fixture.root.appendingPathComponent("linked-identity")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.identityA)
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CachePathGuard.validateDirectory(link, containedIn: fixture.root)
        }

        let state = fixture.identityA.appendingPathComponent("state.json")
        try Data("{}".utf8).write(to: state)
        chmod(state.path, 0o600)
        let alias = fixture.identityA.appendingPathComponent("state-alias.json")
        #expect(linkat(AT_FDCWD, state.path, AT_FDCWD, alias.path, 0) == 0)
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CachePathGuard.validateRegularFile(state, containedIn: fixture.identityA)
        }

        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        chmod(outside.path, 0o700)
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CachePathGuard.validateDirectory(outside, containedIn: fixture.root)
        }

        let realParent = fixture.identityA.appendingPathComponent("real-parent")
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        chmod(realParent.path, 0o700)
        let privateFile = realParent.appendingPathComponent("private.json")
        try Data("{}".utf8).write(to: privateFile)
        chmod(privateFile.path, 0o600)
        let linkedParent = fixture.identityA.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CachePathGuard.validateRegularFile(
                linkedParent.appendingPathComponent("private.json"),
                containedIn: fixture.identityA
            )
        }

        let regularParent = fixture.identityA.appendingPathComponent("not-a-directory")
        try Data().write(to: regularParent)
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CachePathGuard.validateNoSymlinkComponents(
                regularParent.appendingPathComponent("child"),
                containedIn: fixture.identityA
            )
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CachePathGuard.validateOwnedTree(regularParent, containedIn: fixture.identityA)
        }

        let tree = fixture.identityA.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        chmod(tree.path, 0o700)
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CachePathGuard.validateOwnedTree(tree, containedIn: fixture.identityA, makeEnumerator: { _ in nil })
        }
        let treeFile = tree.appendingPathComponent("file")
        try Data().write(to: treeFile)
        let treeAlias = tree.appendingPathComponent("alias")
        #expect(linkat(AT_FDCWD, treeFile.path, AT_FDCWD, treeAlias.path, 0) == 0)
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CachePathGuard.validateOwnedTree(tree, containedIn: fixture.identityA)
        }
        try FileManager.default.removeItem(at: treeAlias)
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CachePathGuard.validateOwnedTree(
                tree,
                containedIn: fixture.identityA,
                metadataProvider: { url in url.path == tree.path ? CachePathGuard.metadata(at: url) : nil }
            )
        }
        #expect(throws: PreparedCacheError.projectInputDrift) {
            try ProjectInputMaterializer.validateAuthenticatedSourcePath(treeFile, sourceRoot: tree) { _, _ in
                throw PreparedCacheError.unsafeCachePath
            }
        }
    }

    @Test("Recovery removes raw source and report classes while allowing DerivedData")
    func retainedArtifactBoundary() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let recovery = CacheRecovery(identityDirectory: fixture.identityA, collectionRoot: fixture.root)
        #expect(try recovery.inspectRetainedArtifacts().isEmpty)
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheRecovery.requireMetadata(fixture.identityA, provider: { _ in nil })
        }
        let retainedDirectory = fixture.identityA.appendingPathComponent("DerivedData")
        try FileManager.default.createDirectory(at: retainedDirectory, withIntermediateDirectories: false)
        #expect(try recovery.inspectRetainedArtifacts() == [.derivedData])
        try FileManager.default.removeItem(at: retainedDirectory)
        try recovery.markDirty()

        try fixture.makeMaterializedSource(in: fixture.identityA)
        let rawReport = fixture.identityA.appendingPathComponent("mutation-report.json")
        try Data("EXTERNAL_CREDENTIAL_CANARY".utf8).write(to: rawReport)
        let selection = fixture.identityA.appendingPathComponent("selection.json")
        try Data("private selector".utf8).write(to: selection)
        let derived = fixture.identityA.appendingPathComponent("DerivedData/Build/product.bin")
        try FileManager.default.createDirectory(
            at: derived.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("compiled product".utf8).write(to: derived)

        #expect(try recovery.recover(expectedProductManifestSHA256: fixture.productA) == .recovered)
        #expect(!FileManager.default.fileExists(atPath: derived.path))
        #expect(!FileManager.default.fileExists(atPath: rawReport.path))
        #expect(!FileManager.default.fileExists(atPath: selection.path))
        #expect(try recovery.inspectRetainedArtifacts().isEmpty)
    }

    @Test("Custody EOF terminates up to four verified groups and rejects PID reuse")
    func custodyQuiescenceAndIdentityVerification() throws {
        let recorder = CustodyRecorder()
        let custody = ProcessCustody(
            verifyIdentity: { recorder.verify($0) },
            terminateGroup: { try recorder.terminate($0) },
            waitForGroup: { try recorder.wait($0) }
        )
        let groups = (1 ... 4).map {
            CustodiedProcessGroup(pid: Int32($0), processGroupID: Int32(100 + $0), birthIdentity: "birth-\($0)")
        }
        for group in groups {
            recorder.allow(group)
            try custody.register(group)
        }

        try custody.handleCustodyEOF()
        #expect(recorder.terminated == groups.map(\.processGroupID))
        #expect(recorder.waited == groups.map(\.processGroupID))
        #expect(custody.isQuiescent)

        let reused = CustodiedProcessGroup(pid: 50, processGroupID: 150, birthIdentity: "old-birth")
        try custody.register(reused)
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try custody.handleEngineTermination()
        }
        #expect(!recorder.terminated.contains(150))
    }

    @Test("Custody refuses groups beyond the bounded concurrency protocol")
    func custodyGroupBound() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let recorder = CustodyRecorder()
        let custody = ProcessCustody(
            registeredGroups: (0 ..< ProcessCustody.maximumTrackedProcessGroups).map { index in
                CustodiedProcessGroup(
                    pid: Int32(index + 1),
                    processGroupID: Int32(index + 100),
                    birthIdentity: "b\(index)"
                )
            },
            verifyIdentity: { recorder.verify($0) },
            terminateGroup: { try recorder.terminate($0) },
            waitForGroup: { try recorder.wait($0) }
        )
        #expect(throws: PreparedCacheError.tooManyProcessGroups) {
            try custody.register(
                CustodiedProcessGroup(
                    pid: Int32(ProcessCustody.maximumTrackedProcessGroups + 1),
                    processGroupID: 999,
                    birthIdentity: "beyond-bound"
                )
            )
        }

        let oversizedRegistry = fixture.identityA.appendingPathComponent("oversized-custody.json")
        let oversizedGroups = (0 ... ProcessCustody.maximumTrackedProcessGroups).map { index in
            CustodiedProcessGroup(
                pid: Int32(index + 1),
                processGroupID: Int32(index + 100),
                birthIdentity: "b\(index)"
            )
        }
        try JSONEncoder().encode(oversizedGroups).write(to: oversizedRegistry)
        chmod(oversizedRegistry.path, 0o600)
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try ProcessCustody.readRegisteredGroups(from: oversizedRegistry)
        }
    }

    @Test("Custody durably tracks eight parallel prepared-target process groups")
    func custodySupportsPreparedTargetConcurrency() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let registry = fixture.identityA.appendingPathComponent("parallel-custody.json")
        let custody = ProcessCustody(
            registrationURL: registry,
            verifyIdentity: { _ in true },
            terminateGroup: { _ in },
            waitForGroup: { _ in }
        )
        let groups = (1 ... 8).map {
            CustodiedProcessGroup(
                pid: Int32($0),
                processGroupID: Int32(100 + $0),
                birthIdentity: "birth-\($0)"
            )
        }
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            for group in groups {
                tasks.addTask { try custody.register(group) }
            }
            try await tasks.waitForAll()
        }
        #expect(Set(try ProcessCustody.readRegisteredGroups(from: registry)) == Set(groups))

        let recovered = try ProcessCustody.system(
            registrationURL: registry,
            identityStatus: { _ in .absent },
            signal: { _, _ in
                errno = ESRCH
                return -1
            },
            sleep: { _ in }
        )
        try recovered.handleEngineTermination()
        #expect(recovered.isQuiescent)
        #expect(try ProcessCustody.readRegisteredGroups(from: registry).isEmpty)
    }

    @Test("Custody atomically persists its verified registry through quiescence")
    func custodyRegistry() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let registry = fixture.identityA.appendingPathComponent("process-custody.json")
        let recorder = CustodyRecorder()
        let group = CustodiedProcessGroup(pid: 7, processGroupID: 17, birthIdentity: "birth-7")
        recorder.allow(group)
        let custody = ProcessCustody(
            registrationURL: registry,
            verifyIdentity: { recorder.verify($0) },
            terminateGroup: { try recorder.terminate($0) },
            waitForGroup: { try recorder.wait($0) }
        )

        try custody.register(group)
        #expect(try ProcessCustody.readRegisteredGroups(from: registry) == [group])
        let attributes = try FileManager.default.attributesOfItem(atPath: registry.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)

        try custody.unregister(pid: group.pid)
        #expect(try ProcessCustody.readRegisteredGroups(from: registry).isEmpty)
        try custody.register(group)

        try custody.handleCustodyEOF()
        #expect(try ProcessCustody.readRegisteredGroups(from: registry).isEmpty)

        let replacementFailure = ProcessCustody(
            registrationURL: registry,
            registeredGroups: [group],
            verifyIdentity: { recorder.verify($0) },
            terminateGroup: { try recorder.terminate($0) },
            waitForGroup: { try recorder.wait($0) },
            replaceRegistry: { _, _ in
                errno = EIO
                return -1
            }
        )
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try replacementFailure.unregister(pid: group.pid)
        }
        #expect(try ProcessCustody.readRegisteredGroups(from: registry).isEmpty)

        let syncFailure = ProcessCustody(
            registrationURL: registry,
            verifyIdentity: { recorder.verify($0) },
            terminateGroup: { try recorder.terminate($0) },
            waitForGroup: { try recorder.wait($0) },
            syncDescriptor: { _ in
                errno = EIO
                return -1
            }
        )
        #expect(throws: PreparedCacheError.unsafeCachePath) { try syncFailure.register(group) }
        #expect(try ProcessCustody.readRegisteredGroups(from: registry).isEmpty)

        for failingCustody in [
            ProcessCustody(
                registrationURL: registry, verifyIdentity: { _ in true }, terminateGroup: { _ in },
                waitForGroup: { _ in },
                openRegistryFile: { _ in -1 }
            ),
            ProcessCustody(
                registrationURL: registry, verifyIdentity: { _ in true }, terminateGroup: { _ in },
                waitForGroup: { _ in },
                openRegistryDirectory: { _ in -1 }
            ),
        ] {
            #expect(throws: PreparedCacheError.unsafeCachePath) { try failingCustody.register(group) }
        }
        let syncCalls = LockedCounter()
        let parentSyncFailure = ProcessCustody(
            registrationURL: registry, verifyIdentity: { _ in true }, terminateGroup: { _ in }, waitForGroup: { _ in },
            syncDescriptor: { _ in
                syncCalls.increment()
                return syncCalls.value == 1 ? 0 : -1
            }
        )
        #expect(throws: PreparedCacheError.unsafeCachePath) { try parentSyncFailure.register(group) }
    }

    @Test("Absent leader clears only when its recorded group is also absent")
    func absentPIDDoesNotSignalGroup() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let signalRecorder = SignalRecorder()
        let custody = try ProcessCustody.system(
            registrationURL: fixture.identityA.appendingPathComponent("absent-registry.json"),
            identityStatus: { _ in .absent },
            signal: { process, signal in
                signalRecorder.record(process: process, signal: signal)
                errno = ESRCH
                return -1
            },
            sleep: { _ in }
        )
        try custody.register(.init(pid: Int32.max, processGroupID: 42, birthIdentity: "gone"))
        try custody.handleEngineTermination()
        #expect(signalRecorder.calls.count == 1)
        #expect(signalRecorder.calls.first?.0 == -42)
        #expect(signalRecorder.calls.first?.1 == 0)
        #expect(custody.isQuiescent)

        let liveRecorder = SignalRecorder()
        let descendantsLive = try ProcessCustody.system(
            registrationURL: fixture.identityA.appendingPathComponent("descendants-live.json"),
            identityStatus: { _ in .absent },
            signal: { process, signal in
                liveRecorder.record(process: process, signal: signal)
                return 0
            },
            sleep: { _ in }
        )
        try descendantsLive.register(.init(pid: Int32.max, processGroupID: 43, birthIdentity: "gone"))
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try descendantsLive.handleEngineTermination()
        }
        #expect(liveRecorder.calls.count == 50)
        #expect(liveRecorder.calls.first?.0 == -43)
        #expect(liveRecorder.calls.first?.1 == 0)
        #expect(!descendantsLive.isQuiescent)
        #expect(
            try ProcessCustody.readRegisteredGroups(
                from: fixture.identityA.appendingPathComponent("descendants-live.json")
            ).count == 1)

        let probeFailureRegistry = fixture.identityA.appendingPathComponent("group-probe-failure.json")
        let probeFailure = try ProcessCustody.system(
            registrationURL: probeFailureRegistry,
            identityStatus: { _ in .absent },
            signal: { _, _ in
                errno = EACCES
                return -1
            },
            sleep: { _ in }
        )
        let unprovable = CustodiedProcessGroup(pid: Int32.max, processGroupID: 44, birthIdentity: "gone")
        try probeFailure.register(unprovable)
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try probeFailure.handleEngineTermination()
        }
        #expect(try ProcessCustody.readRegisteredGroups(from: probeFailureRegistry) == [unprovable])
    }

    @Test("Custody preserves registration until the entire process group is absent")
    func custodyRequiresWholeGroupAbsence() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let group = CustodiedProcessGroup(pid: 7, processGroupID: 42, birthIdentity: "birth")

        let completionRegistry = fixture.identityA.appendingPathComponent("completion-live-group.json")
        let completion = ProcessCustody(
            registrationURL: completionRegistry,
            verifyIdentity: { _ in true },
            terminateGroup: { _ in },
            waitForGroup: { _ in },
            groupIsAbsent: { _ in false }
        )
        try completion.register(group)
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try completion.unregister(pid: group.pid)
        }
        #expect(!completion.isQuiescent)
        #expect(try ProcessCustody.readRegisteredGroups(from: completionRegistry) == [group])

        let recoveryRegistry = fixture.identityA.appendingPathComponent("recovery-live-group.json")
        let recovery = ProcessCustody(
            registrationURL: recoveryRegistry,
            verifyIdentity: { _ in true },
            terminateGroup: { _ in },
            waitForGroup: { _ in },
            groupIsAbsent: { _ in false }
        )
        try recovery.register(group)
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try recovery.handleEngineTermination()
        }
        #expect(!recovery.isQuiescent)
        #expect(try ProcessCustody.readRegisteredGroups(from: recoveryRegistry) == [group])
    }

    @Test("Custody polling never blocks concurrent process registration")
    func custodyPollingDoesNotHoldRegistryMutex() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let registry = fixture.identityA.appendingPathComponent("concurrent-custody.json")
        let first = CustodiedProcessGroup(pid: 7, processGroupID: 42, birthIdentity: "first")
        let second = CustodiedProcessGroup(pid: 8, processGroupID: 43, birthIdentity: "second")
        let pollingStarted = DispatchSemaphore(value: 0)
        let allowAbsence = DispatchSemaphore(value: 0)
        let unregisterFinished = DispatchSemaphore(value: 0)
        let registrationFinished = DispatchSemaphore(value: 0)
        let custody = ProcessCustody(
            registrationURL: registry,
            verifyIdentity: { _ in true },
            terminateGroup: { _ in },
            waitForGroup: { _ in },
            groupIsAbsent: { _ in
                pollingStarted.signal()
                _ = allowAbsence.wait(timeout: .now() + 2)
                return true
            }
        )
        try custody.register(first)
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try custody.register(.init(pid: first.pid, processGroupID: 99, birthIdentity: "reused-pid"))
        }
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try custody.register(.init(pid: 99, processGroupID: first.processGroupID, birthIdentity: "reused-pgid"))
        }
        let unregisterThread = Thread {
            try? custody.unregister(pid: first.pid)
            unregisterFinished.signal()
        }
        unregisterThread.start()
        #expect(pollingStarted.wait(timeout: .now() + 1) == .success)
        let registerThread = Thread {
            try? custody.register(second)
            registrationFinished.signal()
        }
        registerThread.start()
        let registeredWhilePolling = registrationFinished.wait(timeout: .now() + 1) == .success
        allowAbsence.signal()
        #expect(unregisterFinished.wait(timeout: .now() + 1) == .success)
        #expect(registeredWhilePolling)
        #expect(!custody.isQuiescent)
        #expect(try ProcessCustody.readRegisteredGroups(from: registry) == [second])
    }

    @Test("Custody quiescence reconciles but does not erase a concurrent new group")
    func custodyQuiescenceReconcilesConcurrentRegistration() throws {
        let first = CustodiedProcessGroup(pid: 17, processGroupID: 52, birthIdentity: "first")
        let second = CustodiedProcessGroup(pid: 18, processGroupID: 53, birthIdentity: "second")
        let waitStarted = DispatchSemaphore(value: 0)
        let allowWait = DispatchSemaphore(value: 0)
        let quiescenceFinished = DispatchSemaphore(value: 0)
        let registrationFinished = DispatchSemaphore(value: 0)
        let custody = ProcessCustody(
            verifyIdentity: { _ in true },
            terminateGroup: { _ in },
            waitForGroup: { _ in
                waitStarted.signal()
                _ = allowWait.wait(timeout: .now() + 2)
            }
        )
        try custody.register(first)
        let quiescenceThread = Thread {
            try? custody.handleEngineTermination()
            quiescenceFinished.signal()
        }
        quiescenceThread.start()
        #expect(waitStarted.wait(timeout: .now() + 1) == .success)
        let registerThread = Thread {
            try? custody.register(second)
            registrationFinished.signal()
        }
        registerThread.start()
        let registeredWhileWaiting = registrationFinished.wait(timeout: .now() + 1) == .success
        allowWait.signal()
        #expect(quiescenceFinished.wait(timeout: .now() + 1) == .success)
        #expect(registeredWhileWaiting)
        #expect(!custody.isQuiescent)
    }

    @Test("Command failure scrub preserves unresolved custody for the next recovery")
    func commandFailurePreservesCustodyRegistry() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let recovery = CacheRecovery(identityDirectory: fixture.identityA, collectionRoot: fixture.root)
        try recovery.markDirty()
        try fixture.makeMaterializedSource(in: fixture.identityA)
        let registry = fixture.identityA.appendingPathComponent("process-custody.json")
        let group = CustodiedProcessGroup(pid: 7, processGroupID: 42, birthIdentity: "birth")
        let completion = ProcessCustody(
            registrationURL: registry,
            verifyIdentity: { _ in true },
            terminateGroup: { _ in },
            waitForGroup: { _ in },
            groupIsAbsent: { _ in false }
        )
        try completion.register(group)
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try completion.unregister(pid: group.pid)
        }

        try recovery.scrubAfterCommand()
        #expect(!FileManager.default.fileExists(atPath: fixture.identityA.appendingPathComponent("project").path))
        #expect(try ProcessCustody.readRegisteredGroups(from: registry) == [group])
        #expect(try recovery.inspectRetainedArtifacts().isEmpty)

        let statuses = IdentityStatusRecorder(statuses: [.matching, .matching, .absent])
        let signals = SignalRecorder()
        let nextRecovery = try ProcessCustody.system(
            registrationURL: registry,
            identityStatus: { _ in statuses.next() },
            signal: { process, signal in
                signals.record(process: process, signal: signal)
                if signal == 0 {
                    errno = ESRCH
                    return -1
                }
                return 0
            },
            sleep: { _ in }
        )
        try nextRecovery.handleEngineTermination()
        #expect(signals.calls.contains { $0 == (-group.processGroupID, SIGTERM) })
        #expect(nextRecovery.isQuiescent)
        try recovery.scrubAfterCommand()
        #expect(!FileManager.default.fileExists(atPath: registry.path))

        try Data("[{\"pid\":7,\"processGroupID\":42,\"birthIdentity\":\"birth\",\"unknown\":true}]".utf8)
            .write(to: registry)
        chmod(registry.path, 0o600)
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try recovery.scrubAfterCommand()
        }
        #expect(FileManager.default.fileExists(atPath: registry.path))
    }

    @Test("Custody revalidates identity immediately before TERM and KILL")
    func custodyRevalidatesBeforeSignals() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let group = CustodiedProcessGroup(pid: 7, processGroupID: 42, birthIdentity: "birth")

        let beforeTerm = IdentityStatusRecorder(statuses: [.matching, .mismatched])
        let termSignals = SignalRecorder()
        let termCustody = try ProcessCustody.system(
            registrationURL: fixture.identityA.appendingPathComponent("term-revalidation.json"),
            identityStatus: { _ in beforeTerm.next() },
            signal: { process, signal in
                termSignals.record(process: process, signal: signal)
                return 0
            },
            sleep: { _ in }
        )
        try termCustody.register(group)
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) { try termCustody.handleEngineTermination() }
        #expect(termSignals.calls.isEmpty)

        let beforeKill = IdentityStatusRecorder(
            statuses: Array(repeating: .matching, count: 52) + [.mismatched]
        )
        let killSignals = SignalRecorder()
        let killCustody = try ProcessCustody.system(
            registrationURL: fixture.identityA.appendingPathComponent("kill-revalidation.json"),
            identityStatus: { _ in beforeKill.next() },
            signal: { process, signal in
                killSignals.record(process: process, signal: signal)
                return 0
            },
            sleep: { _ in }
        )
        try killCustody.register(group)
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) { try killCustody.handleEngineTermination() }
        #expect(killSignals.calls.contains { $0.1 == SIGTERM })
        #expect(!killSignals.calls.contains { $0.1 == SIGKILL })

        let legacyFalse = try ProcessCustody.system(
            registrationURL: fixture.identityA.appendingPathComponent("legacy-false.json"),
            verifyIdentity: { _ in false }, signal: { _, _ in 0 }, sleep: { _ in }
        )
        try legacyFalse.register(group)
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) { try legacyFalse.handleEngineTermination() }
        errno = EACCES
        #expect(
            SystemProcessIdentity.status(of: group, birthIdentity: { _ in nil }, getGroup: { _ in 0 }) == .mismatched)
        errno = ESRCH
        #expect(SystemProcessIdentity.status(of: group, birthIdentity: { _ in nil }, getGroup: { _ in 0 }) == .absent)
        #expect(
            SystemProcessIdentity.status(
                of: group,
                birthIdentity: { _ in group.birthIdentity },
                getGroup: { _ in
                    errno = ESRCH
                    return -1
                }
            ) == .absent
        )
        #expect(
            SystemProcessIdentity.status(
                of: group,
                birthIdentity: { _ in group.birthIdentity },
                getGroup: { _ in
                    errno = EACCES
                    return -1
                }
            ) == .mismatched
        )

        let transientProbeCalls = LockedCounter()
        let transientProbe = try ProcessCustody.system(
            registrationURL: fixture.identityA.appendingPathComponent("transient-probe.json"),
            identityStatus: { _ in .matching },
            signal: { _, signal in
                guard signal == 0 else { return 0 }
                let call = transientProbeCalls.incrementedValue()
                if call <= 50 { return 0 }
                errno = call == 51 ? EPERM : ESRCH
                return -1
            },
            sleep: { _ in }
        )
        try transientProbe.register(group)
        try transientProbe.handleEngineTermination()
        #expect(transientProbeCalls.value == 52)

        let persistentProbeCalls = LockedCounter()
        let persistentProbe = try ProcessCustody.system(
            registrationURL: fixture.identityA.appendingPathComponent("persistent-probe.json"),
            identityStatus: { _ in .matching },
            signal: { _, signal in
                guard signal == 0 else { return 0 }
                let call = persistentProbeCalls.incrementedValue()
                if call <= 50 { return 0 }
                errno = EPERM
                return -1
            },
            sleep: { _ in }
        )
        try persistentProbe.register(group)
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try persistentProbe.handleEngineTermination()
        }
        #expect(persistentProbeCalls.value == 100)

        for terminalStatus in [ProcessIdentityStatus.absent, .mismatched] {
            let statuses = IdentityStatusRecorder(statuses: [.matching, .matching, terminalStatus])
            let custody = try ProcessCustody.system(
                registrationURL: fixture.identityA.appendingPathComponent("wait-\(terminalStatus).json"),
                identityStatus: { _ in statuses.next() },
                signal: { _, signal in
                    if signal == 0, terminalStatus == .absent {
                        errno = ESRCH
                        return -1
                    }
                    return 0
                },
                sleep: { _ in }
            )
            try custody.register(group)
            if terminalStatus == .absent {
                try custody.handleEngineTermination()
            } else {
                #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
                    try custody.handleEngineTermination()
                }
            }
        }

        for signalError in [ESRCH, EACCES] {
            let custody = try ProcessCustody.system(
                registrationURL: fixture.identityA.appendingPathComponent("signal-\(signalError).json"),
                identityStatus: { _ in .matching },
                signal: { _, signal in
                    if signal == 0 {
                        errno = signalError
                        return -1
                    }
                    return 0
                }, sleep: { _ in }
            )
            try custody.register(group)
            if signalError == ESRCH {
                try custody.handleEngineTermination()
            } else {
                #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
                    try custody.handleEngineTermination()
                }
            }
        }
    }

    @Test("Custody accepts leader disappearance at the kill boundary only after group absence")
    func custodyLeaderDisappearsAtKillBoundary() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let group = CustodiedProcessGroup(pid: 7, processGroupID: 42, birthIdentity: "birth")
        let statuses = IdentityStatusRecorder(
            statuses: Array(repeating: .matching, count: 52) + [.absent]
        )
        let signals = SignalRecorder()
        let custody = try ProcessCustody.system(
            registrationURL: fixture.identityA.appendingPathComponent("kill-boundary.json"),
            identityStatus: { _ in statuses.next() },
            signal: { process, signal in
                signals.record(process: process, signal: signal)
                if signal == 0, signals.calls.filter({ $0.1 == 0 }).count > 50 {
                    errno = ESRCH
                    return -1
                }
                return 0
            },
            sleep: { _ in }
        )
        try custody.register(group)
        try custody.handleEngineTermination()
        #expect(!signals.calls.contains { $0.1 == SIGKILL })
        #expect(custody.isQuiescent)
    }

    @Test("Custody descriptor EOF quiesces registered process groups")
    func custodyDescriptorEOF() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let recorder = CustodyRecorder()
        let group = CustodiedProcessGroup(pid: 11, processGroupID: 21, birthIdentity: "birth-11")
        recorder.allow(group)
        let custody = ProcessCustody(
            verifyIdentity: { recorder.verify($0) },
            terminateGroup: { try recorder.terminate($0) },
            waitForGroup: { try recorder.wait($0) }
        )
        try custody.register(group)
        var ownedDescriptor: Int32 = -1
        let monitor = try CustodyFDMonitor(
            descriptor: Int(descriptors[0]),
            custody: custody,
            duplicateDescriptor: { descriptor in
                ownedDescriptor = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
                return ownedDescriptor
            }
        )
        #expect(fcntl(ownedDescriptor, F_GETFD) & FD_CLOEXEC != 0)

        close(descriptors[1])
        descriptors[1] = -1
        for _ in 0 ..< 50 where !custody.isQuiescent { try await Task.sleep(for: .milliseconds(10)) }

        try monitor.checkFailure()
        #expect(custody.isQuiescent)
        #expect(recorder.terminated == [21])
    }

    @Test("Custody rejects invalid registrations and reports asynchronous EOF failures")
    func custodyFailureBranches() async throws {
        let custody = ProcessCustody(
            verifyIdentity: { _ in false },
            terminateGroup: { _ in throw PreparedCacheError.unverifiableProcessIdentity },
            waitForGroup: { _ in throw PreparedCacheError.unverifiableProcessIdentity }
        )
        for invalid in [
            CustodiedProcessGroup(pid: 0, processGroupID: 1, birthIdentity: "x"),
            CustodiedProcessGroup(pid: 1, processGroupID: 0, birthIdentity: "x"),
            CustodiedProcessGroup(pid: 1, processGroupID: 1, birthIdentity: ""),
        ] {
            #expect(throws: PreparedCacheError.unverifiableProcessIdentity) { try custody.register(invalid) }
        }
        let group = CustodiedProcessGroup(pid: 31, processGroupID: 41, birthIdentity: "stale")
        try custody.register(group)
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        defer {
            close(descriptors[0])
            if descriptors[1] >= 0 { close(descriptors[1]) }
        }
        let monitor = try CustodyFDMonitor(descriptor: Int(descriptors[0]), custody: custody)
        close(descriptors[1])
        descriptors[1] = -1
        var sawFailure = false
        for _ in 0 ..< 50 where !sawFailure {
            do { try monitor.checkFailure() } catch { sawFailure = true }
            if !sawFailure { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(sawFailure)
        let failedRuntime = PreparedBuildCoordinator.CustodyRuntime(
            custody: custody, monitor: monitor, launcher: XcodeProcessLauncher()
        )
        #expect(!PreparedBuildCoordinator.custodyIsQuiescent(failedRuntime))
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try PreparedBuildCoordinator.requireCustodyQuiescence(failedRuntime)
        }
        monitor.cancel()
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try CustodyFDMonitor(descriptor: -1, custody: custody)
        }
        var readErrorDescriptors: [Int32] = [0, 0]
        #expect(pipe(&readErrorDescriptors) == 0)
        defer {
            close(readErrorDescriptors[0])
            close(readErrorDescriptors[1])
        }
        let readErrorMonitor = try CustodyFDMonitor(
            descriptor: Int(readErrorDescriptors[0]),
            custody: custody,
            readDescriptor: { _, _, _ in
                errno = EIO
                return -1
            }
        )
        var wakeByte: UInt8 = 1
        #expect(Darwin.write(readErrorDescriptors[1], &wakeByte, 1) == 1)
        var sawReadFailure = false
        for _ in 0 ..< 50 where !sawReadFailure {
            do { try readErrorMonitor.checkFailure() } catch { sawReadFailure = true }
            if !sawReadFailure { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(sawReadFailure)
        readErrorMonitor.cancel()
        var interruptedDescriptors: [Int32] = [0, 0]
        #expect(pipe(&interruptedDescriptors) == 0)
        defer {
            close(interruptedDescriptors[0])
            if interruptedDescriptors[1] >= 0 { close(interruptedDescriptors[1]) }
        }
        let readCalls = LockedCounter()
        let interruptedMonitor = try CustodyFDMonitor(
            descriptor: Int(interruptedDescriptors[0]),
            custody: ProcessCustody(
                verifyIdentity: { _ in true }, terminateGroup: { _ in }, waitForGroup: { _ in }
            ),
            readDescriptor: { descriptor, buffer, count in
                readCalls.increment()
                if readCalls.value == 1 {
                    errno = EINTR
                    return -1
                }
                return Darwin.read(descriptor, buffer, count)
            }
        )
        #expect(Darwin.write(interruptedDescriptors[1], &wakeByte, 1) == 1)
        for _ in 0 ..< 50 where readCalls.value < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(readCalls.value >= 2)
        close(interruptedDescriptors[1])
        interruptedDescriptors[1] = -1
        interruptedMonitor.cancel()

        let deadlineGroup = CustodiedProcessGroup(pid: 91, processGroupID: 91, birthIdentity: "birth")
        let deadlineClock = MonotonicRecorder(values: [10, 9])
        let deadlineCustody = ProcessCustody(
            registeredGroups: [deadlineGroup],
            verifyIdentity: { _ in true }, terminateGroup: { _ in }, waitForGroup: { _ in },
            monotonicNow: { deadlineClock.next() }
        )
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try deadlineCustody.handleEngineTermination()
        }

        let firstBudgetedGroup = CustodiedProcessGroup(
            pid: 92, processGroupID: 92, birthIdentity: "birth-92")
        let secondBudgetedGroup = CustodiedProcessGroup(
            pid: 93, processGroupID: 93, birthIdentity: "birth-93")
        let multiGroupClock = MonotonicRecorder(values: [0, 1, 4, 8, 12, 13, 18, 23, 29])
        let multiGroupCustody = ProcessCustody(
            registeredGroups: [firstBudgetedGroup, secondBudgetedGroup],
            verifyIdentity: { _ in true },
            terminateGroup: { _ in },
            waitForGroup: { _ in },
            monotonicNow: { multiGroupClock.next() },
            maximumQuiescenceNanoseconds: 15
        )
        try multiGroupCustody.handleEngineTermination()
        #expect(multiGroupCustody.isQuiescent)

        let overflowingBudgetCustody = ProcessCustody(
            registeredGroups: [firstBudgetedGroup, secondBudgetedGroup],
            verifyIdentity: { _ in true },
            terminateGroup: { _ in },
            waitForGroup: { _ in },
            monotonicNow: { 0 },
            maximumQuiescenceNanoseconds: UInt64.max
        )
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try overflowingBudgetCustody.handleEngineTermination()
        }

        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try SystemProcessIdentity.group(for: Int32.max)
        }
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try SystemProcessIdentity.group(for: getpid(), getGroup: { _ in -1 })
        }

        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let registryDirectory = fixture.identityA.appendingPathComponent("process-custody.json")
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: false)
        try Data("occupied".utf8).write(to: registryDirectory.appendingPathComponent("child"))
        let persistent = ProcessCustody(
            registrationURL: registryDirectory,
            verifyIdentity: { _ in true }, terminateGroup: { _ in }, waitForGroup: { _ in }
        )
        #expect(throws: (any Error).self) {
            try persistent.register(.init(pid: 1, processGroupID: 1, birthIdentity: "birth"))
        }
        let createFailure = ProcessCustody(
            registrationURL: fixture.identityA.appendingPathComponent("create-failure.json"),
            verifyIdentity: { _ in true }, terminateGroup: { _ in }, waitForGroup: { _ in },
            createRegistryFile: { _, _ in false }
        )
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try createFailure.register(.init(pid: 3, processGroupID: 3, birthIdentity: "birth"))
        }

        let absentByDefault = ProcessCustody(
            registeredGroups: [.init(pid: 8, processGroupID: 8, birthIdentity: "gone")],
            verifyIdentity: { _ in false }, terminateGroup: { _ in }, waitForGroup: nil,
            identityStatus: { _ in .absent }
        )
        try absentByDefault.handleEngineTermination()
        #expect(absentByDefault.isQuiescent)

        for invalidRegistry in [
            "[{\"pid\":0,\"processGroupID\":1,\"birthIdentity\":\"b\"}]",
            "[{\"pid\":1,\"processGroupID\":1,\"birthIdentity\":\"b\"},{\"pid\":1,\"processGroupID\":2,\"birthIdentity\":\"c\"}]",
        ] {
            let url = fixture.identityA.appendingPathComponent("invalid-registry-\(UUID().uuidString).json")
            try Data(invalidRegistry.utf8).write(to: url)
            chmod(url.path, 0o600)
            #expect(throws: PreparedCacheError.invalidCacheState) {
                try ProcessCustody.readRegisteredGroups(from: url)
            }
        }

        let synthetic = CustodiedProcessGroup(pid: 4, processGroupID: 4, birthIdentity: "birth")
        let termFailure = try ProcessCustody.system(
            registrationURL: fixture.identityA.appendingPathComponent("term-failure.json"),
            verifyIdentity: { _ in true },
            signal: { _, signal in
                if signal == SIGTERM {
                    errno = EACCES
                    return -1
                }
                return -1
            },
            sleep: { _ in }
        )
        try termFailure.register(synthetic)
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) { try termFailure.handleEngineTermination() }

        let killSignals = SignalRecorder()
        let killSuccess = try ProcessCustody.system(
            registrationURL: fixture.identityA.appendingPathComponent("kill-success.json"),
            verifyIdentity: { _ in true },
            signal: { _, signal in
                killSignals.record(process: -synthetic.processGroupID, signal: signal)
                if signal == 0, killSignals.calls.contains(where: { $0.1 == SIGKILL }) {
                    errno = ESRCH
                    return -1
                }
                return 0
            },
            sleep: { _ in }
        )
        try killSuccess.register(synthetic)
        try killSuccess.handleEngineTermination()

        let killFailure = try ProcessCustody.system(
            registrationURL: fixture.identityA.appendingPathComponent("kill-failure.json"),
            verifyIdentity: { _ in true },
            signal: { _, signal in
                if signal == SIGKILL { return -1 }
                return 0
            },
            sleep: { _ in }
        )
        try killFailure.register(synthetic)
        #expect(throws: PreparedCacheError.unverifiableProcessIdentity) { try killFailure.handleEngineTermination() }
        let current = try SystemProcessIdentity.group(for: getpid())
        #expect(
            !SystemProcessIdentity.matchesOrIsAbsent(
                .init(
                    pid: current.pid, processGroupID: current.processGroupID, birthIdentity: "wrong"
                )))

        var dataDescriptors: [Int32] = [0, 0]
        #expect(pipe(&dataDescriptors) == 0)
        let dataCustody = ProcessCustody(
            verifyIdentity: { _ in true }, terminateGroup: { _ in }, waitForGroup: { _ in }
        )
        try dataCustody.register(.init(pid: 2, processGroupID: 2, birthIdentity: "birth"))
        let dataMonitor = try CustodyFDMonitor(descriptor: Int(dataDescriptors[0]), custody: dataCustody)
        var byte: UInt8 = 1
        #expect(Darwin.write(dataDescriptors[1], &byte, 1) == 1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!dataCustody.isQuiescent)
        close(dataDescriptors[1])
        for _ in 0 ..< 50 where !dataCustody.isQuiescent { try await Task.sleep(for: .milliseconds(10)) }
        dataMonitor.cancel()
        close(dataDescriptors[0])
    }

    @Test("System custody verifies and terminates a real child process group")
    func systemCustodyLifecycle() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let registry = fixture.identityA.appendingPathComponent("process-custody.json")
        func runChild() throws -> CustodiedProcessGroup {
            var attributes: posix_spawnattr_t?
            #expect(posix_spawnattr_init(&attributes) == 0)
            defer { posix_spawnattr_destroy(&attributes) }
            #expect(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0)
            #expect(posix_spawnattr_setpgroup(&attributes, 0) == 0)
            var pid: pid_t = 0
            let executable = strdup("/bin/sleep")!
            let duration = strdup("30")!
            var arguments: [UnsafeMutablePointer<CChar>?] = [executable, duration, nil]
            defer {
                free(executable)
                free(duration)
            }
            let result = arguments.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(&pid, "/bin/sleep", nil, &attributes, buffer.baseAddress!, environ)
            }
            #expect(result == 0)
            defer { _ = kill(pid, SIGKILL) }
            let group = try SystemProcessIdentity.group(for: pid)
            #expect(SystemProcessIdentity.matchesOrIsAbsent(group))
            let custody = try ProcessCustody.system(registrationURL: registry)
            try custody.register(group)
            let recovered = try ProcessCustody.system(registrationURL: registry)
            let childPID = pid
            let waiter = Thread {
                _ = waitForExit(childPID)
            }
            waiter.start()
            try recovered.handleEngineTermination()
            for _ in 0 ..< 50 where !waiter.isFinished { usleep(10_000) }
            #expect(waiter.isFinished)
            #expect(recovered.isQuiescent)
            return group
        }
        let terminated = try runChild()
        #expect(SystemProcessIdentity.matchesOrIsAbsent(terminated))

        try Data("not-json".utf8).write(to: registry)
        chmod(registry.path, 0o600)
        #expect(throws: (any Error).self) { try ProcessCustody.readRegisteredGroups(from: registry) }
    }

    @Test("Trusted roots reject symlinked ancestors")
    func trustedRootsRejectSymlinkedAncestors() throws {
        let canonicalBase = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: canonicalBase) }
        try FileManager.default.createDirectory(at: canonicalBase, withIntermediateDirectories: false)
        chmod(canonicalBase.path, 0o700)
        let real = canonicalBase.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        chmod(real.path, 0o700)
        let nested = real.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        chmod(nested.path, 0o700)
        let linked = canonicalBase.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        let attackedRoot = linked.appendingPathComponent("nested")

        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CachePathGuard.validateDirectory(attackedRoot, containedIn: attackedRoot)
        }
        if FileManager.default.temporaryDirectory.path != canonicalBase.deletingLastPathComponent().path {
            #expect(throws: PreparedCacheError.unsafeCachePath) {
                try CachePathGuard.validateCanonicalAbsoluteRoot(FileManager.default.temporaryDirectory)
            }
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheEvidenceWriter.write(
                CacheEvidence(
                    schemaVersion: 1, invocationNonce: "abcdefghijklmnopqrstuv", operation: "recover",
                    outcome: "failed", compatibilitySHA256: String(repeating: "a", count: 64),
                    projectInputManifestSHA256: String(repeating: "b", count: 64), preparedInventorySHA256: nil,
                    runOrdinal: nil, attemptOrdinal: nil, productManifestSHA256: nil,
                    fullBuilds: 0, incrementalBuilds: 0, fallbackBuilds: 0,
                    sourceBearingBytesScrubbed: false, childGroupsQuiescent: false
                ),
                to: attackedRoot.appendingPathComponent("evidence.json")
            )
        }
    }

    @Test("Product hashing and retention reject intermediate retained-tree symlinks")
    func retainedTreeIntermediateSymlinks() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("Products"), withIntermediateDirectories: true)
        try Data("compiled".utf8).write(to: outside.appendingPathComponent("Products/App"))
        let derived = fixture.identityA.appendingPathComponent("DerivedData")
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: derived.appendingPathComponent("Build"), withDestinationURL: outside
        )
        let productEnumeration = LockedCounter()
        #expect(throws: PreparedCacheError.productManifestMismatch) {
            try RetainedProductManifest.sha256(
                derivedDataURL: derived,
                makeEnumerator: { root in
                    productEnumeration.increment()
                    return FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
                })
        }
        #expect(productEnumeration.value == 0)

        try CacheRecovery(identityDirectory: fixture.identityA, collectionRoot: fixture.root)
            .writeRetentionMetadata(lastUsedAt: .distantPast)
        try FileManager.default.removeItem(at: derived)
        try FileManager.default.createSymbolicLink(at: derived, withDestinationURL: outside)
        let retentionEnumeration = LockedCounter()
        var retention = CacheRetention(collectionRoot: fixture.root)
        retention.makeEnumerator = { root in
            retentionEnumeration.increment()
            return FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try retention.enforce()
        }
        #expect(retentionEnumeration.value == 0)
    }

    @Test("Persisted cache and custody JSON reject unknown keys")
    func persistedJSONRejectsUnknownKeys() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.makeIdentity(fixture.identityA)
        let recovery = CacheRecovery(identityDirectory: fixture.identityA, collectionRoot: fixture.root)
        try recovery.markDirty()
        let stateURL = fixture.identityA.appendingPathComponent("cache-state.json")
        var state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        state["unknown"] = true
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
        chmod(stateURL.path, 0o600)
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try recovery.recover(expectedProductManifestSHA256: fixture.productA)
        }

        try recovery.writeRetentionMetadata(lastUsedAt: .distantPast)
        let retentionURL = fixture.identityA.appendingPathComponent("retention.json")
        var retention = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: retentionURL)) as? [String: Any])
        retention["unknown"] = true
        try JSONSerialization.data(withJSONObject: retention).write(to: retentionURL)
        chmod(retentionURL.path, 0o600)
        #expect(throws: PreparedCacheError.invalidCacheState) { try recovery.retentionLastUsedAt() }

        let registry = fixture.identityA.appendingPathComponent("process-custody.json")
        try Data("[{\"pid\":1,\"processGroupID\":1,\"birthIdentity\":\"b\",\"unknown\":true}]".utf8)
            .write(to: registry)
        chmod(registry.path, 0o600)
        #expect(throws: PreparedCacheError.invalidCacheState) {
            try ProcessCustody.readRegisteredGroups(from: registry)
        }
    }
}

private final class PreparedCoordinatorLauncher: @unchecked Sendable, ProcessLaunching {
    var enumerationExitCode: Int32 = 0
    var omitBuildProducts = false
    func launch(
        executableURL: URL, arguments: [String], workingDirectoryURL: URL, timeout: Double
    ) async throws -> Int32 { 0 }

    func launchCapturing(_ request: ProcessRequest) async throws -> (exitCode: Int32, output: String) {
        if request.arguments.contains("build-for-testing"),
            let index = request.arguments.firstIndex(of: "-derivedDataPath")
        {
            if omitBuildProducts { return (0, "") }
            let derivedData = URL(fileURLWithPath: request.arguments[index + 1])
            let products = derivedData.appendingPathComponent("Build/Products")
            try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["__xctestrun_metadata__": ["FormatVersion": 1]],
                format: .xml,
                options: 0
            )
            try plist.write(to: products.appendingPathComponent("App.xctestrun"), options: .atomic)
            try Data("compiled".utf8).write(to: products.appendingPathComponent("App"), options: .atomic)
        }
        if request.arguments.contains("-enumerate-tests"),
            let index = request.arguments.firstIndex(of: "-test-enumeration-output-path")
        {
            try Data("{\"values\":[]}".utf8).write(to: URL(fileURLWithPath: request.arguments[index + 1]))
            return (enumerationExitCode, enumerationExitCode == 0 ? "" : "enumeration failed")
        }
        return (0, "")
    }
}

private final class CustodyRecorder: @unchecked Sendable {
    private var allowed = Set<CustodiedProcessGroup>()
    private(set) var terminated: [Int32] = []
    private(set) var waited: [Int32] = []

    func allow(_ group: CustodiedProcessGroup) { allowed.insert(group) }
    func verify(_ group: CustodiedProcessGroup) -> Bool { allowed.contains(group) }
    func terminate(_ processGroupID: Int32) throws { terminated.append(processGroupID) }
    func wait(_ processGroupID: Int32) throws { waited.append(processGroupID) }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func incrementedValue() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private final class MonotonicRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(values: [UInt64]) { self.values = values }
    func next() -> UInt64 { lock.withLock { values.isEmpty ? 0 : values.removeFirst() } }
}

private final class CloseRecorder: @unchecked Sendable {
    private(set) var count = 0

    func close(_ descriptor: Int32) -> Int32 {
        count += 1
        _ = Darwin.close(descriptor)
        errno = EIO
        return -1
    }
}

private final class SignalRecorder: @unchecked Sendable {
    private(set) var calls: [(Int32, Int32)] = []

    func record(process: Int32, signal: Int32) { calls.append((process, signal)) }
}

private final class IdentityStatusRecorder: @unchecked Sendable {
    private var statuses: [ProcessIdentityStatus]

    init(statuses: [ProcessIdentityStatus]) { self.statuses = statuses }

    func next() -> ProcessIdentityStatus {
        statuses.isEmpty ? .mismatched : statuses.removeFirst()
    }
}

private struct RecoveryFixture {
    let root: URL
    let identityA: URL
    let identityB: URL
    let productA = String(repeating: "a", count: 64)
    let productB = String(repeating: "b", count: 64)

    init() throws {
        root = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!
            .appendingPathComponent(UUID().uuidString)
        identityA = root.appendingPathComponent(String(repeating: "1", count: 64))
        identityB = root.appendingPathComponent(String(repeating: "2", count: 64))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, 0o700)
    }

    func makeIdentity(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        chmod(url.path, 0o700)
    }

    func makeMaterializedSource(in identity: URL) throws {
        let source = identity.appendingPathComponent("project/Sources/Secret.swift")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("let secret = \"EXTERNAL_CREDENTIAL_CANARY\"".utf8).write(to: source)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
