import Darwin
import Foundation
import Testing

@testable import SwiftMutationTesting

@Suite("Gate simulator custody supervisor", .serialized)
struct GateSimulatorSupervisorTests {
    private func readReady(_ descriptor: Int32) -> UInt8? {
        var readable = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        guard Darwin.poll(&readable, 1, 5_000) > 0 else { return nil }
        var ready: UInt8 = 0
        return Darwin.read(descriptor, &ready, 1) == 1 ? ready : nil
    }

    private static let registeredSimulator = GateSimulatorRegistration(
        schemaVersion: 1, gateRunNonce: "GATEABCDEFGHIJKLMNOPQR",
        guideLockInode: 1, deviceSetPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices").path,
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

    @Test("Device lookup rejects the same UDID under the wrong runtime or device type")
    func mismatchedRegisteredIdentityFailsClosed() async {
        let wrongRuntime = SimulatorManager(launcher: MockProcessLauncher(
            exitCode: 0,
            output: #"{"devices":{"other-runtime":[{"udid":"GATE-UDID","deviceTypeIdentifier":"type"}]}}"#))
        let wrongType = SimulatorManager(launcher: MockProcessLauncher(
            exitCode: 0,
            output: #"{"devices":{"runtime":[{"udid":"GATE-UDID","deviceTypeIdentifier":"other-type"}]}}"#))

        #expect(await !GateSimulatorSupervisor.deviceExists(Self.registeredSimulator, manager: wrongRuntime))
        #expect(await !GateSimulatorSupervisor.deviceExists(Self.registeredSimulator, manager: wrongType))
    }

    @Test("Prepare supervisor directly acknowledges idle and cleans on pre-ACK EOF")
    func directPrepareSupervisorProtocol() async throws {
        for acknowledge in [true, false] {
            let fixture = try DirectSupervisorFixture()
            defer { fixture.cleanup() }
            let descriptors = try fixture.pipes()
            let arguments = fixture.prepareArguments(descriptors: descriptors)
            let task = Task { await GateSimulatorSupervisor.runPreparing(arguments) }
            let ready = readReady(descriptors.readyRead)
            #expect(ready == 1)
            #expect(ready == 1)
            _ = close(descriptors.readyRead)
            if acknowledge {
                var byte: UInt8 = 3
                #expect(Darwin.write(descriptors.controlWrite, &byte, 1) == 1)
            }
            _ = close(descriptors.controlWrite)
            #expect(try await task.value == 0)
            _ = close(descriptors.controlRead)
            _ = close(descriptors.readyWrite)
            #expect(try GateSimulatorRegistration.load(from: fixture.registrationURL).state
                == (acknowledge ? .idle : .deleted))
        }
    }

    @Test("Active supervisor directly accepts start and finish control bytes")
    func directActiveSupervisorProtocol() async throws {
        let fixture = try DirectSupervisorFixture(active: true)
        defer { fixture.cleanup() }
        let descriptors = try fixture.pipes(includeWrapper: true)
        let arguments = try fixture.activeArguments(descriptors: descriptors)
        #expect(try GateSimulatorRegistration.load(from: fixture.registrationURL).state == .active)
        #expect(await GateSimulatorSupervisor.deviceExists(
            try GateSimulatorRegistration.load(from: fixture.registrationURL),
            manager: SimulatorManager(launcher: XcodeProcessLauncher(), executableURL: fixture.xcrunURL)))
        let task = Task { await GateSimulatorSupervisor.run(arguments) }
        let ready = readReady(descriptors.readyRead)
        #expect(ready == 1)
        _ = close(descriptors.readyRead)
        var start: UInt8 = 1
        #expect(Darwin.write(descriptors.controlWrite, &start, 1) == 1)
        var done: UInt8 = 2
        #expect(Darwin.write(descriptors.controlWrite, &done, 1) == 1)
        _ = close(descriptors.controlWrite)
        let result = await task.value
        #expect(result == 0)
        _ = close(descriptors.controlRead)
        _ = close(descriptors.readyWrite)
        _ = close(descriptors.wrapperRead)
        _ = close(descriptors.wrapperWrite)
    }

    @Test("Custody session parent paths spawn, acknowledge, finish, and reject a missing executable")
    func directCustodySessionParentPaths() throws {
        let fixture = try DirectSupervisorFixture(active: true)
        defer { fixture.cleanup() }
        let activeChild = try fixture.childScript(readinessArgument: 9)
        var wrapper: [Int32] = [-1, -1]
        #expect(pipe(&wrapper) == 0)
        defer { wrapper.forEach { _ = close($0) } }
        let active = try GateSimulatorCustodySession.start(
            registrationURL: fixture.registrationURL, cacheRoot: fixture.root,
            guideLockInode: fixture.inode, invocationNonce: fixture.invocationNonce,
            wrapperLeaseFD: Int(wrapper[0]), guideLockFD: Int(fixture.guideFD),
            executableURL: activeChild, xcrunURL: fixture.xcrunURL)
        try active.finish()
        try active.finish()

        let prepareChild = try fixture.childScript(readinessArgument: 9)
        let preparing = try GateSimulatorCustodySession.startPreparing(
            destination: fixture.destination, registrationURL: fixture.registrationURL,
            cacheRoot: fixture.root, gateRunNonce: fixture.gateNonce,
            guideLockInode: fixture.inode, guideLockFD: Int(fixture.guideFD),
            executableURL: prepareChild, xcrunURL: fixture.xcrunURL)
        try preparing.acknowledgePreparation()
        try preparing.acknowledgePreparation()

        #expect(throws: PreparedCacheError.self) {
            _ = try GateSimulatorCustodySession.start(
                registrationURL: fixture.registrationURL, cacheRoot: fixture.root,
                guideLockInode: fixture.inode, invocationNonce: fixture.invocationNonce,
                wrapperLeaseFD: Int(wrapper[0]), guideLockFD: Int(fixture.guideFD),
                executableURL: fixture.root.appendingPathComponent("missing"),
                xcrunURL: fixture.xcrunURL)
        }
    }

    @Test("Direct supervisors reject malformed identity and readiness frames")
    func directSupervisorFailureFrames() async throws {
        #expect(await GateSimulatorSupervisor.runPreparing([]) == 64)
        #expect(await GateSimulatorSupervisor.run([]) == 64)
        let fixture = try DirectSupervisorFixture(active: true)
        defer { fixture.cleanup() }
        var descriptors = try fixture.pipes(includeWrapper: true)
        var active = try fixture.activeArguments(descriptors: descriptors)
        active[4] = "wrong-digest"
        #expect(await GateSimulatorSupervisor.run(active) == 65)
        fixture.close(descriptors)

        descriptors = try fixture.pipes(includeWrapper: true)
        active = try fixture.activeArguments(descriptors: descriptors)
        active[7] = "-1"
        #expect(await GateSimulatorSupervisor.run(active) == 66)
        fixture.close(descriptors)

        let failedPrepare = try DirectSupervisorFixture(xcrunFails: true)
        defer { failedPrepare.cleanup() }
        descriptors = try failedPrepare.pipes()
        #expect(await GateSimulatorSupervisor.runPreparing(
            failedPrepare.prepareArguments(descriptors: descriptors)) == 67)
        failedPrepare.close(descriptors)

