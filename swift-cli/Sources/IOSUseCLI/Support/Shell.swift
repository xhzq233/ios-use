import Foundation

enum Shell {
    struct RunResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    static var runOverrideForTesting: ((String, [String], String?, Bool) throws -> String)?
    static var runResultOverrideForTesting: ((String, [String], String?) throws -> RunResult)?

    static func run(_ executable: String, arguments: [String], cwd: String? = nil) throws -> String {
        try runCaptured(executable, arguments: arguments, cwd: cwd, combineStderr: false)
    }

    static func runCombined(_ executable: String, arguments: [String], cwd: String? = nil) throws -> String {
        try runCaptured(executable, arguments: arguments, cwd: cwd, combineStderr: true)
    }

    static func runWithResult(_ executable: String, arguments: [String], cwd: String? = nil) throws -> RunResult {
        if let override = runResultOverrideForTesting {
            return try override(executable, arguments, cwd)
        }
        return try runCapturedWithResult(executable, arguments: arguments, cwd: cwd)
    }

    static func runData(_ executable: String, arguments: [String], cwd: String? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stdoutURL = tempDir.appendingPathComponent("stdout")
        let stderrURL = tempDir.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let error = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        if process.terminationStatus != 0 {
            throw CLIParseError.invalidValue(error.isEmpty ? "\(executable) failed with exit \(process.terminationStatus)" : error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (try? Data(contentsOf: stdoutURL)) ?? Data()
    }

    static func runInheriting(_ executable: String, arguments: [String], cwd: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw CLIParseError.invalidValue("\(executable) failed with exit \(process.terminationStatus)")
        }
    }

    private static func runCaptured(_ executable: String, arguments: [String], cwd: String?, combineStderr: Bool) throws -> String {
        if let runOverrideForTesting {
            return try runOverrideForTesting(executable, arguments, cwd, combineStderr)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stdoutURL = tempDir.appendingPathComponent("stdout")
        let stderrURL = tempDir.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        var output = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let error = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        if combineStderr {
            output += error
        }
        if process.terminationStatus != 0 {
            throw CLIParseError.invalidValue(error.isEmpty ? "\(executable) failed with exit \(process.terminationStatus)" : error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private static func runCapturedWithResult(_ executable: String, arguments: [String], cwd: String?) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stdoutURL = tempDir.appendingPathComponent("stdout")
        let stderrURL = tempDir.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let out = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return RunResult(stdout: out, stderr: err, exitCode: process.terminationStatus)
    }
}
