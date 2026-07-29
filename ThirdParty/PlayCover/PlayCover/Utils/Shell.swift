//
//  Shell.swift
//  PlayCover
//

import Foundation
import AppKit

public enum Shell {
    @discardableResult
    public static func run(print: Bool = true, _ binary: String, _ args: String...) throws -> String {
        let process = Process()
        let pipe = Pipe()
        let invocation = anchoredInvocation(arguments: args)

        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.currentDirectory
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
        if print {
            Swift.print(String(data: output, encoding: .utf8) ?? "Shell error occured")
        }

        process.waitUntilExit()
        let status = process.terminationStatus
        if status != 0 {
            throw String(data: output, encoding: .utf8) ?? "Shell error occured"
        }
        return String(data: output, encoding: .utf8) ?? "Shell error occured"
    }

    private static func anchoredInvocation(
        arguments: [String]
    ) -> (arguments: [String], currentDirectory: URL?) {
        guard let root = arguments.lazy.compactMap({
            stableVolumeRoot(containing: $0)
        }).first else {
            return (arguments, nil)
        }
        let rewritten = arguments.map { argument -> String in
            if argument == root {
                return "."
            }
            guard argument.hasPrefix(root + "/") else {
                return argument
            }
            return String(argument.dropFirst(root.count + 1))
        }
        return (
            rewritten,
            URL(fileURLWithPath: root, isDirectory: true)
        )
    }

    private static func stableVolumeRoot(
        containing argument: String
    ) -> String? {
        guard argument.hasPrefix("/.vol/") else {
            return nil
        }
        let components = argument.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        guard components.count >= 3,
              components[0] == ".vol",
              components[1].allSatisfy(\.isNumber),
              components[2].allSatisfy(\.isNumber) else {
            return nil
        }
        return "/.vol/\(components[1])/\(components[2])"
    }

    public static func runSu(_ args: [String], _ argc: String) -> Bool {
        let password = argc
        let passwordWithNewline = password + "\n"
        let sudo = Process()
        sudo.launchPath = "/usr/bin/sudo"
        sudo.arguments = args
        let sudoIn = Pipe()
        let sudoOut = Pipe()
        sudo.standardOutput = sudoOut
        sudo.standardError = sudoOut
        sudo.standardInput = sudoIn
        sudo.launch()

        var result = true

        // Show the output as it is produced
        sudoOut.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.count == 0 { return }

            if let out = String(bytes: data, encoding: .utf8) {
                Swift.print(out)
                if out.contains("password") {
                    result = false
                }
            }
        }
        if let data = passwordWithNewline.data(using: .utf8) {
            // Write the password
            sudoIn.fileHandleForWriting.write(data)

            // Close the file handle after writing the password; avoids a
            // hang for incorrect password.
            try? sudoIn.fileHandleForWriting.close()
        }

        // Make sure we don't disappear while output is still being produced.
        sudo.waitUntilExit()
        return result
    }

    public static func signMacho(_ binary: URL) throws {
        try run("/usr/bin/codesign", "-fs-", binary.path)
    }

    public static func signMacho(
        _ binary: URL,
        identity: String
    ) throws {
        try run(
            "/usr/bin/codesign",
            "--force",
            "--sign",
            identity,
            "--timestamp=none",
            binary.path
        )
    }

    public static func signAppWith(_ app: URL, entitlements: URL) throws {
        try run("/usr/bin/codesign", "-fs-", app.path,
                "--entitlements", entitlements.path)
    }

    public static func signAppWith(
        _ app: URL,
        entitlements: URL,
        identity: String
    ) throws {
        try run(
            "/usr/bin/codesign",
            "--force",
            "--sign",
            identity,
            "--timestamp=none",
            app.path,
            "--entitlements",
            entitlements.path
        )
    }

    /// Exact pinned `Shell.signAppWith` arguments for the independent oracle.
    ///
    /// The ios-use production engine never calls this helper.
    public static func signAppWithPinnedOracle(
        _ app: URL,
        entitlements: URL
    ) throws {
        try run(
            "/usr/bin/codesign",
            "-fs-",
            app.path,
            "--deep",
            "--entitlements",
            entitlements.path
        )
    }

    /// Pinned PlayCover semantics used by `PlayTools.installInIPA`.
    ///
    /// The ios-use prepare engine never calls this helper; it signs its
    /// managed app explicitly inside-out.
    public static func signApp(_ exec: URL) throws {
        try run(
            "/usr/bin/codesign",
            "-fs-",
            exec.deletingLastPathComponent().path,
            "--deep",
            "--preserve-metadata=entitlements"
        )
    }

    static func setMetalHUD(_ bundleID: String, enabled: Bool) throws {
        try run("/usr/bin/defaults", "write", bundleID,
                      "MetalForceHudEnabled", "-bool", String(enabled))
    }

    static func lldb(_ url: URL, withTerminalWindow: Bool = false) throws {
        Task(priority: .utility) {
            if withTerminalWindow {
                let escapedPath = url.path
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let command = "/usr/bin/lldb -o run \"\(escapedPath)\" -o exit"
                    .replacingOccurrences(of: "\\", with: "\\\\")
                let osascript = """
                    tell app "Terminal"
                        reopen
                        activate
                        do script "\(command)"
                    end tell
                """
                let appleScript = NSAppleScript(source: osascript)
                var possibleError: NSDictionary?
                appleScript?.executeAndReturnError(&possibleError)

                if let error = possibleError {
                    for key in error.allKeys {
                        if let key = key as? String {
                            throw error.value(forKey: key).debugDescription
                        }
                    }
                }
            } else {
                try run("/usr/bin/lldb", "-o", "run", url.path, "-o", "exit")
            }
        }
    }
}

extension Swift.String: Swift.Error { }

extension Swift.String: Foundation.LocalizedError {
    public var errorDescription: String? { self }
}
