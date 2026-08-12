import Foundation
import Testing

@testable import SwiftMutationTesting

extension PreparedBuildRecoveryTests {
    @Test("Coordinator binds a registered simulator destination and writes prepared build-count receipt")
    func coordinatorWritesPreparedBuildCountEvidence() async throws {
        let root = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(root) }
        let output = root.appendingPathComponent("build-count.json")
        let base = MockProcessLauncher(exitCode: 0)
        let counter = ObservedBuildCountingLauncher(
            base: base, countBuildForTestingAsIncremental: true)
        _ = try await counter.launchCapturing(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: ["build-for-testing"], environment: nil, additionalEnvironment: [:],
            workingDirectoryURL: root, timeout: 1))
        let coordinator = PreparedBuildCoordinator(
            configuration: makeRunnerConfiguration(projectPath: root.path),
            options: .init(
                mode: .prepare, invocationNonce: "ABCDEFGHIJKLMNOPQRSTUV",
                buildCountEvidenceOutput: output.path),
            launcher: base, registeredSimulatorUDID: "REGISTERED-UDID")

        #expect(coordinator.simulatorBoundDestination("name=iPhone 16")
            == "platform=iOS Simulator,id=REGISTERED-UDID")
        try coordinator.writeBuildCountEvidence(
            counter: counter, projectInputManifestSHA256: "manifest",
            inventorySHA256: "inventory", compatibilitySHA256: "compatibility",
            selector: nil, selection: nil)

        let evidence = try JSONDecoder().decode(
            BuildCountEvidence.self, from: Data(contentsOf: output))
        #expect(evidence.mode == "prepared_cache")
        #expect(evidence.counters.incrementalBuilds == 1)
        #expect(evidence.projectInputManifestSHA256 == "manifest")
    }

    @Test("Build-count evidence is private, deterministic, and binds source bytes")
    func buildCountEvidenceWriterBindsSourceSnapshot() throws {
        let root = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(root) }
        let source = root.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("let enabled = true\n".utf8).write(to: source)
        try Data("let second = false\n".utf8).write(
            to: source.deletingLastPathComponent().appendingPathComponent("Second.swift"))
        chmod(source.path, 0o755)
        try Data("plain\n".utf8).write(to: root.appendingPathComponent("README.txt"))
        let output = root.appendingPathComponent("evidence.json")

        let evidence = try BuildCountEvidenceWriter.make(
            nonce: "ABCDEFGHIJKLMNOPQRSTUV", projectPath: root.path,
            projectInputManifestSHA256: "manifest", inventorySHA256: "inventory",
            compatibilitySHA256: "compatibility", mode: "prepared_cache",
            selector: "AppTests/test", runOrdinal: 7, attemptOrdinal: 1,
            counters: .init(
                fullBuilds: 1, incrementalBuilds: 2,
                testWithoutBuildingRuns: 3, fallbackBuilds: 4))
        let snapshot = try BuildCountEvidenceWriter.sourceSnapshotSHA256(root.path)
        #expect(evidence.sourceSnapshotSHA256 == snapshot)
        try BuildCountEvidenceWriter.write(evidence, to: output)

        #expect(try JSONDecoder().decode(
            BuildCountEvidence.self, from: Data(contentsOf: output)) == evidence)
        #expect(try Data(contentsOf: output).last == 0x0A)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Build-count evidence rejects absent observed counters")
    func buildCountEvidenceRequiresCounters() throws {
        let root = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(root) }
        #expect(throws: PreparedCacheError.self) {
            _ = try BuildCountEvidenceWriter.make(
                nonce: "ABCDEFGHIJKLMNOPQRSTUV", projectPath: root.path,
                projectInputManifestSHA256: nil, inventorySHA256: nil,
                compatibilitySHA256: nil, mode: "prepared_cache", selector: nil,
                runOrdinal: nil, attemptOrdinal: nil)
        }
        #expect(throws: UsageError.self) {
            _ = try BuildCountEvidenceWriter.sourceSnapshotSHA256(
                root.appendingPathComponent("absent").path)
        }
        chmod(root.path, 0o700)
        let manifest = root.appendingPathComponent("manifest.json")
        try Data("manifest".utf8).write(to: manifest)
        let ignoredOutput = root.appendingPathComponent("ignored.json")
        try CacheFailureEvidenceRecorder.record(options: .init(
            mode: .legacyBenchmark, buildCacheRoot: root.path,
            compatibilityID: String(repeating: "a", count: 64),
            projectInputManifest: manifest.path, evidenceOutput: ignoredOutput.path,
            invocationNonce: "ABCDEFGHIJKLMNOPQRSTUV"))
        #expect(!FileManager.default.fileExists(atPath: ignoredOutput.path))
    }
}
