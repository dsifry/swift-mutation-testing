import Foundation
import Testing

@testable import SwiftMutationTesting

@Suite("XCResultParser")
struct XCResultParserTests {

    @Test("Complete terminal summary is authoritative only when every test is accounted for")
    func terminalSummaryRequiresCompleteAccounting() {
        let parser = XCResultParser()
        #expect(parser.parseTerminalSummary("""
        {"totalTestCount":72,"passedTests":71,"failedTests":1,"skippedTests":0,"expectedFailures":0,"result":"Failed"}
        """) == 1)
        #expect(parser.parseTerminalSummary("""
        {"totalTestCount":72,"passedTests":70,"failedTests":1,"skippedTests":0,"expectedFailures":0,"result":"Failed"}
        """) == nil)
        #expect(parser.parseTerminalSummary("{\"result\":\"Failed\"}") == nil)
        #expect(parser.parseTerminalSummary("""
        {"totalTestCount":72,"passedTests":72,"failedTests":0,"skippedTests":0,"expectedFailures":0,"result":"Passed"}
        """) == 0)
        #expect(parser.parseTerminalSummary("""
        {"totalTestCount":72,"passedTests":72,"failedTests":0,"skippedTests":0,"expectedFailures":0,"result":"Failed"}
        """) == nil)
    }

    @Test("Terminal summary reader rejects missing and failed evidence and parses complete evidence")
    func terminalSummaryReaderFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = root.appendingPathComponent("result.xcresult")

        #expect(await XCResultTerminalSummaryReader(
            launcher: MockProcessLauncher(exitCode: 0)
        ).read(path: result.path, workingDirectory: root) == nil)
        #expect(await XCResultTerminalSummaryReader().read(
            path: result.path + ".missing", workingDirectory: root
        ) == nil)
        try Data().write(to: result)
        let complete = """
        {"totalTestCount":1,"passedTests":0,"failedTests":1,"skippedTests":0,"expectedFailures":0,"result":"Failed"}
        """
        #expect(await XCResultTerminalSummaryReader(
            launcher: MockProcessLauncher(exitCode: 0, output: complete)
        ).read(path: result.path, workingDirectory: root) == 1)
        #expect(await XCResultTerminalSummaryReader(
            launcher: MockProcessLauncher(exitCode: 2, output: complete)
        ).read(path: result.path, workingDirectory: root) == nil)
        #expect(await XCResultTerminalSummaryReader(
            launcher: MockProcessLauncher(exitCode: 0, throwsOnCapture: true)
        ).read(path: result.path, workingDirectory: root) == nil)
    }
    @Test("Given test-results JSON with failed test case, when parsed, then returns killed with nodeIdentifier")
    func parsesFailedTestCase() {
        let json = """
            {
              "testNodes": [
                {
                  "nodeType": "Test Suite",
                  "name": "MySuite",
                  "result": "Failed",
                  "children": [
                    {
                      "nodeType": "Test Case",
                      "name": "myTest()",
                      "nodeIdentifier": "MySuite/myTest()",
                      "result": "Failed"
                    }
                  ]
                }
              ]
            }
            """

        let result = XCResultParser().parse(json)

        guard case .killed(let name) = result else {
            Issue.record("Expected .killed but got \(result)")
            return
        }
        #expect(name == "MySuite/myTest()")
    }

    @Test("Given test-results JSON with deeply nested failed test case, when parsed, then returns killed")
    func parsesDeeplyNestedFailedTestCase() {
        let json = """
            {
              "testNodes": [
                {
                  "nodeType": "Unit test bundle",
                  "name": "MyTests",
                  "result": "Failed",
                  "children": [
                    {
                      "nodeType": "Test Suite",
                      "name": "MySuite",
                      "result": "Failed",
                      "children": [
                        {
                          "nodeType": "Test Case",
                          "name": "myTest()",
                          "nodeIdentifier": "MySuite/myTest()",
                          "result": "Failed"
                        }
                      ]
                    }
                  ]
                }
              ]
            }
            """

        let result = XCResultParser().parse(json)

        guard case .killed(let name) = result else {
            Issue.record("Expected .killed but got \(result)")
            return
        }
        #expect(name == "MySuite/myTest()")
    }

    @Test("Given test-results JSON with no failed test cases, when parsed, then returns crashed")
    func parsesNoFailuresAsCrashed() {
        let json = """
            {
              "testNodes": [
                {
                  "nodeType": "Test Suite",
                  "name": "MySuite",
                  "result": "Passed"
                }
              ]
            }
            """

        let result = XCResultParser().parse(json)

        #expect(result == .crashed)
    }

    @Test("Given JSON missing testNodes, when parsed, then returns crashed")
    func parsesMissingTestNodesAsCrashed() {
        let result = XCResultParser().parse("{}")

        #expect(result == .crashed)
    }

    @Test("Given malformed JSON, when parsed, then returns crashed")
    func parsesMalformedJSONAsCrashed() {
        let result = XCResultParser().parse("not json")

        #expect(result == .crashed)
    }
}
