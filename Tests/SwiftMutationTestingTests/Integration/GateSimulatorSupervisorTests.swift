import Darwin
import Foundation
import Testing

@testable import SwiftMutationTesting

@Suite("Gate simulator custody supervisor")
struct GateSimulatorSupervisorTests {
    private static let registeredSimulator = GateSimulatorRegistration(
        schemaVersion: 1, gateRunNonce: "GATEABCDEFGHIJKLMNOPQR",
        guideLockInode: 1, deviceSetPath: "/tmp/gate-simulator-GATEABCDEFGHIJKLMNOPQR",
        udid: "GATE-UDID", runtimeIdentifier: "runtime", deviceTypeIdentifier: "type",
        generation: 1, state: .active, activeInvocationNonce: "INVOCATIONABCDEFGHIJKLMNOP")

    @Test("Device lookup fails closed when the exact registered UDID is missing")
    func missingRegisteredDeviceFailsClosed() async {
        let manager = SimulatorManager(launcher: MockProcessLauncher(
            exitCode: 0,
            output: #"{"devices":{"runtime":[{"udid":"GATE-UDID-SUFFIX"}]}}"#))

        #expect(await !GateSimulatorSupervisor.deviceExists(Self.registeredSimulator, manager: manager))
    }

    @Test("Device lookup fails closed when simctl returns malformed JSON")
    func malformedDeviceListFailsClosed() async {
        let manager = SimulatorManager(launcher: MockProcessLauncher(
            exitCode: 0, output: #"{"devices":"#))

        #expect(await !GateSimulatorSupervisor.deviceExists(Self.registeredSimulator, manager: manager))
    }

    @Test("Device lookup fails closed when simctl exits unsuccessfully")
    func unsuccessfulDeviceListFailsClosed() async {
        let manager = SimulatorManager(launcher: MockProcessLauncher(
            exitCode: 1,
            output: #"{"devices":{"runtime":[{"udid":"GATE-UDID"}]}}"#))

        #expect(await !GateSimulatorSupervisor.deviceExists(Self.registeredSimulator, manager: manager))
    }

    @Test("Engine kill helper")
    func engineKillHelper() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let registrationPath = environment["GATE_SUPERVISOR_REGISTRATION"],
            let rootPath = environment["GATE_SUPERVISOR_ROOT"],
            let lockPath = environment["GATE_SUPERVISOR_LOCK"],
            let executablePath = environment["GATE_SUPERVISOR_EXECUTABLE"],
            let xcrunPath = environment["GATE_SUPERVISOR_XCRUN"],
            let readyPath = environment["GATE_SUPERVISOR_READY"]
        else { return }
        let guideFD = open(lockPath, O_RDONLY)
        guard guideFD >= 0 else { throw PreparedCacheError.unverifiableProcessIdentity }
        defer { _ = close(guideFD) }
        var metadata = stat()
        guard fstat(guideFD, &metadata) == 0 else { throw PreparedCacheError.unverifiableProcessIdentity }
        var wrapper: [Int32] = [-1, -1]
        guard pipe(&wrapper) == 0 else { throw PreparedCacheError.unverifiableProcessIdentity }
        defer { wrapper.forEach { _ = close($0) } }
        _ = try GateSimulatorCustodySession.start(
            registrationURL: URL(fileURLWithPath: registrationPath),
            cacheRoot: URL(fileURLWithPath: rootPath, isDirectory: true),
            guideLockInode: UInt64(metadata.st_ino), invocationNonce: "INVOCATIONABCDEFGHIJKLMNOP",
            wrapperLeaseFD: Int(wrapper[0]), guideLockFD: Int(guideFD),
            executableURL: URL(fileURLWithPath: executablePath),
            xcrunURL: URL(fileURLWithPath: xcrunPath))
        try Data("ready".utf8).write(to: URL(fileURLWithPath: readyPath), options: .atomic)
        while true { pause() }
    }

    @Test("A dedicated supervisor deletes the active simulator after literal engine SIGKILL")
    func literalEngineKillCleanup() throws {
        let root = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(root) }
        chmod(root.path, 0o700)
        let deviceSet = root.appendingPathComponent("gate-simulator-GATEABCDEFGHIJKLMNOPQR")
        try FileManager.default.createDirectory(at: deviceSet, withIntermediateDirectories: false)
        chmod(deviceSet.path, 0o700)
        let lock = root.appendingPathComponent("guide.lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        let guideFD = open(lock.path, O_RDONLY)
        defer { _ = close(guideFD) }
        var metadata = stat()
        #expect(fstat(guideFD, &metadata) == 0)
        let registrationURL = root.appendingPathComponent("registration.json")
        let registration = GateSimulatorRegistration(
            schemaVersion: 1, gateRunNonce: "GATEABCDEFGHIJKLMNOPQR",
            guideLockInode: UInt64(metadata.st_ino), deviceSetPath: deviceSet.path,
            udid: "GATE-UDID", runtimeIdentifier: "runtime", deviceTypeIdentifier: "type",
            generation: 1, state: .active, activeInvocationNonce: "INVOCATIONABCDEFGHIJKLMNOP")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(registration).write(to: registrationURL)
        chmod(registrationURL.path, 0o600)

        let deletedMarker = root.appendingPathComponent("deleted")
        let fakeXcrun = root.appendingPathComponent("xcrun")
        let script = """
        #!/bin/sh
        if echo "$*" | grep -q ' delete '; then : > '\(deletedMarker.path)'; exit 0; fi
        if echo "$*" | grep -q 'list devices'; then
          if [ -f '\(deletedMarker.path)' ]; then echo '{"devices":{}}';
          else echo '{
            "devices" : {
              "com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
                {
                  "state" : "Booted",
                  "isAvailable" : true,
                  "name" : "SwiftMutationGate",
                  "udid" : "GATE-UDID"
                }
              ]
            }
          }'; fi
          exit 0
        fi
        exit 0
        """
        try Data(script.utf8).write(to: fakeXcrun)
        chmod(fakeXcrun.path, 0o700)
        let ready = root.appendingPathComponent("ready")
        let buildRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build")
        let cli = try #require(FileManager.default.enumerator(at: buildRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first(where: {
                $0.lastPathComponent == "swift-mutation-testing" && access($0.path, X_OK) == 0
            }))
        let testBundle = try #require(FileManager.default.enumerator(at: buildRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first(where: {
                $0.lastPathComponent == "SwiftMutationTestingPackageTests"
                    && $0.deletingLastPathComponent().lastPathComponent == "MacOS"
            }))
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode.app/Contents/Developer"
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: developerDirectory).appendingPathComponent(
            "Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper")
        helper.arguments = [
            "--test-bundle-path", testBundle.path, "--skip-build", "--no-parallel",
            "--filter", "engineKillHelper", testBundle.path, "--testing-library", "swift-testing",
        ]
        helper.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var environment = ProcessInfo.processInfo.environment
        environment["GATE_SUPERVISOR_REGISTRATION"] = registrationURL.path
        environment["GATE_SUPERVISOR_ROOT"] = root.path
        environment["GATE_SUPERVISOR_LOCK"] = lock.path
        environment["GATE_SUPERVISOR_EXECUTABLE"] = cli.path
        environment["GATE_SUPERVISOR_XCRUN"] = fakeXcrun.path
        environment["GATE_SUPERVISOR_READY"] = ready.path
        environment["LLVM_PROFILE_FILE"] = root.appendingPathComponent("helper-%p.profraw").path
        helper.environment = environment
        try helper.run()
        for _ in 0 ..< 500 where !FileManager.default.fileExists(atPath: ready.path) { usleep(10_000) }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        #expect(kill(helper.processIdentifier, SIGKILL) == 0)
        helper.waitUntilExit()
        for _ in 0 ..< 500 {
            if (try? GateSimulatorRegistration.load(from: registrationURL).state) == .deleted { break }
            usleep(10_000)
        }
        #expect(try GateSimulatorRegistration.load(from: registrationURL).state == .deleted)
        #expect(FileManager.default.fileExists(atPath: deletedMarker.path))
        #expect(!FileManager.default.fileExists(atPath: deviceSet.path))
    }

}
