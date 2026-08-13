import Foundation

struct PrepareLifecycleChildIdentity: Codable, Equatable, Sendable {
    let pid: Int32
    let pgid: Int32
    let birthIdentity: String

    static func current() throws -> Self {
        let pid = getpid()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pgid=", "-o", "lstart=", "-p", String(pid)]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try parseProcessIdentity(text, expectedPID: pid)
    }

    static func parseProcessIdentity(_ text: String, expectedPID pid: Int32) throws -> Self {
        let pieces = text.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard pieces.count == 2,
            let pgid = Int32(pieces[0]), pgid == pid
        else { throw PreparedCacheError.unverifiableProcessIdentity }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        guard let date = formatter.date(from: String(pieces[1])) else {
            throw PreparedCacheError.unverifiableProcessIdentity
        }
        return Self(
            pid: pid, pgid: pgid,
            birthIdentity: String(Int64((date.timeIntervalSince1970 * 1_000).rounded())))
    }
}

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
    let prepareLifecycleChild: PrepareLifecycleChildIdentity

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, gateRunNonce, guideLockInode, deviceSetPath, udid
        case runtimeIdentifier, deviceTypeIdentifier, generation, state, activeInvocationNonce
        case prepareLifecycleChild
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
        activeInvocationNonce: String?,
        prepareLifecycleChild: PrepareLifecycleChildIdentity = .init(
            pid: 1, pgid: 1, birthIdentity: "0")
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
        self.prepareLifecycleChild = prepareLifecycleChild
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
        prepareLifecycleChild = try container.decode(
            PrepareLifecycleChildIdentity.self, forKey: .prepareLifecycleChild)
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
        try container.encode(prepareLifecycleChild, forKey: .prepareLifecycleChild)
    }

    static func load(from url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue)),
            let child = object[CodingKeys.prepareLifecycleChild.rawValue] as? [String: Any],
            Set(child.keys) == Set(["pid", "pgid", "birthIdentity"]),
            let pid = child["pid"] as? Int, pid > 0,
            let pgid = child["pgid"] as? Int, pgid == pid,
            let birthIdentity = child["birthIdentity"] as? String,
            (1 ... 32).contains(birthIdentity.count),
            birthIdentity.allSatisfy(\.isNumber)
        else { throw SimulatorError.cloneFailed(udid: "invalid gate registration") }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func replacing(state: State) -> Self {
        Self(
            schemaVersion: schemaVersion, gateRunNonce: gateRunNonce,
            guideLockInode: guideLockInode, deviceSetPath: deviceSetPath, udid: udid,
            runtimeIdentifier: runtimeIdentifier, deviceTypeIdentifier: deviceTypeIdentifier,
            generation: generation, state: state, activeInvocationNonce: nil,
            prepareLifecycleChild: prepareLifecycleChild
        )
    }
}

struct SimulatorManager: Sendable {
    let launcher: any ProcessLaunching
    var executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    var defaultDeviceSetURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL

    static func requiresSimulatorPool(for destination: String) -> Bool {
        guard !destination.contains("platform=macOS") else { return false }
        return destination.contains("Simulator") || !destination.contains("platform=")
    }

