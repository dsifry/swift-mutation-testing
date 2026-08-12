import Darwin
import Foundation
import Testing

@testable import SwiftMutationTesting

@Suite("SimulatorManager")
struct SimulatorManagerTests {
    @Test("One gate simulator is registered, reused, and deleted exactly once")
    func gateSimulatorLifecycleUsesStableUDID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-simulator-\(UUID().uuidString)", isDirectory: true)
        let registrationURL = root.appendingPathComponent("registration.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = GateSimulatorCommandLog()
        let manager = SimulatorManager(launcher: launcher)

        let registration = try await manager.prepareGateSimulator(
            destination: "platform=iOS Simulator,name=iPhone 16",
            cacheRoot: root,
            registrationURL: registrationURL,
            gateRunNonce: "ABCDEFGHIJKLMNOPQRSTUV",
            guideLockInode: 42
        )
        #expect(registration.udid == "GATE-UDID")
        #expect(registration.state == .idle)
        #expect(try GateSimulatorRegistration.load(from: registrationURL).udid == "GATE-UDID")

        let pool = SimulatorPool(
            registeredUDID: registration.udid,
            destination: "platform=iOS Simulator,name=iPhone 16",
            launcher: launcher
        )
        try await pool.setUp()
        for _ in 0 ..< 103 {
            let slot = try await pool.acquire()
            #expect(slot.udid == "GATE-UDID")
            await pool.release(slot)
        }
        await pool.tearDown()
        try await manager.cleanupGateSimulator(
            registrationURL: registrationURL,
            expectedGateRunNonce: "ABCDEFGHIJKLMNOPQRSTUV",
            expectedGuideLockInode: 42
        )

        let commands = await launcher.commands
        #expect(commands.filter { $0.contains(" create ") }.count == 1)
        #expect(commands.filter { $0.contains(" boot GATE-UDID") }.count == 1)
        #expect(commands.filter { $0.contains(" shutdown GATE-UDID") }.count == 1)
        #expect(commands.filter { $0.contains(" delete GATE-UDID") }.count == 1)
        #expect(try GateSimulatorRegistration.load(from: registrationURL).state == .deleted)
    }

