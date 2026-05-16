import XCTest
import IOSUseCLI
import IOSUseProtocol

final class IOSUseCLITests: XCTestCase {
    func testHelpContainsRewriteStatusAndFallbackCommand() {
        let result = IOSUseCLI().run(arguments: ["--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Swift rewrite scaffold"))
        XCTAssertTrue(result.stdout.contains("bun run src/cli.ts <command>"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testVersionMatchesCurrentPackageVersion() {
        let result = IOSUseCLI().run(arguments: ["--version"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "1.0.0\n")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testUnknownOptionFailsBeforeAnySessionWork() {
        let result = IOSUseCLI().run(arguments: ["--not-a-real-option"])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("unknown option '--not-a-real-option'"))
        XCTAssertTrue(result.stdout.isEmpty)
    }

    func testKnownDriverCommandReportsExplicitMigrationBoundary() {
        let result = IOSUseCLI().run(arguments: ["find"])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.stderr.contains("Swift CLI driver command 'find' is not implemented yet"))
        XCTAssertTrue(result.stderr.contains("TypeScript CLI"))
    }

    func testProtocolConstantsMatchDriverDefaults() {
        XCTAssertEqual(IOSUseProtocol.defaultDriverPort, 8100)
        XCTAssertEqual(IOSUseProtocol.maxFrameSizeBytes, 50 * 1024 * 1024)
        XCTAssertEqual(IOSUseProtocol.commandTimeoutSeconds, 45)
        XCTAssertEqual(IOSUseProtocol.commandCompletionTimeoutSeconds, 120)
    }

    func testDriverCommandNamesMatchWireCommands() {
        let commands = Set(DriverCommand.allCases.map(\.rawValue))

        XCTAssertTrue(commands.contains("dom"))
        XCTAssertTrue(commands.contains("find"))
        XCTAssertTrue(commands.contains("waitFor"))
        XCTAssertTrue(commands.contains("dismissAlert"))
        XCTAssertEqual(commands.count, 14)
    }
}
