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

struct CacheDeleteTreeOperations: @unchecked Sendable {
    var openParent: (String) -> Int32
    var closeDescriptor: (Int32) -> Int32
    var metadataAt: (Int32, String) -> stat?
    var metadataAtError: () -> Int32
    var openChild: (Int32, String) -> Int32
    var metadataOf: (Int32) -> stat?
    var childNames: (Int32) -> [String]?
    var unlinkEntry: (Int32, String, Int32) -> Int32

    static let system = Self(
        openParent: { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) },
        closeDescriptor: { close($0) },
        metadataAt: { descriptor, name in
            var value = stat()
            return fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 ? value : nil
        },
        metadataAtError: { errno },
        openChild: { openat($0, $1, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) },
        metadataOf: { descriptor in
            var value = stat()
            return fstat(descriptor, &value) == 0 ? value : nil
        },
        childNames: { systemChildNames(descriptor: $0) },
        unlinkEntry: { unlinkat($0, $1, $2) }
    )

    static func systemChildNames(
        descriptor: Int32,
        duplicate: (Int32) -> Int32 = { dup($0) },
        openDirectory: (Int32) -> UnsafeMutablePointer<DIR>? = { fdopendir($0) },
        readEntry: (UnsafeMutablePointer<DIR>?) -> UnsafeMutablePointer<dirent>? = { readdir($0) },
        readError: () -> Int32 = { errno },
        closeDirectory: (UnsafeMutablePointer<DIR>?) -> Int32 = { closedir($0) }
    ) -> [String]? {
        let duplicate = duplicate(descriptor)
        guard duplicate >= 0 else { return nil }
        guard let directory = openDirectory(duplicate) else {
            _ = close(duplicate)
            return nil
        }
        errno = 0
        var names: [String] = []
        while let entry = readEntry(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        let enumerationError = readError()
        let closeResult = closeDirectory(directory)
        guard enumerationError == 0, closeResult == 0 else { return nil }
        return names
    }
}

struct CacheEntryIdentity {
    let device: dev_t
    let inode: ino_t
    let uid: uid_t
    let kind: mode_t

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        uid = metadata.st_uid
        kind = metadata.st_mode & S_IFMT
    }

    func matches(_ metadata: stat) -> Bool {
        device == metadata.st_dev && inode == metadata.st_ino && uid == metadata.st_uid
            && kind == metadata.st_mode & S_IFMT
    }

    func matches(_ other: CacheEntryIdentity) -> Bool {
        device == other.device && inode == other.inode && uid == other.uid && kind == other.kind
    }
}

enum CacheDeleteTree {
    static func entryExists(
        _ root: URL,
        containedIn parent: URL,
        operations: CacheDeleteTreeOperations = .system
    ) throws -> Bool {
        try withParentDescriptor(
            root, containedIn: parent, expectedKind: nil, operations: operations
        ) { descriptor, name in
            if operations.metadataAt(descriptor, name) != nil { return true }
            guard operations.metadataAtError() == ENOENT else {
                throw PreparedCacheError.unsafeCachePath
            }
            return false
        }
    }

    static func byteSize(
        _ root: URL,
        containedIn parent: URL,
        operations: CacheDeleteTreeOperations = .system
    ) throws -> Int64 {
        try withParentDescriptor(
            root, containedIn: parent, expectedKind: S_IFDIR, operations: operations
        ) { descriptor, name in
            try inspectEntry(
                parentDescriptor: descriptor, name: name, remove: false,
                rejectHardlinks: true, operations: operations)
        }
    }

    static func validateForRemoval(
        _ root: URL,
        containedIn parent: URL,
        operations: CacheDeleteTreeOperations = .system
    ) throws -> CacheEntryIdentity {
        try withParentDescriptor(
            root, containedIn: parent, expectedKind: S_IFDIR, operations: operations
        ) { descriptor, name in
            guard let metadata = operations.metadataAt(descriptor, name) else {
                throw PreparedCacheError.unsafeCachePath
            }
            let identity = CacheEntryIdentity(metadata)
            _ = try inspectEntry(
                parentDescriptor: descriptor, name: name, remove: false,
                rejectHardlinks: true, expectedIdentity: identity, operations: operations)
            return identity
        }
    }

