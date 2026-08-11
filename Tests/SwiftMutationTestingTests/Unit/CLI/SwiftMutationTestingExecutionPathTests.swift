import Foundation
import Testing

@testable import SwiftMutationTesting

@Suite("SwiftMutationTesting.run execution path")
struct SwiftMutationTestingExecutionPathTests {
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
