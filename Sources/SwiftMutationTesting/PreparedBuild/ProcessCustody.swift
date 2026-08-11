import Foundation

struct CustodiedProcessGroup: Hashable, Codable, Sendable {
    let pid: Int32
    let processGroupID: Int32
    let birthIdentity: String
}

enum ProcessIdentityStatus: Equatable, Sendable {
    case matching
    case absent
    case mismatched
}

final class ProcessCustody: @unchecked Sendable {
    /// The execution protocol's hard ceiling for parallel workers and live child groups.
    static let maximumTrackedProcessGroups = 64

    typealias IdentityVerifier = @Sendable (CustodiedProcessGroup) -> Bool
    typealias IdentityStatusVerifier = @Sendable (CustodiedProcessGroup) -> ProcessIdentityStatus
    typealias GroupOperation = @Sendable (Int32) throws -> Void

    private let verifyIdentity: IdentityVerifier
    private let identityStatus: IdentityStatusVerifier
    private let terminateGroup: GroupOperation
    private let waitForVerifiedGroup: @Sendable (CustodiedProcessGroup) throws -> Void
    private let groupIsAbsent: @Sendable (Int32) -> Bool
    private let createRegistryFile: @Sendable (String, Data) -> Bool
    private let replaceRegistry: @Sendable (String, String) -> Int32
    private let syncDescriptor: @Sendable (Int32) -> Int32
    private let openRegistryFile: @Sendable (String) -> Int32
    private let openRegistryDirectory: @Sendable (String) -> Int32
    private let monotonicNow: @Sendable () -> UInt64
    private let maximumQuiescenceNanoseconds: UInt64
    private let registrationURL: URL?
    private let mutex = NSLock()
    private var groups: [CustodiedProcessGroup] = []

