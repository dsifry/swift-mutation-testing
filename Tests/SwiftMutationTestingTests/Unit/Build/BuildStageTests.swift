import Foundation
import Testing

@testable import SwiftMutationTesting

@Suite("BuildStage")
struct BuildStageTests {
    @Test("Given retained derived data, when build called, then it is reused and signing is disabled")
    func usesRetainedDerivedDataAndDisablesSigning() async throws {
        let projectDir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(projectDir) }
        let derivedData = projectDir.appendingPathComponent("retained-derived-data")
        let productsDir = derivedData.appendingPathComponent("Build/Products")
        try FileManager.default.createDirectory(at: productsDir, withIntermediateDirectories: true)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["__xctestrun_metadata__": ["FormatVersion": 1]],
            format: .xml,
            options: 0
        )
        try plistData.write(to: productsDir.appendingPathComponent("App.xctestrun"))
        let launcher = BuildRecordingLauncher()

        let artifact = try await BuildStage(launcher: launcher).build(
            sandbox: Sandbox(rootURL: projectDir),
            scheme: "App",
            destination: "platform=macOS",
            timeout: 60,
            derivedDataURL: derivedData
        )

        let request = try #require(await launcher.request)
        #expect(artifact.derivedDataPath == derivedData.path)
        #expect(request.arguments.contains(derivedData.path))
        #expect(request.arguments.contains("CODE_SIGNING_ALLOWED=NO"))
    }

    @Test("Given successful build and xctestrun present, when build called, then returns BuildArtifact")
    func returnsArtifactOnSuccess() async throws {
        let projectDir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(projectDir) }

        let productsDir = projectDir.appendingPathComponent(".xmr-derived-data/Build/Products")
        try FileManager.default.createDirectory(at: productsDir, withIntermediateDirectories: true)

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["__xctestrun_metadata__": ["FormatVersion": 1]],
            format: .xml,
            options: 0
        )
        try plistData.write(to: productsDir.appendingPathComponent("App.xctestrun"))

        let sandbox = Sandbox(rootURL: projectDir)
        let launcher = BuildRecordingLauncher()
        let stage = BuildStage(launcher: launcher)

        let artifact = try await stage.build(
            sandbox: sandbox,
            scheme: "App",
            destination: "platform=macOS,arch=arm64",
            timeout: 60
        )

        #expect(artifact.derivedDataPath == projectDir.appendingPathComponent(".xmr-derived-data").path)
        #expect(artifact.xctestrunURL?.lastPathComponent == "App.xctestrun")
        #expect(!(try #require(await launcher.request)).arguments.contains("CODE_SIGNING_ALLOWED=NO"))
    }

    @Test("Given build failure, when build called, then throws compilationFailed")
    func throwsCompilationFailedOnNonZeroExitCode() async throws {
        let projectDir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(projectDir) }

        let sandbox = Sandbox(rootURL: projectDir)
        let stage = BuildStage(launcher: MockProcessLauncher(exitCode: 1))

        await #expect {
            try await stage.build(
                sandbox: sandbox,
                scheme: "App",
                destination: "platform=macOS,arch=arm64",
                timeout: 60
            )
        } throws: { error in
            guard case BuildError.compilationFailed = error else { return false }
            return true
        }
    }

    @Test("Given an absent sandbox, when build fails, then project discovery remains fail-safe")
    func absentSandboxBuildFailure() async throws {
        let sandbox = Sandbox(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString))
        await #expect(throws: BuildError.self) {
            try await BuildStage(launcher: MockProcessLauncher(exitCode: 1)).build(
                sandbox: sandbox, scheme: "App", destination: "platform=macOS", timeout: 1
            )
        }
    }

    @Test("Given xcworkspace in sandbox, when build called, then workspace flag is passed")
    func usesWorkspaceFlagWhenXcworkspacePresent() async throws {
        let projectDir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(projectDir) }

        try FileManager.default.createDirectory(
            at: projectDir.appendingPathComponent("MyApp.xcworkspace"),
            withIntermediateDirectories: true
        )
        let productsDir = projectDir.appendingPathComponent(".xmr-derived-data/Build/Products")
        try FileManager.default.createDirectory(at: productsDir, withIntermediateDirectories: true)

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["__xctestrun_metadata__": ["FormatVersion": 1]],
            format: .xml, options: 0
        )
        try plistData.write(to: productsDir.appendingPathComponent("App.xctestrun"))

        let sandbox = Sandbox(rootURL: projectDir)
        let stage = BuildStage(launcher: MockProcessLauncher(exitCode: 0))

        let artifact = try await stage.build(
            sandbox: sandbox, scheme: "App", destination: "platform=macOS", timeout: 60
        )

        #expect(artifact.xctestrunURL?.lastPathComponent == "App.xctestrun")
    }

    @Test("Given xcodeproj in sandbox, when build called, then project flag is passed")
    func usesProjectFlagWhenXcodeprojPresent() async throws {
        let projectDir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(projectDir) }

        try FileManager.default.createDirectory(
            at: projectDir.appendingPathComponent("MyApp.xcodeproj"),
            withIntermediateDirectories: true
        )
        let productsDir = projectDir.appendingPathComponent(".xmr-derived-data/Build/Products")
        try FileManager.default.createDirectory(at: productsDir, withIntermediateDirectories: true)

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["__xctestrun_metadata__": ["FormatVersion": 1]],
            format: .xml, options: 0
        )
        try plistData.write(to: productsDir.appendingPathComponent("App.xctestrun"))

        let sandbox = Sandbox(rootURL: projectDir)
        let stage = BuildStage(launcher: MockProcessLauncher(exitCode: 0))

        let artifact = try await stage.build(
            sandbox: sandbox, scheme: "App", destination: "platform=macOS", timeout: 60
        )

        #expect(artifact.xctestrunURL?.lastPathComponent == "App.xctestrun")
    }

    @Test("Given xctestrun file with invalid plist data, when build called, then throws xctestrunNotFound")
    func throwsXctestrunNotFoundForInvalidPlist() async throws {
        let projectDir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(projectDir) }

        let productsDir = projectDir.appendingPathComponent(".xmr-derived-data/Build/Products")
        try FileManager.default.createDirectory(at: productsDir, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: productsDir.appendingPathComponent("App.xctestrun"))

        let sandbox = Sandbox(rootURL: projectDir)
        let stage = BuildStage(launcher: MockProcessLauncher(exitCode: 0))

        await #expect(throws: BuildError.xctestrunNotFound) {
            try await stage.build(
                sandbox: sandbox, scheme: "App", destination: "platform=macOS", timeout: 60
            )
        }
    }

    @Test("Given successful build but missing xctestrun, when build called, then throws xctestrunNotFound")
    func throwsXctestrunNotFoundWhenFileAbsent() async throws {
        let projectDir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(projectDir) }

        let productsDir = projectDir.appendingPathComponent(".xmr-derived-data/Build/Products")
        try FileManager.default.createDirectory(at: productsDir, withIntermediateDirectories: true)

        let sandbox = Sandbox(rootURL: projectDir)
        let stage = BuildStage(launcher: MockProcessLauncher(exitCode: 0))

        await #expect(throws: BuildError.xctestrunNotFound) {
            try await stage.build(
                sandbox: sandbox,
                scheme: "App",
                destination: "platform=macOS,arch=arm64",
                timeout: 60
            )
        }
    }

    @Test("Given successful SPM build, when buildSPM called, then returns artifact with nil xctestrunURL and plist")
    func spmBuildReturnsArtifactWithNilXctestrunAndPlist() async throws {
        let projectDir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(projectDir) }

        let sandbox = Sandbox(rootURL: projectDir)
        let stage = BuildStage(launcher: MockProcessLauncher(exitCode: 0))

        let artifact = try await stage.buildSPM(sandbox: sandbox, timeout: 60)

        #expect(artifact.derivedDataPath == projectDir.appendingPathComponent(".build").path)
        #expect(artifact.xctestrunURL == nil)
        #expect(artifact.plist == nil)
    }

    @Test("Given SPM build failure, when buildSPM called, then throws compilationFailed")
    func spmBuildFailureThrowsCompilationFailed() async throws {
        let projectDir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(projectDir) }

        let sandbox = Sandbox(rootURL: projectDir)
        let stage = BuildStage(launcher: MockProcessLauncher(exitCode: 1))

        await #expect {
            try await stage.buildSPM(sandbox: sandbox, timeout: 60)
        } throws: { error in
            guard case BuildError.compilationFailed = error else { return false }
            return true
        }
    }

}

private actor BuildRecordingLauncher: ProcessLaunching {
    private(set) var request: ProcessRequest?

    func launch(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL,
        timeout: Double
    ) async throws -> Int32 {
        0
    }

    func launchCapturing(_ request: ProcessRequest) async throws -> (exitCode: Int32, output: String) {
        self.request = request
        return (0, "")
    }
}
