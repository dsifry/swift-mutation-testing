import CryptoKit
import Darwin
import Foundation

enum RetainedProductManifest {
    private struct Entry: Codable {
        let path: String
        let mode: UInt16
        let byteSize: Int64
        let sha256: String
    }

    static func sha256(
        derivedDataURL: URL,
        metadataProvider: (URL) -> stat? = { metadata(at: $0) },
        makeEnumerator: (URL) -> FileManager.DirectoryEnumerator? = {
            FileManager.default.enumerator(at: $0, includingPropertiesForKeys: nil)
        }
    ) throws -> String {
        let products = derivedDataURL.appendingPathComponent("Build/Products", isDirectory: true)
        do {
            try CachePathGuard.validateNoSymlinkComponents(products, containedIn: derivedDataURL)
        } catch {
            throw PreparedCacheError.productManifestMismatch
        }
        guard CachePathGuard.isContained(products, in: derivedDataURL), let root = metadataProvider(products),
            root.st_uid == getuid(), root.st_mode & S_IFMT == S_IFDIR
        else { throw PreparedCacheError.productManifestMismatch }
        guard let enumerator = makeEnumerator(products) else {
            throw PreparedCacheError.productManifestMismatch
        }
        var entries: [Entry] = []
        for case let url as URL in enumerator {
            guard CachePathGuard.isContained(url, in: products), let value = metadataProvider(url),
                value.st_uid == getuid(), value.st_mode & S_IFMT != S_IFLNK
            else { throw PreparedCacheError.productManifestMismatch }
            guard value.st_mode & S_IFMT == S_IFREG else { continue }
            guard value.st_nlink == 1 else { throw PreparedCacheError.productManifestMismatch }
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            let relative = String(url.standardizedFileURL.path.dropFirst(products.standardizedFileURL.path.count + 1))
            entries.append(
                Entry(
                    path: relative,
                    mode: UInt16(value.st_mode & 0o777),
                    byteSize: Int64(bytes.count),
                    sha256: ProjectInputManifest.sha256(bytes)
                ))
        }
        guard !entries.isEmpty else { throw PreparedCacheError.productManifestMismatch }
        entries.sort { $0.path < $1.path }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ProjectInputManifest.sha256(try encoder.encode(entries))
    }

    static func metadata(at url: URL) -> stat? {
        var value = stat()
        return lstat(url.path, &value) == 0 ? value : nil
    }
}

enum CacheRecoveryOutcome: Equatable, Sendable {
    case absent
    case recovered
    case ready
}

