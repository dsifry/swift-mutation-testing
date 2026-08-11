import Foundation

struct PreparedBuildState: Codable, Equatable, Sendable {
    let sandboxPath: String
    let derivedDataPath: String
    let xctestrunPath: String
    let inventory: PreparedMutantInventory
}

struct PreparedBuildStore: Sendable {
    init(root: String, compatibilityID: String) {
        directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(compatibilityID, isDirectory: true)
    }

    let directory: URL

    var stateURL: URL { directory.appendingPathComponent("prepared-build.json") }
    var sandboxURL: URL { directory.appendingPathComponent("sandbox", isDirectory: true) }
    var derivedDataURL: URL { directory.appendingPathComponent("DerivedData", isDirectory: true) }

    func reset() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func save(_ state: PreparedBuildState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    func load() throws -> PreparedBuildState {
        guard let data = try? Data(contentsOf: stateURL),
            let state = try? JSONDecoder().decode(PreparedBuildState.self, from: data)
        else { throw PreparedBuildError.preparedBuildMissing }
        return state
    }
}
