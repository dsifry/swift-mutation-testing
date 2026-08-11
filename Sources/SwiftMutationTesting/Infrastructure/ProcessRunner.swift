import Darwin
import Foundation

struct ProcessRunner: Sendable {
    typealias SpawnInitializer =
        @Sendable (
            UnsafeMutablePointer<posix_spawn_file_actions_t?>,
            UnsafeMutablePointer<posix_spawnattr_t?>
        ) -> Bool
    typealias SpawnConfigurator =
        @Sendable (
            UnsafeMutablePointer<posix_spawn_file_actions_t?>,
            UnsafeMutablePointer<posix_spawnattr_t?>,
            Int32,
            String
        ) -> Bool

    var processDidStart: (@Sendable (Int32) throws -> Void)?
    var postTerminationCleanup: (@Sendable (Int32) throws -> Void)?
    let onTimeout: @Sendable (Int32) -> Void
    let timeoutDidFinish: @Sendable (Int32) -> Void
    var establishProcessGroup: @Sendable (Int32) -> Bool
    var terminateDirectProcess: @Sendable (Int32) -> Void
    var openNullDescriptor: @Sendable () -> Int32
    var createCaptureDescriptor: @Sendable (String) -> Int32
    var closeCaptureDescriptor: @Sendable (Int32) -> Int32 = { close($0) }
    var captureDescriptorIdentity: @Sendable (Int32) -> stat? = { descriptor in
        var identity = stat()
        return fstat(descriptor, &identity) == 0 ? identity : nil
    }
    var readCaptureDescriptor: @Sendable (Int32) -> String? = { readCapturedOutput(from: $0) }
    var captureRoot: URL?
    var initializeSpawn: SpawnInitializer
    var configureSpawn: SpawnConfigurator

    init(
        processDidStart: (@Sendable (Int32) throws -> Void)? = nil,
        postTerminationCleanup: (@Sendable (Int32) throws -> Void)? = nil,
        onTimeout: @escaping @Sendable (Int32) -> Void,
        timeoutDidFinish: @escaping @Sendable (Int32) -> Void = { _ in },
        establishProcessGroup: @escaping @Sendable (Int32) -> Bool = { getpgid($0) == $0 },
        terminateDirectProcess: @escaping @Sendable (Int32) -> Void = { _ = kill($0, SIGKILL) },
        openNullDescriptor: @escaping @Sendable () -> Int32 = { open("/dev/null", O_WRONLY | O_CLOEXEC) },
        createCaptureDescriptor: @escaping @Sendable (String) -> Int32 = {
            openPrivateCaptureFile($0)
        },
        captureRoot: URL? = nil,
        initializeSpawn: @escaping SpawnInitializer = { actions, attributes in
            initializeSpawnResources(actions: actions, attributes: attributes)
        },
        configureSpawn: @escaping SpawnConfigurator = { actions, attributes, output, directory in
            configureSpawnResources(
                actions: actions, attributes: attributes, output: output, directory: directory
            )
        }
    ) {
        self.processDidStart = processDidStart
        self.postTerminationCleanup = postTerminationCleanup
        self.onTimeout = onTimeout
        self.timeoutDidFinish = timeoutDidFinish
        self.establishProcessGroup = establishProcessGroup
        self.terminateDirectProcess = terminateDirectProcess
        self.openNullDescriptor = openNullDescriptor
        self.createCaptureDescriptor = createCaptureDescriptor
        self.captureRoot = captureRoot
        self.initializeSpawn = initializeSpawn
        self.configureSpawn = configureSpawn
    }

