import Foundation

struct PreparedBuildState: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sandboxPath: String
    let derivedDataPath: String
    let xctestrunPath: String
    let productManifestSHA256: String
    let projectInputManifestSHA256: String
    let preparedInventorySHA256: String

    init(
        schemaVersion: Int = 1,
        sandboxPath: String,
        derivedDataPath: String,
        xctestrunPath: String,
        productManifestSHA256: String,
        projectInputManifestSHA256: String,
        preparedInventorySHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.sandboxPath = sandboxPath
        self.derivedDataPath = derivedDataPath
        self.xctestrunPath = xctestrunPath
        self.productManifestSHA256 = productManifestSHA256
        self.projectInputManifestSHA256 = projectInputManifestSHA256
        self.preparedInventorySHA256 = preparedInventorySHA256
    }
}

struct PreparedBuildStore: Sendable {
    init(root: String, compatibilityID: String) {
        directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(compatibilityID, isDirectory: true)
    }

    let directory: URL

    var stateURL: URL { directory.appendingPathComponent("prepared-build.json") }
    var sandboxURL: URL { directory.appendingPathComponent("project", isDirectory: true) }
    var derivedDataURL: URL { directory.appendingPathComponent("DerivedData", isDirectory: true) }

    func prepareDirectory(
        createDirectory: (String, mode_t) -> Int32 = { mkdir($0, $1) },
        metadataOf: (URL) -> stat? = { CachePathGuard.metadata(at: $0) }
    ) throws -> CacheEntryIdentity {
        let root = directory.deletingLastPathComponent()
        try CachePathGuard.validateDirectory(root, containedIn: root)
        let result = createDirectory(directory.path, 0o700)
        if result != 0 {
            guard errno == EEXIST else { throw PreparedCacheError.unsafeCachePath }
            try CachePathGuard.validateDirectory(directory, containedIn: root)
            guard let metadata = metadataOf(directory) else {
                throw PreparedCacheError.unsafeCachePath
            }
            return CacheEntryIdentity(metadata)
        }
        try CachePathGuard.validateDirectory(directory, containedIn: root)
        guard let metadata = metadataOf(directory) else {
            throw PreparedCacheError.unsafeCachePath
        }
        return CacheEntryIdentity(metadata)
    }

    func directoryIdentity(
        metadataOf: (URL) -> stat? = { CachePathGuard.metadata(at: $0) }
    ) throws -> CacheEntryIdentity {
        let root = directory.deletingLastPathComponent()
        try CachePathGuard.validateDirectory(directory, containedIn: root)
        guard let metadata = metadataOf(directory) else {
            throw PreparedCacheError.unsafeCachePath
        }
        return CacheEntryIdentity(metadata)
    }

    func reset() throws {
        let root = directory.deletingLastPathComponent()
        try CachePathGuard.validateDirectory(root, containedIn: root)
        if CachePathGuard.metadata(at: directory) != nil {
            try CachePathGuard.validateDirectory(directory, containedIn: root)
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try CachePathGuard.validateDirectory(directory, containedIn: root)
    }

    func save(_ state: PreparedBuildState) throws {
        try CachePathGuard.validateDirectory(
            directory, containedIn: directory.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    func load() throws -> PreparedBuildState {
        do {
            try CachePathGuard.validateDirectory(
                directory.deletingLastPathComponent(), containedIn: directory.deletingLastPathComponent())
            try CachePathGuard.validateDirectory(directory, containedIn: directory.deletingLastPathComponent())
            try CachePathGuard.validateRegularFile(stateURL, containedIn: directory)
        } catch {
            throw PreparedBuildError.preparedBuildMissing
        }
        guard let data = try? Data(contentsOf: stateURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == [
                "schemaVersion", "sandboxPath", "derivedDataPath", "xctestrunPath", "productManifestSHA256",
                "projectInputManifestSHA256", "preparedInventorySHA256",
            ],
            let state = try? JSONDecoder().decode(PreparedBuildState.self, from: data),
            state.schemaVersion == 1,
            state.sandboxPath == sandboxURL.path,
            state.derivedDataPath == derivedDataURL.path,
            CachePathGuard.isContained(URL(fileURLWithPath: state.xctestrunPath), in: derivedDataURL),
            CachePathGuard.isLowercaseHexDigest(state.productManifestSHA256),
            CachePathGuard.isLowercaseHexDigest(state.projectInputManifestSHA256),
            CachePathGuard.isLowercaseHexDigest(state.preparedInventorySHA256)
        else { throw PreparedBuildError.preparedBuildMissing }
        do {
            try CachePathGuard.validateNoSymlinkComponents(derivedDataURL, containedIn: directory)
            guard let derivedMetadata = CachePathGuard.metadata(at: derivedDataURL),
                derivedMetadata.st_uid == getuid(), derivedMetadata.st_mode & S_IFMT == S_IFDIR
            else { throw PreparedCacheError.unsafeCachePath }
            let xctestrunURL = URL(fileURLWithPath: state.xctestrunPath)
            try CachePathGuard.validateNoSymlinkComponents(xctestrunURL, containedIn: derivedDataURL)
            guard let xctestrunMetadata = CachePathGuard.metadata(at: xctestrunURL),
                xctestrunMetadata.st_uid == getuid(), xctestrunMetadata.st_mode & S_IFMT == S_IFREG,
                xctestrunMetadata.st_nlink == 1
            else { throw PreparedCacheError.unsafeCachePath }
        } catch {
            throw PreparedBuildError.preparedBuildMissing
        }
        return state
    }
}
