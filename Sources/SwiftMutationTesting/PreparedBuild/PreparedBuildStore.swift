import Foundation

struct PreparedBuildState: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sandboxPath: String
    let derivedDataPath: String
    let xctestrunPath: String
    let productManifestSHA256: String
    let inventory: PreparedMutantInventory

    init(
        schemaVersion: Int = 1,
        sandboxPath: String,
        derivedDataPath: String,
        xctestrunPath: String,
        productManifestSHA256: String,
        inventory: PreparedMutantInventory
    ) {
        self.schemaVersion = schemaVersion
        self.sandboxPath = sandboxPath
        self.derivedDataPath = derivedDataPath
        self.xctestrunPath = xctestrunPath
        self.productManifestSHA256 = productManifestSHA256
        self.inventory = inventory
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

    func prepareDirectory() throws {
        let root = directory.deletingLastPathComponent()
        try CachePathGuard.validateDirectory(root, containedIn: root)
        if FileManager.default.fileExists(atPath: directory.path) {
            try CachePathGuard.validateDirectory(directory, containedIn: root)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        chmod(directory.path, 0o700)
        try CachePathGuard.validateDirectory(directory, containedIn: root)
    }

    func reset() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func save(_ state: PreparedBuildState) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    func load() throws -> PreparedBuildState {
        do {
            try CachePathGuard.validateDirectory(directory.deletingLastPathComponent(), containedIn: directory.deletingLastPathComponent())
            try CachePathGuard.validateDirectory(directory, containedIn: directory.deletingLastPathComponent())
            try CachePathGuard.validateRegularFile(stateURL, containedIn: directory)
        } catch {
            throw PreparedBuildError.preparedBuildMissing
        }
        guard let data = try? Data(contentsOf: stateURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == ["schemaVersion", "sandboxPath", "derivedDataPath", "xctestrunPath", "productManifestSHA256", "inventory"],
            let inventoryObject = object["inventory"] as? [String: Any],
            Set(inventoryObject.keys) == ["schemaVersion", "projectInputManifestSHA256", "mutants"],
            let rows = inventoryObject["mutants"] as? [[String: Any]],
            rows.allSatisfy({ Set($0.keys) == ["id", "sourcePath", "sourceUTF8Offset", "operatorIdentifier", "replacementBytesSHA256"] }),
            let state = try? JSONDecoder().decode(PreparedBuildState.self, from: data),
            state.schemaVersion == 1,
            state.sandboxPath == sandboxURL.path,
            state.derivedDataPath == derivedDataURL.path,
            CachePathGuard.isContained(URL(fileURLWithPath: state.xctestrunPath), in: derivedDataURL),
            state.productManifestSHA256.count == 64,
            state.productManifestSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { throw PreparedBuildError.preparedBuildMissing }
        do { try state.inventory.validatePersisted() }
        catch { throw PreparedBuildError.preparedBuildMissing }
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
