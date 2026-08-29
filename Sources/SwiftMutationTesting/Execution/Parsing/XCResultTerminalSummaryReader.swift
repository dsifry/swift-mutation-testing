import Foundation

struct XCResultTerminalSummaryReader: Sendable {
    let launcher: any ProcessLaunching

    init(captureRoot: URL? = nil, launcher: (any ProcessLaunching)? = nil) {
        self.launcher = launcher ?? XcodeProcessLauncher(captureRoot: captureRoot)
    }

    func read(path: String, workingDirectory: URL) async -> Int32? {
        guard FileManager.default.fileExists(atPath: path),
              let summary = try? await launcher.launchCapturing(ProcessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: [
                    "xcresulttool", "get", "test-results", "summary", "--path", path,
                ],
                environment: nil,
                additionalEnvironment: [:],
                workingDirectoryURL: workingDirectory,
                timeout: 2
              )), summary.exitCode == 0
        else { return nil }
        return XCResultParser().parseTerminalSummary(summary.output)
    }
}