    @Test("A wrapper or engine failure cleans the bound gate simulator before returning")
    func failedInvocationCleansBoundGateSimulator() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-simulator-failure-\(UUID().uuidString)", isDirectory: true)
        let registrationURL = root.appendingPathComponent("registration.json")
        let lockURL = root.appendingPathComponent("guide.lock")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: lockURL.path, contents: Data())
        let descriptor = open(lockURL.path, O_RDONLY | O_CLOEXEC)
        defer {
            _ = close(descriptor)
            try? FileManager.default.removeItem(at: root)
        }
        var metadata = stat()
        #expect(fstat(descriptor, &metadata) == 0)
        let launcher = GateSimulatorCommandLog()
        let manager = SimulatorManager(launcher: launcher)
        _ = try await manager.prepareGateSimulator(
            destination: "platform=iOS Simulator,name=iPhone 16",
            cacheRoot: root,
            registrationURL: registrationURL,
            gateRunNonce: "ABCDEFGHIJKLMNOPQRSTUV",
            guideLockInode: UInt64(metadata.st_ino)
        )
        _ = try await manager.activateRegistration(
            at: registrationURL, expectedCacheRoot: root,
            expectedGuideLockInode: UInt64(metadata.st_ino),
            invocationNonce: "INVOCATIONABCDEFGHIJKL")
        let parsed = ParsedArguments(cache: .init(
            mode: .legacyBenchmark,
            buildCacheRoot: root.path,
            invocationNonce: "INVOCATIONABCDEFGHIJKL",
            simulatorRegistration: registrationURL.path,
            guideLockFD: Int(descriptor)
        ))

        await SwiftMutationTesting.cleanupBoundSimulatorAfterFailure(parsed: parsed, launcher: launcher)

        #expect(try GateSimulatorRegistration.load(from: registrationURL).state == .deleted)
        let commands = await launcher.commands
        #expect(commands.filter { $0.contains(" shutdown GATE-UDID") }.count == 1)
        #expect(commands.filter { $0.contains(" delete GATE-UDID") }.count == 1)
    }

    @Test("Gate simulator registration rejects extra keys and unauthenticated state")
    func registrationIsClosedAndFailClosed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-registration-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"activeInvocationNonce":null,"deviceSetPath":"/tmp/device-set","deviceTypeIdentifier":"type","extra":true,"gateRunNonce":"ABCDEFGHIJKLMNOPQRSTUV","generation":1,"guideLockInode":42,"runtimeIdentifier":"runtime","schemaVersion":1,"state":"idle","udid":"GATE-UDID"}"#.utf8)
            .write(to: url)

        #expect(throws: (any Error).self) {
            _ = try GateSimulatorRegistration.load(from: url)
        }
    }

    @Test("Gate registration validates an idle device-set and preserves active invocation encoding")
    func validatesRegistrationAndEncodesActiveInvocation() throws {
        let root = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(root) }
        let registrationURL = root.appendingPathComponent("registration.json")
        let registration = GateSimulatorRegistration(
            schemaVersion: 1, gateRunNonce: "ABCDEFGHIJKLMNOPQRSTUV", guideLockInode: 42,
            deviceSetPath: root.path, udid: "GATE-UDID", runtimeIdentifier: "runtime",
            deviceTypeIdentifier: "type", generation: 1, state: .idle,
            activeInvocationNonce: "abcdefghijklmnopqrstuv"
        )
        try JSONEncoder().encode(registration).write(to: registrationURL)
        let decoded = try JSONDecoder().decode(
            GateSimulatorRegistration.self, from: Data(contentsOf: registrationURL))
        #expect(decoded.activeInvocationNonce == "abcdefghijklmnopqrstuv")

        let idle = GateSimulatorRegistration(
            schemaVersion: 1, gateRunNonce: "ABCDEFGHIJKLMNOPQRSTUV", guideLockInode: 42,
            deviceSetPath: root.path, udid: "GATE-UDID", runtimeIdentifier: "runtime",
            deviceTypeIdentifier: "type", generation: 1, state: .idle,
            activeInvocationNonce: nil
        )
        try JSONEncoder().encode(idle).write(to: registrationURL)
        #expect(try SimulatorManager.validatedRegistration(
            at: registrationURL, expectedGuideLockInode: 42).udid == "GATE-UDID")
    }

    @Test("Gate preparation rejects an existing receipt and removes its device set after create failure")
    func preparationFailureIsFailClosedAndScrubsDeviceSet() async throws {
        let root = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(root) }
        let registrationURL = root.appendingPathComponent("registration.json")
        try Data().write(to: registrationURL)
        await #expect(throws: SimulatorError.self) {
            try await SimulatorManager(launcher: GateSimulatorCommandLog()).prepareGateSimulator(
                destination: "platform=iOS Simulator,name=iPhone 16", cacheRoot: root,
                registrationURL: registrationURL, gateRunNonce: "ABCDEFGHIJKLMNOPQRSTUV",
                guideLockInode: 42)
        }
        try FileManager.default.removeItem(at: registrationURL)

        let launcher = GateSimulatorFailureLog()
        await #expect(throws: SimulatorError.self) {
            try await SimulatorManager(launcher: launcher).prepareGateSimulator(
                destination: "platform=iOS Simulator,name=Unknown", cacheRoot: root,
                registrationURL: registrationURL, gateRunNonce: "abcdefghijklmnopqrstuv",
                guideLockInode: 42)
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("gate-simulator-abcdefghijklmnopqrstuv").path))
    }

    @Test("Gate cleanup rejects a device still present after deletion")
    func cleanupRequiresDeletionReadback() async throws {
        let root = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(root) }
        let deviceSet = root.appendingPathComponent("device-set")
        try FileManager.default.createDirectory(at: deviceSet, withIntermediateDirectories: false)
        let url = root.appendingPathComponent("registration.json")
        let registration = GateSimulatorRegistration(
            schemaVersion: 1, gateRunNonce: "ABCDEFGHIJKLMNOPQRSTUV", guideLockInode: 42,
            deviceSetPath: deviceSet.path, udid: "GATE-UDID", runtimeIdentifier: "runtime",
            deviceTypeIdentifier: "type", generation: 1, state: .idle, activeInvocationNonce: nil)
        try JSONEncoder().encode(registration).write(to: url)
        await #expect(throws: SimulatorError.self) {
            try await SimulatorManager(launcher: GateSimulatorStillListedLog()).cleanupGateSimulator(
                registrationURL: url, expectedGateRunNonce: nil, expectedGuideLockInode: 42)
        }
    }
    @Test("Given iOS Simulator destination, when requiresSimulatorPool called, then returns true")
    func requiresSimulatorPoolReturnsTrueForIOSSimulator() {
        let result = SimulatorManager.requiresSimulatorPool(for: "platform=iOS Simulator,name=iPhone 15")

        #expect(result)
    }

    @Test("Given macOS destination, when requiresSimulatorPool called, then returns false")
    func requiresSimulatorPoolReturnsFalseForMacOS() {
        let result = SimulatorManager.requiresSimulatorPool(for: "platform=macOS,arch=arm64")

        #expect(!result)
    }

    @Test("Given destination with name, when resolveBaseUDID called, then returns matching UDID")
    func resolveBaseUDIDFindsDeviceByName() async throws {
        let json = SimulatorCommandMock.bootedDevicesJSON(udid: "FOUND-UDID", name: "iPhone 15")
        let manager = SimulatorManager(launcher: SimulatorCommandMock(listOutput: json, cloneUDID: ""))

        let udid = try await manager.resolveBaseUDID(for: "platform=iOS Simulator,name=iPhone 15")

        #expect(udid == "FOUND-UDID")
    }

    @Test("Given destination with id, when resolveBaseUDID called, then returns the given UDID")
    func resolveBaseUDIDReturnsDirectID() async throws {
        let json = SimulatorCommandMock.bootedDevicesJSON(udid: "DIRECT-UDID")
        let manager = SimulatorManager(launcher: SimulatorCommandMock(listOutput: json, cloneUDID: ""))

        let udid = try await manager.resolveBaseUDID(for: "platform=iOS Simulator,id=DIRECT-UDID")

        #expect(udid == "DIRECT-UDID")
    }

    @Test("Given destination with unknown name, when resolveBaseUDID called, then throws deviceNotFound")
    func resolveBaseUDIDThrowsForUnknownDevice() async throws {
        let emptyJSON = #"{"devices":{}}"#
        let manager = SimulatorManager(
            launcher: SimulatorCommandMock(listOutput: emptyJSON, cloneUDID: "")
        )

        await #expect(throws: SimulatorError.self) {
            try await manager.resolveBaseUDID(for: "platform=iOS Simulator,name=Unknown Device")
        }
    }

    @Test("Given booted device in JSON, when waitForBooted called, then returns on first poll without sleeping")
    func waitForBootedReturnsOnFirstPoll() async throws {
        let json = SimulatorCommandMock.bootedDevicesJSON(udid: "TEST-UDID")
        let manager = SimulatorManager(launcher: SimulatorCommandMock(listOutput: json, cloneUDID: ""))

        let start = Date()
        try await manager.waitForBooted(udid: "TEST-UDID")
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.4)
    }

    @Test("Given destination without platform= prefix, when requiresSimulatorPool called, then returns true")
    func requiresSimulatorPoolReturnsTrueForUnknownPlatform() {
        let result = SimulatorManager.requiresSimulatorPool(for: "name=My Device,OS=latest")
        #expect(result)
    }

    @Test("Given simulator never boots within max attempts, when waitForBooted called, then throws bootTimeout")
    func waitForBootedThrowsBootTimeoutWhenNeverBoots() async {
        let json = SimulatorCommandMock.bootedDevicesJSON(udid: "OTHER-UDID")
        let manager = SimulatorManager(launcher: SimulatorCommandMock(listOutput: json, cloneUDID: ""))

        await #expect(throws: SimulatorError.self) {
            try await manager.waitForBooted(udid: "TEST-UDID", maxAttempts: 1, sleepDuration: .zero)
        }
    }

    @Test("Given destination with neither id nor name, when resolveBaseUDID called, then throws deviceNotFound")
    func resolveBaseUDIDThrowsWhenNoIdOrName() async {
        let json = SimulatorCommandMock.bootedDevicesJSON(udid: "ANY-UDID")
        let manager = SimulatorManager(launcher: SimulatorCommandMock(listOutput: json, cloneUDID: ""))

        await #expect(throws: SimulatorError.self) {
            try await manager.resolveBaseUDID(for: "platform=iOS Simulator,arch=arm64")
        }
    }

    @Test("Given device list with non-matching name, when resolveBaseUDID called, then throws deviceNotFound")
    func resolveBaseUDIDThrowsWhenDeviceNameNotFoundInNonEmptyList() async {
        let json = SimulatorCommandMock.bootedDevicesJSON(udid: "OTHER-UDID", name: "iPhone 99")
        let manager = SimulatorManager(launcher: SimulatorCommandMock(listOutput: json, cloneUDID: ""))

        await #expect(throws: SimulatorError.self) {
            try await manager.resolveBaseUDID(for: "platform=iOS Simulator,name=iPhone 15")
        }
    }

    @Test("Given malformed JSON from simctl, when resolveBaseUDID with name called, then throws deviceNotFound")
    func resolveBaseUDIDThrowsForMalformedJSON() async {
        let manager = SimulatorManager(
            launcher: SimulatorCommandMock(listOutput: "not json", cloneUDID: "")
        )

        await #expect(throws: SimulatorError.self) {
            try await manager.resolveBaseUDID(for: "platform=iOS Simulator,name=iPhone 15")
        }
    }

    @Test("Given device not booted on first poll but booted on second, when waitForBooted called, then retries")
    func waitForBootedSleepsAndRetriesUntilBooted() async throws {
        let shutdown = #"{"devices":{"com.apple.runtime.iOS":[{"udid":"TEST-UDID","name":"M","state":"Shutdown"}]}}"#
        let booted = SimulatorCommandMock.bootedDevicesJSON(udid: "TEST-UDID")
        let manager = SimulatorManager(launcher: SequentialOutputMock(outputs: [shutdown, booted]))

        try await manager.waitForBooted(udid: "TEST-UDID", maxAttempts: 3, sleepDuration: .zero)
    }

    @Test("Given device never booted across attempts, when waitForBooted called, then throws bootTimeout with udid")
    func waitForBootedThrowsBootTimeoutWithCorrectUDID() async {
        let notBooted = #"{"devices":{"com.apple.runtime.iOS":[{"udid":"OTHER","name":"Mock","state":"Shutdown"}]}}"#
        let manager = SimulatorManager(
            launcher: SequentialOutputMock(outputs: [notBooted, notBooted, notBooted])
        )

        var threwBootTimeout = false
        do {
            try await manager.waitForBooted(udid: "TEST-UDID", maxAttempts: 2, sleepDuration: .zero)
        } catch SimulatorError.bootTimeout(udid: "TEST-UDID") {
            threwBootTimeout = true
        } catch {}

        #expect(threwBootTimeout)
    }
}

