import Foundation
import SwiftParser
import Testing

@testable import SwiftMutationTesting

@Suite("SchemataGenerator")
struct SchemataGeneratorTests {
    private let generator = SchemataGenerator()

    @Test("Given one mutation, when generated, then produces switch with one case and default")
    func oneMutationProducesSwitchWithOneCaseAndDefault() {
        let source = makeParsedSource("func f() { let x = true }")
        let mutations = mutationsWithIndices(source)
        let result = generator.generate(source: source, mutations: mutations)
        #expect(result.contains("switch __swiftMutationTestingID"))
        #expect(result.contains("case \"swift-mutation-testing_0\""))
        #expect(result.contains("default:"))
    }

    @Test("Given mutation, when generated, then mutated text appears in case body")
    func mutatedTextAppearsInCaseBody() {
        let source = makeParsedSource("func f() { let x = true }")
        let mutations = mutationsWithIndices(source)
        let result = generator.generate(source: source, mutations: mutations)
        #expect(result.contains("false"))
    }

    @Test("Given mutation, when generated, then original text appears in default body")
    func originalTextAppearsInDefaultBody() {
        let source = makeParsedSource("func f() { let x = true }")
        let mutations = mutationsWithIndices(source)
        let result = generator.generate(source: source, mutations: mutations)
        #expect(result.contains("true"))
    }

    @Test("Given two mutations in same function, when generated, then produces switch with two cases")
    func twoMutationsInSameFunctionProduceTwoCases() {
        let source = makeParsedSource("func f() { let a = true; let b = false }")
        let mutations = mutationsWithIndices(source)
        let result = generator.generate(source: source, mutations: mutations)
        #expect(result.contains("case \"swift-mutation-testing_0\""))
        #expect(result.contains("case \"swift-mutation-testing_1\""))
    }

    @Test("Given mutations in two functions, when generated, then each function gets its own switch")
    func mutationsInTwoFunctionsEachGetOwnSwitch() {
        let source = makeParsedSource("func f() { let x = true } func g() { let y = false }")
        let mutations = mutationsWithIndices(source)
        let result = generator.generate(source: source, mutations: mutations)
        let switchCount = result.components(separatedBy: "switch __swiftMutationTestingID").count - 1
        #expect(switchCount == 2)
    }

    @Test("Given generated content, when checked, then does not declare __swiftMutationTestingID")
    func schematizedContentDoesNotDeclareIDVariable() {
        let source = makeParsedSource("func f() { let x = true }")
        let mutations = mutationsWithIndices(source)
        let result = generator.generate(source: source, mutations: mutations)
        #expect(!result.contains("var __swiftMutationTestingID"))
    }

    @Test("Given no mutations in function, when generated, then returns original content unchanged")
    func emptyMutationsReturnsOriginalContent() {
        let source = makeParsedSource("func f() { let x = 1 }")
        let result = generator.generate(source: source, mutations: [])
        #expect(result == source.file.content)
    }

    @Test("Given mutation uses correct mutant ID format, when generated, then ID matches swift-mutation-testing prefix")
    func mutantIDUsesCorrectFormat() {
        let source = makeParsedSource("func f() { let x = true }")
        let mutations = mutationsWithIndices(source, startIndex: 5)
        let result = generator.generate(source: source, mutations: mutations)
        #expect(result.contains("swift-mutation-testing_5"))
    }

    @Test("Given mutation at file scope, when generated, then returns original content unchanged")
    func mutationAtFileScopeIsSkipped() {
        let source = makeParsedSource("let x = true")
        let mutations = mutationsWithIndices(source)
        #expect(!mutations.isEmpty)
        let result = generator.generate(source: source, mutations: mutations)
        #expect(result == source.file.content)
    }

    @Test("Given generated content, when parsed by SwiftSyntax, then has no syntax errors")
    func generatedContentIsParseableBySwiftSyntax() {
        let source = makeParsedSource("func f() { let x = true; let y = false }")
        let mutations = mutationsWithIndices(source)
        let result = generator.generate(source: source, mutations: mutations)
        #expect(!Parser.parse(source: result).hasError)
    }

    @Test("Given an implicit getter mutation, when generated, then the getter contains a parseable schema")
    func implicitGetterProducesParseableSchema() {
        let source = makeParsedSource("struct S { var enabled: Bool { true || false } }")
        let result = generator.generate(source: source, mutations: mutationsWithIndices(source))

        #expect(result.contains("case \"swift-mutation-testing_0\""))
        #expect(!Parser.parse(source: result).hasError)
        #expect(typeCheck(result) == 0)
    }

    @Test("Given a file-scope closure mutation, when generated, then the closure contains a parseable schema")
    func fileScopeClosureProducesParseableSchema() {
        let source = makeParsedSource("let enabled = { true || false }")
        let result = generator.generate(source: source, mutations: mutationsWithIndices(source))

        #expect(result.contains("case \"swift-mutation-testing_0\""))
        #expect(!Parser.parse(source: result).hasError)
        #expect(typeCheck(result) == 0)
    }

    private func typeCheck(_ source: String) -> Int32 {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let input = directory.appendingPathComponent("Generated.swift")
            try ("let __swiftMutationTestingID = \"\"\n" + source).write(
                to: input, atomically: true, encoding: .utf8
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["swiftc", "-typecheck", input.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
