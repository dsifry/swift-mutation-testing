import Darwin
import Foundation
import Testing

@testable import SwiftMutationTesting

@Suite("SwiftMutationTesting.run execution path")
struct SwiftMutationTestingExecutionPathTests {
    @Test("Hidden simulator supervisor mode rejects an incomplete internal frame")
    func simulatorSupervisorDispatchRejectsIncompleteFrame() async {
        #expect(await SwiftMutationTesting.main(args: ["--gate-simulator-supervisor"]) == 64)
        #expect(await SwiftMutationTesting.main(
            args: ["--gate-simulator-prepare-supervisor"]) == 64)
    }
    @Test("Shipping CLI prepares and cleans the authenticated gate simulator")
    func gateSimulatorDispatch() async throws {
        let root = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(root) }
        chmod(root.path, 0o700)
        let lock = root.appendingPathComponent("lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        let descriptor = open(lock.path, O_RDONLY | O_CLOEXEC)
        defer { _ = close(descriptor) }
        let registration = root.appendingPathComponent("registration.json")
        let launcher = ExecutionGateSimulatorLauncher()
        let cache = ParsedArguments.CacheOptions(
            mode: .simulatorPrepare, buildCacheRoot: root.path,
            invocationNonce: "ABCDEFGHIJKLMNOPQRSTUV",
            simulatorRegistration: registration.path,
            guideLockFD: Int(descriptor))
        let prepare = ParsedArguments(
            build: .init(destination: "platform=iOS Simulator,name=iPhone 16"),
            cache: cache)
        #expect(try await SwiftMutationTesting.execute(parsed: prepare, launcher: launcher) == .success)
        let cleanup = ParsedArguments(cache: .init(
            mode: .simulatorCleanup, buildCacheRoot: root.path,
            invocationNonce: "ABCDEFGHIJKLMNOPQRSTUV",
            simulatorRegistration: registration.path,
            guideLockFD: Int(descriptor)))
        #expect(try await SwiftMutationTesting.execute(parsed: cleanup, launcher: launcher) == .success)
        #expect(try GateSimulatorRegistration.load(from: registration).state == .deleted)
    }

    @Test("Shipping gate simulator dispatch fails closed for incomplete protocol")
    func gateSimulatorDispatchRejectsIncompleteOptions() async {
        await #expect(throws: UsageError.self) {
            _ = try await SwiftMutationTesting.execute(
                parsed: ParsedArguments(cache: .init(mode: .simulatorPrepare)),
                launcher: MockProcessLauncher(exitCode: 0))
        }
        #expect(throws: UsageError.self) { try SwiftMutationTesting.descriptorInode(-1) }
        let root = try? FileHelpers.makeTemporaryDirectory()
        if let root {
            defer { FileHelpers.cleanup(root) }
            chmod(root.path, 0o700)
            let registration = root.appendingPathComponent("registration.json")
            let lock = root.appendingPathComponent("lock")
            FileManager.default.createFile(atPath: lock.path, contents: Data())
            let descriptor = open(lock.path, O_RDONLY | O_CLOEXEC)
            defer { _ = close(descriptor) }
            await #expect(throws: UsageError.self) {
                _ = try await SwiftMutationTesting.execute(
                    parsed: ParsedArguments(
                        build: .init(destination: nil),
                        cache: .init(
                            mode: .simulatorPrepare, buildCacheRoot: root.path,
                            invocationNonce: "ABCDEFGHIJKLMNOPQRSTUV",
                            simulatorRegistration: registration.path,
                            guideLockFD: Int(descriptor))),
                    launcher: MockProcessLauncher(exitCode: 0))
            }
        }
    }

    @Test("Legacy build-count evidence forwards schedule and observed counters")
    func legacyBuildCountEvidenceContract() throws {
        let root = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(root) }
        let output = root.appendingPathComponent("build-count.json")
        try SwiftMutationTesting.writeLegacyBuildCountEvidence(
            to: output, nonce: "ABCDEFGHIJKLMNOPQRSTUV",
            selector: "AppTests/One", runOrdinal: 7, attemptOrdinal: 1,
            projectPath: root.path, fullBuilds: 2, fallbackBuilds: 3,
            testWithoutBuildingRuns: 4)
        let receipt = try JSONDecoder().decode(BuildCountEvidence.self, from: Data(contentsOf: output))
        #expect(receipt.runOrdinal == 7)
        #expect(receipt.attemptOrdinal == 1)
        #expect(receipt.counters == .init(
            fullBuilds: 2, incrementalBuilds: 0,
            testWithoutBuildingRuns: 4, fallbackBuilds: 3))
    }

    @Test("Legacy benchmark execution reuses the registered simulator and writes evidence")
    func legacyBenchmarkRegisteredExecution() async throws {
        let root = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(root) }
        chmod(root.path, 0o700)
        try "scheme: App\ndestination: platform=iOS Simulator,name=iPhone 16\nquiet: true\n".write(
            to: root.appendingPathComponent(".swift-mutation-testing.yml"), atomically: true, encoding: .utf8)
        let lock = root.appendingPathComponent("lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        let descriptor = open(lock.path, O_RDONLY | O_CLOEXEC)
        defer { _ = close(descriptor) }
        var metadata = stat()
        #expect(fstat(descriptor, &metadata) == 0)
        let registration = root.appendingPathComponent("registration.json")
        let launcher = ExecutionGateSimulatorLauncher()
        _ = try await SimulatorManager(launcher: launcher).prepareGateSimulator(
            destination: "platform=iOS Simulator,name=iPhone 16", cacheRoot: root,
            registrationURL: registration, gateRunNonce: "ABCDEFGHIJKLMNOPQRSTUV",
            guideLockInode: UInt64(metadata.st_ino))
        let evidence = root.appendingPathComponent("build-count.json")
        let report = root.appendingPathComponent("selector-report.json")
        let parsed = ParsedArguments(
            projectPath: root.path,
            build: .init(scheme: "App", destination: "platform=iOS Simulator,name=iPhone 16", testTarget: "AppTests/One", noCache: true),
            reporting: .init(output: report.path, quiet: true),
            cache: .init(
                mode: .legacyBenchmark, buildCacheRoot: root.path,
                invocationNonce: "ABCDEFGHIJKLMNOPQRSTUV", simulatorRegistration: registration.path,
                buildCountEvidenceOutput: evidence.path, guideLockFD: Int(descriptor),
                wrapperLeaseFD: 5, runOrdinal: 7, attemptOrdinal: 1))
        #expect(try await SwiftMutationTesting.execute(parsed: parsed, launcher: launcher) == .success)
        let receipt = try JSONDecoder().decode(BuildCountEvidence.self, from: Data(contentsOf: evidence))
        #expect(receipt.runOrdinal == 7)
        #expect(receipt.attemptOrdinal == 1)
        #expect(receipt.counters.fullBuilds == 1)
        #expect(receipt.counters.testWithoutBuildingRuns == 0)
        #expect(await launcher.xcodeDeviceSetEnvironmentCount == 0)
        let reportPayload = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        #expect(reportPayload?["schemaVersion"] as? String == "1")
        #expect(reportPayload?["projectRoot"] as? String == root.resolvingSymlinksInPath().path)
    }

    @Test("A post-finish receipt failure preserves the idle shared simulator")
    func receiptFailurePreservesIdleSimulator() async throws {
        let root = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(root) }
        chmod(root.path, 0o700)
        try "scheme: App\ndestination: platform=iOS Simulator,name=iPhone 16\nquiet: true\n".write(
            to: root.appendingPathComponent(".swift-mutation-testing.yml"), atomically: true, encoding: .utf8)
        let lock = root.appendingPathComponent("lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        let descriptor = open(lock.path, O_RDONLY | O_CLOEXEC)
        defer { _ = close(descriptor) }
        var metadata = stat()
        #expect(fstat(descriptor, &metadata) == 0)
        let registration = root.appendingPathComponent("registration.json")
        let launcher = ExecutionGateSimulatorLauncher()
        _ = try await SimulatorManager(launcher: launcher).prepareGateSimulator(
            destination: "platform=iOS Simulator,name=iPhone 16", cacheRoot: root,
            registrationURL: registration, gateRunNonce: "ABCDEFGHIJKLMNOPQRSTUV",
            guideLockInode: UInt64(metadata.st_ino))
        let parsed = ParsedArguments(
            projectPath: root.path,
            build: .init(scheme: "App", destination: "platform=iOS Simulator,name=iPhone 16", testTarget: "AppTests/One", noCache: true),
            reporting: .init(quiet: true),
            cache: .init(
                mode: .legacyBenchmark, buildCacheRoot: root.path,
                invocationNonce: "INVOCATIONABCDEFGHIJKL", simulatorRegistration: registration.path,
                buildCountEvidenceOutput: root.path, guideLockFD: Int(descriptor),
                wrapperLeaseFD: 5, runOrdinal: 7, attemptOrdinal: 1))
        await #expect(throws: (any Error).self) {
            _ = try await SwiftMutationTesting.execute(parsed: parsed, launcher: launcher)
        }
        #expect(try GateSimulatorRegistration.load(from: registration).state == .idle)
        await SwiftMutationTesting.cleanupBoundSimulatorAfterFailure(parsed: parsed, launcher: launcher)
        #expect(try GateSimulatorRegistration.load(from: registration).state == .idle)
        #expect(await launcher.deleteCount == 0)
    }

    @Test("Nil launcher paths use the explicit deterministic Xcode launcher seam")
    func explicitDefaultLauncherSeam() async throws {
        let root = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(root) }
        chmod(root.path, 0o700)
        let lock = root.appendingPathComponent("lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        let descriptor = open(lock.path, O_RDONLY | O_CLOEXEC)
        defer { _ = close(descriptor) }
        let registration = root.appendingPathComponent("registration.json")
        let launcher = ExecutionGateSimulatorLauncher()
        let parsed = ParsedArguments(
            build: .init(destination: "platform=iOS Simulator,name=iPhone 16"),
            cache: .init(
                mode: .simulatorPrepare, buildCacheRoot: root.path,
                invocationNonce: "ABCDEFGHIJKLMNOPQRSTUV",
                simulatorRegistration: registration.path, guideLockFD: Int(descriptor)))
        #expect(try await SwiftMutationTesting.execute(
            parsed: parsed, launcher: nil, defaultXcodeLauncher: launcher) == .success)
        _ = try await SimulatorManager(launcher: launcher).activateRegistration(
            at: registration, expectedCacheRoot: root,
            expectedGuideLockInode: SwiftMutationTesting.descriptorInode(Int(descriptor)),
            invocationNonce: "INVOCATIONABCDEFGHIJKL")
        await SwiftMutationTesting.cleanupBoundSimulatorAfterFailure(
            parsed: ParsedArguments(cache: .init(
                mode: .legacyBenchmark, buildCacheRoot: root.path,
                invocationNonce: "INVOCATIONABCDEFGHIJKL",
                simulatorRegistration: registration.path,
                guideLockFD: Int(descriptor))),
            launcher: nil, defaultLauncher: launcher)
        #expect(try GateSimulatorRegistration.load(from: registration).state == .deleted)
    }

    @Test("Production prepare dispatch uses the hidden custody child and retains idle after ACK")
    func productionPrepareCustodyDispatch() async throws {
        let root = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(root) }
        chmod(root.path, 0o700)
        let lock = root.appendingPathComponent("lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        let descriptor = open(lock.path, O_RDONLY)
        defer { _ = close(descriptor) }
        let registration = root.appendingPathComponent("registration.json")
        let fakeXcrun = root.appendingPathComponent("xcrun")
        let script = """
        #!/bin/sh
        if echo "$*" | grep -q 'list devicetypes'; then echo '{"devicetypes":[{"name":"iPhone 16","identifier":"type"}]}'; exit 0; fi
        if echo "$*" | grep -q 'list runtimes'; then echo '{"runtimes":[{"identifier":"runtime","isAvailable":true}]}'; exit 0; fi
        if echo "$*" | grep -q ' clone SOURCE-UDID '; then echo 'GATE-UDID'; exit 0; fi
        if echo "$*" | grep -q 'list devices'; then echo '{"devices":{"runtime":[{"name":"iPhone 16","udid":"SOURCE-UDID","deviceTypeIdentifier":"type","isAvailable":true},{"udid":"GATE-UDID","deviceTypeIdentifier":"type","isAvailable":true}]}}'; exit 0; fi
        exit 0
        """
        try Data(script.utf8).write(to: fakeXcrun)
        chmod(fakeXcrun.path, 0o700)
        let buildRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build")
        let cli = try #require(FileManager.default.enumerator(
            at: buildRoot, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.first {
                $0.lastPathComponent == "swift-mutation-testing" && access($0.path, X_OK) == 0
            })
        let parsed = ParsedArguments(
            build: .init(destination: "platform=iOS Simulator,name=iPhone 16"),
            cache: .init(
                mode: .simulatorPrepare, buildCacheRoot: root.path,
                invocationNonce: "ABCDEFGHIJKLMNOPQRSTUV",
                simulatorRegistration: registration.path, guideLockFD: Int(descriptor)))

        #expect(try await SwiftMutationTesting.execute(
            parsed: parsed, launcher: nil, defaultXcodeLauncher: XcodeProcessLauncher(),
            gateSupervisorExecutableURL: cli, xcrunURL: fakeXcrun) == .success)
        #expect(try GateSimulatorRegistration.load(from: registration).state == .idle)
    }
    @Test("Prepare and target dispatch complete through the CLI execution path")
    func successfulCacheCommandDispatch() async throws {
        let project = try FileHelpers.makeTemporaryDirectory()
        let root = try FileHelpers.makeTemporaryDirectory()
        defer {
            FileHelpers.cleanup(project)
            FileHelpers.cleanup(root)
        }
        chmod(project.path, 0o700)
        chmod(root.path, 0o700)
        try "scheme: App\ndestination: platform=macOS\nquiet: false\n".write(
            to: project.appendingPathComponent(".swift-mutation-testing.yml"), atomically: true, encoding: .utf8
        )
        let projectFile = project.appendingPathComponent("App.xcodeproj/project.pbxproj")
        let sourceFile = project.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: projectFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sourceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let projectBytes = Data("// project".utf8)
        let sourceBytes = Data("let enabled = true\n".utf8)
        try projectBytes.write(to: projectFile)
        try sourceBytes.write(to: sourceFile)
        chmod(projectFile.path, 0o644)
        chmod(sourceFile.path, 0o644)
        func entry(_ path: String, _ bytes: Data) -> ProjectInputManifest.Entry {
            let digest = ProjectInputManifest.sha256(bytes)
            return .init(
                path: path, mode: 0o644, byteSize: bytes.count, sha256: digest,
                deterministicMTime: ProjectInputManifest.deterministicMTime(forSHA256: digest))
        }
        let manifest = ProjectInputManifest(
            schemaVersion: 1,
            entries: [
                entry("App.xcodeproj/project.pbxproj", projectBytes),
                entry("Sources/App.swift", sourceBytes),
            ])
        let manifestURL = project.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let identity = String(repeating: "a", count: 64)
        let inventoryURL = project.appendingPathComponent("inventory.json")
        let launcher = DispatchPreparedLauncher()
        let common = [
            project.path, "--build-cache-root", root.path, "--cache-compatibility-id", identity,
            "--project-input-manifest", manifestURL.path, "--custody-fd", "0",
            "--invocation-nonce", "abcdefghijklmnopqrstuv",
        ]
        #expect(
            await SwiftMutationTesting.run(
                args: common + [
                    "--prepare-only", "--test-enumeration-output", project.appendingPathComponent("tests.json").path,
                    "--mutant-inventory-output", inventoryURL.path,
                    "--cache-evidence-output", project.appendingPathComponent("prepare-evidence.json").path,
                ], launcher: launcher) == .success)

        let state = try PreparedBuildStore(root: root.path, compatibilityID: identity).load()
        let selection = MutantSelectionManifest(
            schemaVersion: 1,
            projectInputManifestSHA256: ProjectInputManifest.sha256(try Data(contentsOf: manifestURL)),
            preparedInventorySHA256: state.preparedInventorySHA256,
            selector: "AppTests/Empty",
            runOrdinal: 0,
            attemptOrdinal: 0,
            ownedSourcePaths: []
        )
        let selectionURL = project.appendingPathComponent("selection.json")
        try JSONEncoder().encode(selection).write(to: selectionURL)
        #expect(
            await SwiftMutationTesting.run(
                args: common + [
                    "--target", "AppTests/Empty", "--no-cache", "--mutant-selection-manifest", selectionURL.path,
                    "--output", project.appendingPathComponent("report.json").path,
                    "--cache-evidence-output", project.appendingPathComponent("target-evidence.json").path,
                ], launcher: launcher) == .success)
    }

    @Test("Validated cache commands dispatch through prepare and target coordinators")
    func cacheCommandDispatch() async throws {
        for operation in ["prepare", "target"] {
            let project = try FileHelpers.makeTemporaryDirectory()
            let root = try FileHelpers.makeTemporaryDirectory()
            defer {
                FileHelpers.cleanup(project)
                FileHelpers.cleanup(root)
            }
            chmod(project.path, 0o700)
            chmod(root.path, 0o700)
            try "scheme: App\ndestination: platform=macOS\nquiet: true\n".write(
                to: project.appendingPathComponent(".swift-mutation-testing.yml"),
                atomically: true,
                encoding: .utf8
            )
            let manifest = project.appendingPathComponent("manifest.json")
            try Data("{}".utf8).write(to: manifest)
            let evidence = project.appendingPathComponent("dispatch-evidence.json")
            var arguments = [
                project.path,
                "--build-cache-root", root.path,
                "--cache-compatibility-id", String(repeating: operation == "prepare" ? "1" : "2", count: 64),
                "--project-input-manifest", manifest.path,
                "--cache-evidence-output", evidence.path,
                "--custody-fd", "0",
                "--invocation-nonce", "abcdefghijklmnopqrstuv",
            ]
            if operation == "prepare" {
                arguments += [
                    "--prepare-only", "--test-enumeration-output", project.appendingPathComponent("tests.json").path,
                    "--mutant-inventory-output", project.appendingPathComponent("inventory.json").path,
                ]
            } else {
                arguments += [
                    "--target", "AppTests", "--no-cache", "--mutant-selection-manifest",
                    project.appendingPathComponent("selection.json").path,
                    "--output", project.appendingPathComponent("report.json").path,
                ]
            }
            #expect(
                await SwiftMutationTesting.run(args: arguments, launcher: MockProcessLauncher(exitCode: 1)) == .error)
            let receipt = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: evidence)) as? [String: Any])
            #expect(receipt["operation"] as? String == operation)
        }
    }

    @Test("Validated prepare and target failures each emit one exact failed cache receipt")
    func cacheFailuresBeforeCoordinatorEmitEvidence() async throws {
        for operation in ["prepare", "target"] {
            let project = try FileHelpers.makeTemporaryDirectory()
            let root = try FileHelpers.makeTemporaryDirectory()
            defer {
                FileHelpers.cleanup(project)
                FileHelpers.cleanup(root)
            }
            chmod(project.path, 0o700)
            chmod(root.path, 0o700)
            let manifest = project.appendingPathComponent("manifest.json")
            try Data("{}".utf8).write(to: manifest)
            let evidence = project.appendingPathComponent("evidence.json")
            let identity = String(repeating: operation == "prepare" ? "5" : "6", count: 64)
            var arguments = [
                project.path,
                "--build-cache-root", root.path,
                "--cache-compatibility-id", identity,
                "--project-input-manifest", manifest.path,
                "--cache-evidence-output", evidence.path,
                "--custody-fd", "0",
                "--invocation-nonce", "abcdefghijklmnopqrstuv",
            ]
            if operation == "prepare" {
                arguments += [
                    "--prepare-only",
                    "--test-enumeration-output", project.appendingPathComponent("tests.json").path,
                    "--mutant-inventory-output", project.appendingPathComponent("inventory.json").path,
                ]
            } else {
                arguments += [
                    "--target", "TheGuideTests/ExampleTests",
                    "--no-cache",
                    "--mutant-selection-manifest", project.appendingPathComponent("selection.json").path,
                    "--output", project.appendingPathComponent("report.json").path,
                ]
            }

            #expect(
                await SwiftMutationTesting.run(args: arguments, launcher: MockProcessLauncher(exitCode: 1)) == .error)
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: evidence)) as? [String: Any]
            )
            #expect(object["operation"] as? String == operation)
            #expect(object["outcome"] as? String == "failed")
            #expect(object["sourceBearingBytesScrubbed"] as? Bool == true)
            #expect(object["childGroupsQuiescent"] as? Bool == true)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: project.path)
                    .filter { $0.hasPrefix("evidence") }.count == 1)
        }
    }

    @Test("Recover mode scrubs dirty materialized source without discovery")
    func recoverModeScrubsDirtyProject() async throws {
        let project = try FileHelpers.makeTemporaryDirectory()
        let root = try FileHelpers.makeTemporaryDirectory()
        defer {
            FileHelpers.cleanup(project)
            FileHelpers.cleanup(root)
        }
        chmod(project.path, 0o700)
        chmod(root.path, 0o700)
        let identity = String(repeating: "7", count: 64)
        let store = PreparedBuildStore(root: root.path, compatibilityID: identity)
        try store.reset()
        let recovery = CacheRecovery(identityDirectory: store.directory, collectionRoot: root)
        try recovery.markDirty()
        try FileManager.default.createDirectory(at: store.sandboxURL, withIntermediateDirectories: true)
        try Data("private source".utf8).write(to: store.sandboxURL.appendingPathComponent("Source.swift"))
        let manifest = project.appendingPathComponent("manifest.json")
        try Data("{}".utf8).write(to: manifest)
        let evidence = project.appendingPathComponent("evidence.json")

        let result = await SwiftMutationTesting.run(
            args: [
                project.path,
                "--build-cache-root", root.path,
                "--cache-compatibility-id", identity,
                "--project-input-manifest", manifest.path,
                "--cache-evidence-output", evidence.path,
                "--recover-only",
                "--custody-fd", "0",
                "--invocation-nonce", "abcdefghijklmnopqrstuv",
            ], launcher: MockProcessLauncher(exitCode: 0))

        #expect(result == .success)
        #expect(!FileManager.default.fileExists(atPath: store.sandboxURL.path))
    }

    @Test("Given valid config with macOS destination and no Swift files, when run called, then returns success")
    func mainExecutionPathWithEmptyProjectReturnsSuccess() async throws {
        let dir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(dir) }

        let yml = "scheme: NonExistentScheme\ndestination: platform=macOS\n"
        try yml.write(to: dir.appendingPathComponent(".swift-mutation-testing.yml"), atomically: true, encoding: .utf8)

        let result = await SwiftMutationTesting.run(
            args: [dir.path],
            launcher: MockProcessLauncher(exitCode: 1)
        )

        #expect(result == .success)

        #expect(await SwiftMutationTesting.run(args: [dir.path]) == .success)
    }

    @Test("Given valid config with quiet false and no Swift files, when run called, then returns success")
    func quietFalseExecutionPathReturnsSuccess() async throws {
        let dir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(dir) }

        let yml = "scheme: NonExistentScheme\ndestination: platform=macOS\nquiet: false\n"
        try yml.write(to: dir.appendingPathComponent(".swift-mutation-testing.yml"), atomically: true, encoding: .utf8)

        let result = await SwiftMutationTesting.run(
            args: [dir.path],
            launcher: MockProcessLauncher(exitCode: 1)
        )

        #expect(result == .success)
    }

    @Test("Given iOS Simulator destination with invalid simctl output, when run called, then returns error")
    func iOSSimulatorDestinationWithInvalidSimctlOutputReturnsError() async throws {
        let dir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(dir) }

        let yml = "scheme: NonExistentScheme\ndestination: \"platform=iOS Simulator,name=iPhone 15\"\n"
        try yml.write(to: dir.appendingPathComponent(".swift-mutation-testing.yml"), atomically: true, encoding: .utf8)

        let result = await SwiftMutationTesting.run(
            args: [dir.path],
            launcher: MockProcessLauncher(exitCode: 1, output: "not-valid-json")
        )

        #expect(result == .error)
    }

    @Test("Given iOS Simulator destination with valid simctl output, when run called, then SimulatorPool is created")
    func iOSSimulatorPoolIsCreatedWhenDestinationRequiresSimulator() async throws {
        let dir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(dir) }

        let cloneUDID = "CLONE-UDID"
        let listJSON = """
            {"devices":{"com.apple.runtime.iOS":[
                {"udid":"BASE-UDID","name":"iPhone 15","state":"Booted"},
                {"udid":"\(cloneUDID)","name":"Clone","state":"Booted"}
            ]}}
            """
        let yml = "scheme: NonExistentScheme\ndestination: \"platform=iOS Simulator,name=iPhone 15\"\n"
        try yml.write(to: dir.appendingPathComponent(".swift-mutation-testing.yml"), atomically: true, encoding: .utf8)

        let result = await SwiftMutationTesting.run(
            args: [dir.path],
            launcher: IOSSimulatorMock(listJSON: listJSON, cloneUDID: cloneUDID)
        )

        #expect(result == .success)
    }

    @Test("Given xcode project type, when defaultLauncher called, then returns XcodeProcessLauncher")
    func defaultLauncherForXcodeReturnsXcodeProcessLauncher() {
        let launcher = SwiftMutationTesting.defaultLauncher(for: .xcode(scheme: "S", destination: "d"))
        #expect(launcher is XcodeProcessLauncher)
    }

    @Test("Given spm project type, when defaultLauncher called, then returns SPMProcessLauncher")
    func defaultLauncherForSPMReturnsSPMProcessLauncher() {
        let launcher = SwiftMutationTesting.defaultLauncher(for: .spm)
        #expect(launcher is SPMProcessLauncher)
    }

    @Test("Given corrupted cache file at project path, when run called, then returns error")
    func corruptedCacheFileReturnsError() async throws {
        let dir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(dir) }

        let yml = "scheme: NonExistentScheme\ndestination: platform=macOS\n"
        try yml.write(to: dir.appendingPathComponent(".swift-mutation-testing.yml"), atomically: true, encoding: .utf8)

        let cacheDir = dir.appendingPathComponent(CacheStore.directoryName)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try "not valid json at all!!!".write(
            to: cacheDir.appendingPathComponent("results.json"),
            atomically: true,
            encoding: .utf8
        )

        let result = await SwiftMutationTesting.run(
            args: [dir.path],
            launcher: MockProcessLauncher(exitCode: 1)
        )

        #expect(result == .error)
    }
}

