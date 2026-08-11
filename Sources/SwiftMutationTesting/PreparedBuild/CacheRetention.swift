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
        let identity: CacheEntryIdentity
        let bytes: Int64
        let lastUsed: Date
    }

    let collectionRoot: URL
    var policy = CacheRetentionPolicy()
    var beforeRemovalAttempt: @Sendable (URL) throws -> Void = { _ in }
    var requireCustodyEligible: @Sendable (URL) throws -> Void = { identity in
        let registry = identity.appendingPathComponent("process-custody.json")
        guard try CacheDeleteTree.entryExists(registry, containedIn: identity) else { return }
        do {
            guard try ProcessCustody.readRegisteredGroups(from: registry).isEmpty else {
                throw PreparedCacheError.lockBusy
            }
        } catch {
            throw PreparedCacheError.lockBusy
        }
    }
    var beforeTombstoneRemoval: @Sendable (URL) throws -> Void = { _ in }
    var renameIdentity: @Sendable (String, String) -> Int32 = { rename($0, $1) }
    var openCollectionDirectory: @Sendable (String) -> Int32 = {
        open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    }
    var syncCollectionDescriptor: @Sendable (Int32) -> Int32 = { fsync($0) }
    var closeCollectionDescriptor: @Sendable (Int32) -> Int32 = { close($0) }
    var metadataOf: @Sendable (URL) -> stat? = { CachePathGuard.metadata(at: $0) }

    func enforce(now: Date = Date()) throws -> [URL] {
        try CachePathGuard.validateDirectory(collectionRoot, containedIn: collectionRoot)
        try removeAbandonedTombstones()
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
            || candidates.reduce(Int64(0), { $0 + $1.bytes }) > policy.maximumTotalBytes
        {
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
            guard let metadata = metadataOf(url) else {
                throw PreparedCacheError.unsafeCachePath
            }
            let lastUsed = try CacheRecovery(identityDirectory: url, collectionRoot: collectionRoot)
                .retentionLastUsedAt()
            return Candidate(
                url: url, identity: CacheEntryIdentity(metadata),
                bytes: try derivedDataBytes(at: url), lastUsed: lastUsed)
        }
    }

    private func derivedDataBytes(at identity: URL) throws -> Int64 {
        let root = identity.appendingPathComponent("DerivedData")
        guard try CacheDeleteTree.entryExists(root, containedIn: identity) else { return 0 }
        return try CacheDeleteTree.byteSize(root, containedIn: identity)
    }

    private func remove(_ candidate: Candidate) throws {
        try beforeRemovalAttempt(candidate.url)
        let lock: CacheLock
        do {
            lock = try CacheLock(
                identityDirectory: candidate.url,
                expectedDirectoryIdentity: candidate.identity)
        } catch PreparedCacheError.lockBusy {
            throw PreparedCacheError.lockBusy
        }
        defer { try? lock.release() }
        try CachePathGuard.validateDirectory(candidate.url, containedIn: collectionRoot)
        try requireCustodyEligible(candidate.url)
        _ = try CacheRecovery(identityDirectory: candidate.url, collectionRoot: collectionRoot).retentionLastUsedAt()
        _ = try CacheDeleteTree.validateForRemoval(candidate.url, containedIn: collectionRoot)
        try lock.validateDirectoryIdentity()
        let tombstone = collectionRoot.appendingPathComponent(
            ".evicting-\(candidate.url.lastPathComponent)-\(UUID().uuidString)"
        )
        guard renameIdentity(candidate.url.path, tombstone.path) == 0 else {
            throw PreparedCacheError.unsafeCachePath
        }
        try syncCollectionRoot()
        try CachePathGuard.validateDirectory(tombstone, containedIn: collectionRoot)
        let tombstoneIdentity = try CacheDeleteTree.validateForRemoval(
            tombstone, containedIn: collectionRoot)
        guard candidate.identity.matches(tombstoneIdentity) else {
            throw PreparedCacheError.unsafeCachePath
        }
        try beforeTombstoneRemoval(tombstone)
        try CacheDeleteTree.remove(
            tombstone, containedIn: collectionRoot, rejectHardlinks: true,
            expectedIdentity: tombstoneIdentity)
        try syncCollectionRoot()
    }

    private func removeAbandonedTombstones() throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: collectionRoot, includingPropertiesForKeys: nil
        )
        for tombstone in entries where tombstone.lastPathComponent.hasPrefix(".evicting-") {
            guard Self.isTombstoneName(tombstone.lastPathComponent) else {
                throw PreparedCacheError.retentionUnsatisfied
            }
            do {
                try CachePathGuard.validateDirectory(tombstone, containedIn: collectionRoot)
            } catch {
                throw PreparedCacheError.retentionUnsatisfied
            }
            guard let metadata = metadataOf(tombstone) else {
                throw PreparedCacheError.retentionUnsatisfied
            }
            let lock: CacheLock
            do {
                lock = try CacheLock(
                    identityDirectory: tombstone,
                    expectedDirectoryIdentity: CacheEntryIdentity(metadata))
            } catch PreparedCacheError.lockBusy {
                throw PreparedCacheError.retentionUnsatisfied
            }
            defer { try? lock.release() }
            do {
                try requireCustodyEligible(tombstone)
            } catch {
                _ = try CacheDeleteTree.byteSize(tombstone, containedIn: collectionRoot)
                throw PreparedCacheError.retentionUnsatisfied
            }
            do {
                let tombstoneIdentity = try CacheDeleteTree.validateForRemoval(
                    tombstone, containedIn: collectionRoot)
                try CacheDeleteTree.remove(
                    tombstone, containedIn: collectionRoot, rejectHardlinks: true,
                    expectedIdentity: tombstoneIdentity)
            } catch {
                throw PreparedCacheError.retentionUnsatisfied
            }
            try syncCollectionRoot()
        }
    }

    private func syncCollectionRoot() throws {
        let descriptor = openCollectionDirectory(collectionRoot.path)
        guard descriptor >= 0 else { throw PreparedCacheError.unsafeCachePath }
        let syncResult = syncCollectionDescriptor(descriptor)
        let closeResult = closeCollectionDescriptor(descriptor)
        guard syncResult == 0, closeResult == 0 else { throw PreparedCacheError.unsafeCachePath }
    }

    private static func isCompatibilityID(_ value: String) -> Bool {
        CachePathGuard.isLowercaseHexDigest(value)
    }

    private static func isTombstoneName(_ value: String) -> Bool {
        let prefix = ".evicting-"
        let suffix = String(value.dropFirst(prefix.count))
        guard suffix.count == 64 + 1 + 36 else { return false }
        let separator = suffix.index(suffix.startIndex, offsetBy: 64)
        let compatibilityID = String(suffix[..<separator])
        let uuid = String(suffix[suffix.index(after: separator)...])
        return suffix[separator] == "-" && isCompatibilityID(compatibilityID) && UUID(uuidString: uuid) != nil
    }
}
