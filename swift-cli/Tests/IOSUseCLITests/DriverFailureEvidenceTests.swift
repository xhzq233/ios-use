import Foundation
import IOSUseProtocol
import XCTest
@testable import IOSUseCLI

final class DriverFailureEvidenceTests: XCTestCase {
    override func tearDown() {
        DriverFailureEvidence.ocrRecognizerForTesting = nil
        IOSUseCLI.driverClientFactoryForTesting = nil
        super.tearDown()
    }

    func testEvidenceProfileIsBoundedByActionAndErrorClass() {
        let tap = DriverAction.tap(
            target: "Continue",
            offset: nil,
            offsetRatio: nil,
            traits: nil,
            cindex: nil,
            postDom: nil
        )
        let ambiguous = ForyErrorPayload(
            category: IOSUseErrorCategory.lookup,
            code: IOSUseErrorCode.elementAmbiguous,
            phase: IOSUseErrorPhase.lookup
        )
        let notFound = ForyErrorPayload(
            category: IOSUseErrorCategory.lookup,
            code: IOSUseErrorCode.elementNotFound,
            phase: IOSUseErrorPhase.lookup
        )
        let invalid = ForyErrorPayload(
            category: IOSUseErrorCategory.validation,
            code: IOSUseErrorCode.invalidArguments,
            phase: IOSUseErrorPhase.validation
        )
        let fatal = ForyErrorPayload(
            category: IOSUseErrorCategory.timeout,
            code: IOSUseErrorCode.driverWatchdogTimeout,
            phase: IOSUseErrorPhase.dispatch,
            fatal: true
        )
        let actionFailure = ForyErrorPayload(
            category: IOSUseErrorCategory.action,
            code: IOSUseErrorCode.inputFailed,
            phase: IOSUseErrorPhase.interaction
        )

        XCTAssertEqual(DriverFailureEvidence.profile(action: tap, errorPayload: ambiguous), .manifestOnly)
        XCTAssertEqual(DriverFailureEvidence.profile(action: tap, errorPayload: notFound), .uiSnapshot)
        XCTAssertEqual(DriverFailureEvidence.profile(action: tap, errorPayload: invalid), .none)
        XCTAssertEqual(DriverFailureEvidence.profile(action: tap, errorPayload: fatal), .none)
        XCTAssertEqual(DriverFailureEvidence.profile(action: .home, errorPayload: notFound), .none)
        XCTAssertFalse(DriverFailureEvidence.mutationMayHaveApplied(errorPayload: notFound))
        XCTAssertTrue(DriverFailureEvidence.mutationMayHaveApplied(errorPayload: actionFailure))
    }

