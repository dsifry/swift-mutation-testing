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
        let normalized = ownedSourcePaths.map(Self.normalize)
        let available = Set(inventorySourcePaths.map(Self.normalize))
        guard schemaVersion == 1,
            selector == expectedSelector,
            preparedInventorySHA256 == inventorySHA256,
            runOrdinal >= 0,
            attemptOrdinal == 0 || attemptOrdinal == 1,
            !normalized.isEmpty,
            normalized == normalized.sorted(),
            Set(normalized).count == normalized.count,
            normalized.allSatisfy(available.contains)
        else { throw PreparedBuildError.selectionMismatch }
        return normalized
    }

    static func load(from path: String) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private static func normalize(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }
}
