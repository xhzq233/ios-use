import Foundation

public struct CLIResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct CLIErrorEnvelope: Equatable, Sendable {
    public let message: String
    public let exitCode: Int32

    public init(message: String, exitCode: Int32 = 64) {
        self.message = message
        self.exitCode = exitCode
    }

    public func render(help: String? = nil) -> CLIResult {
        var stderr = "error: \(message)\n"
        if let help, !help.isEmpty {
            stderr += "\n\(help)"
        }
        return CLIResult(exitCode: exitCode, stderr: stderr)
    }
}