enum RetainedArtifactClass: String, Comparable, Sendable {
    case derivedData

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct CacheRecovery: Sendable {
    private struct State: Codable, Sendable {
        enum Phase: String, Codable, Sendable { case dirty, ready }
        let schemaVersion: Int
        var phase: Phase
        var productManifestSHA256: String?
        var previousReadyProductManifestSHA256: String?
    }

    private struct RetentionMetadata: Codable, Sendable {
        let schemaVersion: Int
        let lastUsedAt: TimeInterval
    }

    let identityDirectory: URL
    let collectionRoot: URL
    var createPrivateFile: @Sendable (String, Data) -> Bool = {
        FileManager.default.createFile(atPath: $0, contents: $1, attributes: [.posixPermissions: 0o600])
    }
    var replaceJournal: @Sendable (String, String) -> Int32 = { rename($0, $1) }
    var syncDescriptor: @Sendable (Int32) -> Int32 = { fsync($0) }
    var openJournalFile: @Sendable (String) -> Int32 = {
        open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    var openJournalDirectory: @Sendable (String) -> Int32 = {
        open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    }

    private var stateURL: URL { identityDirectory.appendingPathComponent("cache-state.json") }
    private var retentionURL: URL { identityDirectory.appendingPathComponent("retention.json") }

    func markDirty(previousReadyProductManifestSHA256: String? = nil) throws {
        try validateIdentity()
        try write(
            State(
                schemaVersion: 1,
                phase: .dirty,
                productManifestSHA256: nil,
                previousReadyProductManifestSHA256: previousReadyProductManifestSHA256
            ),
            to: stateURL
        )
    }

    func markReady(productManifestSHA256: String) throws {
        try validateIdentity()
        guard CachePathGuard.isLowercaseHexDigest(productManifestSHA256) else {
            throw PreparedCacheError.invalidCacheState
        }
        try scrubSourceBearingArtifacts()
        try write(
            State(
                schemaVersion: 1,
                phase: .ready,
                productManifestSHA256: productManifestSHA256,
                previousReadyProductManifestSHA256: nil
            ),
            to: stateURL
        )
    }

    func recordMutationOrTestFailure() throws {
        try validateIdentity()
        let state = try loadState()
        guard state.phase == .ready else { throw PreparedCacheError.invalidCacheState }
        try scrubSourceBearingArtifacts()
    }

    func scrubAfterCommand() throws {
        try validateIdentity()
        try scrubSourceBearingArtifacts()
    }

    func recover(expectedProductManifestSHA256: String) throws -> CacheRecoveryOutcome {
        guard FileManager.default.fileExists(atPath: identityDirectory.path) else { return .absent }
        try validateIdentity()
        try scrubSourceBearingArtifacts()
        let state = try loadState()
        switch state.phase {
        case .dirty:
            try invalidateDirtyProducts()
            return .recovered
        case .ready:
            guard state.productManifestSHA256 == expectedProductManifestSHA256 else {
                throw PreparedCacheError.productManifestMismatch
            }
            return .ready
        }
    }

    func invalidateDivergentPreparedBuild() throws {
        try validateIdentity()
        try scrubSourceBearingArtifacts()
        try invalidateDirtyProducts()
    }

    func writeRetentionMetadata(lastUsedAt: Date) throws {
        try validateIdentity()
        try write(
            RetentionMetadata(schemaVersion: 1, lastUsedAt: lastUsedAt.timeIntervalSince1970),
            to: retentionURL
        )
    }

    func retentionLastUsedAt() throws -> Date {
        try validateIdentity()
        let metadata: RetentionMetadata = try read(
            RetentionMetadata.self, from: retentionURL, keys: ["schemaVersion", "lastUsedAt"]
        )
        guard metadata.schemaVersion == 1, metadata.lastUsedAt.isFinite else {
            throw PreparedCacheError.invalidCacheState
        }
        return Date(timeIntervalSince1970: metadata.lastUsedAt)
    }

    func inspectRetainedArtifacts() throws -> [RetainedArtifactClass] {
        try validateIdentity()
        let names = try FileManager.default.contentsOfDirectory(atPath: identityDirectory.path)
        var forbidden: [String] = []
        for name in names where !Self.retainedNames.contains(name) {
            if try shouldRetainCustodyRegistry(named: name) { continue }
            forbidden.append(name)
        }
        guard forbidden.isEmpty else { throw PreparedCacheError.invalidCacheState }
        return names.contains("DerivedData") ? [.derivedData] : []
    }

    private func validateIdentity() throws {
        try CachePathGuard.validateDirectory(collectionRoot, containedIn: collectionRoot)
        try CachePathGuard.validateDirectory(identityDirectory, containedIn: collectionRoot)
    }

    private func loadState() throws -> State {
        let state: State = try readState()
        guard state.schemaVersion == 1,
            state.productManifestSHA256.map(CachePathGuard.isLowercaseHexDigest) ?? true,
            state.previousReadyProductManifestSHA256.map(CachePathGuard.isLowercaseHexDigest) ?? true,
            (state.phase == .ready) == (state.productManifestSHA256 != nil)
        else { throw PreparedCacheError.invalidCacheState }
        return state
    }

    private func scrubSourceBearingArtifacts() throws {
        let manager = FileManager.default
        for name in try manager.contentsOfDirectory(atPath: identityDirectory.path)
        where !Self.retainedNames.contains(name) {
            if try shouldRetainCustodyRegistry(named: name) { continue }
            let target = identityDirectory.appendingPathComponent(name)
            try CachePathGuard.validateNoSymlinkComponents(target, containedIn: identityDirectory)
            let metadata = try Self.requireMetadata(target)
            if metadata.st_mode & S_IFMT == S_IFDIR {
                try CachePathGuard.validateOwnedTree(target, containedIn: identityDirectory)
            }
            try manager.removeItem(at: target)
        }
    }

    private func shouldRetainCustodyRegistry(named name: String) throws -> Bool {
        guard name == Self.custodyRegistryName else { return false }
        return try !ProcessCustody.readRegisteredGroups(
            from: identityDirectory.appendingPathComponent(name)
        ).isEmpty
    }

    private func invalidateDirtyProducts() throws {
        for target in [
            identityDirectory.appendingPathComponent("DerivedData", isDirectory: true),
            identityDirectory.appendingPathComponent("prepared-build.json"),
        ] where FileManager.default.fileExists(atPath: target.path) {
            try CachePathGuard.validateNoSymlinkComponents(target, containedIn: identityDirectory)
            let metadata = try Self.requireMetadata(target)
            if metadata.st_mode & S_IFMT == S_IFDIR {
                try CachePathGuard.validateOwnedTree(target, containedIn: identityDirectory)
            } else {
                try CachePathGuard.validateRegularFile(target, containedIn: identityDirectory)
            }
            try FileManager.default.removeItem(at: target)
        }
    }

    static func requireMetadata(
        _ target: URL, provider: (URL) -> stat? = { CachePathGuard.metadata(at: $0) }
    ) throws -> stat {
        guard let metadata = provider(target) else { throw PreparedCacheError.unsafeCachePath }
        return metadata
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString)")
        let data = try encoder.encode(value)
        guard createPrivateFile(temporary.path, data) else {
            throw PreparedCacheError.unsafeCachePath
        }
        do {
            try CachePathGuard.validateRegularFile(temporary, containedIn: identityDirectory)
            let temporaryDescriptor = openJournalFile(temporary.path)
            guard temporaryDescriptor >= 0 else { throw PreparedCacheError.unsafeCachePath }
            let fileSync = syncDescriptor(temporaryDescriptor)
            let fileClose = close(temporaryDescriptor)
            guard fileSync == 0, fileClose == 0 else {
                throw PreparedCacheError.unsafeCachePath
            }
            if FileManager.default.fileExists(atPath: url.path) {
                try CachePathGuard.validateRegularFile(url, containedIn: identityDirectory)
            }
            guard replaceJournal(temporary.path, url.path) == 0 else {
                throw PreparedCacheError.unsafeCachePath
            }
            try CachePathGuard.validateRegularFile(url, containedIn: identityDirectory)
            let parentDescriptor = openJournalDirectory(url.deletingLastPathComponent().path)
            guard parentDescriptor >= 0 else { throw PreparedCacheError.unsafeCachePath }
            let parentSync = syncDescriptor(parentDescriptor)
            let parentClose = close(parentDescriptor)
            guard parentSync == 0, parentClose == 0 else {
                throw PreparedCacheError.unsafeCachePath
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL, keys: Set<String>) throws -> T {
        do {
            try CachePathGuard.validateRegularFile(url, containedIn: identityDirectory)
            let data = try Data(contentsOf: url)
            _ = try ExactJSON.object(data, keys: keys)
            return try JSONDecoder().decode(type, from: data)
        } catch let error as PreparedCacheError {
            throw error
        } catch {
            throw PreparedCacheError.invalidCacheState
        }
    }

    private func readState() throws -> State {
        do {
            try CachePathGuard.validateRegularFile(stateURL, containedIn: identityDirectory)
            let data = try Data(contentsOf: stateURL)
            _ = try ExactJSON.object(
                data,
                requiredKeys: ["schemaVersion", "phase"],
                allowedKeys: ["schemaVersion", "phase", "productManifestSHA256", "previousReadyProductManifestSHA256"]
            )
            return try JSONDecoder().decode(State.self, from: data)
        } catch let error as PreparedCacheError {
            throw error
        } catch {
            throw PreparedCacheError.invalidCacheState
        }
    }

    private static let retainedNames: Set<String> = [
        "DerivedData", "cache-state.json", "retention.json", "prepared-build.json", "engine.lock",
    ]
    private static let custodyRegistryName = "process-custody.json"

}
