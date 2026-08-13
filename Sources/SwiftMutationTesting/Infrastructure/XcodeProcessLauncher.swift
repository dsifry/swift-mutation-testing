import Foundation

protocol XcodeCustodyPreservingLauncher {
    var supportsXcodeCustody: Bool { get }
    func applyingXcodeCustody(
        _ custody: ProcessCustody?, captureRoot: URL?
    ) -> any ProcessLaunching
}

struct XcodeProcessLauncher: Sendable, ProcessLaunching {
    init(custody: ProcessCustody? = nil, captureRoot: URL? = nil) {
        self.custody = custody
        self.captureRoot = captureRoot
    }

    private let custody: ProcessCustody?
    private let captureRoot: URL?

    func launch(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL,
        timeout: Double
    ) async throws -> Int32 {
        try await makeRunner().launch(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectoryURL: workingDirectoryURL,
            timeout: timeout
        )
    }

    func launchCapturing(
        _ request: ProcessRequest
    ) async throws -> (exitCode: Int32, output: String) {
        try await makeRunner().launchCapturing(request)
    }

    func makeRunner() -> ProcessRunner {
        let escalation = ProcessEscalationController()
        return ProcessRunner(
            processDidStart: { pid in
                guard let custody else { return }
                try custody.register(SystemProcessIdentity.group(for: pid))
            },
            postTerminationCleanup: { pid in try custody?.unregister(pid: pid) },
            onTimeout: { escalation.begin(pid: $0) },
            timeoutDidFinish: { escalation.cancel(pid: $0) },
            captureRoot: captureRoot
        )
    }
}

extension XcodeProcessLauncher: XcodeCustodyPreservingLauncher {
    var supportsXcodeCustody: Bool { true }

    func applyingXcodeCustody(
        _ custody: ProcessCustody?, captureRoot: URL?
    ) -> any ProcessLaunching {
        XcodeProcessLauncher(custody: custody, captureRoot: captureRoot)
    }
}

final class ProcessEscalationController: @unchecked Sendable {
    typealias Identity = @Sendable (Int32) -> CustodiedProcessGroup?
    typealias Status = @Sendable (CustodiedProcessGroup) -> ProcessIdentityStatus
    typealias Signal = @Sendable (Int32, Int32) -> Int32
    typealias Delay = @Sendable () async throws -> Void

    private let identity: Identity
    private let status: Status
    private let signal: Signal
    private let delay: Delay
    private let lock = NSLock()
    private var tasks: [Int32: Task<Void, Never>] = [:]

    init(
        identity: @escaping Identity = { try? SystemProcessIdentity.group(for: $0) },
        status: @escaping Status = { SystemProcessIdentity.status(of: $0) },
        signal: @escaping Signal = { kill($0, $1) },
        delay: @escaping Delay = { try await Task.sleep(for: .seconds(5)) }
    ) {
        self.identity = identity
        self.status = status
        self.signal = signal
        self.delay = delay
    }

    func begin(pid: Int32) {
        guard pid > 0, let group = identity(pid) else { return }
        let signalTarget = group.pid == group.processGroupID ? -group.processGroupID : group.pid
        lock.withLock {
            guard tasks[pid] == nil else { return }
            tasks[pid] = Task { [weak self] in
                guard let self, status(group) == .matching else { return }
                _ = signal(signalTarget, SIGTERM)
                do { try await delay() } catch { return }
                guard !Task.isCancelled, status(group) == .matching else { return }
                _ = signal(signalTarget, SIGKILL)
            }
        }
    }

    func cancel(pid: Int32) {
        lock.withLock { tasks.removeValue(forKey: pid) }?.cancel()
    }
}

final class ObservedBuildCountingLauncher: @unchecked Sendable, ProcessLaunching {
    private let base: any ProcessLaunching
    private let countAsFallback: Bool
    private let countBuildForTestingAsIncremental: Bool
    private let lock = NSLock()
    private var buildAttempts = 0
    private var incrementalAttempts = 0
    private var fallbackAttempts = 0
    private var testWithoutBuildingAttempts = 0

    init(
        base: any ProcessLaunching,
        countAsFallback: Bool = false,
        countBuildForTestingAsIncremental: Bool = false
    ) {
        self.base = base
        self.countAsFallback = countAsFallback
        self.countBuildForTestingAsIncremental = countBuildForTestingAsIncremental
    }

    var buildForTestingAttempts: Int { lock.withLock { buildAttempts + incrementalAttempts } }
    var fullBuildAttempts: Int { lock.withLock { buildAttempts } }
    var incrementalBuildAttempts: Int { lock.withLock { incrementalAttempts } }
    var fallbackBuildAttempts: Int { lock.withLock { fallbackAttempts } }
    var testWithoutBuildingRuns: Int { lock.withLock { testWithoutBuildingAttempts } }

    func launch(
        executableURL: URL, arguments: [String], workingDirectoryURL: URL, timeout: Double
    ) async throws -> Int32 {
        record(executableURL: executableURL, arguments: arguments)
        return try await base.launch(
            executableURL: executableURL, arguments: arguments,
            workingDirectoryURL: workingDirectoryURL, timeout: timeout
        )
    }

    func launchCapturing(_ request: ProcessRequest) async throws -> (exitCode: Int32, output: String) {
        record(executableURL: request.executableURL, arguments: request.arguments)
        return try await base.launchCapturing(request)
    }

    private func record(executableURL: URL, arguments: [String]) {
        guard executableURL.path == "/usr/bin/xcodebuild", let operation = arguments.first else { return }
        lock.withLock {
            if operation == "build-for-testing" {
                if countBuildForTestingAsIncremental {
                    incrementalAttempts += 1
                } else {
                    buildAttempts += 1
                }
            }
            if countAsFallback, operation == "test" { fallbackAttempts += 1 }
            if operation == "test-without-building" { testWithoutBuildingAttempts += 1 }
        }
    }
}