    static func remove(
        _ root: URL,
        containedIn parent: URL,
        rejectHardlinks: Bool = false,
        expectedIdentity: CacheEntryIdentity? = nil,
        operations: CacheDeleteTreeOperations = .system
    ) throws {
        _ = try withParentDescriptor(
            root, containedIn: parent, expectedKind: S_IFDIR, operations: operations
        ) { descriptor, name in
            try inspectEntry(
                parentDescriptor: descriptor,
                name: name,
                remove: true,
                rejectHardlinks: rejectHardlinks,
                expectedIdentity: expectedIdentity,
                operations: operations
            )
        }
    }

    static func removeRegularFile(
        _ root: URL,
        containedIn parent: URL,
        operations: CacheDeleteTreeOperations = .system
    ) throws {
        _ = try withParentDescriptor(
            root, containedIn: parent, expectedKind: S_IFREG, operations: operations
        ) { descriptor, name in
            try inspectEntry(
                parentDescriptor: descriptor, name: name, remove: true,
                rejectHardlinks: true, expectedIdentity: nil, operations: operations)
        }
    }

    static func removeDirectory(
        _ root: URL,
        containedIn parent: URL,
        operations: CacheDeleteTreeOperations = .system
    ) throws {
        _ = try withParentDescriptor(
            root, containedIn: parent, expectedKind: S_IFDIR, operations: operations
        ) { descriptor, name in
            try inspectEntry(
                parentDescriptor: descriptor, name: name, remove: true,
                rejectHardlinks: true, expectedIdentity: nil, operations: operations)
        }
    }

    private static func withParentDescriptor<T>(
        _ root: URL,
        containedIn parent: URL,
        expectedKind: mode_t?,
        operations: CacheDeleteTreeOperations,
        body: (Int32, String) throws -> T
    ) throws -> T {
        try CachePathGuard.validateDirectory(parent, containedIn: parent)
        guard root.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path,
            !root.lastPathComponent.isEmpty
        else { throw PreparedCacheError.unsafeCachePath }
        let descriptor = operations.openParent(parent.path)
        guard descriptor >= 0 else { throw PreparedCacheError.unsafeCachePath }
        defer { _ = operations.closeDescriptor(descriptor) }
        if let expectedKind {
            guard let metadata = operations.metadataAt(descriptor, root.lastPathComponent),
                metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == expectedKind
            else { throw PreparedCacheError.unsafeCachePath }
        }
        return try body(descriptor, root.lastPathComponent)
    }

    private static func inspectEntry(
        parentDescriptor: Int32,
        name: String,
        remove: Bool,
        rejectHardlinks: Bool,
        expectedIdentity: CacheEntryIdentity? = nil,
        operations: CacheDeleteTreeOperations
    ) throws -> Int64 {
        guard let before = operations.metadataAt(parentDescriptor, name), before.st_uid == getuid()
        else { throw PreparedCacheError.unsafeCachePath }
        guard expectedIdentity?.matches(before) != false else {
            throw PreparedCacheError.unsafeCachePath
        }
        let kind = before.st_mode & S_IFMT
        if kind == S_IFDIR {
            return try inspectDirectory(
                parentDescriptor: parentDescriptor, name: name, before: before,
                remove: remove, rejectHardlinks: rejectHardlinks, operations: operations)
        }
        return try inspectLeaf(
            parentDescriptor: parentDescriptor, name: name, before: before, kind: kind,
            remove: remove, rejectHardlinks: rejectHardlinks, operations: operations)
    }

    private static func inspectDirectory(
        parentDescriptor: Int32,
        name: String,
        before: stat,
        remove: Bool,
        rejectHardlinks: Bool,
        operations: CacheDeleteTreeOperations
    ) throws -> Int64 {
        let child = operations.openChild(parentDescriptor, name)
        guard child >= 0 else { throw PreparedCacheError.unsafeCachePath }
        defer { _ = operations.closeDescriptor(child) }
        guard let opened = operations.metadataOf(child), sameIdentity(before, opened) else {
            throw PreparedCacheError.unsafeCachePath
        }
        guard let names = operations.childNames(child) else { throw PreparedCacheError.unsafeCachePath }
        var total: Int64 = 0
        for entryName in names {
            total += try inspectEntry(
                parentDescriptor: child, name: entryName, remove: remove,
                rejectHardlinks: rejectHardlinks, expectedIdentity: nil,
                operations: operations)
        }
        if remove {
            guard let current = operations.metadataAt(parentDescriptor, name) else {
                throw PreparedCacheError.unsafeCachePath
            }
            guard sameIdentity(before, current) else {
                throw PreparedCacheError.unsafeCachePath
            }
            guard operations.unlinkEntry(parentDescriptor, name, AT_REMOVEDIR) == 0 else {
                throw PreparedCacheError.unsafeCachePath
            }
        }
        return total
    }

