import CryptoKit
import Darwin
import Foundation

struct ProjectInputManifest: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let path: String
        let mode: Int
        let byteSize: Int
        let sha256: String
        let deterministicMTime: Int64
    }

    let schemaVersion: Int
    let entries: [Entry]

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func deterministicMTime(forSHA256 digest: String) -> Int64 {
        let prefix = UInt64(digest.prefix(12), radix: 16) ?? 0
        return 946_684_800 + Int64(prefix % 946_684_800)
    }
}

struct ProjectInputMaterializer: Sendable {
    let sourceRoot: URL
    let identityDirectory: URL
    let collectionRoot: URL
    var createOutputFile: @Sendable (String, Data, Int) -> Bool = { path, data, mode in
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: mode])
    }
    var outputFileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    var didPrepareOutputDirectory: @Sendable (URL) -> Void = { _ in }

    func materialize(
        manifestAt manifestURL: URL,
        schematizedFiles: [SchematizedFile] = [],
        supportFileContent: String = ""
    ) throws -> URL {
        try CachePathGuard.validateDirectory(collectionRoot, containedIn: collectionRoot)
        try CachePathGuard.validateDirectory(identityDirectory, containedIn: collectionRoot)
        let sourceIdentity = try directoryIdentity(at: sourceRoot)
        let manifest = try loadManifest(at: manifestURL)
        try validate(manifest)

        let projectURL = identityDirectory.appendingPathComponent("project", isDirectory: true)
        if FileManager.default.fileExists(atPath: projectURL.path) {
            try validateRemovableProject(projectURL)
            try FileManager.default.removeItem(at: projectURL)
        }
        try makePrivateDirectory(projectURL)

        do {
            var overrides = try schematizedOverrides(schematizedFiles)
            var preparedOutputDirectories: Set<String> = []
            for entry in manifest.entries {
                try assertDirectoryIdentity(sourceIdentity, at: sourceRoot)
                let sourceURL = sourceRoot.appendingPathComponent(entry.path)
                let data = try authenticatedRead(sourceURL, entry: entry)
                try assertDirectoryIdentity(sourceIdentity, at: sourceRoot)
                let output = projectURL.appendingPathComponent(entry.path)
                let outputDirectory = output.deletingLastPathComponent()
                let relativeOutputDirectory = (entry.path as NSString).deletingLastPathComponent
                if preparedOutputDirectories.insert(relativeOutputDirectory).inserted {
                    try makePrivateDirectory(outputDirectory)
                    didPrepareOutputDirectory(outputDirectory)
                }
                let materialized =
                    overrides.removeValue(forKey: entry.path)
                    .map { Data(fixEmptySwitchCaseBodies($0).utf8) } ?? data
                guard createOutputFile(output.path, materialized, entry.mode) else {
                    throw PreparedCacheError.unsafeCachePath
                }
                chmod(output.path, mode_t(entry.mode))
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: TimeInterval(entry.deterministicMTime))],
                    ofItemAtPath: output.path
                )
            }
            try Self.requireNoUnusedOverrides(overrides)
            try injectSupportFile(
                supportFileContent,
                into: projectURL,
                schematizedFiles: schematizedFiles,
                manifest: manifest
            )
            return projectURL
        } catch {
            try? FileManager.default.removeItem(at: projectURL)
            throw error
        }
    }

    private func loadManifest(at url: URL) throws -> ProjectInputManifest {
        do {
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(root.keys) == ["schemaVersion", "entries"],
                let entries = root["entries"] as? [[String: Any]],
                entries.allSatisfy({ Set($0.keys) == ["path", "mode", "byteSize", "sha256", "deterministicMTime"] })
            else { throw PreparedCacheError.invalidProjectInputManifest }
            return try JSONDecoder().decode(ProjectInputManifest.self, from: data)
        } catch let error as PreparedCacheError {
            throw error
        } catch {
            throw PreparedCacheError.invalidProjectInputManifest
        }
    }

    private func validate(_ manifest: ProjectInputManifest) throws {
        guard manifest.schemaVersion == 1, !manifest.entries.isEmpty else {
            throw PreparedCacheError.invalidProjectInputManifest
        }
        var prior: String?
        for entry in manifest.entries {
            guard isSafeRelativePath(entry.path),
                !Self.isForbidden(entry.path),
                prior.map({ $0 < entry.path }) ?? true,
                entry.mode == 0o600 || entry.mode == 0o644 || entry.mode == 0o700 || entry.mode == 0o755,
                entry.byteSize >= 0,
                CachePathGuard.isLowercaseHexDigest(entry.sha256),
                entry.deterministicMTime == ProjectInputManifest.deterministicMTime(forSHA256: entry.sha256)
            else { throw PreparedCacheError.invalidProjectInputManifest }
            if let sourceMetadata = metadata(at: sourceRoot.appendingPathComponent(entry.path)),
                sourceMetadata.st_mode & S_IFMT == S_IFLNK
            {
                throw PreparedCacheError.invalidProjectInputManifest
            }
            do {
                try CachePathGuard.validateNoSymlinkComponents(
                    sourceRoot.appendingPathComponent(entry.path),
                    containedIn: sourceRoot
                )
            } catch {
                throw PreparedCacheError.invalidProjectInputManifest
            }
            prior = entry.path
        }
    }

    private func authenticatedRead(_ url: URL, entry: ProjectInputManifest.Entry) throws -> Data {
        try Self.validateAuthenticatedSourcePath(url, sourceRoot: sourceRoot)
        guard CachePathGuard.isContained(url, in: sourceRoot), let before = metadata(at: url),
            before.st_uid == getuid(), before.st_mode & S_IFMT == S_IFREG,
            before.st_mode & 0o777 == mode_t(entry.mode), before.st_nlink == 1,
            before.st_size == entry.byteSize
        else { throw PreparedCacheError.projectInputDrift }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let after = metadata(at: url), sameFile(before, after), data.count == entry.byteSize,
            ProjectInputManifest.sha256(data) == entry.sha256
        else { throw PreparedCacheError.projectInputDrift }
        return data
    }

    static func validateAuthenticatedSourcePath(
        _ url: URL,
        sourceRoot: URL,
        validator: (URL, URL) throws -> Void = { try CachePathGuard.validateNoSymlinkComponents($0, containedIn: $1) }
    ) throws {
        do { try validator(url, sourceRoot) } catch { throw PreparedCacheError.projectInputDrift }
    }

    private func schematizedOverrides(_ files: [SchematizedFile]) throws -> [String: String] {
        var result: [String: String] = [:]
        let root = sourceRoot.standardizedFileURL.path
        for file in files {
            let absolute = URL(fileURLWithPath: file.originalPath).standardizedFileURL.path
            guard absolute.hasPrefix(root + "/") else { throw PreparedCacheError.invalidProjectInputManifest }
            let relative = String(absolute.dropFirst(root.count + 1))
            guard isSafeRelativePath(relative), result.updateValue(file.schematizedContent, forKey: relative) == nil
            else {
                throw PreparedCacheError.invalidProjectInputManifest
            }
        }
        return result
    }

    private func injectSupportFile(
        _ content: String,
        into projectURL: URL,
        schematizedFiles: [SchematizedFile],
        manifest: ProjectInputManifest
    ) throws {
        guard !content.isEmpty, let first = schematizedFiles.first else { return }
        let root = sourceRoot.standardizedFileURL.path
        let original = URL(fileURLWithPath: first.originalPath).standardizedFileURL.path
        let relative = String(original.dropFirst(root.count + 1))
        let target = projectURL.appendingPathComponent(relative)
        guard outputFileExists(target.path), let entry = manifest.entries.first(where: { $0.path == relative }) else {
            throw PreparedCacheError.invalidProjectInputManifest
        }
        let computed =
            "var __swiftMutationTestingID: String {\n    ProcessInfo.processInfo.environment[\"__SWIFT_MUTATION_TESTING_ACTIVE\"] ?? \"\"\n}"
        let stored =
            "nonisolated(unsafe) var __swiftMutationTestingID: String = ProcessInfo.processInfo.environment[\"__SWIFT_MUTATION_TESTING_ACTIVE\"] ?? \"\""
        let adjusted = content.replacingOccurrences(of: computed, with: stored)
        let existing = try String(contentsOf: target, encoding: .utf8)
        try (existing + "\n" + adjusted).write(to: target, atomically: true, encoding: .utf8)
        chmod(target.path, mode_t(entry.mode))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: TimeInterval(entry.deterministicMTime))],
            ofItemAtPath: target.path
        )
    }

    private func validateRemovableProject(_ url: URL) throws {
        try CachePathGuard.validateDirectory(url, containedIn: identityDirectory)
        try CachePathGuard.validateOwnedTree(url, containedIn: identityDirectory)
    }

    private func makePrivateDirectory(_ url: URL) throws {
        let identityPath = CachePathGuard.lexicalPath(identityDirectory)
        let targetPath = CachePathGuard.lexicalPath(url)
        var current = identityDirectory
        let relative = String(targetPath.dropFirst(identityPath.count + 1))
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            if FileManager.default.fileExists(atPath: current.path) {
                try CachePathGuard.validateDirectory(current, containedIn: identityDirectory)
            } else {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
                chmod(current.path, 0o700)
                try CachePathGuard.validateDirectory(current, containedIn: identityDirectory)
            }
        }
    }

    private func directoryIdentity(at url: URL) throws -> stat {
        guard let value = metadata(at: url), value.st_uid == getuid(), value.st_mode & S_IFMT == S_IFDIR else {
            throw PreparedCacheError.unsafeCachePath
        }
        return value
    }

    func assertDirectoryIdentity(_ expected: stat, at url: URL) throws {
        guard let current = metadata(at: url), sameFile(expected, current) else {
            throw PreparedCacheError.projectInputDrift
        }
    }

    private func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private func metadata(at url: URL) -> stat? {
        var value = stat()
        return lstat(url.path, &value) == 0 ? value : nil
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
            (path as NSString).standardizingPath == path
        else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            $0 != "." && $0 != ".." && !$0.isEmpty
        }
    }

    static func isForbidden(_ path: String) -> Bool {
        let components = path.lowercased().split(separator: "/").map(String.init)
        let forbiddenComponents: Set<String> = [
            ".git", ".build", "deriveddata", ".env", ".ssh", ".gnupg", ".aws", "keychains",
            "xcuserdata", "provisioning profiles",
        ]
        if components.contains(where: forbiddenComponents.contains) { return true }
        guard let name = components.last else { return true }
        return name.hasSuffix(".mobileprovision") || name.hasSuffix(".provisionprofile")
            || name.hasSuffix(".p12") || name.hasSuffix(".pfx") || name.hasSuffix(".key")
            || name.hasSuffix(".pem") || name.hasSuffix(".cer") || name.hasSuffix(".p8")
            || name.hasSuffix(".keychain") || name.hasSuffix(".keychain-db")
    }

    static func requireNoUnusedOverrides(_ overrides: [String: String]) throws {
        if !overrides.isEmpty {
            throw PreparedCacheError.invalidProjectInputManifest
        }
    }

    private func fixEmptySwitchCaseBodies(_ content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var output: [String] = []
        for index in lines.indices {
            output.append(lines[index])
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case \""), trimmed.hasSuffix(":") else { continue }
            let next = lines[(index + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
                .trimmingCharacters(in: .whitespaces)
            guard let next, next.hasPrefix("case ") || next.hasPrefix("default") || next == "}" else { continue }
            output.append(String(lines[index].prefix { $0 == " " || $0 == "\t" }) + "    break")
        }
        return output.joined(separator: "\n")
    }
}