        let badWrite = try DirectSupervisorFixture()
        defer { badWrite.cleanup() }
        descriptors = try badWrite.pipes()
        var prepare = badWrite.prepareArguments(descriptors: descriptors)
        prepare[7] = "-1"
        #expect(await GateSimulatorSupervisor.runPreparing(prepare) == 0)
        #expect(try GateSimulatorRegistration.load(from: badWrite.registrationURL).state == .deleted)
        badWrite.close(descriptors)
    }

    @Test("Direct active supervisor cleans on pre-start EOF and wrapper EOF")
    func directActiveSupervisorCleanupFrames() async throws {
        for wrapperEOF in [false, true] {
            let fixture = try DirectSupervisorFixture(active: true)
            defer { fixture.cleanup() }
            let descriptors = try fixture.pipes(includeWrapper: true)
            let arguments = try fixture.activeArguments(descriptors: descriptors)
            let task = Task { await GateSimulatorSupervisor.run(arguments) }
            let ready = readReady(descriptors.readyRead)
            #expect(ready == 1)
            if wrapperEOF {
                var start: UInt8 = 1
                #expect(Darwin.write(descriptors.controlWrite, &start, 1) == 1)
                _ = close(descriptors.wrapperWrite)
            } else {
                _ = close(descriptors.controlWrite)
            }
            #expect(try await task.value == 0)
            #expect(try GateSimulatorRegistration.load(from: fixture.registrationURL).state == .deleted)
            fixture.close(descriptors)
        }
    }

    @Test("Direct active supervisor rejects missing device and invalid start or command")
    func directActiveSupervisorAdditionalFrames() async throws {
        let missing = try DirectSupervisorFixture(active: true, deviceMissing: true)
        defer { missing.cleanup() }
        var descriptors = try missing.pipes(includeWrapper: true)
        #expect(await GateSimulatorSupervisor.run(
            try missing.activeArguments(descriptors: descriptors)) == 65)
        missing.close(descriptors)

        for invalidStart in [UInt8(0), UInt8(9)] {
            let fixture = try DirectSupervisorFixture(active: true)
            defer { fixture.cleanup() }
            descriptors = try fixture.pipes(includeWrapper: true)
            let arguments = try fixture.activeArguments(descriptors: descriptors)
            let task = Task { await GateSimulatorSupervisor.run(arguments) }
            let ready = readReady(descriptors.readyRead)
            #expect(ready == 1)
            var byte = invalidStart
            #expect(Darwin.write(descriptors.controlWrite, &byte, 1) == 1)
            #expect(try await task.value == 0)
            #expect(try GateSimulatorRegistration.load(from: fixture.registrationURL).state == .deleted)
            fixture.close(descriptors)
        }

        let fixture = try DirectSupervisorFixture(active: true)
        defer { fixture.cleanup() }
        descriptors = try fixture.pipes(includeWrapper: true)
        let arguments = try fixture.activeArguments(descriptors: descriptors)
        let task = Task { await GateSimulatorSupervisor.run(arguments) }
        let ready = readReady(descriptors.readyRead)
        #expect(ready == 1)
        var start: UInt8 = 1
        #expect(Darwin.write(descriptors.controlWrite, &start, 1) == 1)
        var unknown: UInt8 = 9
        #expect(Darwin.write(descriptors.controlWrite, &unknown, 1) == 1)
        _ = Darwin.close(descriptors.controlWrite)
        #expect(try await task.value == 0)
        #expect(try GateSimulatorRegistration.load(from: fixture.registrationURL).state == .deleted)
        fixture.close(descriptors)
    }

    @Test("Custody parents reject children that never become ready")
    func directCustodyReadinessFailures() throws {
        let fixture = try DirectSupervisorFixture(active: true)
        defer { fixture.cleanup() }
        let silent = try fixture.silentChildScript()
        var wrapper: [Int32] = [-1, -1]
        #expect(pipe(&wrapper) == 0)
        defer { wrapper.forEach { _ = close($0) } }
        #expect(throws: PreparedCacheError.self) {
            _ = try GateSimulatorCustodySession.start(
                registrationURL: fixture.registrationURL, cacheRoot: fixture.root,
                guideLockInode: fixture.inode, invocationNonce: fixture.invocationNonce,
                wrapperLeaseFD: Int(wrapper[0]), guideLockFD: Int(fixture.guideFD),
                executableURL: silent, xcrunURL: fixture.xcrunURL)
        }
        #expect(throws: PreparedCacheError.self) {
            _ = try GateSimulatorCustodySession.startPreparing(
                destination: fixture.destination, registrationURL: fixture.registrationURL,
                cacheRoot: fixture.root, gateRunNonce: fixture.gateNonce,
                guideLockInode: fixture.inode, guideLockFD: Int(fixture.guideFD),
                executableURL: silent, xcrunURL: fixture.xcrunURL)
        }
    }

    @Test("Custody parent finish methods surface nonzero child exits")
    func directCustodyExitFailures() throws {
        let fixture = try DirectSupervisorFixture(active: true)
        defer { fixture.cleanup() }
        let failing = try fixture.childScript(readinessArgument: 9, exitCode: 7)
        var wrapper: [Int32] = [-1, -1]
        #expect(pipe(&wrapper) == 0)
        defer { wrapper.forEach { _ = Darwin.close($0) } }
        let active = try GateSimulatorCustodySession.start(
            registrationURL: fixture.registrationURL, cacheRoot: fixture.root,
            guideLockInode: fixture.inode, invocationNonce: fixture.invocationNonce,
            wrapperLeaseFD: Int(wrapper[0]), guideLockFD: Int(fixture.guideFD),
            executableURL: failing, xcrunURL: fixture.xcrunURL)
        #expect(throws: PreparedCacheError.self) { try active.finish() }

        let preparing = try GateSimulatorCustodySession.startPreparing(
            destination: fixture.destination, registrationURL: fixture.registrationURL,
            cacheRoot: fixture.root, gateRunNonce: fixture.gateNonce,
            guideLockInode: fixture.inode, guideLockFD: Int(fixture.guideFD),
            executableURL: failing, xcrunURL: fixture.xcrunURL)
        #expect(throws: PreparedCacheError.self) { try preparing.acknowledgePreparation() }
    }

    @Test("Custody optional and deinit paths preserve bounded child ownership")
    func directCustodyOptionalAndDeinitPaths() throws {
        let fixture = try DirectSupervisorFixture(active: true)
        defer { fixture.cleanup() }
        var wrapper: [Int32] = [-1, -1]
        #expect(pipe(&wrapper) == 0)
        defer { wrapper.forEach { _ = Darwin.close($0) } }
        #expect(try GateSimulatorCustodySession.startIfNeeded(
            enabled: false, registrationURL: fixture.registrationURL,
            cacheRoot: fixture.root, guideLockInode: fixture.inode,
            invocationNonce: fixture.invocationNonce, wrapperLeaseFD: Int(wrapper[0]),
            guideLockFD: Int(fixture.guideFD)) == nil)
        let child = try fixture.childScript(readinessArgument: 9)
        let optionalResult = try GateSimulatorCustodySession.startIfNeeded(
            enabled: true, registrationURL: fixture.registrationURL,
            cacheRoot: fixture.root, guideLockInode: fixture.inode,
            invocationNonce: fixture.invocationNonce, wrapperLeaseFD: Int(wrapper[0]),
            guideLockFD: Int(fixture.guideFD), executableURL: child,
            xcrunURL: fixture.xcrunURL)
        let optional = try #require(optionalResult)
        try optional.finish()
        var session: GateSimulatorCustodySession? = try GateSimulatorCustodySession.start(
            registrationURL: fixture.registrationURL, cacheRoot: fixture.root,
            guideLockInode: fixture.inode, invocationNonce: fixture.invocationNonce,
            wrapperLeaseFD: Int(wrapper[0]), guideLockFD: Int(fixture.guideFD),
            executableURL: child, xcrunURL: fixture.xcrunURL)
        session = nil
        #expect(session == nil)
    }

    @Test("Custody prepare spawn failure and active cleanup failure fail closed")
    func directCustodyAdditionalFailures() async throws {
        let fixture = try DirectSupervisorFixture(active: true)
        defer { fixture.cleanup() }
        #expect(throws: PreparedCacheError.self) {
            _ = try GateSimulatorCustodySession.startPreparing(
                destination: fixture.destination, registrationURL: fixture.registrationURL,
                cacheRoot: fixture.root, gateRunNonce: fixture.gateNonce,
                guideLockInode: fixture.inode, guideLockFD: Int(fixture.guideFD),
                executableURL: fixture.root.appendingPathComponent("missing"),
                xcrunURL: fixture.xcrunURL)
        }
        let descriptors = try fixture.pipes(includeWrapper: true)
        let arguments = try fixture.activeArguments(descriptors: descriptors)
        let task = Task { await GateSimulatorSupervisor.run(arguments) }
        let ready = readReady(descriptors.readyRead)
        #expect(ready == 1)
        var invalid: UInt8 = 0
        try Data("invalid".utf8).write(to: fixture.registrationURL)
        #expect(Darwin.write(descriptors.controlWrite, &invalid, 1) == 1)
        #expect(await task.value == 67)
        fixture.close(descriptors)
    }

    @Test("Injected system calls cover pipe and poll failure protocols")
    func injectedSystemCallFailures() async throws {
        let fixture = try DirectSupervisorFixture(active: true)
        defer { fixture.cleanup() }
        let originalSession = GateSimulatorCustodySession.systemCalls
        let originalSupervisor = GateSimulatorSupervisor.systemCalls
        defer {
            GateSimulatorCustodySession.systemCalls = originalSession
            GateSimulatorSupervisor.systemCalls = originalSupervisor
        }
        GateSimulatorCustodySession.systemCalls.pipe = { _ in -1 }
        var wrapper: [Int32] = [-1, -1]
        #expect(pipe(&wrapper) == 0)
        defer { wrapper.forEach { _ = Darwin.close($0) } }
        #expect(throws: PreparedCacheError.self) {
            _ = try GateSimulatorCustodySession.start(
                registrationURL: fixture.registrationURL, cacheRoot: fixture.root,
                guideLockInode: fixture.inode, invocationNonce: fixture.invocationNonce,
                wrapperLeaseFD: Int(wrapper[0]), guideLockFD: Int(fixture.guideFD))
        }
        let pipeCalls = LockedCounter()
        GateSimulatorCustodySession.systemCalls.pipe = { descriptors in
            pipeCalls.increment() == 1 ? Darwin.pipe(descriptors) : -1
        }
        #expect(throws: PreparedCacheError.self) {
            _ = try GateSimulatorCustodySession.startPreparing(
                destination: fixture.destination, registrationURL: fixture.registrationURL,
                cacheRoot: fixture.root, gateRunNonce: fixture.gateNonce,
                guideLockInode: fixture.inode, guideLockFD: Int(fixture.guideFD))
        }
        GateSimulatorCustodySession.systemCalls.pipe = originalSession.pipe
        GateSimulatorCustodySession.systemCalls.configureSpawnAttributes = { _ in -1 }
        #expect(throws: PreparedCacheError.self) {
            _ = try GateSimulatorCustodySession.start(
                registrationURL: fixture.registrationURL, cacheRoot: fixture.root,
                guideLockInode: fixture.inode, invocationNonce: fixture.invocationNonce,
                wrapperLeaseFD: Int(wrapper[0]), guideLockFD: Int(fixture.guideFD))
        }
        let destroyed = LockedCounter()
        GateSimulatorCustodySession.systemCalls.configureSpawnAttributes = { attributes in
            _ = posix_spawnattr_init(attributes)
            return -1
        }
        GateSimulatorCustodySession.systemCalls.destroySpawnAttributes = { attributes in
            _ = destroyed.increment()
            return posix_spawnattr_destroy(attributes)
        }
        #expect(throws: PreparedCacheError.self) {
            _ = try GateSimulatorCustodySession.start(
                registrationURL: fixture.registrationURL, cacheRoot: fixture.root,
                guideLockInode: fixture.inode, invocationNonce: fixture.invocationNonce,
                wrapperLeaseFD: Int(wrapper[0]), guideLockFD: Int(fixture.guideFD))
        }
        #expect(throws: PreparedCacheError.self) {
            _ = try GateSimulatorCustodySession.startPreparing(
                destination: fixture.destination, registrationURL: fixture.registrationURL,
                cacheRoot: fixture.root, gateRunNonce: fixture.gateNonce,
                guideLockInode: fixture.inode, guideLockFD: Int(fixture.guideFD))
        }
        #expect(destroyed.value == 2)
        GateSimulatorCustodySession.systemCalls.destroySpawnAttributes =
            originalSession.destroySpawnAttributes
        #expect(throws: PreparedCacheError.self) {
            _ = try GateSimulatorCustodySession.startPreparing(
                destination: fixture.destination, registrationURL: fixture.registrationURL,
                cacheRoot: fixture.root, gateRunNonce: fixture.gateNonce,
                guideLockInode: fixture.inode, guideLockFD: Int(fixture.guideFD))
        }
        GateSimulatorCustodySession.systemCalls.configureSpawnAttributes =
            originalSession.configureSpawnAttributes
        #expect(throws: PreparedCacheError.self) {
            _ = try GateSimulatorCustodySession.startPreparing(
                destination: fixture.destination, registrationURL: fixture.registrationURL,
                cacheRoot: fixture.root, gateRunNonce: fixture.gateNonce,
                guideLockInode: fixture.inode, guideLockFD: Int(fixture.guideFD))
        }

        let descriptors = try fixture.pipes(includeWrapper: true)
        let arguments = try fixture.activeArguments(descriptors: descriptors)
        GateSimulatorSupervisor.systemCalls.poll = { _, _, _ in -1 }
        errno = EIO
        let task = Task { await GateSimulatorSupervisor.run(arguments) }
        let ready = readReady(descriptors.readyRead)
        #expect(ready == 1)
        var start: UInt8 = 1
        #expect(Darwin.write(descriptors.controlWrite, &start, 1) == 1)
        #expect(await task.value == 0)
        #expect(try GateSimulatorRegistration.load(from: fixture.registrationURL).state == .deleted)
        fixture.close(descriptors)
    }

    @Test("Injected poll and wait cover EINTR, HUP, and signaled child states")
    func injectedSystemCallEdges() async throws {
        let fixture = try DirectSupervisorFixture(active: true)
        defer { fixture.cleanup() }
        let originalSession = GateSimulatorCustodySession.systemCalls
        let originalSupervisor = GateSimulatorSupervisor.systemCalls
        defer {
            GateSimulatorCustodySession.systemCalls = originalSession
            GateSimulatorSupervisor.systemCalls = originalSupervisor
        }
        let pollCalls = LockedCounter()
        GateSimulatorSupervisor.systemCalls.poll = { descriptors, _, _ in
            if pollCalls.increment() == 1 {
                errno = EINTR
                return -1
            }
            descriptors[0].revents = Int16(POLLHUP)
            return 1
        }
        let descriptors = try fixture.pipes(includeWrapper: true)
        let arguments = try fixture.activeArguments(descriptors: descriptors)
        let task = Task { await GateSimulatorSupervisor.run(arguments) }
        let ready = readReady(descriptors.readyRead)
        #expect(ready == 1)
        var start: UInt8 = 1
        #expect(Darwin.write(descriptors.controlWrite, &start, 1) == 1)
        #expect(await task.value == 0)
        fixture.close(descriptors)

        let waitCalls = LockedCounter()
        GateSimulatorCustodySession.systemCalls.waitpid = { pid, status, options in
            if waitCalls.increment() == 1 {
                errno = EINTR
                return -1
            }
            return Darwin.waitpid(pid, status, options)
        }
        let child = try fixture.childScript(readinessArgument: 9, exitCode: 7)
        var wrapper: [Int32] = [-1, -1]
        #expect(pipe(&wrapper) == 0)
        defer { wrapper.forEach { _ = Darwin.close($0) } }
        let session = try GateSimulatorCustodySession.start(
            registrationURL: fixture.registrationURL, cacheRoot: fixture.root,
            guideLockInode: fixture.inode, invocationNonce: fixture.invocationNonce,
            wrapperLeaseFD: Int(wrapper[0]), guideLockFD: Int(fixture.guideFD),
            executableURL: child, xcrunURL: fixture.xcrunURL)
        #expect(throws: PreparedCacheError.self) { try session.finish() }
        #expect(waitCalls.value >= 2)

        GateSimulatorCustodySession.systemCalls.waitpid = { pid, status, options in
            _ = Darwin.waitpid(pid, status, options)
            errno = EIO
            return -1
        }
        let successfulChild = try fixture.childScript(readinessArgument: 9)
        let failedWait = try GateSimulatorCustodySession.start(
            registrationURL: fixture.registrationURL, cacheRoot: fixture.root,
            guideLockInode: fixture.inode, invocationNonce: fixture.invocationNonce,
            wrapperLeaseFD: Int(wrapper[0]), guideLockFD: Int(fixture.guideFD),
            executableURL: successfulChild, xcrunURL: fixture.xcrunURL)
        #expect(throws: PreparedCacheError.self) { try failedWait.finish() }
    }

    @Test("Invalid descriptors and closed child controls fail closed")
    func invalidDescriptorAndClosedControlFailures() async throws {
        let fixture = try DirectSupervisorFixture(active: true)
        defer { fixture.cleanup() }
        let descriptors = try fixture.pipes(includeWrapper: true)
        var invalid = try fixture.activeArguments(descriptors: descriptors)
        invalid[5] = "-1"
        #expect(await GateSimulatorSupervisor.run(invalid) == 65)
        fixture.close(descriptors)

        let prior = signal(SIGPIPE, SIG_IGN)
        defer { _ = signal(SIGPIPE, prior) }
        let activeChild = try fixture.readyThenExitChildScript(
            readinessArgument: 9, controlArgument: 8)
        var wrapper: [Int32] = [-1, -1]
        #expect(pipe(&wrapper) == 0)
        defer { wrapper.forEach { _ = Darwin.close($0) } }
        #expect(throws: PreparedCacheError.self) {
            _ = try GateSimulatorCustodySession.start(
                registrationURL: fixture.registrationURL, cacheRoot: fixture.root,
                guideLockInode: fixture.inode, invocationNonce: fixture.invocationNonce,
                wrapperLeaseFD: Int(wrapper[0]), guideLockFD: Int(fixture.guideFD),
                executableURL: activeChild, xcrunURL: fixture.xcrunURL)
        }
        let prepareChild = try fixture.readyThenExitChildScript(
            readinessArgument: 9, controlArgument: 8)
        let preparing = try GateSimulatorCustodySession.startPreparing(
            destination: fixture.destination, registrationURL: fixture.registrationURL,
            cacheRoot: fixture.root, gateRunNonce: fixture.gateNonce,
            guideLockInode: fixture.inode, guideLockFD: Int(fixture.guideFD),
            executableURL: prepareChild, xcrunURL: fixture.xcrunURL)
        usleep(50_000)
        #expect(throws: PreparedCacheError.self) { try preparing.acknowledgePreparation() }
    }

    @Test("Injected readable EOF and signaled children fail closed")
    func injectedReadableEOFAndSignaledChild() async throws {
        let fixture = try DirectSupervisorFixture(active: true)
        defer { fixture.cleanup() }
        let original = GateSimulatorSupervisor.systemCalls
        defer { GateSimulatorSupervisor.systemCalls = original }
        GateSimulatorSupervisor.systemCalls.poll = { descriptors, _, _ in
            descriptors[0].revents = Int16(POLLIN)
            return 1
        }
        let descriptors = try fixture.pipes(includeWrapper: true)
        let arguments = try fixture.activeArguments(descriptors: descriptors)
        let task = Task { await GateSimulatorSupervisor.run(arguments) }
        let ready = readReady(descriptors.readyRead)
        #expect(ready == 1)
        var start: UInt8 = 1
        #expect(Darwin.write(descriptors.controlWrite, &start, 1) == 1)
        _ = Darwin.close(descriptors.controlWrite)
        #expect(await task.value == 0)
        fixture.close(descriptors)

        let signaled = try fixture.signaledChildScript(readinessArgument: 9)
        var wrapper: [Int32] = [-1, -1]
        #expect(pipe(&wrapper) == 0)
        defer { wrapper.forEach { _ = Darwin.close($0) } }
        let session = try GateSimulatorCustodySession.start(
            registrationURL: fixture.registrationURL, cacheRoot: fixture.root,
            guideLockInode: fixture.inode, invocationNonce: fixture.invocationNonce,
            wrapperLeaseFD: Int(wrapper[0]), guideLockFD: Int(fixture.guideFD),
            executableURL: signaled, xcrunURL: fixture.xcrunURL)
        #expect(throws: PreparedCacheError.self) { try session.finish() }
    }

    @Test("Active supervisor loops after an unknown command and then accepts done")
    func activeUnknownThenDone() async throws {
        let fixture = try DirectSupervisorFixture(active: true)
        defer { fixture.cleanup() }
        let descriptors = try fixture.pipes(includeWrapper: true)
        let arguments = try fixture.activeArguments(descriptors: descriptors)
        let task = Task { await GateSimulatorSupervisor.run(arguments) }
        let ready = readReady(descriptors.readyRead)
        #expect(ready == 1)
        var start: UInt8 = 1
        #expect(Darwin.write(descriptors.controlWrite, &start, 1) == 1)
        var unknown: UInt8 = 9
        #expect(Darwin.write(descriptors.controlWrite, &unknown, 1) == 1)
        usleep(20_000)
        var done: UInt8 = 2
        #expect(Darwin.write(descriptors.controlWrite, &done, 1) == 1)
        #expect(await task.value == 0)
        fixture.close(descriptors)
    }

    @Test("Active finish detects a child that closes custody control after start")
    func activeFinishClosedControl() throws {
        let fixture = try DirectSupervisorFixture(active: true)
        defer { fixture.cleanup() }
        let prior = signal(SIGPIPE, SIG_IGN)
        defer { _ = signal(SIGPIPE, prior) }
        let child = try fixture.childScript(readinessArgument: 9)
        var wrapper: [Int32] = [-1, -1]
        #expect(pipe(&wrapper) == 0)
        defer { wrapper.forEach { _ = Darwin.close($0) } }
        let session = try GateSimulatorCustodySession.start(
            registrationURL: fixture.registrationURL, cacheRoot: fixture.root,
            guideLockInode: fixture.inode, invocationNonce: fixture.invocationNonce,
            wrapperLeaseFD: Int(wrapper[0]), guideLockFD: Int(fixture.guideFD),
            executableURL: child, xcrunURL: fixture.xcrunURL)
        usleep(100_000)
        #expect(throws: PreparedCacheError.self) { try session.finish() }
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

    @Test("Prepare parent kill helper")
    func prepareParentKillHelper() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let registrationPath = environment["GATE_PREPARE_REGISTRATION"],
            let rootPath = environment["GATE_PREPARE_ROOT"],
            let lockPath = environment["GATE_PREPARE_LOCK"],
            let executablePath = environment["GATE_PREPARE_EXECUTABLE"],
            let xcrunPath = environment["GATE_PREPARE_XCRUN"]
        else { return }
        let guideFD = open(lockPath, O_RDONLY)
        guard guideFD >= 0 else { throw PreparedCacheError.unverifiableProcessIdentity }
        defer { _ = close(guideFD) }
        var metadata = stat()
        guard fstat(guideFD, &metadata) == 0 else {
            throw PreparedCacheError.unverifiableProcessIdentity
        }
        let custody = try GateSimulatorCustodySession.startPreparing(
            destination: "platform=iOS Simulator,name=iPhone 16",
            registrationURL: URL(fileURLWithPath: registrationPath),
            cacheRoot: URL(fileURLWithPath: rootPath, isDirectory: true),
            gateRunNonce: "GATEABCDEFGHIJKLMNOPQR",
            guideLockInode: UInt64(metadata.st_ino), guideLockFD: Int(guideFD),
            executableURL: URL(fileURLWithPath: executablePath),
            xcrunURL: URL(fileURLWithPath: xcrunPath))
        withExtendedLifetime(custody) { while true { pause() } }
    }

    @Test("The prepare child deletes its exact clone when its parent dies before success ACK")
    func literalPrepareParentKillCleanup() throws {
        let root = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(root) }
        chmod(root.path, 0o700)
        let lock = root.appendingPathComponent("guide.lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        let registrationURL = root.appendingPathComponent("registration.json")
        let deletedMarker = root.appendingPathComponent("deleted")
        let commandLog = root.appendingPathComponent("commands")
        let bootBlocked = root.appendingPathComponent("boot-blocked")
        let helperPIDFile = root.appendingPathComponent("helper-pid")
        let fakeXcrun = root.appendingPathComponent("xcrun")
        let script = """
        #!/bin/sh
        echo "$*" >> '\(commandLog.path)'
        if echo "$*" | grep -q 'list devicetypes'; then echo '{"devicetypes":[{"name":"iPhone 16","identifier":"type"}]}'; exit 0; fi
        if echo "$*" | grep -q 'list runtimes'; then echo '{"runtimes":[{"identifier":"runtime","isAvailable":true}]}'; exit 0; fi
        if echo "$*" | grep -q ' clone SOURCE-UDID '; then echo 'GATE-UDID'; exit 0; fi
        if echo "$*" | grep -q 'simctl boot GATE-UDID'; then
          : > '\(bootBlocked.path)'
          while [ ! -s '\(helperPIDFile.path)' ] || kill -0 "$(cat '\(helperPIDFile.path)' 2>/dev/null)" 2>/dev/null; do sleep 0.01; done
          exit 0
        fi
        if echo "$*" | grep -q ' delete GATE-UDID'; then : > '\(deletedMarker.path)'; exit 0; fi
        if echo "$*" | grep -q 'list devices'; then
          if [ -f '\(deletedMarker.path)' ]; then echo '{"devices":{"runtime":[{"udid":"SOURCE-UDID","name":"iPhone 16","deviceTypeIdentifier":"type","isAvailable":true},{"udid":"UNRELATED-UDID"}]}}';
          else echo '{"devices":{"runtime":[{"udid":"SOURCE-UDID","name":"iPhone 16","deviceTypeIdentifier":"type","isAvailable":true},{"udid":"UNRELATED-UDID"},{"udid":"GATE-UDID","name":"SwiftMutationGate","deviceTypeIdentifier":"type","isAvailable":true}]}}'; fi
          exit 0
        fi
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
        let testBundle = try #require(FileManager.default.enumerator(
            at: buildRoot, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.first {
                $0.lastPathComponent == "SwiftMutationTestingPackageTests"
                    && $0.deletingLastPathComponent().lastPathComponent == "MacOS"
            })
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode.app/Contents/Developer"
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: developerDirectory).appendingPathComponent(
            "Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper")
        helper.arguments = [
            "--test-bundle-path", testBundle.path, "--skip-build", "--no-parallel",
            "--filter", "prepareParentKillHelper", testBundle.path,
            "--testing-library", "swift-testing",
        ]
        helper.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var environment = ProcessInfo.processInfo.environment
        environment["GATE_PREPARE_REGISTRATION"] = registrationURL.path
        environment["GATE_PREPARE_ROOT"] = root.path
        environment["GATE_PREPARE_LOCK"] = lock.path
        environment["GATE_PREPARE_EXECUTABLE"] = cli.path
        environment["GATE_PREPARE_XCRUN"] = fakeXcrun.path
        environment["LLVM_PROFILE_FILE"] = root.appendingPathComponent("prepare-helper-%p.profraw").path
        helper.environment = environment
        try helper.run()
        try Data(String(helper.processIdentifier).utf8).write(to: helperPIDFile, options: .atomic)
        for _ in 0 ..< 500 {
            if FileManager.default.fileExists(atPath: bootBlocked.path),
                (try? GateSimulatorRegistration.load(from: registrationURL).state) == .creating { break }
            usleep(10_000)
        }
        #expect(FileManager.default.fileExists(atPath: bootBlocked.path))
        #expect(try GateSimulatorRegistration.load(from: registrationURL).state == .creating)
        #expect(kill(helper.processIdentifier, SIGKILL) == 0)
        helper.waitUntilExit()
        for _ in 0 ..< 500 {
            if (try? GateSimulatorRegistration.load(from: registrationURL).state) == .deleted { break }
            usleep(10_000)
        }
        #expect(try GateSimulatorRegistration.load(from: registrationURL).state == .deleted)
        let commands = try String(contentsOf: commandLog, encoding: .utf8)
        #expect(commands.contains("delete GATE-UDID"))
        #expect(!commands.contains("delete UNRELATED-UDID"))
    }

    @Test("A dedicated supervisor deletes the active simulator after literal engine SIGKILL")
    func literalEngineKillCleanup() throws {
        let root = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(root) }
        chmod(root.path, 0o700)
        let deviceSet = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices")
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
        let commandLog = root.appendingPathComponent("commands")
        let fakeXcrun = root.appendingPathComponent("xcrun")
        let script = """
        #!/bin/sh
        echo "$*" >> '\(commandLog.path)'
        if echo "$*" | grep -q ' delete GATE-UDID'; then : > '\(deletedMarker.path)'; exit 0; fi
        if echo "$*" | grep -q 'list devices'; then
          if [ -f '\(deletedMarker.path)' ]; then echo '{"devices":{"runtime":[{"udid":"UNRELATED-UDID"}]}}';
          else echo '{
            "devices" : {
              "runtime" : [
                {
                  "state" : "Booted",
                  "isAvailable" : true,
                  "name" : "SwiftMutationGate",
                  "udid" : "GATE-UDID",
                  "deviceTypeIdentifier" : "type"
                }, {"udid":"UNRELATED-UDID","name":"Unrelated"}
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
        let commands = try String(contentsOf: commandLog, encoding: .utf8)
        #expect(commands.contains("delete GATE-UDID"))
        #expect(!commands.contains("delete UNRELATED-UDID"))
    }

}

private final class DirectSupervisorFixture {
    struct Descriptors {
        let controlRead: Int32
        let controlWrite: Int32
        let readyRead: Int32
        let readyWrite: Int32
        let wrapperRead: Int32
        let wrapperWrite: Int32
    }

    let root: URL
    let registrationURL: URL
    let xcrunURL: URL
    let guideFD: Int32
    let inode: UInt64
    let gateNonce = "GATEABCDEFGHIJKLMNOPQR"
    let invocationNonce = "INVOCATIONABCDEFGHIJKLMNOP"
    let destination = "platform=iOS Simulator,name=iPhone 16"

    init(active: Bool = false, xcrunFails: Bool = false, deviceMissing: Bool = false) throws {
        root = try FileHelpers.makeTemporaryDirectory()
        chmod(root.path, 0o700)
        registrationURL = root.appendingPathComponent("registration.json")
        let lock = root.appendingPathComponent("guide.lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        guideFD = open(lock.path, O_RDONLY)
        var metadata = stat()
        guard guideFD >= 0, fstat(guideFD, &metadata) == 0 else {
            throw PreparedCacheError.unverifiableProcessIdentity
        }
        inode = UInt64(metadata.st_ino)
        let deleted = root.appendingPathComponent("deleted")
        xcrunURL = root.appendingPathComponent("xcrun")
        let script = """
        #!/bin/sh
        \(xcrunFails ? "exit 1" : ":")
        if echo "$*" | grep -q 'list devicetypes'; then echo '{"devicetypes":[{"name":"iPhone 16","identifier":"type"}]}'; exit 0; fi
        if echo "$*" | grep -q 'list runtimes'; then echo '{"runtimes":[{"identifier":"runtime","isAvailable":true}]}'; exit 0; fi
        if echo "$*" | grep -q ' clone SOURCE-UDID '; then echo 'GATE-UDID'; exit 0; fi
        if echo "$*" | grep -q ' delete GATE-UDID'; then : > '\(deleted.path)'; exit 0; fi
        if echo "$*" | grep -q 'list devices'; then
          if [ -f '\(deleted.path)' ]; then echo '{"devices":{"runtime":[{"udid":"SOURCE-UDID","name":"iPhone 16","deviceTypeIdentifier":"type","isAvailable":true},{"udid":"UNRELATED-UDID"}]}}';
          else echo '\(deviceMissing ? #"{"devices":{"runtime":[{"udid":"SOURCE-UDID","name":"iPhone 16","deviceTypeIdentifier":"type","isAvailable":true}]}}"# : #"{"devices":{"runtime":[{"udid":"SOURCE-UDID","name":"iPhone 16","deviceTypeIdentifier":"type","isAvailable":true},{"udid":"UNRELATED-UDID"},{"udid":"GATE-UDID","deviceTypeIdentifier":"type","isAvailable":true}]}}"#)'; fi
          exit 0
        fi
        exit 0
        """
        try Data(script.utf8).write(to: xcrunURL)
        chmod(xcrunURL.path, 0o700)
        if active {
            try writeRegistration(state: .active)
        }
    }

    func pipes(includeWrapper: Bool = false) throws -> Descriptors {
        var control: [Int32] = [-1, -1]
        var ready: [Int32] = [-1, -1]
        var wrapper: [Int32] = [-1, -1]
        guard pipe(&control) == 0, pipe(&ready) == 0,
            (!includeWrapper || pipe(&wrapper) == 0)
        else { throw PreparedCacheError.unverifiableProcessIdentity }
        return Descriptors(
            controlRead: control[0], controlWrite: control[1],
            readyRead: ready[0], readyWrite: ready[1],
            wrapperRead: wrapper[0], wrapperWrite: wrapper[1])
    }

    func prepareArguments(descriptors: Descriptors) -> [String] {
        [registrationURL.path, root.path, String(inode), gateNonce, destination,
         String(guideFD), String(descriptors.controlRead), String(descriptors.readyWrite), xcrunURL.path]
    }

    func activeArguments(descriptors: Descriptors) throws -> [String] {
        let digest = ProjectInputManifest.sha256(try Data(contentsOf: registrationURL))
        return [registrationURL.path, root.path, String(inode), invocationNonce, digest,
                String(guideFD), String(descriptors.controlRead), String(descriptors.readyWrite),
                String(descriptors.wrapperRead), xcrunURL.path]
    }

    func childScript(readinessArgument: Int, exitCode: Int = 0) throws -> URL {
        let url = root.appendingPathComponent("child-\(readinessArgument)-\(exitCode)")
        let script = """
        #!/bin/sh
        eval "printf '\\001' >&${\(readinessArgument)}"
        eval "dd bs=1 count=1 <&${8} >/dev/null 2>&1"
        exit \(exitCode)
        """
        try Data(script.utf8).write(to: url)
        chmod(url.path, 0o700)
        return url
    }

    func silentChildScript() throws -> URL {
        let url = root.appendingPathComponent("silent-child")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        chmod(url.path, 0o700)
        return url
    }

    func readyThenExitChildScript(readinessArgument: Int, controlArgument: Int) throws -> URL {
        let url = root.appendingPathComponent("ready-exit-child-\(readinessArgument)")
        let script = """
        #!/bin/sh
        eval "exec ${\(controlArgument)}<&-"
        eval "printf '\\001' >&${\(readinessArgument)}"
        exit 0
        """
        try Data(script.utf8).write(to: url)
        chmod(url.path, 0o700)
        return url
    }

    func signaledChildScript(readinessArgument: Int) throws -> URL {
        let url = root.appendingPathComponent("signaled-child")
        let script = """
        #!/bin/sh
        eval "printf '\\001' >&${\(readinessArgument)}"
        eval "dd bs=1 count=1 <&${8} >/dev/null 2>&1"
        kill -9 $$
        """
        try Data(script.utf8).write(to: url)
        chmod(url.path, 0o700)
        return url
    }

    func close(_ descriptors: Descriptors) {
        [descriptors.controlRead, descriptors.controlWrite, descriptors.readyRead,
         descriptors.readyWrite, descriptors.wrapperRead, descriptors.wrapperWrite]
            .filter { $0 >= 0 }.forEach { _ = Darwin.close($0) }
    }

    func cleanup() {
        _ = Darwin.close(guideFD)
        FileHelpers.cleanup(root)
    }

    private func writeRegistration(state: GateSimulatorRegistration.State) throws {
        let registration = GateSimulatorRegistration(
            schemaVersion: 1, gateRunNonce: gateNonce, guideLockInode: inode,
            deviceSetPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/CoreSimulator/Devices").path,
            udid: "GATE-UDID", runtimeIdentifier: "runtime", deviceTypeIdentifier: "type",
            generation: 1, state: state,
            activeInvocationNonce: state == .active ? invocationNonce : nil)
        try JSONEncoder().encode(registration).write(to: registrationURL)
        chmod(registrationURL.path, 0o600)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}
