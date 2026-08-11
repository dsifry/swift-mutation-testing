import Darwin
import Foundation
import Testing

@testable import SwiftMutationTesting

@Suite("Prepared cache retention", .serialized)
struct CacheRetentionTests {
    @Test("Prepared cache digests accept only lowercase ASCII hexadecimal")
    func digestAlphabetIsASCII() {
        #expect(CachePathGuard.isLowercaseHexDigest(String(repeating: "f", count: 64)))
        #expect(!CachePathGuard.isLowercaseHexDigest(String(repeating: "ｆ", count: 64)))
    }

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

    @Test("Retention never evicts an identity whose custody is ineligible")
    func liveCustodyUnsatisfied() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 3_500_000)
        let victim = try fixture.identity("f", bytes: 1, lastUsed: now.addingTimeInterval(-1_000))
        let registry = victim.appendingPathComponent("process-custody.json")
        let group = CustodiedProcessGroup(pid: 71, processGroupID: 71, birthIdentity: "birth-71")
        let writer = ProcessCustody(
            registrationURL: registry,
            verifyIdentity: { _ in true },
            terminateGroup: { _ in },
            waitForGroup: nil
        )
        try writer.register(group)
        let retention = CacheRetention(
            collectionRoot: fixture.root,
            policy: .init(maximumIdentityCount: 0, maximumTotalBytes: 0, maximumInactiveAge: 1),
            requireCustodyEligible: { _ in throw PreparedCacheError.lockBusy }
        )

        #expect(throws: PreparedCacheError.retentionUnsatisfied) {
            try retention.enforce(now: now)
        }
        #expect(FileManager.default.fileExists(atPath: victim.path))
        let preserved = try ProcessCustody.system(
            registrationURL: registry,
            identityStatus: { _ in .matching },
            signal: { _, _ in 0 },
            sleep: { _ in }
        )
        #expect(!preserved.isQuiescent)
    }

    @Test("Retention allows an exact empty custody registry")
    func emptyCustodyAllowsEviction() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 3_600_000)
        let victim = try fixture.identity("f", bytes: 1, lastUsed: now.addingTimeInterval(-1_000))
        let registry = victim.appendingPathComponent("process-custody.json")
        try Data("[]".utf8).write(to: registry)
        chmod(registry.path, 0o600)

        let removed = try CacheRetention(
            collectionRoot: fixture.root,
            policy: .init(maximumIdentityCount: 0, maximumTotalBytes: 0, maximumInactiveAge: 1)
        ).enforce(now: now)

        #expect(removed.map(\.path) == [victim.path])
        #expect(!FileManager.default.fileExists(atPath: victim.path))
    }

    @Test("Any nonempty victim custody makes that identity ineligible without signalling")
    func nonemptyCustodyMakesVictimIneligible() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 3_650_000)
        let victim = try fixture.identity("f", bytes: 1, lastUsed: now.addingTimeInterval(-1_000))
        let registry = victim.appendingPathComponent("process-custody.json")
        let group = CustodiedProcessGroup(
            pid: Int32.max, processGroupID: Int32.max, birthIdentity: "recorded-child")
        try ProcessCustody(
            registrationURL: registry,
            verifyIdentity: { _ in true },
            terminateGroup: { _ in },
            waitForGroup: nil
        ).register(group)

        #expect(throws: PreparedCacheError.retentionUnsatisfied) {
            try CacheRetention(
                collectionRoot: fixture.root,
                policy: .init(maximumIdentityCount: 0, maximumTotalBytes: 0, maximumInactiveAge: 1)
            ).enforce(now: now)
        }
        #expect(FileManager.default.fileExists(atPath: victim.path))
        #expect(try ProcessCustody.readRegisteredGroups(from: registry) == [group])
    }

    @Test("Retention treats a dangling custody registry as present and preserves its victim")
    func danglingCustodyRegistryFailsClosed() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 3_700_000)
        let victim = try fixture.identity("f", bytes: 1, lastUsed: now.addingTimeInterval(-1_000))
        try FileManager.default.createSymbolicLink(
            at: victim.appendingPathComponent("process-custody.json"),
            withDestinationURL: fixture.root.appendingPathComponent("missing-registry")
        )
        #expect(
            try CacheDeleteTree.entryExists(
                victim.appendingPathComponent("process-custody.json"), containedIn: victim))

        #expect(throws: PreparedCacheError.retentionUnsatisfied) {
            try CacheRetention(
                collectionRoot: fixture.root,
                policy: .init(maximumIdentityCount: 0, maximumTotalBytes: 0, maximumInactiveAge: 1)
            ).enforce(now: now)
        }
        #expect(FileManager.default.fileExists(atPath: victim.path))
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

    @Test("Retention rejects a dangling DerivedData root instead of treating it as absent")
    func danglingDerivedDataRootFailsClosed() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let identity = try fixture.identity("f", bytes: 1, lastUsed: Date())
        let derivedData = identity.appendingPathComponent("DerivedData")
        try FileManager.default.removeItem(at: derivedData)
        try FileManager.default.createSymbolicLink(
            at: derivedData,
            withDestinationURL: fixture.root.appendingPathComponent("missing-target")
        )

        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheRetention(collectionRoot: fixture.root).enforce(now: Date())
        }
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

    @Test("Retention rejects a victim replacement inside the rename boundary")
    func preRenameReplacementFailsClosed() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 4_625_000)
        let victim = try fixture.identity("f", bytes: 1, lastUsed: now.addingTimeInterval(-1_000))
        let saved = fixture.root.appendingPathComponent("saved-original")
        let retention = CacheRetention(
            collectionRoot: fixture.root,
            policy: .init(maximumIdentityCount: 0, maximumTotalBytes: 0, maximumInactiveAge: 1),
            renameIdentity: { source, destination in
                try! FileManager.default.moveItem(atPath: source, toPath: saved.path)
                _ = try! fixture.identity("f", bytes: 1, lastUsed: now)
                return rename(source, destination)
            })

        #expect(throws: PreparedCacheError.unsafeCachePath) { try retention.enforce(now: now) }
        #expect(FileManager.default.fileExists(atPath: saved.path))
    }

    @Test("Retention never deletes a directory substituted for its authenticated tombstone")
    func tombstoneReplacementFailsClosed() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 4_650_000)
        _ = try fixture.identity("f", bytes: 1, lastUsed: now.addingTimeInterval(-1_000))
        let observation = TombstoneObservation()
        let retention = CacheRetention(
            collectionRoot: fixture.root,
            policy: .init(maximumIdentityCount: 0, maximumTotalBytes: 0, maximumInactiveAge: 1),
            beforeTombstoneRemoval: { tombstone in
                observation.url = tombstone
                let original = fixture.root.appendingPathComponent("saved-tombstone")
                try FileManager.default.moveItem(at: tombstone, to: original)
                try FileManager.default.createDirectory(
                    at: tombstone, withIntermediateDirectories: false)
                chmod(tombstone.path, 0o700)
                observation.replacement = original
            }
        )

        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try retention.enforce(now: now)
        }
        #expect(FileManager.default.fileExists(atPath: try #require(observation.url).path))
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

    @Test("Abandoned tombstone live custody is never signalled or deleted")
    func abandonedTombstoneLiveCustodyIsPreserved() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let victim = try fixture.identity("f", bytes: 1, lastUsed: Date())
        let tombstone = fixture.root.appendingPathComponent(
            ".evicting-\(victim.lastPathComponent)-00000000-0000-0000-0000-000000000000"
        )
        try FileManager.default.moveItem(at: victim, to: tombstone)

        var attributes: posix_spawnattr_t?
        #expect(posix_spawnattr_init(&attributes) == 0)
        defer { posix_spawnattr_destroy(&attributes) }
        #expect(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0)
        #expect(posix_spawnattr_setpgroup(&attributes, 0) == 0)
        var pid: pid_t = 0
        let executable = strdup("/bin/sleep")!
        let duration = strdup("30")!
        var arguments: [UnsafeMutablePointer<CChar>?] = [executable, duration, nil]
        defer {
            free(executable)
            free(duration)
            if pid > 0 {
                _ = kill(pid, SIGKILL)
                _ = waitpid(pid, nil, 0)
            }
        }
        let spawnResult = arguments.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, "/bin/sleep", nil, &attributes, buffer.baseAddress!, environ)
        }
        #expect(spawnResult == 0)
        let group = try SystemProcessIdentity.group(for: pid)
        let registry = tombstone.appendingPathComponent("process-custody.json")
        try ProcessCustody.system(registrationURL: registry).register(group)
        #expect(throws: PreparedCacheError.retentionUnsatisfied) {
            try CacheRetention(collectionRoot: fixture.root).enforce(now: Date())
        }

        #expect(kill(-group.processGroupID, 0) == 0)
        #expect(SystemProcessIdentity.matchesOrIsAbsent(group))
        #expect(FileManager.default.fileExists(atPath: tombstone.path))
        #expect(try ProcessCustody.readRegisteredGroups(from: registry) == [group])
    }

    @Test("Unverifiable abandoned tombstone custody is preserved fail closed")
    func unverifiableAbandonedTombstoneCustodyIsPreserved() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let victim = try fixture.identity("f", bytes: 1, lastUsed: Date())
        let tombstone = fixture.root.appendingPathComponent(
            ".evicting-\(victim.lastPathComponent)-00000000-0000-0000-0000-000000000000"
        )
        try FileManager.default.moveItem(at: victim, to: tombstone)
        let registry = tombstone.appendingPathComponent("process-custody.json")
        let group = CustodiedProcessGroup(
            pid: getpid(), processGroupID: getpgrp(), birthIdentity: "wrong-birth-identity")
        try ProcessCustody(
            registrationURL: registry,
            verifyIdentity: { _ in true },
            terminateGroup: { _ in },
            waitForGroup: nil
        ).register(group)

        #expect(throws: PreparedCacheError.retentionUnsatisfied) {
            try CacheRetention(collectionRoot: fixture.root).enforce(now: Date())
        }

        #expect(FileManager.default.fileExists(atPath: tombstone.path))
        #expect(try ProcessCustody.readRegisteredGroups(from: registry) == [group])
    }

    @Test("Unresolved tombstones participate in count and byte limits")
    func unresolvedTombstonesParticipateInLimits() throws {
        let countFixture = try RetentionFixture()
        defer { countFixture.cleanup() }
        let countIdentity = try countFixture.identity("f", bytes: 1, lastUsed: Date())
        let countTombstone = countFixture.root.appendingPathComponent(
            ".evicting-\(countIdentity.lastPathComponent)-00000000-0000-0000-0000-000000000000"
        )
        try FileManager.default.moveItem(at: countIdentity, to: countTombstone)
        let countRegistry = countTombstone.appendingPathComponent("process-custody.json")
        try Data("not-json".utf8).write(to: countRegistry)
        chmod(countRegistry.path, 0o600)

        #expect(throws: PreparedCacheError.retentionUnsatisfied) {
            try CacheRetention(
                collectionRoot: countFixture.root,
                policy: .init(
                    maximumIdentityCount: 0, maximumTotalBytes: .max,
                    maximumInactiveAge: .greatestFiniteMagnitude)
            ).enforce()
        }
        #expect(FileManager.default.fileExists(atPath: countTombstone.path))

        let bytesFixture = try RetentionFixture()
        defer { bytesFixture.cleanup() }
        let bytesIdentity = try bytesFixture.identity("e", bytes: 1, lastUsed: Date())
        let bytesTombstone = bytesFixture.root.appendingPathComponent(
            ".evicting-\(bytesIdentity.lastPathComponent)-00000000-0000-0000-0000-000000000000"
        )
        try FileManager.default.moveItem(at: bytesIdentity, to: bytesTombstone)
        let bytesRegistry = bytesTombstone.appendingPathComponent("process-custody.json")
        try Data("not-json".utf8).write(to: bytesRegistry)
        chmod(bytesRegistry.path, 0o600)

        #expect(throws: PreparedCacheError.retentionUnsatisfied) {
            try CacheRetention(
                collectionRoot: bytesFixture.root,
                policy: .init(
                    maximumIdentityCount: 1, maximumTotalBytes: 0,
                    maximumInactiveAge: .greatestFiniteMagnitude)
            ).enforce()
        }
        #expect(FileManager.default.fileExists(atPath: bytesTombstone.path))
    }

    @Test("Retention unlinks package symlink leaves after tombstoning without following targets")
    func retentionUnlinksPackageSymlinkLeaves() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 4_725_000)
        let victim = try fixture.identity("f", bytes: 1, lastUsed: now.addingTimeInterval(-1_000))
        let external = fixture.root.appendingPathComponent("external-package")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let marker = external.appendingPathComponent("marker.swift")
        try Data("external bytes".utf8).write(to: marker)
        let links = victim.appendingPathComponent(
            "DerivedData/SourcePackages/checkouts/xctest-dynamic-overlay/Sources/IssueReporting/Symbolic Links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: links.appendingPathComponent("IssueReportingPackageSupport"),
            withDestinationURL: external
        )

        let removed = try CacheRetention(
            collectionRoot: fixture.root,
            policy: .init(maximumIdentityCount: 0, maximumTotalBytes: 0, maximumInactiveAge: 1)
        ).enforce(now: now)

        #expect(removed.map(\.path) == [victim.path])
        #expect(try String(contentsOf: marker, encoding: .utf8) == "external bytes")
    }

    @Test("An invalid abandoned tombstone blocks retention fail closed")
    func invalidAbandonedTombstoneFailsClosed() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 4_750_000)
        let invalidIdentity = try fixture.identity("f", bytes: 1, lastUsed: now)
        let invalidTombstone = fixture.root.appendingPathComponent(
            ".evicting-\(invalidIdentity.lastPathComponent)-00000000-0000-0000-0000-000000000000"
        )
        try FileManager.default.moveItem(at: invalidIdentity, to: invalidTombstone)
        let invalidDirectoryTombstone = fixture.root.appendingPathComponent(
            ".evicting-\(String(repeating: "d", count: 64))-00000000-0000-0000-0000-000000000000"
        )
        try FileManager.default.createSymbolicLink(
            at: invalidDirectoryTombstone, withDestinationURL: fixture.root)
        let payload = invalidTombstone.appendingPathComponent("DerivedData/payload")
        let alias = invalidTombstone.appendingPathComponent("DerivedData/payload-alias")
        #expect(linkat(AT_FDCWD, payload.path, AT_FDCWD, alias.path, 0) == 0)
        let validIdentity = try fixture.identity(
            "e", bytes: 1, lastUsed: now.addingTimeInterval(-1_000))

        #expect(throws: PreparedCacheError.retentionUnsatisfied) {
            try CacheRetention(
                collectionRoot: fixture.root,
                policy: .init(maximumIdentityCount: 0, maximumTotalBytes: 0, maximumInactiveAge: 1)
            ).enforce(now: now)
        }

        #expect(FileManager.default.fileExists(atPath: validIdentity.path))
        #expect(FileManager.default.fileExists(atPath: invalidTombstone.path))
        #expect(FileManager.default.fileExists(atPath: invalidDirectoryTombstone.path))
    }

    @Test("An unsafe abandoned tombstone root fails retention closed")
    func unsafeAbandonedTombstoneRootFailsClosed() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let tombstone = fixture.root.appendingPathComponent(
            ".evicting-\(String(repeating: "d", count: 64))-00000000-0000-0000-0000-000000000000"
        )
        try FileManager.default.createSymbolicLink(at: tombstone, withDestinationURL: fixture.root)

        #expect(throws: PreparedCacheError.retentionUnsatisfied) {
            try CacheRetention(collectionRoot: fixture.root).enforce()
        }
        #expect(try #require(CachePathGuard.metadata(at: tombstone)).st_mode & S_IFMT == S_IFLNK)
    }

    @Test("Retention rejects entries that disappear after directory validation")
    func metadataDisappearanceFailsClosed() throws {
        let candidateFixture = try RetentionFixture()
        defer { candidateFixture.cleanup() }
        let candidate = try candidateFixture.identity("a", bytes: 1, lastUsed: Date())
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheRetention(
                collectionRoot: candidateFixture.root,
                metadataOf: { url in url.path == candidate.path ? nil : CachePathGuard.metadata(at: url) }
            ).enforce()
        }

        let tombstoneFixture = try RetentionFixture()
        defer { tombstoneFixture.cleanup() }
        let identity = try tombstoneFixture.identity("b", bytes: 1, lastUsed: Date())
        let tombstone = tombstoneFixture.root.appendingPathComponent(
            ".evicting-\(identity.lastPathComponent)-00000000-0000-0000-0000-000000000000")
        try FileManager.default.moveItem(at: identity, to: tombstone)
        #expect(throws: PreparedCacheError.retentionUnsatisfied) {
            try CacheRetention(
                collectionRoot: tombstoneFixture.root,
                metadataOf: { url in url.path == tombstone.path ? nil : CachePathGuard.metadata(at: url) }
            ).enforce()
        }
    }

    @Test("Malformed tombstone prefixes make retention unsatisfied")
    func malformedTombstoneNameFailsClosed() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let malformed = fixture.root.appendingPathComponent(".evicting-not-an-identity")
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: false)
        chmod(malformed.path, 0o700)

        #expect(throws: PreparedCacheError.retentionUnsatisfied) {
            try CacheRetention(collectionRoot: fixture.root).enforce()
        }
        #expect(FileManager.default.fileExists(atPath: malformed.path))
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
        #expect(throws: PreparedCacheError.retentionUnsatisfied) {
            try CacheRetention(collectionRoot: tombstoneFixture.root).enforce(now: now)
        }
        #expect(FileManager.default.fileExists(atPath: tombstone.path))
    }

    @Test("Retention tie breaking, expired locks, safe symlink leaves, and hardlinks are deterministic")
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
        _ = try CacheRetention(collectionRoot: fixture.root).enforce(now: now)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "x")
        try FileManager.default.removeItem(at: link)
        let payload = laterName.appendingPathComponent("DerivedData/payload")
        let hardlink = laterName.appendingPathComponent("DerivedData/payload-hardlink")
        #expect(linkat(AT_FDCWD, payload.path, AT_FDCWD, hardlink.path, 0) == 0)
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheRetention(collectionRoot: fixture.root).enforce(now: now)
        }
        try FileManager.default.removeItem(at: hardlink)
        _ = try CacheRetention(collectionRoot: fixture.root).enforce(now: now)
    }

    @Test("Descriptor syscall adapters report failures without following paths")
    func descriptorSystemOperationFailures() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let directory = try fixture.identity("d", bytes: 1, lastUsed: Date())
        let file = directory.appendingPathComponent("retention.json")

        #expect(CacheDeleteTreeOperations.system.metadataAt(-1, "missing") == nil)
        #expect(CacheDeleteTreeOperations.system.metadataOf(-1) == nil)
        #expect(CacheDeleteTreeOperations.system.childNames(-1) == nil)
        #expect(CacheDeleteTreeOperations.system.openChild(-1, "missing") < 0)
        #expect(CacheDeleteTreeOperations.system.unlinkEntry(-1, "missing", 0) < 0)
        #expect(CacheDeleteTreeOperations.system.openParent("/definitely/missing") < 0)
        let regularDescriptor = open(file.path, O_RDONLY | O_CLOEXEC)
        #expect(regularDescriptor >= 0)
        #expect(CacheDeleteTreeOperations.system.childNames(regularDescriptor) == nil)
        _ = close(regularDescriptor)
        let fakeDirectory = UnsafeMutablePointer<DIR>(bitPattern: 1)!
        #expect(
            CacheDeleteTreeOperations.systemChildNames(
                descriptor: 1,
                duplicate: { $0 },
                openDirectory: { _ in fakeDirectory },
                readEntry: { _ in nil },
                readError: { EIO },
                closeDirectory: { _ in 0 }
            ) == nil
        )
        #expect(
            CacheDeleteTreeOperations.systemChildNames(
                descriptor: 1,
                duplicate: { $0 },
                openDirectory: { _ in fakeDirectory },
                readEntry: { _ in nil },
                readError: { 0 },
                closeDirectory: { _ in -1 }
            ) == nil
        )
    }

    @Test("Descriptor validation fails closed on missing metadata and child access")
    func descriptorValidationFailures() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let directory = try fixture.identity("d", bytes: 1, lastUsed: Date())
        let file = directory.appendingPathComponent("retention.json")

        var operations = CacheDeleteTreeOperations.system
        operations.openParent = { _ in -1 }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheDeleteTree.byteSize(directory, containedIn: fixture.root, operations: operations)
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheDeleteTree.byteSize(
                directory.appendingPathComponent("nested"),
                containedIn: fixture.root,
                operations: .system
            )
        }

        operations = .system
        operations.metadataAt = { _, _ in nil }
        operations.metadataAtError = { ENOENT }
        #expect(
            try CacheDeleteTree.entryExists(
                file, containedIn: directory, operations: operations) == false)
        operations.metadataAtError = { EIO }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheDeleteTree.entryExists(file, containedIn: directory, operations: operations)
        }

        operations = .system
        operations.metadataAt = { _, _ in nil }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheDeleteTree.removeRegularFile(
                file, containedIn: directory, operations: operations)
        }

        operations = .system
        let systemMetadataAt = operations.metadataAt
        var validationReads = 0
        operations.metadataAt = { descriptor, name in
            validationReads += 1
            return validationReads == 2 ? nil : systemMetadataAt(descriptor, name)
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheDeleteTree.validateForRemoval(
                directory, containedIn: fixture.root, operations: operations)
        }

        operations = .system
        validationReads = 0
        operations.metadataAt = { descriptor, name in
            validationReads += 1
            return validationReads == 2 ? nil : systemMetadataAt(descriptor, name)
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheDeleteTree.byteSize(
                directory, containedIn: fixture.root, operations: operations)
        }

        operations = .system
        operations.openChild = { _, _ in -1 }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheDeleteTree.byteSize(directory, containedIn: fixture.root, operations: operations)
        }

        operations = .system
        operations.metadataOf = { _ in nil }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheDeleteTree.byteSize(directory, containedIn: fixture.root, operations: operations)
        }

        operations = .system
        operations.childNames = { _ in nil }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheDeleteTree.byteSize(directory, containedIn: fixture.root, operations: operations)
        }
    }

    @Test("Descriptor deletion rejects unlink failures and entry replacement")
    func descriptorRemovalRaceFailures() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let directory = try fixture.identity("d", bytes: 1, lastUsed: Date())
        let file = directory.appendingPathComponent("retention.json")
        let emptyDirectory = fixture.root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: false)
        chmod(emptyDirectory.path, 0o700)

        var operations = CacheDeleteTreeOperations.system
        let systemMetadataAt = operations.metadataAt
        operations.unlinkEntry = { _, _, _ in -1 }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheDeleteTree.removeDirectory(
                emptyDirectory, containedIn: fixture.root, operations: operations)
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheDeleteTree.removeRegularFile(
                file, containedIn: directory, operations: operations)
        }

        operations = .system
        var directoryReads = 0
        operations.metadataAt = { descriptor, name in
            guard var metadata = systemMetadataAt(descriptor, name) else { return nil }
            directoryReads += 1
            if directoryReads == 3 { metadata.st_ino ^= 1 }
            return metadata
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheDeleteTree.removeDirectory(
                emptyDirectory, containedIn: fixture.root, operations: operations)
        }

        operations = .system
        directoryReads = 0
        operations.metadataAt = { descriptor, name in
            directoryReads += 1
            return directoryReads == 3 ? nil : systemMetadataAt(descriptor, name)
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheDeleteTree.removeDirectory(
                emptyDirectory, containedIn: fixture.root, operations: operations)
        }

        operations = .system
        var fileReads = 0
        operations.metadataAt = { descriptor, name in
            guard var metadata = systemMetadataAt(descriptor, name) else { return nil }
            fileReads += 1
            if fileReads == 3 { metadata.st_ino ^= 1 }
            return metadata
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheDeleteTree.removeRegularFile(
                file, containedIn: directory, operations: operations)
        }

        operations = .system
        fileReads = 0
        operations.metadataAt = { descriptor, name in
            fileReads += 1
            return fileReads == 3 ? nil : systemMetadataAt(descriptor, name)
        }
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try CacheDeleteTree.removeRegularFile(
                file, containedIn: directory, operations: operations)
        }
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