private actor ExecutionGateSimulatorLauncher: ProcessLaunching {
    private var exists = false
    private(set) var deleteCount = 0
    private(set) var xcodeDeviceSetEnvironmentCount = 0
    func launch(executableURL: URL, arguments: [String], workingDirectoryURL: URL, timeout: Double) async throws -> Int32 {
        if arguments.contains("delete") {
            exists = false
            deleteCount += 1
        }
        return 0
    }
    func launchCapturing(_ request: ProcessRequest) async throws -> (exitCode: Int32, output: String) {
        if request.executableURL.path == "/usr/bin/xcodebuild",
            request.additionalEnvironment["SIMULATOR_DEVICE_SET_PATH"] != nil
        {
            xcodeDeviceSetEnvironmentCount += 1
        }
        if request.arguments.contains("build-for-testing"),
            let index = request.arguments.firstIndex(of: "-derivedDataPath")
        {
            let products = URL(fileURLWithPath: request.arguments[index + 1]).appendingPathComponent("Build/Products")
            try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["__xctestrun_metadata__": ["FormatVersion": 1]], format: .xml, options: 0)
            try plist.write(to: products.appendingPathComponent("App.xctestrun"))
        }
        if request.arguments.contains("clone") {
            exists = true
            return (0, "GATE-UDID\n")
        }
        if request.arguments.contains("devicetypes") {
            return (0, #"{"devicetypes":[{"name":"iPhone 16","identifier":"type"}]}"#)
        }
        if request.arguments.contains("runtimes") {
            return (0, #"{"runtimes":[{"identifier":"runtime","isAvailable":true}]}"#)
        }
        return exists
            ? (0, #"{"devices":{"runtime":[{"name":"iPhone 16","udid":"SOURCE-UDID","deviceTypeIdentifier":"type","isAvailable":true},{"name":"SwiftMutationGate-ABCDEFGHIJKLMNOPQRSTUV","udid":"GATE-UDID","deviceTypeIdentifier":"type","isAvailable":true}]}}"#)
            : (0, #"{"devices":{"runtime":[{"name":"iPhone 16","udid":"SOURCE-UDID","deviceTypeIdentifier":"type","isAvailable":true}]}}"#)
    }
}

private final class DispatchPreparedLauncher: @unchecked Sendable, ProcessLaunching {
    func launch(
        executableURL: URL, arguments: [String], workingDirectoryURL: URL, timeout: Double
    ) async throws -> Int32 { 0 }

    func launchCapturing(_ request: ProcessRequest) async throws -> (exitCode: Int32, output: String) {
        if request.arguments.contains("build-for-testing"),
            let index = request.arguments.firstIndex(of: "-derivedDataPath")
        {
            let products = URL(fileURLWithPath: request.arguments[index + 1]).appendingPathComponent("Build/Products")
            try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["__xctestrun_metadata__": ["FormatVersion": 1]], format: .xml, options: 0
            )
            try plist.write(to: products.appendingPathComponent("App.xctestrun"))
            try Data("compiled".utf8).write(to: products.appendingPathComponent("App"))
        }
        if request.arguments.contains("-enumerate-tests"),
            let index = request.arguments.firstIndex(of: "-test-enumeration-output-path")
        {
            try Data("{\"values\":[]}".utf8).write(to: URL(fileURLWithPath: request.arguments[index + 1]))
        }
        return (0, "")
    }
}
