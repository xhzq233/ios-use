import XCTest
@testable import IOSUseCLI

final class UpdateReminderTests: XCTestCase {
    private var directory: URL!
    private var paths: IOSUsePaths!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let newer = UpdateReminderService.Release(tag_name: "v99.0.0", prerelease: false, draft: false)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": directory.path])
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testStableReleaseComparisonUsesNumericComponentsAndPrereleaseOrdering() {
        XCTAssertTrue(UpdateReminderService.isNewerStableRelease("v2.10.0", than: "2.9.9"))
        XCTAssertTrue(UpdateReminderService.isNewerStableRelease("v2.1.0", than: "2.1.0-alpha.12"))
        XCTAssertFalse(UpdateReminderService.isNewerStableRelease("v2.1.0", than: "2.1.0"))
        XCTAssertFalse(UpdateReminderService.isNewerStableRelease("v2.0.9", than: "2.1.0"))
        XCTAssertFalse(UpdateReminderService.isNewerStableRelease("v2.2.0-alpha.1", than: "2.1.0"))
        for tag in ["", "latest", "v2.1", "v2.1.-1", "v2.1.2;echo", "v2.1.2+build"] {
            XCTAssertFalse(UpdateReminderService.isNewerStableRelease(tag, than: "2.1.0"))
        }
    }

    func testDailyLimitPersistsAcrossInvocationsAndExpires() throws {
        var checks = 0
        let fetch = { self.newerChecked(&checks) }
        XCTAssertNotNil(reminder(fetch: fetch))
        XCTAssertNil(reminder(now: now.addingTimeInterval(60), fetch: fetch))
        XCTAssertEqual(checks, 1)
        let cache = try JSONDecoder().decode(UpdateReminderService.Cache.self, from: Data(contentsOf: URL(fileURLWithPath: paths.updateReminderCache)))
        XCTAssertEqual(cache.checkedAt, now)
        XCTAssertEqual(cache.remindedAt, now)
        XCTAssertNotNil(reminder(now: now.addingTimeInterval(UpdateReminderService.checkInterval), fetch: fetch))
        XCTAssertEqual(checks, 2)
    }

    func testAutomationHelpAndFailedCommandsSkipNetworkAndCache() {
        var checks = 0
        let fetch = { self.newerChecked(&checks) }
        XCTAssertNil(reminder(arguments: ["status", "--json"], fetch: fetch))
        XCTAssertNil(reminder(arguments: ["--json", "status"], fetch: fetch))
        XCTAssertNil(reminder(arguments: ["status", "--help"], fetch: fetch))
        XCTAssertNil(reminder(arguments: ["--version"], fetch: fetch))
        XCTAssertNil(reminder(arguments: ["dom"], fetch: fetch))
        XCTAssertNil(reminder(result: CLIResult(exitCode: 1), fetch: fetch))
        XCTAssertNil(reminder(environment: ["CI": "true"], fetch: fetch))
        XCTAssertNil(reminder(interactive: false, fetch: fetch))
        XCTAssertEqual(checks, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testOfflineFailuresAreThrottledAndLeaveCommandResultUntouched() throws {
        var checks = 0
        let result = CLIResult(exitCode: 0, stdout: "command result\n", stderr: "existing warning\n")
        let fetch: () throws -> UpdateReminderService.Release = {
            checks += 1
            throw URLError(.timedOut)
        }
        XCTAssertNil(reminder(result: result, fetch: fetch))
        XCTAssertNil(reminder(result: result, now: now.addingTimeInterval(60), fetch: fetch))
        XCTAssertEqual(checks, 1)
        let cache = try JSONDecoder().decode(UpdateReminderService.Cache.self, from: Data(contentsOf: URL(fileURLWithPath: paths.updateReminderCache)))
        XCTAssertEqual(cache.checkedAt, now)
        XCTAssertNil(cache.remindedAt)
    }

    func testPrereleaseAndDraftResponsesDoNotProduceReminders() {
        XCTAssertNil(reminder(fetch: {
            UpdateReminderService.Release(tag_name: "v99.0.0", prerelease: true, draft: false)
        }))
        XCTAssertNil(reminder(now: now.addingTimeInterval(UpdateReminderService.checkInterval), fetch: {
            UpdateReminderService.Release(tag_name: "v99.0.0", prerelease: false, draft: true)
        }))
    }

    func testReadOnlyHomeSkipsNetworkInsteadOfCheckingEveryInvocation() throws {
        try Data().write(to: directory)
        var checks = 0
        XCTAssertNil(reminder(fetch: { self.newerChecked(&checks) }))
        XCTAssertEqual(checks, 0)
    }

    private func newerChecked(_ checks: inout Int) -> UpdateReminderService.Release {
        checks += 1
        return newer
    }

    private func reminder(
        arguments: [String] = ["status"], result: CLIResult = CLIResult(exitCode: 0),
        environment: [String: String] = [:], interactive: Bool = true,
        now: Date? = nil, fetch: () throws -> UpdateReminderService.Release
    ) -> String? {
        UpdateReminderService.reminder(arguments: arguments, result: result, paths: paths,
            environment: environment, interactive: interactive, now: now ?? self.now, fetch: fetch)
    }
}