    final class KilledByUsFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        var value: Bool { lock.withLock { flag } }
        func mark() { lock.withLock { flag = true } }
    }

    func launch(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL,
        timeout: Double
    ) async throws -> Int32 {
        let nullDescriptor = openNullDescriptor()
        guard nullDescriptor >= 0 else { throw PreparedCacheError.unverifiableProcessIdentity }
        defer { close(nullDescriptor) }
        let pid = try spawn(
            executableURL: executableURL,
            arguments: arguments,
            environment: nil,
            workingDirectoryURL: workingDirectoryURL,
            outputDescriptor: nullDescriptor
        )
        return try await supervise(pid: pid, timeout: timeout) { status in status }
    }

    func launchCapturing(_ request: ProcessRequest) async throws -> (exitCode: Int32, output: String) {
        let root = try Self.captureDirectory(captureRoot)
        if captureRoot != nil {
            try CachePathGuard.validateCanonicalAbsoluteRoot(root)
            try CachePathGuard.validateDirectory(root, containedIn: root)
        }
        let tempURL = root.appendingPathComponent(".swift-mutation-capture.\(UUID().uuidString)")
        let captureDescriptor = createCaptureDescriptor(tempURL.path)
        guard captureDescriptor >= 0 else {
            throw PreparedCacheError.unverifiableProcessIdentity
        }
        var captureDescriptorIsOpen = true
        defer { if captureDescriptorIsOpen { _ = closeCaptureDescriptor(captureDescriptor) } }
        guard let captureIdentity = captureDescriptorIdentity(captureDescriptor),
            captureIdentity.st_uid == getuid(), captureIdentity.st_mode & S_IFMT == S_IFREG,
            captureIdentity.st_mode & 0o777 == 0o600, captureIdentity.st_nlink == 0
        else {
            throw PreparedCacheError.unsafeCachePath
        }
        do {
            var environment = request.environment
            if !request.additionalEnvironment.isEmpty {
                var merged = environment ?? ProcessInfo.processInfo.environment
                for (key, value) in request.additionalEnvironment { merged[key] = value }
                environment = merged
            }
            let pid = try spawn(
                executableURL: request.executableURL,
                arguments: request.arguments,
                environment: environment,
                workingDirectoryURL: request.workingDirectoryURL,
                outputDescriptor: captureDescriptor
            )
            let exitCode = try await supervise(pid: pid, timeout: request.timeout) { status in status }
            guard let output = readCaptureDescriptor(captureDescriptor) else {
                throw PreparedCacheError.unsafeCachePath
            }
            let closeResult = closeCaptureDescriptor(captureDescriptor)
            captureDescriptorIsOpen = false
            guard closeResult == 0 else { throw PreparedCacheError.unverifiableProcessIdentity }
            return (exitCode, output)
        } catch {
            throw error
        }
    }

    static func readCapturedOutput(from descriptor: Int32) -> String? {
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            try handle.seek(toOffset: 0)
            return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func supervise<T: Sendable>(
        pid: Int32,
        timeout: Double,
        transform: @escaping @Sendable (Int32) -> T
    ) async throws -> T {
        guard establishProcessGroup(pid) else {
            terminateDirectProcess(pid)
            _ = waitForExit(pid)
            throw PreparedCacheError.unverifiableProcessIdentity
        }
        do {
            try processDidStart?(pid)
        } catch {
            _ = kill(-pid, SIGKILL)
            _ = waitForExit(pid)
            throw error
        }
        let killedByUs = KilledByUsFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task {
                    try await Task.sleep(for: .seconds(timeout))
                    killedByUs.mark()
                    onTimeout(pid)
                }
                DispatchQueue.global().async {
                    let status = waitForExit(pid)
                    timeoutTask.cancel()
                    timeoutDidFinish(pid)
                    do {
                        try postTerminationCleanup?(pid)
                        continuation.resume(returning: transform(killedByUs.value ? -1 : status))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            killedByUs.mark()
            onTimeout(pid)
        }
    }

    private func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        workingDirectoryURL: URL,
        outputDescriptor: Int32
    ) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard initializeSpawn(&actions, &attributes) else {
            throw PreparedCacheError.unverifiableProcessIdentity
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        guard configureSpawn(&actions, &attributes, outputDescriptor, workingDirectoryURL.path) else {
            throw PreparedCacheError.unverifiableProcessIdentity
        }

        let argv = ([executableURL.path] + arguments).map { strdup($0) } + [nil]
        let environmentValues = (environment ?? ProcessInfo.processInfo.environment)
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let envp = environmentValues.map { strdup($0) } + [nil]
        defer {
            for argument in argv.dropLast() { free(argument) }
            for environmentValue in envp.dropLast() { free(environmentValue) }
        }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envBuffer in
                posix_spawn(
                    &pid,
                    executableURL.path,
                    &actions,
                    &attributes,
                    UnsafeMutablePointer(mutating: argvBuffer.baseAddress!),
                    UnsafeMutablePointer(mutating: envBuffer.baseAddress!)
                )
            }
        }
        guard result == 0, pid > 0 else {
            errno = result
            throw CocoaError(.executableNotLoadable)
        }
        return pid
    }

    static func openPrivateCaptureFile(
        _ path: String,
        openFile: (String) -> Int32 = {
            open($0, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        },
        descriptorIdentity: (Int32) -> stat? = { descriptor in
            var identity = stat()
            return fstat(descriptor, &identity) == 0 ? identity : nil
        },
        unlinkFile: (String) -> Int32 = { unlink($0) },
        closeFile: (Int32) -> Void = { _ = close($0) }
    ) -> Int32 {
        let descriptor = openFile(path)
        guard descriptor >= 0 else { return -1 }
        guard let identity = descriptorIdentity(descriptor), identity.st_uid == getuid(),
            identity.st_mode & S_IFMT == S_IFREG, identity.st_mode & 0o777 == 0o600,
            identity.st_nlink == 1, unlinkFile(path) == 0,
            let unlinkedIdentity = descriptorIdentity(descriptor),
            unlinkedIdentity.st_dev == identity.st_dev, unlinkedIdentity.st_ino == identity.st_ino,
            unlinkedIdentity.st_nlink == 0
        else {
            closeFile(descriptor)
            return -1
        }
        return descriptor
    }

    static func captureDirectory(
        _ requested: URL?,
        canonicalizer: (URL) -> URL? = { CachePathGuard.canonicalURL($0) }
    ) throws -> URL {
        if let requested { return requested }
        guard let root = canonicalizer(FileManager.default.temporaryDirectory) else {
            throw PreparedCacheError.unsafeCachePath
        }
        return root
    }

    static func initializeSpawnResources(
        actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
        attributes: UnsafeMutablePointer<posix_spawnattr_t?>,
        initializeActions: (UnsafeMutablePointer<posix_spawn_file_actions_t?>) -> Int32 = posix_spawn_file_actions_init,
        initializeAttributes: (UnsafeMutablePointer<posix_spawnattr_t?>) -> Int32 = posix_spawnattr_init,
        destroyActions: (UnsafeMutablePointer<posix_spawn_file_actions_t?>) -> Int32 = posix_spawn_file_actions_destroy
    ) -> Bool {
        guard initializeActions(actions) == 0 else { return false }
        guard initializeAttributes(attributes) == 0 else {
            _ = destroyActions(actions)
            return false
        }
        return true
    }

    static func configureSpawnResources(
        actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
        attributes: UnsafeMutablePointer<posix_spawnattr_t?>,
        output: Int32,
        directory: String,
        addInput: (
            UnsafeMutablePointer<posix_spawn_file_actions_t?>, Int32, String, Int32, mode_t
        ) -> Int32 = { posix_spawn_file_actions_addopen($0, $1, $2, $3, $4) }
    ) -> Bool {
        addInput(actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0
            && posix_spawn_file_actions_adddup2(actions, output, STDOUT_FILENO) == 0
            && posix_spawn_file_actions_adddup2(actions, output, STDERR_FILENO) == 0
            && posix_spawn_file_actions_addchdir_np(actions, directory) == 0
            && posix_spawnattr_setflags(
                attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
            ) == 0
            && posix_spawnattr_setpgroup(attributes, 0) == 0
    }
}

func waitForExit(
    _ pid: Int32,
    wait: (Int32, UnsafeMutablePointer<Int32>?, Int32) -> Int32 = { waitpid($0, $1, $2) }
) -> Int32 {
    var status: Int32 = 0
    while true {
        let result = wait(pid, &status, 0)
        if result == pid { break }
        if result == -1, errno == EINTR { continue }
        return -1
    }
    let waitStatus = status & 0o177
    if waitStatus == 0 { return (status >> 8) & 0xff }
    return 128 + waitStatus
}
