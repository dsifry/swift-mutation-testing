import Foundation

struct XCResultParser: Sendable {
    enum Result: Sendable {
        case killed(by: String)
        case crashed
    }

    func parse(_ json: String) -> Result {
        guard
            let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let nodes = root["testNodes"] as? [[String: Any]],
            let identifier = firstFailedTestCase(in: nodes)
        else { return .crashed }

        return .killed(by: identifier)
    }

    func parseTerminalSummary(_ json: String) -> Int32? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = root["totalTestCount"] as? Int,
              let passed = root["passedTests"] as? Int,
              let failed = root["failedTests"] as? Int,
              let skipped = root["skippedTests"] as? Int,
              let expectedFailures = root["expectedFailures"] as? Int,
              total > 0,
              total == passed + failed + skipped + expectedFailures,
              let result = root["result"] as? String
        else { return nil }
        if result == "Passed", failed == 0 { return 0 }
        if result == "Failed", failed > 0 { return 1 }
        return nil
    }

    private func firstFailedTestCase(in nodes: [[String: Any]]) -> String? {
        for node in nodes {
            if node["nodeType"] as? String == "Test Case",
                node["result"] as? String == "Failed",
                let identifier = node["nodeIdentifier"] as? String
            {
                return identifier
            }

            if let children = node["children"] as? [[String: Any]],
                let found = firstFailedTestCase(in: children)
            {
                return found
            }
        }

        return nil
    }
}
