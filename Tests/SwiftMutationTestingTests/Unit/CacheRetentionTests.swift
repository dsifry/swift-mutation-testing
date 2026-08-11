import Darwin
import Foundation
import Testing

@testable import SwiftMutationTesting

@Suite("Prepared cache retention", .serialized)
struct CacheRetentionTests {
    @Test("LRU removes the oldest identity until count and bytes are satisfied")
    func lruCountAndBytes() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let oldest = try fixture.identity("a", bytes: 70, lastUsed: now.addingTimeInterval(-300))
        let middle = try fixture.identity("b", bytes: 60, lastUsed: now.addingTimeInterval(-200))
        let newest = try fixture.identity("c", bytes: 50, lastUsed: now.addingTimeInterval(-100))
        let retention = CacheRetention(
            collectionRoot: fixture.root,
            policy: .init(maximumIdentityCount: 2, maximumTotalBytes: 110, maximumInactiveAge: 1_000)
        )

        let removed = try retention.enforce(now: now)
        #expect(removed.map(\.lastPathComponent) == [oldest.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: oldest.path))
        #expect(FileManager.default.fileExists(atPath: middle.path))
        #expect(FileManager.default.fileExists(atPath: newest.path))
    }

    @Test("Seven-day expiry removes only inactive unlocked identities")
    func inactivityExpiry() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let expired = try fixture.identity("d", bytes: 1, lastUsed: now.addingTimeInterval(-(7 * 86_400 + 1)))
        let active = try fixture.identity("e", bytes: 1, lastUsed: now.addingTimeInterval(-(7 * 86_400)))
        let retention = CacheRetention(collectionRoot: fixture.root)

        let removed = try retention.enforce(now: now)
        #expect(removed.map(\.lastPathComponent) == [expired.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: active.path))
    }

    @Test("A live identity lock makes otherwise required retention fail closed")
    func liveLockUnsatisfied() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 3_000_000)
        let first = try fixture.identity("d", bytes: 60, lastUsed: now.addingTimeInterval(-200))
        let second = try fixture.identity("e", bytes: 60, lastUsed: now.addingTimeInterval(-100))
        let firstLock = try CacheLock(identityDirectory: first)
        let secondLock = try CacheLock(identityDirectory: second)
        defer {
            try? firstLock.release()
            try? secondLock.release()
        }
        let retention = CacheRetention(
            collectionRoot: fixture.root,
            policy: .init(maximumIdentityCount: 2, maximumTotalBytes: 100, maximumInactiveAge: 1_000)
        )

        #expect(throws: PreparedCacheError.retentionUnsatisfied) {
            try retention.enforce(now: now)
        }
    }

    @Test("An unsafe candidate is never deleted")
    func unsafeCandidateFailsClosed() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 4_000_000)
        let identity = try fixture.identity("f", bytes: 1, lastUsed: now.addingTimeInterval(-1_000))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: identity.path)
        let retention = CacheRetention(
            collectionRoot: fixture.root,
            policy: .init(maximumIdentityCount: 0, maximumTotalBytes: 0, maximumInactiveAge: 1)
        )

        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try retention.enforce(now: now)
        }
        #expect(FileManager.default.fileExists(atPath: identity.path))
    }

    @Test("Retention locks and revalidates a victim immediately before deletion")
    func victimAcquiredAfterEnumerationIsPreserved() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 4_500_000)
        let identity = try fixture.identity("f", bytes: 1, lastUsed: now.addingTimeInterval(-1_000))
        let lockBox = RetentionLockBox()
        let retention = CacheRetention(
            collectionRoot: fixture.root,
            policy: .init(maximumIdentityCount: 0, maximumTotalBytes: 0, maximumInactiveAge: 1),
            beforeRemovalAttempt: { url in lockBox.lock = try CacheLock(identityDirectory: url) }
        )

        #expect(throws: PreparedCacheError.retentionUnsatisfied) { try retention.enforce(now: now) }
        #expect(FileManager.default.fileExists(atPath: identity.path))
        try lockBox.lock?.release()
    }

    @Test("Retention tombstones a locked victim and never deletes its replacement")
    func lockedVictimUsesTombstoneRename() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 4_600_000)
        let victim = try fixture.identity("f", bytes: 1, lastUsed: now.addingTimeInterval(-1_000))
        let observation = TombstoneObservation()
        let retention = CacheRetention(
            collectionRoot: fixture.root,
            policy: .init(maximumIdentityCount: 0, maximumTotalBytes: 0, maximumInactiveAge: 1),
            beforeTombstoneRemoval: { tombstone in
                observation.url = tombstone
                #expect(!FileManager.default.fileExists(atPath: victim.path))
                observation.replacement = try fixture.identity(
                    "f", bytes: 2, lastUsed: now
                )
            }
        )

        let removed = try retention.enforce(now: now)
        #expect(removed.count == 1)
        #expect(removed.first?.path == victim.path)
        let tombstone = try #require(observation.url)
        #expect(tombstone.lastPathComponent.hasPrefix(".evicting-"))
        #expect(!FileManager.default.fileExists(atPath: tombstone.path))
        #expect(FileManager.default.fileExists(atPath: try #require(observation.replacement).path))
    }

    @Test("Retention resumes an abandoned tombstone after a crash")
    func abandonedTombstoneIsRecovered() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 4_700_000)
        let victim = try fixture.identity("f", bytes: 1, lastUsed: now.addingTimeInterval(-1_000))
        let tombstone = fixture.root.appendingPathComponent(
            ".evicting-\(victim.lastPathComponent)-00000000-0000-0000-0000-000000000000"
        )
        try FileManager.default.moveItem(at: victim, to: tombstone)

        _ = try CacheRetention(collectionRoot: fixture.root).enforce(now: now)

        #expect(!FileManager.default.fileExists(atPath: tombstone.path))
    }

    @Test("Retention fails closed for rename, tombstone-lock, and durability failures")
    func retentionFailureBranches() throws {
        let now = Date(timeIntervalSince1970: 4_800_000)
        func configured(_ fixture: RetentionFixture) throws -> CacheRetention {
            _ = try fixture.identity("f", bytes: 1, lastUsed: now.addingTimeInterval(-1_000))
            return CacheRetention(
                collectionRoot: fixture.root,
                policy: .init(maximumIdentityCount: 0, maximumTotalBytes: 0, maximumInactiveAge: 1)
            )
        }

        let renameFixture = try RetentionFixture()
        defer { renameFixture.cleanup() }
        var renameFailure = try configured(renameFixture)
        renameFailure.renameIdentity = { _, _ in -1 }
        #expect(throws: PreparedCacheError.unsafeCachePath) { try renameFailure.enforce(now: now) }

        let openFixture = try RetentionFixture()
        defer { openFixture.cleanup() }
        var openFailure = try configured(openFixture)
        openFailure.openCollectionDirectory = { _ in -1 }
        #expect(throws: PreparedCacheError.unsafeCachePath) { try openFailure.enforce(now: now) }

        let syncFixture = try RetentionFixture()
        defer { syncFixture.cleanup() }
        var syncFailure = try configured(syncFixture)
        syncFailure.openCollectionDirectory = { _ in 101 }
        syncFailure.syncCollectionDescriptor = { _ in -1 }
        syncFailure.closeCollectionDescriptor = { _ in 0 }
        #expect(throws: PreparedCacheError.unsafeCachePath) { try syncFailure.enforce(now: now) }

        let tombstoneFixture = try RetentionFixture()
        defer { tombstoneFixture.cleanup() }
        let identity = try tombstoneFixture.identity("f", bytes: 1, lastUsed: now)
        let tombstone = tombstoneFixture.root.appendingPathComponent(
            ".evicting-\(identity.lastPathComponent)-00000000-0000-0000-0000-000000000000"
        )
        try FileManager.default.moveItem(at: identity, to: tombstone)
        let tombstoneLock = try CacheLock(identityDirectory: tombstone)
        defer { try? tombstoneLock.release() }
        let ignored = tombstoneFixture.root.appendingPathComponent(".evicting-short")
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: false)
        chmod(ignored.path, 0o700)
        _ = try CacheRetention(collectionRoot: tombstoneFixture.root).enforce(now: now)
        #expect(FileManager.default.fileExists(atPath: tombstone.path))
        #expect(FileManager.default.fileExists(atPath: ignored.path))
    }

    @Test("Retention tie breaking, expired locks, and product symlinks fail deterministically")
    func retentionBranchTable() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 5_000_000)
        let laterName = try fixture.identity("b", bytes: 1, lastUsed: now.addingTimeInterval(-10))
        let earlierName = try fixture.identity("a", bytes: 1, lastUsed: now.addingTimeInterval(-10))
        let removed = try CacheRetention(
            collectionRoot: fixture.root,
            policy: .init(maximumIdentityCount: 1, maximumTotalBytes: 10, maximumInactiveAge: 100)
        ).enforce(now: now)
        #expect(removed.map(\.lastPathComponent) == [earlierName.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: laterName.path))

        let locked = try fixture.identity("c", bytes: 1, lastUsed: now.addingTimeInterval(-101))
        let liveLock = try CacheLock(identityDirectory: locked)
        #expect(throws: PreparedCacheError.retentionUnsatisfied) {
            try CacheRetention(
                collectionRoot: fixture.root,
                policy: .init(
                    maximumIdentityCount: 10, maximumTotalBytes: 10, maximumInactiveAge: 100
                )
            ).enforce(now: now)
        }
        try liveLock.release()

        let outside = fixture.root.appendingPathComponent("outside")
        try Data("x".utf8).write(to: outside)
        let link = laterName.appendingPathComponent("DerivedData/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheRetention(collectionRoot: fixture.root).enforce(now: now)
        }
        try FileManager.default.removeItem(at: link)
        let payload = laterName.appendingPathComponent("DerivedData/payload")
        let hardlink = laterName.appendingPathComponent("DerivedData/payload-hardlink")
        #expect(linkat(AT_FDCWD, payload.path, AT_FDCWD, hardlink.path, 0) == 0)
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheRetention(collectionRoot: fixture.root).enforce(now: now)
        }
        try FileManager.default.removeItem(at: hardlink)
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheRetention(
                collectionRoot: fixture.root,
                metadataProvider: { url in
                    url.lastPathComponent == "DerivedData" ? nil : CachePathGuard.metadata(at: url)
                }
            ).enforce(now: now)
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheRetention(
                collectionRoot: fixture.root,
                metadataProvider: { url in
                    url.lastPathComponent == "payload" ? nil : CachePathGuard.metadata(at: url)
                }
            ).enforce(now: now)
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheRetention(
                collectionRoot: fixture.root,
                makeEnumerator: { _ in nil }
            ).enforce(now: now)
        }
        let enumerationCount = RetentionCounter()
        _ = try CacheRetention(
            collectionRoot: fixture.root,
            makeEnumerator: { root in
                enumerationCount.increment()
                return FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            }
        ).enforce(now: now)
        #expect(enumerationCount.value == 2)
    }
}

private final class RetentionLockBox: @unchecked Sendable {
    var lock: CacheLock?
}

private final class TombstoneObservation: @unchecked Sendable {
    var url: URL?
    var replacement: URL?
}

private final class RetentionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private struct RetentionFixture {
    let root: URL

    init() throws {
        root = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, 0o700)
    }

    func identity(
        _ character: Character,
        bytes: Int,
        lastUsed: Date
    ) throws -> URL {
        let url = root.appendingPathComponent(String(repeating: String(character), count: 64))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        chmod(url.path, 0o700)
        let payload = url.appendingPathComponent("DerivedData/payload")
        try FileManager.default.createDirectory(
            at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5a, count: bytes).write(to: payload)
        try CacheRecovery(identityDirectory: url, collectionRoot: root).writeRetentionMetadata(lastUsedAt: lastUsed)
        return url
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
