import Foundation

struct GateSimulatorRegistration: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case creating, idle, active, cleaning, deleted }

    let schemaVersion: Int
    let gateRunNonce: String
    let guideLockInode: UInt64
    let deviceSetPath: String
    let udid: String
    let runtimeIdentifier: String
    let deviceTypeIdentifier: String
    let generation: Int
    let state: State
    let activeInvocationNonce: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, gateRunNonce, guideLockInode, deviceSetPath, udid
        case runtimeIdentifier, deviceTypeIdentifier, generation, state, activeInvocationNonce
    }

    init(
        schemaVersion: Int,
        gateRunNonce: String,
        guideLockInode: UInt64,
        deviceSetPath: String,
        udid: String,
        runtimeIdentifier: String,
        deviceTypeIdentifier: String,
        generation: Int,
        state: State,
        activeInvocationNonce: String?
    ) {
        self.schemaVersion = schemaVersion
        self.gateRunNonce = gateRunNonce
        self.guideLockInode = guideLockInode
        self.deviceSetPath = deviceSetPath
        self.udid = udid
        self.runtimeIdentifier = runtimeIdentifier
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.generation = generation
        self.state = state
        self.activeInvocationNonce = activeInvocationNonce
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        gateRunNonce = try container.decode(String.self, forKey: .gateRunNonce)
        guideLockInode = try container.decode(UInt64.self, forKey: .guideLockInode)
        deviceSetPath = try container.decode(String.self, forKey: .deviceSetPath)
        udid = try container.decode(String.self, forKey: .udid)
        runtimeIdentifier = try container.decode(String.self, forKey: .runtimeIdentifier)
        deviceTypeIdentifier = try container.decode(String.self, forKey: .deviceTypeIdentifier)
        generation = try container.decode(Int.self, forKey: .generation)
        state = try container.decode(State.self, forKey: .state)
        activeInvocationNonce = try container.decodeIfPresent(String.self, forKey: .activeInvocationNonce)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(gateRunNonce, forKey: .gateRunNonce)
        try container.encode(guideLockInode, forKey: .guideLockInode)
        try container.encode(deviceSetPath, forKey: .deviceSetPath)
        try container.encode(udid, forKey: .udid)
        try container.encode(runtimeIdentifier, forKey: .runtimeIdentifier)
        try container.encode(deviceTypeIdentifier, forKey: .deviceTypeIdentifier)
        try container.encode(generation, forKey: .generation)
        try container.encode(state, forKey: .state)
        if let activeInvocationNonce {
            try container.encode(activeInvocationNonce, forKey: .activeInvocationNonce)
        } else {
            try container.encodeNil(forKey: .activeInvocationNonce)
        }
    }

    static func load(from url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue))
        else { throw SimulatorError.cloneFailed(udid: "invalid gate registration") }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func replacing(state: State) -> Self {
        Self(
            schemaVersion: schemaVersion, gateRunNonce: gateRunNonce,
            guideLockInode: guideLockInode, deviceSetPath: deviceSetPath, udid: udid,
            runtimeIdentifier: runtimeIdentifier, deviceTypeIdentifier: deviceTypeIdentifier,
            generation: generation, state: state, activeInvocationNonce: nil
        )
    }
}

struct SimulatorManager: Sendable {
    let launcher: any ProcessLaunching
    var executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")

    static func requiresSimulatorPool(for destination: String) -> Bool {
        guard !destination.contains("platform=macOS") else { return false }
        return destination.contains("Simulator") || !destination.contains("platform=")
    }