    init(
        registrationURL: URL? = nil,
        registeredGroups: [CustodiedProcessGroup] = [],
        verifyIdentity: @escaping IdentityVerifier,
        terminateGroup: @escaping GroupOperation,
        waitForGroup: GroupOperation?,
        identityStatus: IdentityStatusVerifier? = nil,
        waitForVerifiedGroup: (@Sendable (CustodiedProcessGroup) throws -> Void)? = nil,
        groupIsAbsent: @escaping @Sendable (Int32) -> Bool = { _ in true },
        createRegistryFile: @escaping @Sendable (String, Data) -> Bool = {
            FileManager.default.createFile(atPath: $0, contents: $1, attributes: [.posixPermissions: 0o600])
        },
        replaceRegistry: @escaping @Sendable (String, String) -> Int32 = { rename($0, $1) },
        syncDescriptor: @escaping @Sendable (Int32) -> Int32 = { fsync($0) },
        openRegistryFile: @escaping @Sendable (String) -> Int32 = { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) },
        openRegistryDirectory: @escaping @Sendable (String) -> Int32 = { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) },
        monotonicNow: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        maximumQuiescenceNanoseconds: UInt64 = 15_000_000_000
    ) {
        self.registrationURL = registrationURL
        groups = registeredGroups
        self.verifyIdentity = verifyIdentity
        self.identityStatus = identityStatus ?? { verifyIdentity($0) ? .matching : .mismatched }
        self.terminateGroup = terminateGroup
        if let waitForVerifiedGroup {
            self.waitForVerifiedGroup = waitForVerifiedGroup
        } else {
            self.waitForVerifiedGroup = { group in try waitForGroup?(group.processGroupID) }
        }
        self.groupIsAbsent = groupIsAbsent
        self.createRegistryFile = createRegistryFile
        self.replaceRegistry = replaceRegistry
        self.syncDescriptor = syncDescriptor
        self.openRegistryFile = openRegistryFile
        self.openRegistryDirectory = openRegistryDirectory
        self.monotonicNow = monotonicNow
        self.maximumQuiescenceNanoseconds = maximumQuiescenceNanoseconds
    }

    static func system(
        registrationURL: URL,
        verifyIdentity: IdentityVerifier? = nil,
        identityStatus: IdentityStatusVerifier? = nil,
        signal: @escaping @Sendable (Int32, Int32) -> Int32 = { kill($0, $1) },
        sleep: @escaping @Sendable (useconds_t) -> Void = { usleep($0) }
    ) throws -> ProcessCustody {
        let status: IdentityStatusVerifier
        if let identityStatus {
            status = identityStatus
        } else if let verifyIdentity {
            status = { verifyIdentity($0) ? .matching : .mismatched }
        } else {
            status = { SystemProcessIdentity.status(of: $0) }
        }
        let registered =
            FileManager.default.fileExists(atPath: registrationURL.path)
            ? try readRegisteredGroups(from: registrationURL) : []
        return ProcessCustody(
            registrationURL: registrationURL,
            registeredGroups: registered,
            verifyIdentity: { status($0) == .matching },
            terminateGroup: { processGroupID in
                guard signal(-processGroupID, SIGTERM) == 0 || errno == ESRCH else {
                    throw PreparedCacheError.unverifiableProcessIdentity
                }
            },
            waitForGroup: nil,
            identityStatus: status,
            waitForVerifiedGroup: { group in
                let processGroupID = group.processGroupID
                for _ in 0 ..< 50 {
                    switch status(group) {
                    case .absent: return
                    case .mismatched: throw PreparedCacheError.unverifiableProcessIdentity
                    case .matching: break
                    }
                    guard signal(-processGroupID, 0) == 0 else {
                        if errno == ESRCH { return }
                        throw PreparedCacheError.unverifiableProcessIdentity
                    }
                    sleep(100_000)
                }
                switch status(group) {
                case .absent:
                    return
                case .mismatched:
                    throw PreparedCacheError.unverifiableProcessIdentity
                case .matching:
                    guard signal(-processGroupID, SIGKILL) == 0 else {
                        throw PreparedCacheError.unverifiableProcessIdentity
                    }
                }
            },
            groupIsAbsent: { processGroupID in
                for _ in 0 ..< 50 {
                    let result = signal(-processGroupID, 0)
                    if result == -1, errno == ESRCH { return true }
                    sleep(100_000)
                }
                return false
            }
        )
    }

    var isQuiescent: Bool {
        mutex.withLock { groups.isEmpty }
    }

    func register(_ group: CustodiedProcessGroup) throws {
        try mutex.withLock {
            guard groups.count < Self.maximumTrackedProcessGroups else {
                throw PreparedCacheError.tooManyProcessGroups
            }
            guard group.pid > 0, group.processGroupID > 0, !group.birthIdentity.isEmpty else {
                throw PreparedCacheError.unverifiableProcessIdentity
            }
            guard
                !groups.contains(where: {
                    $0.pid == group.pid || $0.processGroupID == group.processGroupID
                })
            else { throw PreparedCacheError.unverifiableProcessIdentity }
            groups.append(group)
            try persistRegistry()
        }
    }

    func unregister(pid: Int32) throws {
        let group = mutex.withLock { groups.first(where: { $0.pid == pid }) }
        if let group { try requireGroupAbsent(group) }
        try mutex.withLock {
            if let group { groups.removeAll { $0 == group } }
            try persistRegistry()
        }
    }

    func handleCustodyEOF() throws { try quiesce() }
    func handleEngineTermination() throws { try quiesce() }

    private func quiesce() throws {
        let snapshot = mutex.withLock { groups }
        let startedAt = monotonicNow()
        let (scaledBudget, budgetOverflowed) =
            maximumQuiescenceNanoseconds
            .multipliedReportingOverflow(by: UInt64(snapshot.count))
        guard !budgetOverflowed else { throw PreparedCacheError.unverifiableProcessIdentity }
        let quiescenceBudget = scaledBudget
        for group in snapshot {
            try requireWithinQuiescenceDeadline(startedAt, budget: quiescenceBudget)
            switch identityStatus(group) {
            case .absent:
                try requireGroupAbsent(group)
                try requireWithinQuiescenceDeadline(startedAt, budget: quiescenceBudget)
                continue
            case .mismatched: throw PreparedCacheError.unverifiableProcessIdentity
            case .matching: break
            }
            guard verifyIdentity(group) else { throw PreparedCacheError.unverifiableProcessIdentity }
            try terminateGroup(group.processGroupID)
            try requireWithinQuiescenceDeadline(startedAt, budget: quiescenceBudget)
            try waitForVerifiedGroup(group)
            try requireWithinQuiescenceDeadline(startedAt, budget: quiescenceBudget)
            try requireGroupAbsent(group)
            try requireWithinQuiescenceDeadline(startedAt, budget: quiescenceBudget)
        }
        let completed = Set(snapshot)
        try mutex.withLock {
            groups.removeAll { completed.contains($0) }
            try persistRegistry()
        }
    }

    private func requireWithinQuiescenceDeadline(_ startedAt: UInt64, budget: UInt64) throws {
        let current = monotonicNow()
        guard current >= startedAt, current - startedAt <= budget else {
            throw PreparedCacheError.unverifiableProcessIdentity
        }
    }

    private func requireGroupAbsent(_ group: CustodiedProcessGroup) throws {
        guard groupIsAbsent(group.processGroupID) else {
            throw PreparedCacheError.unverifiableProcessIdentity
        }
    }

    static func readRegisteredGroups(from url: URL) throws -> [CustodiedProcessGroup] {
        try CachePathGuard.validateRegularFile(url, containedIn: url.deletingLastPathComponent())
        let data = try Data(contentsOf: url)
        _ = try ExactJSON.arrayOfObjects(data, keys: ["pid", "processGroupID", "birthIdentity"])
        let groups = try JSONDecoder().decode([CustodiedProcessGroup].self, from: data)
        guard groups.count <= maximumTrackedProcessGroups,
            groups.allSatisfy({ $0.pid > 0 && $0.processGroupID > 0 && !$0.birthIdentity.isEmpty }),
            Set(groups.map(\.pid)).count == groups.count
        else { throw PreparedCacheError.invalidCacheState }
        return groups
    }

    private func persistRegistry() throws {
        guard let registrationURL else { return }
        try CachePathGuard.validateDirectory(
            registrationURL.deletingLastPathComponent(),
            containedIn: registrationURL.deletingLastPathComponent()
        )
        let temporary = registrationURL.deletingLastPathComponent()
            .appendingPathComponent(".process-custody.\(UUID().uuidString)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard createRegistryFile(temporary.path, try encoder.encode(groups)) else {
            throw PreparedCacheError.unsafeCachePath
        }
        do {
            try CachePathGuard.validateRegularFile(temporary, containedIn: registrationURL.deletingLastPathComponent())
            let temporaryDescriptor = openRegistryFile(temporary.path)
            guard temporaryDescriptor >= 0 else { throw PreparedCacheError.unsafeCachePath }
            let fileSync = syncDescriptor(temporaryDescriptor)
            let fileClose = close(temporaryDescriptor)
            guard fileSync == 0, fileClose == 0 else { throw PreparedCacheError.unsafeCachePath }
            if FileManager.default.fileExists(atPath: registrationURL.path) {
                try CachePathGuard.validateRegularFile(
                    registrationURL,
                    containedIn: registrationURL.deletingLastPathComponent()
                )
            }
            guard replaceRegistry(temporary.path, registrationURL.path) == 0 else {
                throw PreparedCacheError.unsafeCachePath
            }
            try CachePathGuard.validateRegularFile(
                registrationURL, containedIn: registrationURL.deletingLastPathComponent())
            let parentDescriptor = openRegistryDirectory(registrationURL.deletingLastPathComponent().path)
            guard parentDescriptor >= 0 else { throw PreparedCacheError.unsafeCachePath }
            let parentSync = syncDescriptor(parentDescriptor)
            let parentClose = close(parentDescriptor)
            guard parentSync == 0, parentClose == 0 else { throw PreparedCacheError.unsafeCachePath }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

enum SystemProcessIdentity {
    static func group(for pid: Int32, getGroup: (Int32) -> Int32 = { getpgid($0) }) throws -> CustodiedProcessGroup {
        guard let birth = birthIdentity(pid: pid) else {
            throw PreparedCacheError.unverifiableProcessIdentity
        }
        let group = getGroup(pid)
        guard group > 0 else { throw PreparedCacheError.unverifiableProcessIdentity }
        return CustodiedProcessGroup(pid: pid, processGroupID: group, birthIdentity: birth)
    }

    static func matchesOrIsAbsent(_ group: CustodiedProcessGroup) -> Bool {
        status(of: group) != .mismatched
    }

    static func status(of group: CustodiedProcessGroup) -> ProcessIdentityStatus {
        status(of: group, birthIdentity: birthIdentity, getGroup: getpgid)
    }

    static func status(
        of group: CustodiedProcessGroup,
        birthIdentity: (Int32) -> String?,
        getGroup: (Int32) -> Int32
    ) -> ProcessIdentityStatus {
        guard let current = birthIdentity(group.pid) else {
            return errno == ESRCH ? .absent : .mismatched
        }
        guard current == group.birthIdentity else { return .mismatched }
        let currentGroup = getGroup(group.pid)
        if currentGroup == group.processGroupID { return .matching }
        return currentGroup == -1 && errno == ESRCH ? .absent : .mismatched
    }

    private static func birthIdentity(pid: Int32) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, 4, &info, &size, nil, 0)
        }
        guard result == 0, size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else {
            if result == 0 { errno = ESRCH }
            return nil
        }
        return "\(info.kp_proc.p_starttime.tv_sec):\(info.kp_proc.p_starttime.tv_usec)"
    }
}

