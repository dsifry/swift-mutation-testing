import Foundation

struct ProcessRequest: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]?
    let additionalEnvironment: [String: String]
    let workingDirectoryURL: URL
    let timeout: Double
    let terminalResultProbe: (@Sendable () async -> Int32?)?
    let terminalResultGrace: Double

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        additionalEnvironment: [String: String],
        workingDirectoryURL: URL,
        timeout: Double,
        terminalResultProbe: (@Sendable () async -> Int32?)? = nil,
        terminalResultGrace: Double = 2
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.additionalEnvironment = additionalEnvironment
        self.workingDirectoryURL = workingDirectoryURL
        self.timeout = timeout
        self.terminalResultProbe = terminalResultProbe
        self.terminalResultGrace = terminalResultGrace
    }
}
