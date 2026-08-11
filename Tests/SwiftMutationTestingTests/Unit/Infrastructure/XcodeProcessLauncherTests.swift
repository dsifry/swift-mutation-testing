import Foundation
import Testing

@testable import SwiftMutationTesting

@Suite("XcodeProcessLauncher")
struct XcodeProcessLauncherTests {
    private let launcher = XcodeProcessLauncher()

    @Test("Process runner registers a child after launch and unregisters it after termination")
    func processLifecycleHooks() async throws {
        let recorder = ProcessLifecycleRecorder()
        let runner = ProcessRunner(
            processDidStart: { try recorder.start($0) },
            postTerminationCleanup: { recorder.finish($0) },
            onTimeout: { _ in }
        )

        #expect(try await runner.launch(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            timeout: 10
        ) == 0)
        #expect(recorder.started.count == 1)
        #expect(recorder.finished == recorder.started)
    }

    @Test("Process runner propagates registration failures for both launch modes")
    func processRegistrationFailures() async {
        let runner = ProcessRunner(
            processDidStart: { _ in throw PreparedCacheError.unverifiableProcessIdentity },
            postTerminationCleanup: nil,
            onTimeout: { _ in }
        )
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await runner.launch(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 10
            )
        }
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await runner.launchCapturing(.init(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"],
                environment: nil, additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 10
            ))
        }
        XcodeProcessLauncher().makeRunner().onTimeout(0)
        #expect(ProcessRunner.readCapturedOutput(at: URL(fileURLWithPath: "/definitely/missing")) == "")
    }

    @Test("Process-group setup failure aborts only the direct child and never registers a caller group")
    func processGroupSetupFailureIsContained() async {
        let recorder = ProcessLifecycleRecorder()
        let runner = ProcessRunner(
            processDidStart: { try recorder.start($0) },
            postTerminationCleanup: nil,
            onTimeout: { _ in },
            establishProcessGroup: { _ in false },
            terminateDirectProcess: { recorder.abort($0) }
        )

        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await runner.launch(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 10
            )
        }
        #expect(recorder.started.isEmpty)
        #expect(recorder.aborted.count == 1)

        let defaultAbort = ProcessRunner(
            onTimeout: { _ in },
            establishProcessGroup: { _ in false }
        )
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await defaultAbort.launch(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 10
            )
        }
    }

    @Test("Process runner fails closed for descriptor and spawn setup failures")
    func processSetupFailures() async {
        let nullFailure = ProcessRunner(onTimeout: { _ in }, openNullDescriptor: { -1 })
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await nullFailure.launch(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            )
        }
        let captureFailure = ProcessRunner(onTimeout: { _ in }, createCaptureFile: { _ in false })
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await captureFailure.launchCapturing(.init(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                environment: nil, additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            ))
        }
        #expect(!ProcessRunner.createPrivateCaptureFile("ignored", openFile: { _ in -1 }))
        #expect(!ProcessRunner.createPrivateCaptureFile(
            "ignored", openFile: { _ in open("/dev/null", O_WRONLY) }, closeFile: { descriptor in
                _ = close(descriptor); return -1
            }
        ))
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try ProcessRunner.captureDirectory(nil, canonicalizer: { _ in nil })
        }
        let insecureCapture = ProcessRunner(
            onTimeout: { _ in },
            createCaptureFile: { path in
                FileManager.default.createFile(
                    atPath: path, contents: nil, attributes: [.posixPermissions: 0o644]
                )
            }
        )
        await #expect(throws: PreparedCacheError.unsafeCachePath) {
            try await insecureCapture.launchCapturing(.init(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                environment: nil, additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            ))
        }
        let initializeFailure = ProcessRunner(
            onTimeout: { _ in },
            initializeSpawn: { _, _ in false }
        )
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await initializeFailure.launch(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            )
        }
        let configureFailure = ProcessRunner(
            onTimeout: { _ in },
            configureSpawn: { _, _, _, _ in false }
        )
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await configureFailure.launch(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            )
        }
        #expect(waitForExit(Int32.max) == -1)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let destroyed = ProcessLifecycleRecorder()
        #expect(!ProcessRunner.initializeSpawnResources(
            actions: &actions,
            attributes: &attributes,
            initializeActions: { pointer in posix_spawn_file_actions_init(pointer) },
            initializeAttributes: { _ in EIO },
            destroyActions: { pointer in destroyed.abort(1); return posix_spawn_file_actions_destroy(pointer) }
        ))
        #expect(destroyed.aborted == [1])
        #expect(!ProcessRunner.initializeSpawnResources(
            actions: &actions, attributes: &attributes,
            initializeActions: { _ in EIO }, initializeAttributes: { _ in 0 },
            destroyActions: { _ in destroyed.abort(2); return 0 }
        ))
        #expect(destroyed.aborted == [1])

        #expect(posix_spawn_file_actions_init(&actions) == 0)
        #expect(posix_spawnattr_init(&attributes) == 0)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        #expect(ProcessRunner.configureSpawnResources(
            actions: &actions, attributes: &attributes, output: STDERR_FILENO, directory: "/tmp"
        ))
        var flags: Int16 = 0
        #expect(posix_spawnattr_getflags(&attributes, &flags) == 0)
        #expect(flags & Int16(POSIX_SPAWN_SETPGROUP) != 0)
        #expect(flags & Int16(POSIX_SPAWN_CLOEXEC_DEFAULT) != 0)
    }

    @Test("waitpid retries EINTR and returns the eventual child status")
    func waitRetriesEINTR() {
        let recorder = WaitRecorder(results: [-1, 77], statuses: [0, 3 << 8], errors: [EINTR, 0])
        #expect(waitForExit(77, wait: { pid, status, options in
            recorder.wait(pid: pid, status: status, options: options)
        }) == 3)
        #expect(recorder.calls == 2)
    }

    @Test("Capturing uses and scrubs the authenticated active-run root")
    func authenticatedCaptureRoot() async throws {
        let root = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, 0o700)
        let launcher = XcodeProcessLauncher(captureRoot: root)
        let result = try await launcher.launchCapturing(.init(
            executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: ["private-output"],
            environment: nil, additionalEnvironment: [:], workingDirectoryURL: root, timeout: 10
        ))
        #expect(result.output.contains("private-output"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await #expect(throws: (any Error).self) {
            try await launcher.launchCapturing(.init(
                executableURL: URL(fileURLWithPath: "/missing/executable"), arguments: [],
                environment: nil, additionalEnvironment: [:], workingDirectoryURL: root, timeout: 10
            ))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Escalation is identity-checked and lifecycle-cancellable")
    func escalationLifecycle() async throws {
        let group = CustodiedProcessGroup(pid: 44, processGroupID: 44, birthIdentity: "birth")
        let signals = ProcessLifecycleRecorder()
        let escalation = ProcessEscalationController(
            identity: { _ in group }, status: { _ in .matching },
            signal: { _, signal in signals.abort(signal); return 0 }, delay: {}
        )
        escalation.begin(pid: 44)
        for _ in 0..<50 where signals.aborted.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(signals.aborted == [SIGTERM, SIGKILL])

        let cancelledSignals = ProcessLifecycleRecorder()
        let cancelled = ProcessEscalationController(
            identity: { _ in group }, status: { _ in .matching },
            signal: { _, signal in cancelledSignals.abort(signal); return 0 },
            delay: { try await Task.sleep(for: .seconds(30)) }
        )
        cancelled.begin(pid: 44)
        for _ in 0..<50 where cancelledSignals.aborted.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        cancelled.cancel(pid: 44)
        try await Task.sleep(for: .milliseconds(10))
        #expect(cancelledSignals.aborted == [SIGTERM])

        let wrongGroup = ProcessEscalationController(identity: { _ in
            .init(pid: 44, processGroupID: 1, birthIdentity: "caller")
        })
        wrongGroup.begin(pid: 44)

        let statuses = ProcessStatusRecorder([.mismatched])
        let rejectedSignals = ProcessLifecycleRecorder()
        let rejected = ProcessEscalationController(
            identity: { _ in group }, status: { _ in statuses.next() },
            signal: { _, signal in rejectedSignals.abort(signal); return 0 }, delay: {}
        )
        rejected.begin(pid: 44)
        rejected.begin(pid: 44)
        try await Task.sleep(for: .milliseconds(10))
        #expect(rejectedSignals.aborted.isEmpty)

        let preKillStatuses = ProcessStatusRecorder([.matching, .mismatched])
        let preKillSignals = ProcessLifecycleRecorder()
        let preKill = ProcessEscalationController(
            identity: { _ in group }, status: { _ in preKillStatuses.next() },
            signal: { _, signal in preKillSignals.abort(signal); return 0 }, delay: {}
        )
        preKill.begin(pid: 44)
        for _ in 0..<50 where preKillSignals.aborted.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(preKillSignals.aborted == [SIGTERM])
    }

    @Test("Observed build counter counts delegated attempts including failures")
    func observedBuildCounter() async {
        let base = RecordingBuildLauncher()
        let counter = ObservedBuildCountingLauncher(base: base)
        await #expect(throws: PreparedCacheError.invalidCacheState) {
            try await counter.launchCapturing(.init(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                arguments: ["build-for-testing"], environment: nil, additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            ))
        }
        #expect(counter.buildForTestingAttempts == 1)
        #expect(counter.fallbackBuildAttempts == 0)

        let fallbackCounter = ObservedBuildCountingLauncher(base: base, countAsFallback: true)
        await #expect(throws: PreparedCacheError.invalidCacheState) {
            try await fallbackCounter.launchCapturing(ProcessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                arguments: ["build-for-testing"], environment: nil, additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            ))
        }
        #expect(fallbackCounter.buildForTestingAttempts == 1)
        #expect(fallbackCounter.fallbackBuildAttempts == 0)
        await #expect(throws: PreparedCacheError.invalidCacheState) {
            try await fallbackCounter.launchCapturing(ProcessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                arguments: ["test", "-scheme", "App"], environment: nil, additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            ))
        }
        #expect(fallbackCounter.fallbackBuildAttempts == 1)
        await #expect(throws: PreparedCacheError.invalidCacheState) {
            try await fallbackCounter.launchCapturing(ProcessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                arguments: ["test-without-building"], environment: nil, additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            ))
        }
        await #expect(throws: PreparedCacheError.invalidCacheState) {
            try await fallbackCounter.launchCapturing(ProcessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/false"),
                arguments: ["test"], environment: nil, additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            ))
        }
        #expect(fallbackCounter.fallbackBuildAttempts == 1)

        let nonBuildCounter = ObservedBuildCountingLauncher(base: base)
        await #expect(throws: PreparedCacheError.invalidCacheState) {
            try await nonBuildCounter.launch(
                executableURL: URL(fileURLWithPath: "/usr/bin/false"), arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            )
        }
        #expect(nonBuildCounter.buildForTestingAttempts == 0)
    }

    @Test("Custody unregister failures fail the command instead of being swallowed")
    func unregisterFailurePropagates() async {
        let runner = ProcessRunner(
            processDidStart: nil,
            postTerminationCleanup: { _ in throw PreparedCacheError.unverifiableProcessIdentity },
            onTimeout: { _ in }
        )
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await runner.launch(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 10
            )
        }
    }

    @Test("Custodial launcher persists the live process group and clears it on termination")
    func custodialLauncherRegistryLifecycle() async throws {
        let directory = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        chmod(directory.path, 0o700)
        let registry = directory.appendingPathComponent("process-custody.json")
        let custody = try ProcessCustody.system(registrationURL: registry)
        let launcher = XcodeProcessLauncher(custody: custody)

        let task = Task {
            try await launcher.launch(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["0.2"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 10
            )
        }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: registry.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try ProcessCustody.readRegisteredGroups(from: registry).count == 1)
        #expect(try await task.value == 0)
        #expect(try ProcessCustody.readRegisteredGroups(from: registry).isEmpty)
    }

    @Test("Given a successful executable, when launched, then returns zero exit code")
    func launchReturnsSuccessExitCode() async throws {
        let exitCode = try await launcher.launch(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            timeout: 10
        )

        #expect(exitCode == 0)
    }

    @Test("Given a failing executable, when launched, then returns non-zero exit code")
    func launchReturnsFailureExitCode() async throws {
        let exitCode = try await launcher.launch(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            timeout: 10
        )

        #expect(exitCode != 0)
    }

    @Test("Given echo command, when launched capturing, then output contains the argument")
    func launchCapturingReturnsStdout() async throws {
        let result = try await launcher.launchCapturing(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["hello world"],
                environment: nil,
                additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 10
            )
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("hello world"))
    }

    @Test("Given environment variables, when launched capturing, then process receives the variables")
    func launchCapturingPassesEnvironment() async throws {
        let result = try await launcher.launchCapturing(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo $TEST_VAR"],
                environment: ["TEST_VAR": "expected_value"],
                additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 10
            )
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("expected_value"))
    }

    @Test("Given stderr output, when launched capturing, then stderr is included in output")
    func launchCapturingCapturesStderr() async throws {
        let result = try await launcher.launchCapturing(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo error_text >&2"],
                environment: nil,
                additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 10
            )
        )

        #expect(result.output.contains("error_text"))
    }

    @Test("Given long-running process and short timeout, when timeout expires, then returns minus one exit code")
    func launchTimesOutAndReturnsMinus1() async throws {
        let exitCode = try await launcher.launch(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["60"],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            timeout: 0.5
        )

        #expect(exitCode == -1)
    }

    @Test("Given non-existent executable, when launched, then throws")
    func launchThrowsForNonExistentExecutable() async {
        await #expect(throws: (any Error).self) {
            try await launcher.launch(
                executableURL: URL(fileURLWithPath: "/nonexistent/binary"),
                arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 10
            )
        }
    }

    @Test("Given non-existent executable, when launchCapturing called, then throws")
    func launchCapturingThrowsForNonExistentExecutable() async {
        await #expect(throws: (any Error).self) {
            try await launcher.launchCapturing(
                ProcessRequest(
                    executableURL: URL(fileURLWithPath: "/nonexistent/binary"),
                    arguments: [],
                    environment: nil,
                    additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                    timeout: 10
                )
            )
        }
    }

    @Test("Given long-running process and short timeout, when launchCapturing times out, then returns minus one")
    func launchCapturingTimesOut() async throws {
        let result = try await launcher.launchCapturing(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                environment: nil,
                additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 0.5
            )
        )

        #expect(result.exitCode == -1)
    }

    @Test("Given task is cancelled while launch running, when cancelled, then process is terminated")
    func cancelledLaunchTerminatesProcess() async throws {
        let task = Task {
            try await launcher.launch(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 60
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        let exitCode = try await task.value
        #expect(exitCode == -1)
    }

    @Test("Given additionalEnvironment, when launched capturing, then process receives merged variable")
    func launchCapturingMergesAdditionalEnvironment() async throws {
        let result = try await launcher.launchCapturing(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo $EXTRA_VAR"],
                environment: nil,
                additionalEnvironment: ["EXTRA_VAR": "merged_value"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 10
            )
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("merged_value"))
    }

    @Test("Given task is cancelled while launchCapturing running, when cancelled, then process is terminated")
    func cancelledLaunchCapturingTerminatesProcess() async throws {
        let task = Task {
            try await launcher.launchCapturing(
                ProcessRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["60"],
                    environment: nil,
                    additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                    timeout: 60
                )
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        let result = try await task.value
        #expect(result.exitCode == -1)
    }
}

private final class ProcessLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var started: [Int32] = []
    private(set) var finished: [Int32] = []
    private(set) var aborted: [Int32] = []

    func start(_ pid: Int32) throws { lock.withLock { started.append(pid) } }
    func finish(_ pid: Int32) { lock.withLock { finished.append(pid) } }
    func abort(_ pid: Int32) { lock.withLock { aborted.append(pid) } }
}

private final class WaitRecorder: @unchecked Sendable {
    private var results: [Int32]
    private var statuses: [Int32]
    private var errors: [Int32]
    private(set) var calls = 0

    init(results: [Int32], statuses: [Int32], errors: [Int32]) {
        self.results = results
        self.statuses = statuses
        self.errors = errors
    }

    func wait(pid: Int32, status: UnsafeMutablePointer<Int32>?, options: Int32) -> Int32 {
        _ = options
        status?.pointee = statuses[calls]
        errno = errors[calls]
        defer { calls += 1 }
        return results[calls]
    }
}

private final class RecordingBuildLauncher: @unchecked Sendable, ProcessLaunching {
    func launch(executableURL: URL, arguments: [String], workingDirectoryURL: URL, timeout: Double) async throws -> Int32 {
        throw PreparedCacheError.invalidCacheState
    }

    func launchCapturing(_ request: ProcessRequest) async throws -> (exitCode: Int32, output: String) {
        throw PreparedCacheError.invalidCacheState
    }
}

private final class ProcessStatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [ProcessIdentityStatus]

    init(_ statuses: [ProcessIdentityStatus]) { self.statuses = statuses }

    func next() -> ProcessIdentityStatus {
        lock.withLock { statuses.isEmpty ? .mismatched : statuses.removeFirst() }
    }
}
