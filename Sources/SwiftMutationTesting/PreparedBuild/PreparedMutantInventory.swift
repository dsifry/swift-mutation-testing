import CryptoKit
import Foundation

enum PreparedBuildError: Error, Equatable {
    case inventoryMismatch
    case invalidSourcePath
    case emptySelection
    case selectionMismatch
    case preparedBuildMissing
}

struct PreparedMutantInventory: Codable, Equatable, Sendable {
    struct Row: Codable, Equatable, Sendable {
        let id: String
        let sourcePath: String
        let sourceUTF8Offset: Int
        let operatorIdentifier: String
        let replacementBytesSHA256: String
    }

    let schemaVersion: Int
    let projectInputManifestSHA256: String
    let mutants: [Row]

    init(
        projectRoot: String,
        projectInputManifestSHA256: String,
        mutants: [MutantDescriptor]
    ) throws {
        self.schemaVersion = 1
        self.projectInputManifestSHA256 = projectInputManifestSHA256
        self.mutants = try Self.rows(projectRoot: projectRoot, mutants: mutants)
    }

    var sha256: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return Self.sha256(try encoder.encode(self))
        }
    }

    func validate(mutants current: [MutantDescriptor], projectRoot: String) throws {
        guard try Self.rows(projectRoot: projectRoot, mutants: current) == mutants else {
            throw PreparedBuildError.inventoryMismatch
        }
    }

    func validatePersisted() throws {
        guard schemaVersion == 1,
            Self.isDigest(projectInputManifestSHA256),
            Set(mutants.map(\.id)).count == mutants.count,
            mutants.allSatisfy({ row in
                !row.id.isEmpty && !row.sourcePath.isEmpty
                    && row.sourcePath == Self.normalizeRelativePath(row.sourcePath)
                    && !row.sourcePath.split(separator: "/").contains("..")
                    && row.sourceUTF8Offset >= 0 && !row.operatorIdentifier.isEmpty
                    && Self.isDigest(row.replacementBytesSHA256)
            })
        else { throw PreparedBuildError.inventoryMismatch }
    }

    func select(
        mutants current: [MutantDescriptor],
        ownedSourcePaths: [String],
        projectRoot: String
    ) throws -> [MutantDescriptor] {
        try validate(mutants: current, projectRoot: projectRoot)
        let owned = Set(ownedSourcePaths.map(Self.normalizeRelativePath))
        let selected = zip(mutants, current).compactMap { row, descriptor in
            owned.contains(row.sourcePath) ? descriptor : nil
        }
        return selected
    }

    private static func rows(projectRoot: String, mutants: [MutantDescriptor]) throws -> [Row] {
        let root = URL(fileURLWithPath: projectRoot).standardizedFileURL.path
        return try mutants.map { mutant in
            let path = URL(fileURLWithPath: mutant.filePath).standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { throw PreparedBuildError.invalidSourcePath }
            return Row(
                id: mutant.id,
                sourcePath: normalizeRelativePath(String(path.dropFirst(root.count + 1))),
                sourceUTF8Offset: mutant.utf8Offset,
                operatorIdentifier: mutant.operatorIdentifier,
                replacementBytesSHA256: sha256(Data(mutant.mutatedText.utf8))
            )
        }
    }

    private static func normalizeRelativePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