    func testUIFailureCapturesScreenshotThenOverlapsFastOCRWithFreshDOM() throws {
        let fixture = try makeFixture(name: "ui-snapshot")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let concurrency = EvidenceConcurrencyProbe()
        let payload = ForyErrorPayload(
            category: IOSUseErrorCategory.lookup,
            code: IOSUseErrorCode.elementNotActionable,
            phase: IOSUseErrorPhase.lookup,
            retryable: true,
            target: ForyTarget(label: "画中画"),
            candidateCount: 1,
            candidates: [
                ForyErrorCandidate(
                    element: ForyFindMatch(
                        elemType: 9,
                        label: "画中画",
                        rect: ForyRect(x: 10, y: 20, w: 30, h: 40),
                        traits: ["Button"]
                    ),
                    rejectedBy: [IOSUseCandidateRejection.emptyVisibleFrame]
                ),
            ]
        )

        DriverFailureEvidence.ocrRecognizerForTesting = { _, logicalSize, scale, recognitionLevel in
            XCTAssertEqual(recognitionLevel, .fast)
            concurrency.ocrDidStart()
            Thread.sleep(forTimeInterval: 0.15)
            concurrency.ocrDidFinish()
            return OCRService.Result(
                imageWidth: 1206,
                imageHeight: 2622,
                logicalSize: logicalSize,
                scale: scale,
                recognitionLevel: recognitionLevel,
                observations: []
            )
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            EvidenceDriverClient(
                domHandler: { raw, fresh, waitQuiescence in
                    XCTAssertFalse(raw)
                    XCTAssertTrue(fresh)
                    XCTAssertFalse(waitQuiescence)
                    concurrency.domDidRunWhileOCRActive()
                    return ForyDomPayload(
                        app: "com.example",
                        windowSize: ForyPoint(x: 402, y: 874),
                        elements: [ForyDomElement(traits: ["Text"], label: "Settings")]
                    )
                },
                screenshotHandler: {
                    concurrency.screenshotDidRun()
                    return ScreenshotCapture(
                        jpeg: Data("fake-jpeg".utf8),
                        pixelSize: ForyPoint(x: 1206, y: 2622),
                        logicalSize: ForyPoint(x: 402, y: 874),
                        scale: 3
                    )
                },
                tapHandler: { _, _, _, _, _ in
                    throw DriverClientError.driverError(
                        message: "label '画中画' is not actionable",
                        payload: payload
                    )
                }
            )
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": fixture.root]).run(arguments: ["tap", "画中画"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("[element_not_actionable] label '画中画' is not actionable"))
        XCTAssertFalse(result.stderr.contains("hint:"))
        XCTAssertFalse(result.stderr.contains("DOM:"))
        XCTAssertFalse(result.stderr.contains("screenshot.jpg"))
        XCTAssertEqual(result.stderr.components(separatedBy: "Evidence:").count - 1, 1)
        XCTAssertTrue(concurrency.didCaptureScreenshotBeforeOCR)
        XCTAssertTrue(concurrency.didObserveDOMDuringOCR)

        let manifestURL = try evidenceManifestURL(from: result.stderr)
        let manifest = try jsonObject(at: manifestURL)
        XCTAssertEqual(manifest["schemaVersion"] as? Int, 2)
        XCTAssertEqual(manifest["command"] as? String, "tap")
        XCTAssertEqual(manifest["profile"] as? String, "ui-snapshot")

        let error = try XCTUnwrap(manifest["error"] as? [String: Any])
        XCTAssertEqual(error["category"] as? String, IOSUseErrorCategory.lookup)
        XCTAssertEqual(error["code"] as? String, IOSUseErrorCode.elementNotActionable)
        XCTAssertEqual(error["candidateCount"] as? Int, 1)
        XCTAssertEqual(error["mutationMayHaveApplied"] as? Bool, false)
        let candidates = try XCTUnwrap(error["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.first?["rejectedBy"] as? [String], [IOSUseCandidateRejection.emptyVisibleFrame])

        let artifacts = try XCTUnwrap(manifest["artifacts"] as? [String: Any])
        XCTAssertEqual(artifacts["screenshot"] as? String, "screenshot.jpg")
        XCTAssertEqual(artifacts["ocr"] as? String, "screenshot.ocr.json")
        XCTAssertEqual(artifacts["dom"] as? String, "dom.txt")
        for name in ["screenshot.jpg", "screenshot.ocr.json", "dom.txt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.deletingLastPathComponent().appendingPathComponent(name).path))
        }
        let ocr = try jsonObject(at: manifestURL.deletingLastPathComponent().appendingPathComponent("screenshot.ocr.json"))
        XCTAssertEqual(ocr["recognitionLevel"] as? String, "fast")

        let timing = try XCTUnwrap(manifest["timing"] as? [String: Any])
        XCTAssertNotNil(timing["screenshotOffsetMs"])
        XCTAssertNotNil(timing["ocrOffsetMs"])
        XCTAssertNotNil(timing["domOffsetMs"])
        XCTAssertLessThan(
            try XCTUnwrap(timing["domOffsetMs"] as? Int),
            try XCTUnwrap(timing["ocrOffsetMs"] as? Int)
        )
    }

    func testAmbiguityWritesOnlyCompactManifest() throws {
        let fixture = try makeFixture(name: "manifest-only")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let payload = ForyErrorPayload(
            category: IOSUseErrorCategory.lookup,
            code: IOSUseErrorCode.elementAmbiguous,
            phase: IOSUseErrorPhase.lookup,
            retryable: true,
            target: ForyTarget(label: "关闭"),
            candidateCount: 2,
            candidates: [
                ForyErrorCandidate(element: ForyFindMatch(elemType: 9, label: "关闭")),
                ForyErrorCandidate(element: ForyFindMatch(elemType: 9, label: "关闭")),
            ]
        )
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            EvidenceDriverClient(tapHandler: { _, _, _, _, _ in
                throw DriverClientError.driverError(
                    message: "label '关闭' is ambiguous (2 matches)",
                    payload: payload
                )
            })
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": fixture.root]).run(arguments: ["tap", "关闭"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("[element_ambiguous]"))
        XCTAssertFalse(result.stderr.contains("hint:"))
        let manifestURL = try evidenceManifestURL(from: result.stderr)
        let manifest = try jsonObject(at: manifestURL)
        XCTAssertEqual(manifest["profile"] as? String, "manifest-only")
        let artifacts = try XCTUnwrap(manifest["artifacts"] as? [String: Any])
        XCTAssertTrue(artifacts.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: manifestURL.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["manifest.json"])
    }

    func testPostDOMFailureIsClassifiedAsPostconditionAfterMutation() throws {
        let fixture = try makeFixture(name: "postcondition")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let stateLock = NSLock()
        var domCalls = 0
        let underlyingPayload = ForyErrorPayload(
            category: IOSUseErrorCategory.lookup,
            code: IOSUseErrorCode.snapshotFailed,
            phase: IOSUseErrorPhase.snapshot,
            retryable: true
        )
        DriverFailureEvidence.ocrRecognizerForTesting = { _, logicalSize, scale, recognitionLevel in
            XCTAssertEqual(recognitionLevel, .fast)
            return OCRService.Result(
                imageWidth: 1206,
                imageHeight: 2622,
                logicalSize: logicalSize,
                scale: scale,
                recognitionLevel: recognitionLevel,
                observations: []
            )
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            EvidenceDriverClient(
                domHandler: { _, fresh, _ in
                    XCTAssertTrue(fresh)
                    let call = stateLock.withLock { () -> Int in
                        domCalls += 1
                        return domCalls
                    }
                    if call == 1 {
                        throw DriverClientError.driverError(
                            message: "failed to take snapshot",
                            payload: underlyingPayload
                        )
                    }
                    return ForyDomPayload(app: "com.example")
                },
                screenshotHandler: {
                    ScreenshotCapture(
                        jpeg: Data("fake-jpeg".utf8),
                        pixelSize: ForyPoint(x: 1206, y: 2622),
                        logicalSize: ForyPoint(x: 402, y: 874),
                        scale: 3
                    )
                },
                tapHandler: { target, _, _, _, _ in
                    ForyElementPayload(elemType: 9, label: target.label, rect: ForyRect(x: 1, y: 2, w: 3, h: 4))
                }
            )
        }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": fixture.root]).run(arguments: ["tap", "Continue", "--dom"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("[postcondition_failed] DOM after quiescence failed after mutation: failed to take snapshot"))
        let manifest = try jsonObject(at: evidenceManifestURL(from: result.stderr))
        let error = try XCTUnwrap(manifest["error"] as? [String: Any])
        XCTAssertEqual(error["category"] as? String, IOSUseErrorCategory.postcondition)
        XCTAssertEqual(error["code"] as? String, IOSUseErrorCode.postconditionFailed)
        XCTAssertEqual(error["phase"] as? String, IOSUseErrorPhase.postcondition)
        XCTAssertEqual(error["mutationMayHaveApplied"] as? Bool, true)
        XCTAssertEqual(stateLock.withLock { domCalls }, 2)
    }

    func testMissingDriverDoesNotCreateFailureEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-evidence-no-driver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = IOSUseCLI(environment: ["IOS_USE_HOME": root.path]).run(arguments: ["tap", "Continue"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("No active driver"))
        XCTAssertFalse(result.stderr.contains("Evidence:"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts").path))
    }

    private func makeFixture(name: String) throws -> (root: String, paths: IOSUsePaths) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-evidence-\(name)-\(UUID().uuidString)", isDirectory: true)
            .path
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "SIM-EVIDENCE",
                deviceName: "iPhone",
                deviceVersion: "26.0",
                deviceType: "simulator",
                startedAt: 1
            ),
            paths: paths
        )
        return (root, paths)
    }

    private func evidenceManifestURL(from stderr: String) throws -> URL {
        let line = try XCTUnwrap(stderr.split(separator: "\n").first { $0.hasPrefix("Evidence: ") })
        let path = line.dropFirst("Evidence: ".count).split(separator: " ", maxSplits: 1).first.map(String.init)
        return URL(fileURLWithPath: try XCTUnwrap(path))
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class EvidenceConcurrencyProbe {
    private let lock = NSLock()
    private let ocrStarted = DispatchSemaphore(value: 0)
    private var screenshotCaptured = false
    private var ocrActive = false
    private var screenshotBeforeOCR = false
    private var domDuringOCR = false

    var didCaptureScreenshotBeforeOCR: Bool {
        lock.withLock { screenshotBeforeOCR }
    }

    var didObserveDOMDuringOCR: Bool {
        lock.withLock { domDuringOCR }
    }

    func screenshotDidRun() {
        lock.withLock { screenshotCaptured = true }
    }

    func ocrDidStart() {
        lock.withLock {
            screenshotBeforeOCR = screenshotCaptured
            ocrActive = true
        }
        ocrStarted.signal()
    }

    func ocrDidFinish() {
        lock.withLock { ocrActive = false }
    }

    func domDidRunWhileOCRActive() {
        _ = ocrStarted.wait(timeout: .now() + 1)
        lock.withLock { domDuringOCR = ocrActive }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private final class EvidenceDriverClient: DriverCommandClient {
    typealias DomHandler = (Bool, Bool, Bool) throws -> ForyDomPayload
    typealias ScreenshotHandler = () throws -> ScreenshotCapture
    typealias TapHandler = (ForyTarget, String?, Int32?, ForyPoint?, ForyPoint) throws -> ForyElementPayload

    private let domHandler: DomHandler
    private let screenshotHandler: ScreenshotHandler
    private let tapHandler: TapHandler

    init(
        domHandler: @escaping DomHandler = { _, _, _ in throw CLIParseError.invalidValue("unexpected dom") },
        screenshotHandler: @escaping ScreenshotHandler = { throw CLIParseError.invalidValue("unexpected screenshot") },
        tapHandler: @escaping TapHandler
    ) {
        self.domHandler = domHandler
        self.screenshotHandler = screenshotHandler
        self.tapHandler = tapHandler
    }

    func close() {}

    func dom(raw: Bool, fresh: Bool, waitQuiescence: Bool) throws -> ForyDomPayload {
        try domHandler(raw, fresh, waitQuiescence)
    }

    func waitFor(label: String, timeout: Double?, traits: String?, cindex: Int32?) throws -> ForyWaitForPayload {
        throw CLIParseError.invalidValue("unexpected waitFor")
    }

    func screenshot() throws -> Data {
        try screenshotHandler().jpeg
    }

    func screenshotCapture() throws -> ScreenshotCapture {
        try screenshotHandler()
    }

    func tap(target: ForyTarget, traits: String?, cindex: Int32?, offset: ForyPoint?, ratio: ForyPoint) throws -> ForyElementPayload {
        try tapHandler(target, traits, cindex, offset, ratio)
    }

    func longPress(target: ForyTarget, durationMs: Int?, traits: String?, cindex: Int32?) throws -> ForyElementPayload {
        throw CLIParseError.invalidValue("unexpected longPress")
    }

    func input(tap: ForyTarget?, content: String) throws {
        throw CLIParseError.invalidValue("unexpected input")
    }

    func swipe(to: ForyTarget, from: ForyTarget, distance: Double?, dir: String?, traits: String?, cindex: Int32?) throws -> ForySwipePayload {
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

    func dismissAlert(index: Int?) throws -> ForyAlertPayload {
        throw CLIParseError.invalidValue("unexpected dismissAlert")
    }

    func proxyCAPush(caBase64: String) throws -> ForyProxyPayload {
        throw CLIParseError.invalidValue("unexpected proxyCAPush")
    }
}