    private static func inspectLeaf(
        parentDescriptor: Int32,
        name: String,
        before: stat,
        kind: mode_t,
        remove: Bool,
        rejectHardlinks: Bool,
        operations: CacheDeleteTreeOperations
    ) throws -> Int64 {
        guard kind == S_IFREG || kind == S_IFLNK,
            !rejectHardlinks || kind != S_IFREG || before.st_nlink == 1
        else { throw PreparedCacheError.unsafeCachePath }
        if remove {
            guard let current = operations.metadataAt(parentDescriptor, name) else {
                throw PreparedCacheError.unsafeCachePath
            }
            guard sameIdentity(before, current) else {
                throw PreparedCacheError.unsafeCachePath
            }
            guard operations.unlinkEntry(parentDescriptor, name, 0) == 0 else {
                throw PreparedCacheError.unsafeCachePath
            }
        }
        return kind == S_IFREG ? Int64(before.st_size) : 0
    }

    private static func sameIdentity(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino
            && left.st_uid == right.st_uid && left.st_mode & S_IFMT == right.st_mode & S_IFMT
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
    private let directory: URL
    private let directoryIdentity: CacheEntryIdentity
    private var directoryDescriptor: Int32 = -1
    private var descriptor: Int32 = -1
    private let closeLock: (Int32) -> Int32
    private let closeDirectory: (Int32) -> Int32
    private let metadataAt: (Int32, String) -> stat?
    private let metadataOf: (Int32) -> stat?
    private var released = false
    private let mutex = NSLock()

    init(
        identityDirectory: URL,
        expectedDirectoryIdentity: CacheEntryIdentity? = nil,
        lockName: String = "engine.lock",
        openDirectory: (String) -> Int32 = {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        },
        openLockAt: (Int32, String) -> Int32 = {
            openat($0, $1, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        },
        openLock: ((String) -> Int32)? = nil,
        metadataAt: @escaping (Int32, String) -> stat? = { descriptor, name in
            var value = stat()
            return fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 ? value : nil
        },
        metadataOf: @escaping (Int32) -> stat? = { descriptor in
            var value = stat()
            return fstat(descriptor, &value) == 0 ? value : nil
        },
        acquireLock: (Int32) -> Int32 = { flock($0, LOCK_EX | LOCK_NB) },
        closeLock: @escaping (Int32) -> Int32 = { close($0) },
        closeDirectory: @escaping (Int32) -> Int32 = { close($0) },
        pathMetadata: (URL) -> stat? = { CachePathGuard.metadata(at: $0) },
        afterDirectoryValidation: () -> Void = {},
        afterLockOpened: (URL) -> Void = { _ in }
    ) throws {
        try CachePathGuard.validateDirectory(identityDirectory, containedIn: identityDirectory)
        guard let pathMetadata = pathMetadata(identityDirectory) else {
            throw PreparedCacheError.unsafeCachePath
        }
        let claimedIdentity = expectedDirectoryIdentity ?? CacheEntryIdentity(pathMetadata)
        guard claimedIdentity.matches(pathMetadata) else { throw PreparedCacheError.unsafeCachePath }
        directory = identityDirectory
        directoryIdentity = claimedIdentity
        url = identityDirectory.appendingPathComponent(lockName)
        self.closeLock = closeLock
        self.closeDirectory = closeDirectory
        self.metadataAt = metadataAt
        self.metadataOf = metadataOf
        afterDirectoryValidation()
        directoryDescriptor = openDirectory(identityDirectory.path)
        guard directoryDescriptor >= 0 else { throw PreparedCacheError.unsafeCachePath }
        do {
            guard let openedDirectory = metadataOf(directoryDescriptor), claimedIdentity.matches(openedDirectory)
            else { throw PreparedCacheError.unsafeCachePath }
            descriptor = openLock?(url.path) ?? openLockAt(directoryDescriptor, lockName)
            guard descriptor >= 0 else { throw PreparedCacheError.unsafeCachePath }
            guard let openedLock = metadataOf(descriptor),
                let linkedLock = metadataAt(directoryDescriptor, lockName),
                CacheEntryIdentity(openedLock).matches(linkedLock),
                Self.isSafeLockMetadata(openedLock)
            else { throw PreparedCacheError.unsafeCachePath }
            afterLockOpened(url)
            try validateDirectoryIdentity()
            guard acquireLock(descriptor) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw PreparedCacheError.lockBusy }
                throw PreparedCacheError.unsafeCachePath
            }
            try validateDirectoryIdentity()
        } catch {
            if descriptor >= 0 {
                _ = closeLock(descriptor)
                descriptor = -1
            }
            _ = closeDirectory(directoryDescriptor)
            directoryDescriptor = -1
            throw error
        }
    }