    func prepareGateSimulator(
        destination: String,
        cacheRoot: URL,
        registrationURL: URL,
        gateRunNonce: String,
        guideLockInode: UInt64,
        prepareLifecycleChild: PrepareLifecycleChildIdentity? = nil
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
        let sourceUDID = try await sourceUDID(
            destination: destination, runtimeIdentifier: runtime,
            deviceTypeIdentifier: deviceType)
        let cloneName = "SwiftMutationGate-\(gateRunNonce)"
        let prepareChild = prepareLifecycleChild ?? .init(pid: 1, pgid: 1, birthIdentity: "0")
        var clonedUDID: String?
        do {
            let result = try await launchCapturing(
                ["simctl", "clone", sourceUDID, cloneName]
            )
            guard result.exitCode == 0 else { throw SimulatorError.cloneFailed(udid: "gate simulator") }
            let udid = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !udid.isEmpty else { throw SimulatorError.cloneFailed(udid: "gate simulator") }
            clonedUDID = udid
            let creating = GateSimulatorRegistration(
                schemaVersion: 1, gateRunNonce: gateRunNonce, guideLockInode: guideLockInode,
                deviceSetPath: defaultDeviceSetURL.path, udid: udid,
                runtimeIdentifier: runtime, deviceTypeIdentifier: deviceType,
                generation: 1, state: .creating, activeInvocationNonce: nil,
                prepareLifecycleChild: prepareChild)
            try write(creating, to: registrationURL)
            let idle = GateSimulatorRegistration(
                schemaVersion: 1, gateRunNonce: gateRunNonce, guideLockInode: guideLockInode,
                deviceSetPath: defaultDeviceSetURL.path, udid: udid, runtimeIdentifier: runtime,
                deviceTypeIdentifier: deviceType, generation: 1, state: .idle,
                activeInvocationNonce: nil, prepareLifecycleChild: prepareChild
            )
            guard try await launch(["simctl", "boot", udid], timeout: 60) == 0,
                try await launch(["simctl", "bootstatus", udid, "-b"], timeout: 60) == 0,
                try await deviceExists(udid: udid)
            else { throw SimulatorError.cloneFailed(udid: udid) }
            try write(idle, to: registrationURL)
            return idle
        } catch {
            if FileManager.default.fileExists(atPath: registrationURL.path) {
                try? await cleanupGateSimulator(
                    registrationURL: registrationURL, expectedGateRunNonce: gateRunNonce,
                    expectedGuideLockInode: guideLockInode, expectedCacheRoot: cacheRoot)
            } else if let clonedUDID {
                _ = try? await launch(["simctl", "shutdown", clonedUDID], timeout: 30)
                let deleteCode = try? await launch(["simctl", "delete", clonedUDID], timeout: 30)
                let listed = try? await launchCapturing(["simctl", "list", "devices", "--json"])
                guard deleteCode == 0, let listed, listed.exitCode == 0,
                    !Self.containsUDID(clonedUDID, in: listed.output)
                else { throw SimulatorError.cloneFailed(udid: clonedUDID) }
                let deleted = GateSimulatorRegistration(
                    schemaVersion: 1, gateRunNonce: gateRunNonce,
                    guideLockInode: guideLockInode, deviceSetPath: defaultDeviceSetURL.path,
                    udid: clonedUDID, runtimeIdentifier: runtime,
                    deviceTypeIdentifier: deviceType, generation: 1, state: .deleted,
                    activeInvocationNonce: nil, prepareLifecycleChild: prepareChild)
                try? write(deleted, to: registrationURL)
            }
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
        guard registration.schemaVersion == 1,
            expectedGateRunNonce.map({ registration.gateRunNonce == $0 }) ?? true,
            registration.guideLockInode == expectedGuideLockInode,
            registration.generation == 1,
            registration.state == .creating || registration.state == .idle
                || registration.state == .active || registration.state == .cleaning,
            registration.state == .active || registration.activeInvocationNonce == nil,
            !registration.udid.isEmpty,
            registeredDeviceSet == defaultDeviceSetURL
        else { throw SimulatorError.cloneFailed(udid: "invalid gate registration") }
        let beforeCleanup = try await launchCapturing(
            ["simctl", "list", "devices", "--json"])
        guard beforeCleanup.exitCode == 0 else {
            throw SimulatorError.cloneFailed(udid: registration.udid)
        }
        if !Self.containsRegistration(registration, in: beforeCleanup.output) {
            guard registration.state == .cleaning,
                !Self.containsUDID(registration.udid, in: beforeCleanup.output)
            else { throw SimulatorError.cloneFailed(udid: registration.udid) }
            try write(registration.replacing(state: .deleted), to: registrationURL)
            return
        }
        if registration.state != .cleaning {
            try write(registration.replacing(state: .cleaning), to: registrationURL)
        }
        _ = try? await launch(["simctl", "shutdown", registration.udid], timeout: 30)
        guard try await launch(
            ["simctl", "delete", registration.udid], timeout: 30) == 0
        else { throw SimulatorError.cloneFailed(udid: registration.udid) }
        let listed = try await launchCapturing(
            ["simctl", "list", "devices", "--json"])
        guard listed.exitCode == 0, !Self.containsUDID(registration.udid, in: listed.output) else {
            throw SimulatorError.cloneFailed(udid: registration.udid)
        }
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
            URL(fileURLWithPath: registration.deviceSetPath, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL
                == FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
                    .resolvingSymlinksInPath().standardizedFileURL
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
        guard URL(fileURLWithPath: registration.deviceSetPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL == defaultDeviceSetURL else {
            throw SimulatorError.cloneFailed(udid: "invalid gate registration")
        }
        let listed = try await launchCapturing(
            ["simctl", "list", "devices", "--json"])
        guard listed.exitCode == 0, Self.containsRegistration(registration, in: listed.output)
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
            state: .active, activeInvocationNonce: invocationNonce,
            prepareLifecycleChild: registration.prepareLifecycleChild)
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

    private func sourceUDID(
        destination: String, runtimeIdentifier: String, deviceTypeIdentifier: String
    ) async throws -> String {
        let result = try await launchCapturing(["simctl", "list", "devices", "--json"])
        let name = parseValue(for: "name", in: destination)
        guard result.exitCode == 0,
            let data = result.output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devices = object["devices"] as? [String: [[String: Any]]],
            let entries = devices[runtimeIdentifier],
            let udid = entries.first(where: {
                ($0["isAvailable"] as? Bool) != false
                    && $0["deviceTypeIdentifier"] as? String == deviceTypeIdentifier
                    && (name == nil || $0["name"] as? String == name)
            })?["udid"] as? String
        else { throw SimulatorError.deviceNotFound(destination: destination) }
        return udid
    }

    private func deviceExists(udid: String) async throws -> Bool {
        let result = try await launchCapturing(["simctl", "list", "devices", "--json"])
        return result.exitCode == 0 && Self.containsUDID(udid, in: result.output)
    }

    static func containsUDID(_ udid: String, in output: String) -> Bool {
        guard let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devices = object["devices"] as? [String: [[String: Any]]]
        else { return false }
        return devices.values.flatMap({ $0 }).contains { $0["udid"] as? String == udid }
    }

    static func containsRegistration(
        _ registration: GateSimulatorRegistration, in output: String
    ) -> Bool {
        guard let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devices = object["devices"] as? [String: [[String: Any]]],
            let runtimeDevices = devices[registration.runtimeIdentifier]
        else { return false }
        return runtimeDevices.contains {
            $0["udid"] as? String == registration.udid
                && $0["deviceTypeIdentifier"] as? String == registration.deviceTypeIdentifier
        }
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