private actor GateSimulatorCommandLog: ProcessLaunching {
    private(set) var commands: [String] = []
    private var exists = false

    func launch(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL,
        timeout: Double
    ) async throws -> Int32 {
        commands.append(([executableURL.path] + arguments).joined(separator: " "))
        if arguments.contains("delete") { exists = false }
        return 0
    }

    func launchCapturing(_ request: ProcessRequest) async throws -> (exitCode: Int32, output: String) {
        commands.append(([request.executableURL.path] + request.arguments).joined(separator: " "))
        if request.arguments.contains("create") {
            exists = true
            return (0, "GATE-UDID\n")
        }
        if request.arguments.contains("devicetypes") {
            return (0, #"{"devicetypes":[{"name":"iPhone 16","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-16"}]}"#)
        }
        if request.arguments.contains("runtimes") {
            return (0, #"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-0","isAvailable":true}]}"#)
        }
        return exists
            ? (0, #"{"devices":{"runtime":[{"udid":"GATE-UDID"}]}}"#)
            : (0, #"{"devices":{}}"#)
    }
}

private struct GateSimulatorFailureLog: ProcessLaunching {
    func launch(executableURL: URL, arguments: [String], workingDirectoryURL: URL, timeout: Double) async throws -> Int32 { 0 }
    func launchCapturing(_ request: ProcessRequest) async throws -> (exitCode: Int32, output: String) {
        if request.arguments.contains("create") { return (1, "") }
        return (1, "not-json")
    }
}

private struct GateSimulatorStillListedLog: ProcessLaunching {
    func launch(executableURL: URL, arguments: [String], workingDirectoryURL: URL, timeout: Double) async throws -> Int32 { 0 }
    func launchCapturing(_ request: ProcessRequest) async throws -> (exitCode: Int32, output: String) {
        (0, "GATE-UDID")
    }
}
