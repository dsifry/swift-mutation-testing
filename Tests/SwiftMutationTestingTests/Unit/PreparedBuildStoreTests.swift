import Foundation
import Testing

@testable import SwiftMutationTesting

@Suite("Prepared build store")
struct PreparedBuildStoreTests {
    @Test("Prepared state round trips through the compatibility root")
    func stateRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = try PreparedMutantInventory(
            projectRoot: "/repo",
            projectInputManifestSHA256: String(repeating: "a", count: 64),
            mutants: [makeMutantDescriptor(filePath: "/repo/Sources/A.swift")]
        )
        let state = PreparedBuildState(
            sandboxPath: "/tmp/sandbox",
            derivedDataPath: "/tmp/derived-data",
            xctestrunPath: "/tmp/tests.xctestrun",
            inventory: inventory
        )
        let store = PreparedBuildStore(root: root.path, compatibilityID: String(repeating: "b", count: 64))

        try store.save(state)

        #expect(try store.load() == state)
    }

    @Test("Selection manifest rejects a selector or inventory mismatch")
    func selectionManifestValidatesBindings() throws {
        let digest = String(repeating: "c", count: 64)
        let manifest = MutantSelectionManifest(
            schemaVersion: 1,
            projectInputManifestSHA256: String(repeating: "d", count: 64),
            preparedInventorySHA256: digest,
            selector: "TheGuideTests/ExampleTests",
            runOrdinal: 0,
            attemptOrdinal: 0,
            ownedSourcePaths: ["Sources/A.swift"]
        )

        #expect(
            try manifest.validatedSourcePaths(
                selector: "TheGuideTests/ExampleTests",
                inventorySHA256: digest,
                inventorySourcePaths: ["Sources/A.swift"]
            ) == ["Sources/A.swift"]
        )
        #expect(throws: PreparedBuildError.selectionMismatch) {
            try manifest.validatedSourcePaths(
                selector: "TheGuideTests/OtherTests",
                inventorySHA256: digest,
                inventorySourcePaths: ["Sources/A.swift"]
            )
        }
    }
}
