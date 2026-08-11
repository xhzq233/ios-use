import Foundation
import IOSUseProtocol
import XCTest
@testable import IOSUseCLI

final class DriverFailureOutputTests: XCTestCase {
    override func tearDown() {
        IOSUseCLI.driverClientFactoryForTesting = nil
        super.tearDown()
    }

    func testHumanFailureInlinesActionableDiagnosticsWithoutArtifacts()
        throws
    {
        let fixture = try makeFixture(name: "human")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let counters = FailureClientCounters()
        let payload = diagnosticPayload()
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            FailureDriverClient(counters: counters) { _, _, _, _, _ in
                throw DriverClientError.driverError(
                    message: "target is not actionable",
                    payload: payload
                )
            }
        }

        let result = IOSUseCLI(pathsForTesting: fixture.paths).run(
            arguments: ["tap", "Continue"]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("[element_not_actionable]"))
        XCTAssertTrue(result.stderr.contains("target: label=\"Continue\""))
        XCTAssertTrue(result.stderr.contains("suggestions: refresh DOM"))
        XCTAssertTrue(result.stderr.contains("Alert: app alert"))
        XCTAssertTrue(result.stderr.contains("text: Permission"))
        XCTAssertTrue(result.stderr.contains("rejected=empty_visible_frame"))
        XCTAssertFalse(result.stderr.contains("Evidence:"))
        XCTAssertEqual(counters.domCalls, 0)
        XCTAssertEqual(counters.screenshotCalls, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.paths.artifacts)
        )
    }

    func testJSONFailureCarriesStructuredDiagnosticsWithoutManifest()
        throws
    {
        let fixture = try makeFixture(name: "json")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let counters = FailureClientCounters()
        let payload = diagnosticPayload()
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            FailureDriverClient(counters: counters) { _, _, _, _, _ in
                throw DriverClientError.driverError(
                    message: "target is not actionable",
                    payload: payload
                )
            }
        }

        let result = IOSUseCLI(pathsForTesting: fixture.paths).run(
            arguments: ["tap", "Continue", "--json"]
        )

        XCTAssertEqual(result.exitCode, 1)
        let root = try jsonObject(result.stderr)
        XCTAssertNil(root["evidenceManifest"])
        let error = try XCTUnwrap(root["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "element_not_actionable")
        XCTAssertEqual(error["category"] as? String, "lookup")
        XCTAssertEqual(error["mutationMayHaveApplied"] as? Bool, false)
        let data = try XCTUnwrap(root["data"] as? [String: Any])
        let target = try XCTUnwrap(data["target"] as? [String: Any])
        XCTAssertEqual(target["label"] as? String, "Continue")
        XCTAssertEqual(data["candidateCount"] as? Int, 1)
        XCTAssertEqual(data["suggestions"] as? [String], ["refresh DOM"])
        let candidates = try XCTUnwrap(
            data["candidates"] as? [[String: Any]]
        )
        XCTAssertEqual(candidates.first?["label"] as? String, "Continue")
        XCTAssertEqual(
            candidates.first?["rejectedBy"] as? [String],
            ["empty_visible_frame"]
        )
        let alert = try XCTUnwrap(data["alert"] as? [String: Any])
        XCTAssertEqual(alert["buttonCount"] as? Int, 1)
        XCTAssertEqual(counters.domCalls, 0)
        XCTAssertEqual(counters.screenshotCalls, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.paths.artifacts)
        )
    }

    func testPostconditionFailureDoesNotTriggerEvidenceCapture()
        throws
    {
        let fixture = try makeFixture(name: "postcondition")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let counters = FailureClientCounters()
        let underlying = ForyErrorPayload(
            category: IOSUseErrorCategory.lookup,
            code: IOSUseErrorCode.snapshotFailed,
            phase: IOSUseErrorPhase.snapshot,
            retryable: true,
            suggestions: ["run dom explicitly"]
        )
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            FailureDriverClient(
                counters: counters,
                domHandler: { _, fresh, _ in
                    XCTAssertTrue(fresh)
                    throw DriverClientError.driverError(
                        message: "snapshot unavailable",
                        payload: underlying
                    )
                },
                tapHandler: { target, _, _, _, _ in
                    ForyElementPayload(
                        elemType: 9,
                        label: target.label,
                        rect: ForyRect(x: 1, y: 2, w: 3, h: 4)
                    )
                }
            )
        }

        let result = IOSUseCLI(pathsForTesting: fixture.paths).run(
            arguments: ["tap", "Continue", "--dom", "--json"]
        )

        XCTAssertEqual(result.exitCode, 1)
        let root = try jsonObject(result.stderr)
        let error = try XCTUnwrap(root["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "postcondition_failed")
        XCTAssertEqual(error["category"] as? String, "postcondition")
        XCTAssertEqual(error["mutationMayHaveApplied"] as? Bool, true)
        let data = try XCTUnwrap(root["data"] as? [String: Any])
        XCTAssertEqual(
            data["suggestions"] as? [String],
            ["run dom explicitly"]
        )
        XCTAssertGreaterThan(counters.domCalls, 0)
        XCTAssertEqual(counters.screenshotCalls, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.paths.artifacts)
        )
    }

    func testMutationClassificationAndMissingDriverStayArtifactFree()
        throws
    {
        XCTAssertFalse(driverMutationMayHaveApplied(ForyErrorPayload(
            category: IOSUseErrorCategory.lookup,
            code: IOSUseErrorCode.elementNotFound,
            phase: IOSUseErrorPhase.lookup
        )))
        XCTAssertTrue(driverMutationMayHaveApplied(ForyErrorPayload(
            category: IOSUseErrorCategory.action,
            code: IOSUseErrorCode.gestureFailed,
            phase: IOSUseErrorPhase.interaction
        )))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-no-driver-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": root.path]
        )
        let result = IOSUseCLI(pathsForTesting: paths).run(
            arguments: ["tap", "Continue"]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("No active driver"))
        XCTAssertFalse(result.stderr.contains("Evidence:"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.artifacts)
        )
    }

    private func diagnosticPayload() -> ForyErrorPayload {
        ForyErrorPayload(
            category: IOSUseErrorCategory.lookup,
            code: IOSUseErrorCode.elementNotActionable,
            phase: IOSUseErrorPhase.lookup,
            retryable: true,
            target: ForyTarget(label: "Continue", traits: "Button"),
            candidateCount: 1,
            suggestions: ["refresh DOM"],
            candidates: [
                ForyErrorCandidate(
                    element: ForyFindMatch(
                        elemType: 9,
                        label: "Continue",
                        rect: ForyRect(x: 10, y: 20, w: 30, h: 40),
                        traits: ["Button"],
                        ancestors: ["Root"]
                    ),
                    rejectedBy: ["empty_visible_frame"]
                ),
            ],
            alert: ForyAlertPayload(
                surface: "app",
                kind: "alert",
                text: "Permission",
                buttonCount: 1,
                buttons: [
                    ForyAlertButton(
                        queryIndex: 0,
                        label: "OK",
                        hittable: true
                    ),
                ]
            )
        )
    }

    private func makeFixture(
        name: String
    ) throws -> (root: String, paths: IOSUsePaths) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-inline-failure-\(name)-\(UUID().uuidString)",
                isDirectory: true
            ).path
        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": root]
        )
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "SIM-INLINE-FAILURE",
                deviceName: "iPhone",
                deviceVersion: "26.0",
                deviceType: "simulator",
                startedAt: 1
            ),
            paths: paths
        )
        return (root, paths)
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(text.utf8)
            ) as? [String: Any]
        )
    }
}

