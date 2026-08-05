import Foundation
import XCTest
@testable import IOSUseCLI

final class ShellTests: XCTestCase {
    func testAbsoluteExecutableRunsDirectlyWithOriginalArguments() {
        let process = Process()

        Shell.configureExecutable(
            process,
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--strict", "Demo.app"]
        )

        XCTAssertEqual(process.executableURL?.path, "/usr/bin/codesign")
        XCTAssertEqual(process.arguments, ["--verify", "--strict", "Demo.app"])
    }

    func testBareExecutableUsesEnvForPathLookup() {
        let process = Process()

        Shell.configureExecutable(
            process,
            executable: "codesign",
            arguments: ["--verify", "--strict", "Demo.app"]
        )

        XCTAssertEqual(process.executableURL?.path, "/usr/bin/env")
        XCTAssertEqual(
            process.arguments,
            ["codesign", "--verify", "--strict", "Demo.app"]
        )
    }

    func testRunWithResultPreservesEnvironmentCurrentDirectoryAndExitOutput() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-shell-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let result = try Shell.runWithResult(
            "/bin/sh",
            arguments: [
                "-c",
                "printf '%s' \"$SHELL_TEST_VALUE\"; printf '%s' \"$PWD\" >&2; exit 23"
            ],
            cwd: temporaryDirectory.path,
            environment: ["SHELL_TEST_VALUE": "kept"]
        )

        XCTAssertEqual(result.stdout, "kept")
        XCTAssertEqual(
            URL(fileURLWithPath: result.stderr).resolvingSymlinksInPath(),
            temporaryDirectory.resolvingSymlinksInPath()
        )
        XCTAssertEqual(result.exitCode, 23)
    }
}
