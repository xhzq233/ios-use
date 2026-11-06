import XCTest
@testable import SelfRunnerCore

final class ScriptTests: XCTestCase {
    func testNestedRepeatsPreserveOrderAndStopOnFirstFailure() throws {
        let script = try Script.parse(Data(#"{"name":"flow","steps":[{"count":2,"steps":[{"command":"home"},{"command":"dom"}]}]}"#.utf8))
        var calls = [String](), reports = [Bool]()
        XCTAssertThrowsError(try ScriptExecutor.run(script, cancellation: ScriptCancellation(), execute: { command, _ in
            calls.append(command)
            if calls.count == 3 { throw ScriptFailure("failed") }
            return [:]
        }, report: { _, _, result in reports.append((try? result.get()) != nil) }))
        XCTAssertEqual(calls, ["home", "dom", "home"])
        XCTAssertEqual(reports, [true, true, false])
    }
    func testExpansionBudgetAndMalformedRepeatAreRejectedBeforeActions() {
        for json in [#"{"name":"x","steps":[{"count":100,"steps":[{"count":100,"steps":[{"command":"home"}]}]}]}"#,
                     #"{"name":"x","steps":[{"command":"home","count":2}]}"#,
                     #"{"name":"x","steps":[{"command":"sleep","args":{"seconds":-1}}]}"#] {
            XCTAssertThrowsError(try Script.parse(Data(json.utf8)))
        }
    }
    func testCancellationPreventsFollowingActions() throws {
        let script = try Script.parse(Data(#"{"name":"x","steps":[{"command":"home"},{"command":"tap"}]}"#.utf8))
        let token = ScriptCancellation(); var calls = 0
        XCTAssertThrowsError(try ScriptExecutor.run(script, cancellation: token, execute: { _, _ in
            calls += 1; token.cancel(); return [:]
        }, report: { _, _, _ in }))
        XCTAssertEqual(calls, 1)
    }
    func testAssertionReadsRealDOMAndFailsWhenAbsent() throws {
        let script = try Script.parse(Data(#"{"name":"x","steps":[{"command":"assertText","args":{"text":"Expected"}}]}"#.utf8))
        XCTAssertThrowsError(try ScriptExecutor.run(script, cancellation: ScriptCancellation(), execute: { command, _ in
            XCTAssertEqual(command, "dom"); return ["text":"Actual"]
        }, report: { _, _, _ in }))
    }
}
