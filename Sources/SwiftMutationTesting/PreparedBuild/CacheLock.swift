import Darwin
import Foundation

enum PreparedCacheError: Error, Equatable {
    case unsafeCachePath
    case lockBusy
    case productManifestMismatch
    case unverifiableProcessIdentity
    case tooManyProcessGroups
    case retentionUnsatisfied
    case invalidCacheState
    case invalidProjectInputManifest
    case projectInputDrift
}

enum CachePathGuard {
    static func validateCanonicalAbsoluteRoot(_ root: URL) throws {
        let path = lexicalPath(root)
        guard path.hasPrefix("/"), canonicalURL(root).map(lexicalPath) == path else {
            throw PreparedCacheError.unsafeCachePath
        }
    }

    static func canonicalURL(_ url: URL) -> URL? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    static func validateDirectory(
        _ url: URL,
        containedIn root: URL,
        expectedUID: uid_t = getuid()
    ) throws {
        try validateNoSymlinkComponents(url, containedIn: root, expectedUID: expectedUID)
        guard isContained(url, in: root),
            let metadata = metadata(at: url),
            metadata.st_uid == expectedUID,
            metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_mode & 0o777 == 0o700
        else { throw PreparedCacheError.unsafeCachePath }
    }

    static func validateRegularFile(
        _ url: URL,
        containedIn root: URL,
        expectedUID: uid_t = getuid()
    ) throws {
        try validateNoSymlinkComponents(url, containedIn: root, expectedUID: expectedUID)
        guard isContained(url, in: root),
            let metadata = metadata(at: url),
            metadata.st_uid == expectedUID,
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_mode & 0o777 == 0o600,
            metadata.st_nlink == 1
        else { throw PreparedCacheError.unsafeCachePath }
    }

    static func isContained(_ url: URL, in root: URL) -> Bool {
        let candidate = lexicalPath(url)
        let parent = lexicalPath(root)
        return candidate == parent || candidate.hasPrefix(parent + "/")
    }

    static func lexicalPath(_ url: URL) -> String {
        url.path
    }

    static func isLowercaseHexDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
            }
    }

    static func normalizeRelativePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    static func validateNoSymlinkComponents(
        _ url: URL,
        containedIn root: URL,
        expectedUID: uid_t = getuid()
    ) throws {
        try validateCanonicalAbsoluteRoot(root)
        guard isContained(url, in: root) else { throw PreparedCacheError.unsafeCachePath }
        let rootPath = lexicalPath(root)
        let targetPath = lexicalPath(url)
        var current = URL(fileURLWithPath: rootPath, isDirectory: true)
        let suffix = targetPath == rootPath ? "" : String(targetPath.dropFirst(rootPath.count + 1))
        let components = suffix.split(separator: "/").map(String.init)
        var paths = [current]
        for component in components {
            current.appendPathComponent(component)
            paths.append(current)
        }
        for (index, componentURL) in paths.enumerated() {
            guard let value = metadata(at: componentURL), value.st_uid == expectedUID,
                value.st_mode & S_IFMT != S_IFLNK
            else { throw PreparedCacheError.unsafeCachePath }
            if index < paths.count - 1, value.st_mode & S_IFMT != S_IFDIR {
                throw PreparedCacheError.unsafeCachePath
            }
        }
    }

    static func validateOwnedTree(
        _ root: URL,
        containedIn parent: URL,
        metadataProvider: (URL) -> stat? = { metadata(at: $0) },
        makeEnumerator: (URL) -> FileManager.DirectoryEnumerator? = {
            FileManager.default.enumerator(at: $0, includingPropertiesForKeys: nil)
        }
    ) throws {
        try validateNoSymlinkComponents(root, containedIn: parent)
        guard let rootMetadata = metadataProvider(root), rootMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw PreparedCacheError.unsafeCachePath
        }
        guard let enumerator = makeEnumerator(root) else {
            throw PreparedCacheError.unsafeCachePath
        }
        for case let url as URL in enumerator {
            try validateNoSymlinkComponents(url, containedIn: root)
            guard let value = metadataProvider(url) else { throw PreparedCacheError.unsafeCachePath }
            if value.st_mode & S_IFMT == S_IFREG, value.st_nlink != 1 {
                throw PreparedCacheError.unsafeCachePath
            }
        }
    }

    static func metadata(at url: URL) -> stat? {
        var value = stat()
        return lstat(url.path, &value) == 0 ? value : nil
    }
}

enum ExactJSON {
    static func object(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == keys
        else { throw PreparedCacheError.invalidCacheState }
        return object
    }

    static func object(
        _ data: Data,
        requiredKeys: Set<String>,
        allowedKeys: Set<String>
    ) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            requiredKeys.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: allowedKeys)
        else { throw PreparedCacheError.invalidCacheState }
        return object
    }

    static func arrayOfObjects(_ data: Data, keys: Set<String>) throws -> [[String: Any]] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            rows.allSatisfy({ Set($0.keys) == keys })
        else { throw PreparedCacheError.invalidCacheState }
        return rows
    }
}

final class CacheLock: @unchecked Sendable {
    let url: URL
    private let descriptor: Int32
    private let closeLock: (Int32) -> Int32
    private var released = false
    private let mutex = NSLock()

    init(
        identityDirectory: URL,
        openLock: (String) -> Int32 = { open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600) },
        acquireLock: (Int32) -> Int32 = { flock($0, LOCK_EX | LOCK_NB) },
        closeLock: @escaping (Int32) -> Int32 = { close($0) }
    ) throws {
        try CachePathGuard.validateDirectory(identityDirectory, containedIn: identityDirectory)
        url = identityDirectory.appendingPathComponent("engine.lock")
        descriptor = openLock(url.path)
        self.closeLock = closeLock
        guard descriptor >= 0 else {
            throw PreparedCacheError.unsafeCachePath
        }
        do {
            try CachePathGuard.validateRegularFile(url, containedIn: identityDirectory)
            var value = stat()
            guard fstat(descriptor, &value) == 0, value.st_uid == getuid(),
                value.st_mode & S_IFMT == S_IFREG, value.st_mode & 0o777 == 0o600,
                value.st_nlink == 1
            else { throw PreparedCacheError.unsafeCachePath }
            guard acquireLock(descriptor) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw PreparedCacheError.lockBusy }
                throw PreparedCacheError.unsafeCachePath
            }
        } catch {
            _ = closeLock(descriptor)
            throw error
        }
    }

    func release() throws {
        mutex.lock()
        defer { mutex.unlock() }
        guard !released else { return }
        released = true
        guard closeLock(descriptor) == 0 else {
            throw PreparedCacheError.unsafeCachePath
        }
    }

    deinit {
        if descriptor >= 0 && !released {
            _ = closeLock(descriptor)
        }
    }
}
