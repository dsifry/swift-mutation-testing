import Darwin
import Foundation

struct CacheRetentionPolicy: Sendable {
    var maximumIdentityCount: Int = 2
    var maximumTotalBytes: Int64 = 20 * 1024 * 1024 * 1024
    var maximumInactiveAge: TimeInterval = 7 * 86_400
}

struct CacheRetention: Sendable {
    private struct Candidate {
        let url: URL
        let bytes: Int64
        let lastUsed: Date
    }

    let collectionRoot: URL
    var policy = CacheRetentionPolicy()
    var makeEnumerator: @Sendable (URL) -> FileManager.DirectoryEnumerator? = {
        FileManager.default.enumerator(at: $0, includingPropertiesForKeys: nil)
    }
    var beforeRemovalAttempt: @Sendable (URL) throws -> Void = { _ in }
    var metadataProvider: @Sendable (URL) -> stat? = { CachePathGuard.metadata(at: $0) }

    func enforce(now: Date = Date()) throws -> [URL] {
        try CachePathGuard.validateDirectory(collectionRoot, containedIn: collectionRoot)
        var candidates = try loadCandidates().sorted { left, right in
            if left.lastUsed != right.lastUsed { return left.lastUsed < right.lastUsed }
            return left.url.lastPathComponent < right.url.lastPathComponent
        }
        var removed: [URL] = []

        for candidate in candidates where now.timeIntervalSince(candidate.lastUsed) > policy.maximumInactiveAge {
            do {
                try remove(candidate)
            } catch PreparedCacheError.lockBusy {
                throw PreparedCacheError.retentionUnsatisfied
            }
            removed.append(candidate.url)
        }
        let removedSet = Set(removed)
        candidates.removeAll { removedSet.contains($0.url) }

        while candidates.count > policy.maximumIdentityCount
            || candidates.reduce(Int64(0), { $0 + $1.bytes }) > policy.maximumTotalBytes {
            var removedCandidate = false
            for (index, candidate) in candidates.enumerated() {
                do {
                    try remove(candidate)
                    candidates.remove(at: index)
                    removed.append(candidate.url)
                    removedCandidate = true
                    break
                } catch PreparedCacheError.lockBusy {
                    continue
                }
            }
            guard removedCandidate else { throw PreparedCacheError.retentionUnsatisfied }
        }
        return removed
    }

    private func loadCandidates() throws -> [Candidate] {
        let manager = FileManager.default
        return try manager.contentsOfDirectory(
            at: collectionRoot,
            includingPropertiesForKeys: nil,
            options: []
        ).compactMap { url in
            guard Self.isCompatibilityID(url.lastPathComponent) else { return nil }
            try CachePathGuard.validateDirectory(url, containedIn: collectionRoot)
            let lastUsed = try CacheRecovery(identityDirectory: url, collectionRoot: collectionRoot).retentionLastUsedAt()
            return Candidate(url: url, bytes: try derivedDataBytes(at: url), lastUsed: lastUsed)
        }
    }

    private func derivedDataBytes(at identity: URL) throws -> Int64 {
        let root = identity.appendingPathComponent("DerivedData")
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        try CachePathGuard.validateNoSymlinkComponents(root, containedIn: identity)
        guard let rootMetadata = metadataProvider(root), rootMetadata.st_uid == getuid(),
            rootMetadata.st_mode & S_IFMT == S_IFDIR
        else { throw PreparedCacheError.unsafeCachePath }
        try CachePathGuard.validateOwnedTree(root, containedIn: identity)
        var total: Int64 = 0
        guard let enumerator = makeEnumerator(root) else {
            throw PreparedCacheError.unsafeCachePath
        }
        for case let url as URL in enumerator {
            guard let metadata = metadataProvider(url),
                metadata.st_uid == getuid(),
                metadata.st_mode & S_IFMT != S_IFLNK
            else { throw PreparedCacheError.unsafeCachePath }
            if metadata.st_mode & S_IFMT == S_IFREG { total += Int64(metadata.st_size) }
        }
        return total
    }

    private func remove(_ candidate: Candidate) throws {
        try beforeRemovalAttempt(candidate.url)
        let lock: CacheLock
        do {
            lock = try CacheLock(identityDirectory: candidate.url)
        } catch PreparedCacheError.lockBusy {
            throw PreparedCacheError.lockBusy
        }
        defer { try? lock.release() }
        try CachePathGuard.validateDirectory(candidate.url, containedIn: collectionRoot)
        _ = try CacheRecovery(identityDirectory: candidate.url, collectionRoot: collectionRoot).retentionLastUsedAt()
        try CachePathGuard.validateOwnedTree(candidate.url, containedIn: collectionRoot)
        try FileManager.default.removeItem(at: candidate.url)
    }

    private static func isCompatibilityID(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