    func prepareGateSimulator(
        destination: String,
        cacheRoot: URL,
        registrationURL: URL,
        gateRunNonce: String,
        guideLockInode: UInt64
    ) async throws -> GateSimulatorRegistration {
        guard !FileManager.default.fileExists(atPath: registrationURL.path) else {
            throw SimulatorError.cloneFailed(udid: "existing gate registration")
        }
        let name = parseValue(for: "name", in: destination) ?? "iPhone 16"
        let deviceType = try await identifier(
            list: "devicetypes", collection: "devicetypes", matchingName: name,
            fallback: "com.apple.CoreSimulator.SimDeviceType.iPhone-16"
        )
        let runtime = try await identifier(
            list: "runtimes", collection: "runtimes", matchingName: nil,
            fallback: "com.apple.CoreSimulator.SimRuntime.iOS"
        )
        let deviceSet = cacheRoot.appendingPathComponent("gate-simulator-\(gateRunNonce)", isDirectory: true)
        try FileManager.default.createDirectory(at: deviceSet, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deviceSet.path)

        let creating = GateSimulatorRegistration(
            schemaVersion: 1, gateRunNonce: gateRunNonce, guideLockInode: guideLockInode,
            deviceSetPath: deviceSet.path, udid: "", runtimeIdentifier: runtime,
            deviceTypeIdentifier: deviceType, generation: 1, state: .creating,
            activeInvocationNonce: nil
        )
        try write(creating, to: registrationURL)
        do {
            let result = try await launchCapturing(
                ["simctl", "--set", deviceSet.path, "create", "SwiftMutationGate", deviceType, runtime]
            )
            guard result.exitCode == 0 else { throw SimulatorError.cloneFailed(udid: "gate simulator") }
            let udid = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !udid.isEmpty else { throw SimulatorError.cloneFailed(udid: "gate simulator") }
            let idle = GateSimulatorRegistration(
                schemaVersion: 1, gateRunNonce: gateRunNonce, guideLockInode: guideLockInode,
                deviceSetPath: deviceSet.path, udid: udid, runtimeIdentifier: runtime,
                deviceTypeIdentifier: deviceType, generation: 1, state: .idle,
                activeInvocationNonce: nil
            )
            guard try await launch(["simctl", "--set", deviceSet.path, "boot", udid], timeout: 60) == 0,
                try await launch(["simctl", "--set", deviceSet.path, "bootstatus", udid, "-b"], timeout: 60) == 0
            else { throw SimulatorError.cloneFailed(udid: udid) }
            try write(idle, to: registrationURL)
            return idle
        } catch {
            try? FileManager.default.removeItem(at: deviceSet)
            try? FileManager.default.removeItem(at: registrationURL)
            throw error
        }
    }

