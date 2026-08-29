import Foundation
import Testing

@testable import SwiftMutationTesting

@Suite("FallbackExecutor")
struct FallbackExecutorTests {
    @Test("Given SPM project type with successful build, when execute called, then results are returned")
    func spmFallbackBuildSuccessReturnsResults() async throws {
        let dir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(dir) }

        let sourceFile = dir.appendingPathComponent("Foo.swift")
        try "let x = true".write(to: sourceFile, atomically: true, encoding: .utf8)

        let config = makeRunnerConfiguration(projectPath: dir.path, projectType: .spm)

        let launcher = MockProcessLauncher(exitCode: 0)
        let deps = makeExecutionDeps(
            launcher: launcher,
            cacheStorePath: dir.appendingPathComponent("cache.json").path
        )

        let pool = makeSimulatorPool()
        try await pool.setUp()

        let mutant = makeMutantDescriptor(
            id: "m0",
            filePath: sourceFile.path,
            originalText: "true",
            mutatedText: "false",
            operatorIdentifier: "BooleanLiteralReplacement",
            replacementKind: .booleanLiteral,
            description: "true → false",
            isSchematizable: true
        )

        let input = makeRunnerInput(
            projectPath: dir.path,
            projectType: .spm,
            schematizedFiles: [
                SchematizedFile(originalPath: sourceFile.path, schematizedContent: "let x = false")
            ],
            mutants: [mutant]
        )

        let executor = FallbackExecutor(deps: deps, configuration: config)
        let results = try await executor.execute(input: input, pool: pool)

        #expect(results.count == 1)
    }

    @Test("Given an unreadable source after schema failure, preserves unviable classification")
    func unreadableSourceRemainsUnviable() async throws {
        let dir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(dir) }

        let missingSource = dir.appendingPathComponent("Missing.swift")
        let mutant = makeMutantDescriptor(
            id: "m0", filePath: missingSource.path, originalText: "true",
            mutatedText: "false", operatorIdentifier: "BooleanLiteralReplacement",
            replacementKind: .booleanLiteral, description: "true to false",
            isSchematizable: true
        )
        let input = makeRunnerInput(
            projectPath: dir.path,
            schematizedFiles: [
                SchematizedFile(
                    originalPath: missingSource.path, schematizedContent: "invalid schema"
                )
            ],
            mutants: [mutant]
        )
        let deps = makeExecutionDeps(
            launcher: MockProcessLauncher(exitCode: 1),
            cacheStorePath: dir.appendingPathComponent("cache.json").path
        )
        let pool = makeSimulatorPool()
        try await pool.setUp()

        let results = try await FallbackExecutor(
            deps: deps,
            configuration: makeRunnerConfiguration(projectPath: dir.path)
        ).execute(input: input, pool: pool)

        #expect(results.map(\.status) == [.unviable])
    }

    @Test("Given one exact and one unrewritable mutant, preserves each classification")
    func mixedExactAndUnrewritableMutants() async throws {
        let dir = try FileHelpers.makeTemporaryDirectory()
        defer { FileHelpers.cleanup(dir) }

        let sourceFile = dir.appendingPathComponent("Foo.swift")
        try "let enabled = true".write(to: sourceFile, atomically: true, encoding: .utf8)
        let exact = makeMutantDescriptor(
            id: "exact", filePath: sourceFile.path, utf8Offset: 14,
            originalText: "true", mutatedText: "false",
            operatorIdentifier: "BooleanLiteralReplacement",
            replacementKind: .booleanLiteral, description: "true to false",
            isSchematizable: true
        )
        let invalid = makeMutantDescriptor(
            id: "invalid", filePath: sourceFile.path, utf8Offset: 99,
            originalText: "true", mutatedText: "false",
            operatorIdentifier: "BooleanLiteralReplacement",
            replacementKind: .booleanLiteral, description: "true to false",
            isSchematizable: true
        )
        let launcher = SchemaFailureThenTestSuccessMock()
        let deps = makeExecutionDeps(
            launcher: launcher,
            cacheStorePath: dir.appendingPathComponent("cache.json").path,
            total: 2
        )
        let pool = makeSimulatorPool()
        try await pool.setUp()

        let results = try await FallbackExecutor(
            deps: deps,
            configuration: makeRunnerConfiguration(projectPath: dir.path)
        ).execute(
            input: makeRunnerInput(
                projectPath: dir.path,
                schematizedFiles: [
                    SchematizedFile(
                        originalPath: sourceFile.path, schematizedContent: "invalid schema"
                    )
                ],
                mutants: [exact, invalid]
            ),
            pool: pool
        )

        #expect(results.map(\.status) == [.unviable, .survived])
    }
}

private actor SchemaFailureThenTestSuccessMock: ProcessLaunching {
    func launch(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL,
        timeout: Double
    ) async throws -> Int32 { 0 }

    func launchCapturing(_ request: ProcessRequest) async throws -> (exitCode: Int32, output: String) {
        if request.executableURL.lastPathComponent == "xcrun" { return (1, "") }
        if request.arguments.first == "build-for-testing" { return (1, "invalid schema") }
        return (0, "")
    }
}
