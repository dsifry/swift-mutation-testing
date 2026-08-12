import Darwin
import Foundation

enum GateSimulatorSupervisor {
    static func run(_ arguments: [String]) async -> Int32 {
        guard arguments.count == 10,
            let inode = UInt64(arguments[2]),
            let guideFD = Int32(arguments[5]),
            let controlFD = Int32(arguments[6]),
            let readinessFD = Int32(arguments[7]),
            let wrapperFD = Int32(arguments[8])
        else { return 64 }
        let registrationURL = URL(fileURLWithPath: arguments[0])
        let cacheRoot = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let invocationNonce = arguments[3]
        let expectedDigest = arguments[4]
        let xcrunURL = URL(fileURLWithPath: arguments[9])
        guard descriptorInode(guideFD) == inode,
            (try? ProjectInputManifest.sha256(Data(contentsOf: registrationURL))) == expectedDigest,
            let registration = try? GateSimulatorRegistration.load(from: registrationURL),
            registration.guideLockInode == inode,
            registration.state == .active,
            registration.activeInvocationNonce == invocationNonce,
            canonicalDeviceSet(registration, root: cacheRoot)
        else { return 65 }

        let manager = SimulatorManager(launcher: XcodeProcessLauncher(), executableURL: xcrunURL)
        guard await deviceExists(registration, manager: manager) else { return 65 }
        var ready: UInt8 = 1
        guard Darwin.write(readinessFD, &ready, 1) == 1 else { return 66 }
        _ = close(readinessFD)
        var start: UInt8 = 0
        guard Darwin.read(controlFD, &start, 1) == 1, start == 1 else {
            return await cleanup(manager, registrationURL, cacheRoot, inode)
        }

        var descriptors = [
            pollfd(fd: controlFD, events: Int16(POLLIN | POLLHUP), revents: 0),
            pollfd(fd: wrapperFD, events: Int16(POLLIN | POLLHUP), revents: 0),
        ]
        while true {
            let result = poll(&descriptors, nfds_t(descriptors.count), -1)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { return await cleanup(manager, registrationURL, cacheRoot, inode) }
            if descriptors[1].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                return await cleanup(manager, registrationURL, cacheRoot, inode)
            }
            if descriptors[0].revents & Int16(POLLIN) != 0 {
                var command: UInt8 = 0
                let count = Darwin.read(controlFD, &command, 1)
                if count == 1, command == 2 { return 0 }
                if count <= 0 { return await cleanup(manager, registrationURL, cacheRoot, inode) }
            }
            if descriptors[0].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                return await cleanup(manager, registrationURL, cacheRoot, inode)
            }
        }
    }

    private static func descriptorInode(_ descriptor: Int32) -> UInt64? {
        var metadata = stat()
        return fstat(descriptor, &metadata) == 0 ? UInt64(metadata.st_ino) : nil
    }

    private static func canonicalDeviceSet(_ registration: GateSimulatorRegistration, root: URL) -> Bool {
        let expected = root.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("gate-simulator-\(registration.gateRunNonce)", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        return URL(fileURLWithPath: registration.deviceSetPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL == expected
    }

    private static func deviceExists(
        _ registration: GateSimulatorRegistration, manager: SimulatorManager
    ) async -> Bool {
        guard let result = try? await manager.launcher.launchCapturing(ProcessRequest(
            executableURL: manager.executableURL,
            arguments: ["simctl", "--set", registration.deviceSetPath, "list", "devices", "--json"],
            environment: nil, additionalEnvironment: [:],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 30)),
            result.exitCode == 0
        else { return false }
        return result.output.contains("\"udid\":\"\(registration.udid)\"")
            || result.output.contains("\"udid\": \"\(registration.udid)\"")
    }

    private static func cleanup(
        _ manager: SimulatorManager, _ registrationURL: URL, _ root: URL, _ inode: UInt64
    ) async -> Int32 {
        do {
            try await manager.cleanupGateSimulator(
                registrationURL: registrationURL, expectedGateRunNonce: nil,
                expectedGuideLockInode: inode, expectedCacheRoot: root)
            return 0
        } catch { return 67 }
    }
}

final class GateSimulatorCustodySession: @unchecked Sendable {
    private let pid: Int32
    private var controlWrite: Int32
    private let lock = NSLock()

    static func start(
        registrationURL: URL,
        cacheRoot: URL,
        guideLockInode: UInt64,
        invocationNonce: String,
        wrapperLeaseFD: Int,
        guideLockFD: Int = 4,
        executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
        xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun")
    ) throws -> GateSimulatorCustodySession {
        var control: [Int32] = [-1, -1]
        var readiness: [Int32] = [-1, -1]
        guard pipe(&control) == 0, pipe(&readiness) == 0 else {
            throw PreparedCacheError.unverifiableProcessIdentity
        }
        let childDescriptors = [control[0], readiness[1], Int32(guideLockFD), Int32(wrapperLeaseFD)]
        for descriptor in childDescriptors { _ = fcntl(descriptor, F_SETFD, 0) }
        _ = fcntl(control[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(readiness[0], F_SETFD, FD_CLOEXEC)
        let digest = ProjectInputManifest.sha256(try Data(contentsOf: registrationURL))
        let childArguments = [
            "--gate-simulator-supervisor", registrationURL.path, cacheRoot.path,
            String(guideLockInode), invocationNonce, digest, String(guideLockFD), String(control[0]),
            String(readiness[1]), String(wrapperLeaseFD), xcrunURL.path,
        ]
        let executable = executableURL.standardizedFileURL.path
        let argv = ([executable] + childArguments).map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }.sorted()
        let envp = environment.map { strdup($0) } + [nil]
        defer {
            argv.dropLast().forEach { free($0) }
            envp.dropLast().forEach { free($0) }
        }
        var childPID: Int32 = 0
        let spawnResult = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envBuffer in
                posix_spawn(
                    &childPID, executable, nil, nil,
                    UnsafeMutablePointer(mutating: argvBuffer.baseAddress!),
                    UnsafeMutablePointer(mutating: envBuffer.baseAddress!))
            }
        }
        if spawnResult != 0 || childPID <= 0 {
            control.forEach { _ = close($0) }
            readiness.forEach { _ = close($0) }
            throw PreparedCacheError.unverifiableProcessIdentity
        }
        _ = close(control[0])
        _ = close(readiness[1])
        var ready: UInt8 = 0
        let readyCount = Darwin.read(readiness[0], &ready, 1)
        _ = close(readiness[0])
        guard readyCount == 1, ready == 1 else {
            _ = close(control[1])
            _ = waitForExit(childPID)
            throw PreparedCacheError.unverifiableProcessIdentity
        }
        var start: UInt8 = 1
        guard Darwin.write(control[1], &start, 1) == 1 else {
            _ = close(control[1])
            _ = waitForExit(childPID)
            throw PreparedCacheError.unverifiableProcessIdentity
        }
        _ = fcntl(control[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(Int32(guideLockFD), F_SETFD, FD_CLOEXEC)
        _ = fcntl(Int32(wrapperLeaseFD), F_SETFD, FD_CLOEXEC)
        return GateSimulatorCustodySession(pid: childPID, controlWrite: control[1])
    }

    static func startIfNeeded(
        enabled: Bool,
        registrationURL: URL,
        cacheRoot: URL,
        guideLockInode: UInt64,
        invocationNonce: String,
        wrapperLeaseFD: Int,
        guideLockFD: Int
    ) throws -> GateSimulatorCustodySession? {
        guard enabled else { return nil }
        return try start(
            registrationURL: registrationURL, cacheRoot: cacheRoot,
            guideLockInode: guideLockInode, invocationNonce: invocationNonce,
            wrapperLeaseFD: wrapperLeaseFD, guideLockFD: guideLockFD)
    }

    private init(pid: Int32, controlWrite: Int32) {
        self.pid = pid
        self.controlWrite = controlWrite
    }

    func finish() throws {
        let descriptor = lock.withLock { () -> Int32 in
            let value = controlWrite
            controlWrite = -1
            return value
        }
        guard descriptor >= 0 else { return }
        var done: UInt8 = 2
        guard Darwin.write(descriptor, &done, 1) == 1 else {
            _ = close(descriptor)
            throw PreparedCacheError.unverifiableProcessIdentity
        }
        _ = close(descriptor)
        guard Self.waitForExit(pid) == 0 else {
            throw PreparedCacheError.unverifiableProcessIdentity
        }
    }

    deinit {
        let descriptor = lock.withLock { () -> Int32 in
            let value = controlWrite
            controlWrite = -1
            return value
        }
        if descriptor >= 0 { _ = close(descriptor) }
        _ = Self.waitForExit(pid)
    }

    private static func waitForExit(_ pid: Int32) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        return status & 0x7f == 0 ? (status >> 8) & 0xff : -1
    }
}
