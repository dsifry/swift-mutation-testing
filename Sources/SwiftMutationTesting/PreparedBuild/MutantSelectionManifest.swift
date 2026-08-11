import Foundation

struct MutantSelectionManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let projectInputManifestSHA256: String
    let preparedInventorySHA256: String
    let selector: String
    let runOrdinal: Int
    let attemptOrdinal: Int
    let ownedSourcePaths: [String]

    func validatedSourcePaths(
        selector expectedSelector: String,
        inventorySHA256: String,
        inventorySourcePaths: [String]
    ) throws -> [String] {
        let normalized = ownedSourcePaths.map(CachePathGuard.normalizeRelativePath)
        let available = Set(inventorySourcePaths.map(CachePathGuard.normalizeRelativePath))
        guard schemaVersion == 1,
            selector == expectedSelector,
            preparedInventorySHA256 == inventorySHA256,
            runOrdinal >= 0,
            attemptOrdinal == 0 || attemptOrdinal == 1,
            normalized == normalized.sorted(),
            Set(normalized).count == normalized.count,
            normalized.allSatisfy(available.contains)
        else { throw PreparedBuildError.selectionMismatch }
        return normalized
    }

    static func load(from path: String) throws -> Self {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            _ = try ExactJSON.object(
                data,
                keys: [
                    "schemaVersion", "projectInputManifestSHA256", "preparedInventorySHA256", "selector", "runOrdinal",
                    "attemptOrdinal", "ownedSourcePaths",
                ]
            )
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard CachePathGuard.isLowercaseHexDigest(value.projectInputManifestSHA256),
                CachePathGuard.isLowercaseHexDigest(value.preparedInventorySHA256),
                !value.selector.isEmpty
            else { throw PreparedBuildError.selectionMismatch }
            return value
        } catch {
            throw PreparedBuildError.selectionMismatch
        }
    }

}