    static func collection(collectionRoot: URL) throws -> CacheLock {
        try CacheLock(identityDirectory: collectionRoot, lockName: "collection.lock")
    }

    func identityDirectory(
        named name: String,
        createIfMissing: Bool,
        createDirectoryAt: (Int32, String, mode_t) -> Int32 = { mkdirat($0, $1, $2) },
        metadataAtChild: (Int32, String) -> stat? = { descriptor, child in
            var value = stat()
            return fstatat(descriptor, child, &value, AT_SYMLINK_NOFOLLOW) == 0 ? value : nil
        },
        lastError: () -> Int32 = { errno },
        openChild: (Int32, String) -> Int32 = {
            openat($0, $1, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        },
        metadataOfChild: (Int32) -> stat? = { descriptor in
            var value = stat()
            return fstat(descriptor, &value) == 0 ? value : nil
        },
        closeChild: (Int32) -> Int32 = { close($0) }
    ) throws -> CacheEntryIdentity? {
        guard CachePathGuard.isLowercaseHexDigest(name) else {
            throw PreparedCacheError.unsafeCachePath
        }
        try validateDirectoryIdentity()
        if createIfMissing, createDirectoryAt(directoryDescriptor, name, 0o700) != 0,
            lastError() != EEXIST
        {
            throw PreparedCacheError.unsafeCachePath
        }
        guard let linked = metadataAtChild(directoryDescriptor, name) else {
            if !createIfMissing, lastError() == ENOENT { return nil }
            throw PreparedCacheError.unsafeCachePath
        }
        guard linked.st_uid == getuid(), linked.st_mode & S_IFMT == S_IFDIR,
            linked.st_mode & 0o777 == 0o700
        else { throw PreparedCacheError.unsafeCachePath }
        let childDescriptor = openChild(directoryDescriptor, name)
        guard childDescriptor >= 0 else { throw PreparedCacheError.unsafeCachePath }
        guard let opened = metadataOfChild(childDescriptor), CacheEntryIdentity(linked).matches(opened)
        else {
            _ = closeChild(childDescriptor)
            throw PreparedCacheError.unsafeCachePath
        }
        guard closeChild(childDescriptor) == 0 else { throw PreparedCacheError.unsafeCachePath }
        try validateDirectoryIdentity()
        return CacheEntryIdentity(opened)
    }

    func validateDirectoryIdentity() throws {
        try CachePathGuard.validateDirectory(directory, containedIn: directory)
        guard let pathMetadata = CachePathGuard.metadata(at: directory),
            directoryIdentity.matches(pathMetadata),
            let openedDirectory = metadataOf(directoryDescriptor),
            directoryIdentity.matches(openedDirectory),
            let openedLock = metadataOf(descriptor),
            let linkedLock = metadataAt(directoryDescriptor, url.lastPathComponent),
            CacheEntryIdentity(openedLock).matches(linkedLock),
            Self.isSafeLockMetadata(openedLock), Self.isSafeLockMetadata(linkedLock)
        else { throw PreparedCacheError.unsafeCachePath }
    }

    private static func isSafeLockMetadata(_ metadata: stat) -> Bool {
        metadata.st_uid == getuid() && metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_mode & 0o777 == 0o600 && metadata.st_nlink == 1
    }

    func release() throws {
        mutex.lock()
        defer { mutex.unlock() }
        guard !released else { return }
        released = true
        let lockClose = closeLock(descriptor)
        descriptor = -1
        let directoryClose = closeDirectory(directoryDescriptor)
        directoryDescriptor = -1
        guard lockClose == 0, directoryClose == 0 else {
            throw PreparedCacheError.unsafeCachePath
        }
    }

    deinit {
        if !released {
            if descriptor >= 0 { _ = closeLock(descriptor) }
            if directoryDescriptor >= 0 { _ = closeDirectory(directoryDescriptor) }
        }
    }
}