final class CustodyFDMonitor: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let mutex = NSLock()
    private var failure: (any Error)?

    init(
        descriptor: Int,
        custody: ProcessCustody,
        duplicateDescriptor: (Int32) -> Int32 = { fcntl($0, F_DUPFD_CLOEXEC, 0) },
        readDescriptor: @escaping @Sendable (Int32, UnsafeMutableRawPointer?, Int) -> Int = {
            Darwin.read($0, $1, $2)
        }
    ) throws {
        let ownedDescriptor = duplicateDescriptor(Int32(descriptor))
        guard ownedDescriptor >= 0 else { throw PreparedCacheError.unverifiableProcessIdentity }
        source = DispatchSource.makeReadSource(
            fileDescriptor: ownedDescriptor,
            queue: DispatchQueue(label: "swift-mutation-testing.custody-fd")
        )
        source.setEventHandler { [weak self, source] in
            var byte: UInt8 = 0
            let count = readDescriptor(ownedDescriptor, &byte, 1)
            if count < 0 {
                if errno == EINTR { return }
                self?.mutex.withLock { self?.failure = PreparedCacheError.unverifiableProcessIdentity }
                source.cancel()
                return
            }
            guard count == 0 else { return }
            do {
                try custody.handleCustodyEOF()
            } catch {
                self?.mutex.withLock { self?.failure = error }
            }
            source.cancel()
        }
        source.setCancelHandler { close(ownedDescriptor) }
        source.resume()
    }

    func checkFailure() throws {
        if let failure = mutex.withLock({ failure }) { throw failure }
    }

    func cancel() { source.cancel() }

    deinit { source.cancel() }
}