private final class FailureClientCounters {
    var domCalls = 0
    var screenshotCalls = 0
}

private final class FailureDriverClient: DriverCommandClient {
    typealias DomHandler =
        (Bool, Bool, Bool) throws -> ForyDomPayload
    typealias TapHandler =
        (ForyTarget, String?, Int32?, ForyPoint?, ForyPoint?) throws
            -> ForyElementPayload

    private let counters: FailureClientCounters
    private let domHandler: DomHandler
    private let tapHandler: TapHandler

    init(
        counters: FailureClientCounters,
        domHandler: @escaping DomHandler = { _, _, _ in
            throw CLIParseError.invalidValue("unexpected dom")
        },
        tapHandler: @escaping TapHandler
    ) {
        self.counters = counters
        self.domHandler = domHandler
        self.tapHandler = tapHandler
    }

    func close() {}

    func dom(
        raw: Bool,
        fresh: Bool,
        waitQuiescence: Bool
    ) throws -> ForyDomPayload {
        counters.domCalls += 1
        return try domHandler(raw, fresh, waitQuiescence)
    }

    func waitFor(
        label: String,
        timeout: Double?,
        traits: String?,
        cindex: Int32?
    ) throws -> ForyWaitForPayload {
        throw CLIParseError.invalidValue("unexpected waitFor")
    }

    func screenshot() throws -> Data {
        counters.screenshotCalls += 1
        throw CLIParseError.invalidValue("unexpected screenshot")
    }

    func screenshotCapture() throws -> ScreenshotCapture {
        counters.screenshotCalls += 1
        throw CLIParseError.invalidValue("unexpected screenshot")
    }

    func tap(
        target: ForyTarget,
        traits: String?,
        cindex: Int32?,
        offset: ForyPoint?,
        ratio: ForyPoint?
    ) throws -> ForyElementPayload {
        try tapHandler(target, traits, cindex, offset, ratio)
    }

    func longPress(
        target: ForyTarget,
        durationMs: Int?,
        traits: String?,
        cindex: Int32?
    ) throws -> ForyElementPayload {
        throw CLIParseError.invalidValue("unexpected longPress")
    }

    func input(
        tap: ForyTarget?,
        content: String
    ) throws -> ForyElementPayload {
        throw CLIParseError.invalidValue("unexpected input")
    }

    func swipe(
        to: ForyTarget,
        from: ForyTarget,
        distance: Double?,
        dir: String?,
        traits: String?,
        cindex: Int32?
    ) throws -> ForySwipePayload {
        throw CLIParseError.invalidValue("unexpected swipe")
    }

    func activateApp(bundleId: String) throws {
        throw CLIParseError.invalidValue("unexpected activateApp")
    }

    func terminateApp(bundleId: String) throws {
        throw CLIParseError.invalidValue("unexpected terminateApp")
    }

    func home() throws {
        throw CLIParseError.invalidValue("unexpected home")
    }

    func dismissAlert(
        args: ForyDismissAlertArgs
    ) throws -> ForyAlertPayload {
        throw CLIParseError.invalidValue("unexpected dismissAlert")
    }

    func proxyCAPush(caBase64: String) throws -> ForyProxyPayload {
        throw CLIParseError.invalidValue("unexpected proxyCAPush")
    }
}
