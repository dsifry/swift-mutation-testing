import Testing

@testable import SwiftMutationTesting

@Suite("PreparedMutantInventory")
struct PreparedMutantInventoryTests {
    @Test("Given full inventory then later-source selection, when filtered, then original IDs are preserved")
    func laterSourceSelectionPreservesFullInventoryIDs() throws {
        let descriptors = [
            makeMutantDescriptor(
                id: "swift-mutation-testing_0",
                filePath: "/repo/Sources/A.swift",
                utf8Offset: 4,
                mutatedText: "false"
            ),
            makeMutantDescriptor(
                id: "swift-mutation-testing_1",
                filePath: "/repo/Sources/Z.swift",
                utf8Offset: 8,
                mutatedText: "true"
            ),
        ]
        let inventory = try PreparedMutantInventory(
            projectRoot: "/repo",
            projectInputManifestSHA256: String(repeating: "a", count: 64),
            mutants: descriptors
        )

        let selected = try inventory.select(
            mutants: descriptors,
            ownedSourcePaths: ["Sources/Z.swift"],
            projectRoot: "/repo"
        )

        #expect(selected.map(\.id) == ["swift-mutation-testing_1"])
    }

    @Test("Given changed full inventory, when validated, then mismatch is rejected")
    func changedInventoryIsRejected() throws {
        let original = [
            makeMutantDescriptor(
                id: "swift-mutation-testing_0",
                filePath: "/repo/Sources/A.swift",
                mutatedText: "false"
            )
        ]
        let inventory = try PreparedMutantInventory(
            projectRoot: "/repo",
            projectInputManifestSHA256: String(repeating: "b", count: 64),
            mutants: original
        )
        let changed = [
            makeMutantDescriptor(
                id: "swift-mutation-testing_0",
                filePath: "/repo/Sources/A.swift",
                mutatedText: "true"
            )
        ]

        #expect(throws: PreparedBuildError.inventoryMismatch) {
            try inventory.validate(mutants: changed, projectRoot: "/repo")
        }
    }

    @Test("Given no owned sources, when selected, then the result is empty")
    func emptyOwnedSourcesSelectNoMutants() throws {
        let descriptors = [
            makeMutantDescriptor(
                id: "swift-mutation-testing_0",
                filePath: "/repo/Sources/A.swift"
            )
        ]
        let inventory = try PreparedMutantInventory(
            projectRoot: "/repo",
            projectInputManifestSHA256: String(repeating: "c", count: 64),
            mutants: descriptors
        )

        #expect(
            try inventory.select(
                mutants: descriptors,
                ownedSourcePaths: [],
                projectRoot: "/repo"
            ).isEmpty
        )
    }
}