    func cleanupGateSimulator(
        registrationURL: URL,
        expectedGateRunNonce: String?,
        expectedGuideLockInode: UInt64,
        expectedCacheRoot: URL? = nil
    ) async throws {
        let registration = try GateSimulatorRegistration.load(from: registrationURL)
        let registeredDeviceSet = URL(fileURLWithPath: registration.deviceSetPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let expectedDeviceSet = expectedCacheRoot?.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(
            "gate-simulator-\(registration.gateRunNonce)", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard registration.schemaVersion == 1,
            expectedGateRunNonce.map({ registration.gateRunNonce == $0 }) ?? true,
            registration.guideLockInode == expectedGuideLockInode,
            registration.generation == 1,
            registration.state == .idle || registration.state == .active,
            registration.state == .active || registration.activeInvocationNonce == nil,
            !registration.udid.isEmpty,
            expectedDeviceSet.map({ registeredDeviceSet == $0 }) ?? true
        else { throw SimulatorError.cloneFailed(udid: "invalid gate registration") }
        try write(registration.replacing(state: .cleaning), to: registrationURL)
        guard try await launch(
            ["simctl", "--set", registration.deviceSetPath, "shutdown", registration.udid], timeout: 30) == 0,
            try await launch(
                ["simctl", "--set", registration.deviceSetPath, "delete", registration.udid], timeout: 30) == 0
        else { throw SimulatorError.cloneFailed(udid: registration.udid) }
        let listed = try await launchCapturing(
            ["simctl", "--set", registration.deviceSetPath, "list", "devices", "--json"])
        guard listed.exitCode == 0, !listed.output.contains(registration.udid) else {
            throw SimulatorError.cloneFailed(udid: registration.udid)
        }
        try FileManager.default.removeItem(atPath: registration.deviceSetPath)
        try write(registration.replacing(state: .deleted), to: registrationURL)
    }

    static func validatedRegistration(
        at url: URL, expectedGuideLockInode: UInt64
    ) throws -> GateSimulatorRegistration {
        let registration = try GateSimulatorRegistration.load(from: url)
        guard registration.schemaVersion == 1,
            registration.guideLockInode == expectedGuideLockInode,
            registration.generation == 1,
            registration.state == .idle,
            registration.activeInvocationNonce == nil,
            !registration.udid.isEmpty,
            FileManager.default.fileExists(atPath: registration.deviceSetPath)
        else { throw SimulatorError.cloneFailed(udid: "invalid gate registration") }
        return registration
    }

    func validatedRegistration(
        at url: URL,
        expectedCacheRoot: URL,
        expectedGuideLockInode: UInt64
    ) async throws -> GateSimulatorRegistration {
        let registration = try Self.validatedRegistration(
            at: url, expectedGuideLockInode: expectedGuideLockInode)
        let root = expectedCacheRoot.resolvingSymlinksInPath().standardizedFileURL
        let expectedDeviceSet = root.appendingPathComponent(
            "gate-simulator-\(registration.gateRunNonce)", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard URL(fileURLWithPath: registration.deviceSetPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL == expectedDeviceSet else {
            throw SimulatorError.cloneFailed(udid: "invalid gate registration")
        }
        let listed = try await launchCapturing(
            ["simctl", "--set", registration.deviceSetPath, "list", "devices", "--json"])
        guard listed.exitCode == 0,
            let data = listed.output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devices = object["devices"] as? [String: [[String: Any]]],
            devices.values.flatMap({ $0 }).contains(where: { $0["udid"] as? String == registration.udid })
        else { throw SimulatorError.cloneFailed(udid: "invalid gate registration") }
        return registration
    }

    func activateRegistration(
        at url: URL,
        expectedCacheRoot: URL,
        expectedGuideLockInode: UInt64,
        invocationNonce: String
    ) async throws -> GateSimulatorRegistration {
        let registration = try await validatedRegistration(
            at: url, expectedCacheRoot: expectedCacheRoot,
            expectedGuideLockInode: expectedGuideLockInode)
        let active = GateSimulatorRegistration(
            schemaVersion: registration.schemaVersion, gateRunNonce: registration.gateRunNonce,
            guideLockInode: registration.guideLockInode, deviceSetPath: registration.deviceSetPath,
            udid: registration.udid, runtimeIdentifier: registration.runtimeIdentifier,
            deviceTypeIdentifier: registration.deviceTypeIdentifier, generation: registration.generation,
            state: .active, activeInvocationNonce: invocationNonce)
        try write(active, to: url)
        return active
    }

    func finishRegistration(
        at url: URL,
        expectedGuideLockInode: UInt64,
        invocationNonce: String
    ) throws {
        let registration = try GateSimulatorRegistration.load(from: url)
        guard registration.state == .active,
            registration.guideLockInode == expectedGuideLockInode,
            registration.activeInvocationNonce == invocationNonce
        else { throw SimulatorError.cloneFailed(udid: "invalid active gate registration") }
        try write(registration.replacing(state: .idle), to: url)
    }

    private func identifier(
        list: String, collection: String, matchingName: String?, fallback: String
    ) async throws -> String {
        let result = try await launchCapturing(["simctl", "list", list, "--json"])
        guard result.exitCode == 0,
            let data = result.output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = object[collection] as? [[String: Any]]
        else { return fallback }
        if let matchingName,
            let match = entries.first(where: { $0["name"] as? String == matchingName }),
            let identifier = match["identifier"] as? String { return identifier }
        if matchingName == nil,
            let match = entries.first(where: { ($0["isAvailable"] as? Bool) != false }),
            let identifier = match["identifier"] as? String { return identifier }
        return fallback
    }

    private func launch(_ arguments: [String], timeout: Double) async throws -> Int32 {
        try await launcher.launch(
            executableURL: executableURL, arguments: arguments,
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: timeout
        )
    }

    private func launchCapturing(_ arguments: [String]) async throws -> (exitCode: Int32, output: String) {
        try await launcher.launchCapturing(ProcessRequest(
            executableURL: executableURL, arguments: arguments,
            environment: nil, additionalEnvironment: [:],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 30
        ))
    }

    private func write(_ registration: GateSimulatorRegistration, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(registration)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func resolveBaseUDID(for destination: String) async throws -> String {
        let udid: String

        if let value = parseValue(for: "id", in: destination) {
            udid = value
        } else if let name = parseValue(for: "name", in: destination) {
            udid = try await findUDID(named: name, destination: destination)
        } else {
            throw SimulatorError.deviceNotFound(destination: destination)
        }

        return udid
    }

    func waitForBooted(
        udid: String,
        maxAttempts: Int = 60,
        sleepDuration: Duration = .milliseconds(500)
    ) async throws {
        for _ in 0 ..< maxAttempts {
            let result = try await launcher.launchCapturing(
                ProcessRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments: ["simctl", "list", "devices", "--json"],
                    environment: nil,
                    additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                    timeout: 10
                )
            )

            if isBooted(udid: udid, in: result.output) { return }

            try await Task.sleep(for: sleepDuration)
        }

        throw SimulatorError.bootTimeout(udid: udid)
    }

    private func parseValue(for key: String, in destination: String) -> String? {
        let prefix = "\(key)="
        return destination.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)) }
    }

    private func findUDID(named name: String, destination: String) async throws -> String {
        let result = try await launcher.launchCapturing(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["simctl", "list", "devices", "--json"],
                environment: nil,
                additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 10
            )
        )

        guard
            let data = result.output.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devices = json["devices"] as? [String: [[String: Any]]]
        else { throw SimulatorError.deviceNotFound(destination: destination) }

        for list in devices.values {
            for device in list {
                if device["name"] as? String == name, let udid = device["udid"] as? String {
                    return udid
                }
            }
        }

        throw SimulatorError.deviceNotFound(destination: destination)
    }

    private func isBooted(udid: String, in output: String) -> Bool {
        guard
            let data = output.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devices = json["devices"] as? [String: [[String: Any]]]
        else { return false }

        for list in devices.values {
            for device in list
            where device["udid"] as? String == udid && device["state"] as? String == "Booted" {
                return true
            }
        }

        return false
    }
}
