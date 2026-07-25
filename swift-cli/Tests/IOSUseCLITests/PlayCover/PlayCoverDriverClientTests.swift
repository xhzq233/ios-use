import CoreGraphics
import Foundation
import ImageIO
import IOSUseProtocol
import XCTest
@testable import IOSUseCLI

final class PlayCoverDriverClientTests: XCTestCase {
    override func tearDown() {
        IOSUseCLI.playCoverDriverClientFactoryForTesting = nil
        IOSUseCLI.driverClientFactoryForTesting = nil
        super.tearDown()
    }

    func testScreenshotUsesRuntimePayload() throws {
        let jpeg = try makeJPEG(width: 1_290, height: 2_796)
        let payload = makePayload(
            capabilities: ["screenshot"],
            screenshot: makeScreenshotPayload(jpeg: jpeg)
        )
        var runtimeRequests = 0
        let client = PlayCoverDriverClient(
            session: makeSession(),
            runtimeScreenshotRequester: {
                runtimeRequests += 1
                return payload
            }
        )

        let capture = try client.screenshotCapture()

        XCTAssertEqual(runtimeRequests, 1)
        XCTAssertEqual(capture.jpeg, jpeg)
        XCTAssertEqual(capture.pixelSize?.x, 1_290)
        XCTAssertEqual(capture.pixelSize?.y, 2_796)
        XCTAssertEqual(capture.logicalSize?.x, 430)
        XCTAssertEqual(capture.logicalSize?.y, 932)
        XCTAssertEqual(capture.scale, 3)
        XCTAssertEqual(
            capture.geometrySource,
            "playcover-runtime-cgwindow-self"
        )
        XCTAssertNil(capture.warning)
        XCTAssertEqual(
            try jpegPixelSize(capture.jpeg),
            CGSize(width: 1_290, height: 2_796)
        )
    }

    func testScreenshotReportsIncompleteRuntimeFallback() throws {
        let jpeg = try makeJPEG(width: 1_290, height: 2_796)
        let payload = makePayload(
            capabilities: ["screenshot"],
            screenshot: makeScreenshotPayload(
                jpeg: jpeg,
                source: "draw-view-hierarchy",
                complete: false
            )
        )
        let client = PlayCoverDriverClient(
            session: makeSession(),
            runtimeScreenshotRequester: { payload }
        )

        let capture = try client.screenshotCapture()

        XCTAssertEqual(
            capture.geometrySource,
            "playcover-runtime-draw-view-hierarchy"
        )
        XCTAssertEqual(
            capture.warning,
            "PlayCover Runtime reported an incomplete draw-view-hierarchy screenshot"
        )
    }

    func testScreenshotRejectsMismatchedRuntimeGeometry() throws {
        let jpeg = try makeJPEG(width: 1_290, height: 2_796)
        let payload = makePayload(
            capabilities: ["screenshot"],
            screenshot: makeScreenshotPayload(
                jpeg: jpeg,
                logicalWidth: 431
            )
        )
        let client = PlayCoverDriverClient(
            session: makeSession(),
            runtimeScreenshotRequester: { payload }
        )

        XCTAssertThrowsError(try client.screenshotCapture()) {
            XCTAssertEqual(
                $0 as? PlayCoverDriverClientError,
                .runtimeGeometryMismatch("screenshot geometry")
            )
        }
    }

    func testScreenshotRejectsEveryStaleRuntimeIdentityBeforeCapture() throws {
        let screenshot = makeScreenshotPayload(
            jpeg: try makeJPEG(width: 1_290, height: 2_796)
        )
        let variants: [(String, PlayCoverRuntimeResponsePayload)] = [
            (
                "pid",
                makePayload(
                    pid: 99,
                    capabilities: ["screenshot"],
                    screenshot: screenshot
                )
            ),
            (
                "bundle ID",
                makePayload(
                    bundleIdentifier: "wrong.bundle",
                    capabilities: ["screenshot"],
                    screenshot: screenshot
                )
            ),
            (
                "profile hash",
                makePayload(
                    profileHash: "wrong-profile",
                    capabilities: ["screenshot"],
                    screenshot: screenshot
                )
            ),
            (
                "prepared generation",
                makePayload(
                    preparedGenerationID: "wrong-generation",
                    capabilities: ["screenshot"],
                    screenshot: screenshot
                )
            ),
            (
                "socket path",
                makePayload(
                    runtimeSocketPath: "/tmp/wrong.sock",
                    capabilities: ["screenshot"],
                    screenshot: screenshot
                )
            ),
            (
                "runtime instance",
                makePayload(
                    runtimeInstanceID: "wrong-runtime",
                    capabilities: ["screenshot"],
                    screenshot: screenshot
                )
            ),
            (
                "launch nonce",
                makePayload(
                    launchNonce: "wrong-nonce",
                    capabilities: ["screenshot"],
                    screenshot: screenshot
                )
            ),
        ]

        for (field, payload) in variants {
            let client = PlayCoverDriverClient(
                session: makeSession(),
                runtimeScreenshotRequester: { payload }
            )

            XCTAssertThrowsError(try client.screenshotCapture(), field) {
                XCTAssertEqual(
                    $0 as? PlayCoverDriverClientError,
                    .runtimeIdentityMismatch(field)
                )
            }
        }
    }

    func testScreenshotRequiresCapabilityAndTypedPayload() throws {
        let missingCapability = PlayCoverDriverClient(
            session: makeSession(),
            runtimeScreenshotRequester: {
                self.makePayload(
                    screenshot: self.makeScreenshotPayload(
                        jpeg: try self.makeJPEG(
                            width: 1_290,
                            height: 2_796
                        )
                    )
                )
            }
        )
        XCTAssertThrowsError(
            try missingCapability.screenshotCapture()
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverDriverClientError,
                .runtimeCapabilityUnavailable("screenshot")
            )
        }

        let missingPayload = PlayCoverDriverClient(
            session: makeSession(),
            runtimeScreenshotRequester: {
                self.makePayload(capabilities: ["screenshot"])
            }
        )
        XCTAssertThrowsError(try missingPayload.screenshotCapture()) {
            XCTAssertEqual(
                $0 as? PlayCoverDriverClientError,
                .malformedRuntimePayload("screenshot")
            )
        }
    }

    func testScreenshotRejectsInvalidBase64AndJPEGDimensions() throws {
        let invalidBase64 = PlayCoverDriverClient(
            session: makeSession(),
            runtimeScreenshotRequester: {
                self.makePayload(
                    capabilities: ["screenshot"],
                    screenshot: self.makeScreenshotPayload(
                        jpegBase64: "not base64!"
                    )
                )
            }
        )
        XCTAssertThrowsError(
            try invalidBase64.screenshotCapture()
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverDriverClientError,
                .malformedRuntimePayload("screenshot base64")
            )
        }

        let wrongSizeJPEG = try makeJPEG(width: 2, height: 2)
        let wrongSize = PlayCoverDriverClient(
            session: makeSession(),
            runtimeScreenshotRequester: {
                self.makePayload(
                    capabilities: ["screenshot"],
                    screenshot: self.makeScreenshotPayload(
                        jpeg: wrongSizeJPEG
                    )
                )
            }
        )
        XCTAssertThrowsError(try wrongSize.screenshotCapture()) {
            XCTAssertEqual(
                $0 as? PlayCoverDriverClientError,
                .malformedRuntimePayload("screenshot JPEG")
            )
        }
    }

    func testLifecycleCapabilitiesRemainExplicitlyUnsupported() throws {
        let client = PlayCoverDriverClient(
            session: makeSession(),
            runtimeScreenshotRequester: { self.makePayload() }
        )

        XCTAssertThrowsError(try client.activateApp(bundleId: "com.example")) {
            XCTAssertEqual(
                $0 as? PlayCoverDriverClientError,
                .lifecycleCommandUnsupported("activateApp")
            )
        }
        XCTAssertThrowsError(try client.home()) {
            XCTAssertEqual(
                $0 as? PlayCoverDriverClientError,
                .lifecycleCommandUnsupported("home")
            )
        }
    }

    func testDOMForwardsArgumentsAndMapsRuntimePayload() throws {
        var recordedArguments: [PlayCoverRuntimeDOMArguments] = []
        let client = PlayCoverDriverClient(
            session: makeSession(),
            runtimeScreenshotRequester: { self.makePayload() },
            runtimeDOMRequester: { arguments in
                recordedArguments.append(arguments)
                return self.makePayload(
                    capabilities: ["dom"],
                    dom: self.makeDOMPayload()
                )
            }
        )

        let result = try client.dom(
            raw: true,
            fresh: false,
            waitQuiescence: true
        )

        XCTAssertEqual(
            recordedArguments,
            [
                PlayCoverRuntimeDOMArguments(
                    raw: true,
                    fresh: false,
                    waitQuiescence: true
                ),
            ]
        )
        XCTAssertEqual(result.app, "Demo")
        XCTAssertEqual(result.windowSize.x, 430)
        XCTAssertEqual(result.windowSize.y, 932)
        XCTAssertEqual(result.raw, "Application, Demo")
        XCTAssertEqual(result.elements.count, 1)
        XCTAssertEqual(result.elements[0].traits, ["Button"])
        XCTAssertEqual(result.elements[0].childCount, 0)
        XCTAssertEqual(result.elements[0].label, "Continue")
        XCTAssertEqual(result.elements[0].value, "Ready")
        XCTAssertEqual(result.elements[0].rect?.x, 12)
        XCTAssertEqual(result.elements[0].rect?.y, 35)
        XCTAssertEqual(result.elements[0].rect?.w, 121)
        XCTAssertEqual(result.elements[0].rect?.h, 44)
    }

    func testWaitForOverloadsDelegateToFullRequestAndShareTimeoutBudget() throws {
        var requests: [
            (PlayCoverRuntimeWaitForArguments, TimeInterval)
        ] = []
        let client = PlayCoverDriverClient(
            session: makeSession(),
            runtimeScreenshotRequester: { self.makePayload() },
            runtimeWaitForRequester: { arguments, timeoutSeconds in
                requests.append((arguments, timeoutSeconds))
                return self.makePayload(
                    capabilities: ["waitFor"],
                    waitFor: self.makeWaitForPayload()
                )
            }
        )

        _ = try client.waitFor(
            label: "Continue",
            timeout: 9,
            traits: "Button",
            cindex: 2
        )
        _ = try client.waitFor(
            label: "Continue",
            timeout: nil,
            traits: nil,
            cindex: nil,
            gone: true
        )
        let result = try client.waitFor(
            label: "Continue",
            timeout: 3,
            traits: "Button",
            cindex: 1,
            gone: false,
            matchMode: .regex
        )

        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(
            requests[0].0,
            PlayCoverRuntimeWaitForArguments(
                target: PlayCoverRuntimeWaitTarget(
                    label: "Continue",
                    traits: "Button",
                    cindex: 2
                ),
                timeout: 9,
                gone: false,
                matchMode: IOSUseWaitForMatchMode.standard.rawValue
            )
        )
        XCTAssertEqual(
            requests[0].1,
            TimeInterval(
                IOSUseProtocol.waitForSocketReadTimeoutSeconds(9)
            )
        )
        XCTAssertEqual(requests[1].0.timeout, 0)
        XCTAssertTrue(requests[1].0.gone)
        XCTAssertEqual(
            requests[1].0.matchMode,
            IOSUseWaitForMatchMode.standard.rawValue
        )
        XCTAssertEqual(
            requests[1].1,
            TimeInterval(
                IOSUseProtocol.waitForSocketReadTimeoutSeconds(0)
            )
        )
        XCTAssertEqual(
            requests[2].0.matchMode,
            IOSUseWaitForMatchMode.regex.rawValue
        )
        XCTAssertEqual(result.element.elemType, 1)
        XCTAssertEqual(result.element.label, "Continue")
        XCTAssertEqual(result.element.ancestors, ["Demo"])
        XCTAssertEqual(result.element.rect?.x, 10)
        XCTAssertEqual(result.waited, 0.25)
    }

    func testDOMAndWaitForValidateIdentityAndCommandCapability() throws {
        let staleDOMClient = PlayCoverDriverClient(
            session: makeSession(),
            runtimeScreenshotRequester: { self.makePayload() },
            runtimeDOMRequester: { _ in
                self.makePayload(
                    pid: 9_999,
                    capabilities: ["dom"],
                    dom: self.makeDOMPayload()
                )
            }
        )

        XCTAssertThrowsError(
            try staleDOMClient.dom(
                raw: false,
                fresh: true,
                waitQuiescence: false
            )
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverDriverClientError,
                .runtimeIdentityMismatch("pid")
            )
        }

        let missingWaitCapabilityClient = PlayCoverDriverClient(
            session: makeSession(),
            runtimeScreenshotRequester: { self.makePayload() },
            runtimeWaitForRequester: { _, _ in
                self.makePayload(
                    capabilities: ["dom"],
                    waitFor: self.makeWaitForPayload()
                )
            }
        )

        XCTAssertThrowsError(
            try missingWaitCapabilityClient.waitFor(
                label: "Continue",
                timeout: 1,
                traits: nil,
                cindex: nil
            )
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverDriverClientError,
                .runtimeCapabilityUnavailable("waitFor")
            )
        }
    }

    func testSemanticRuntimeErrorMapsToDriverErrorPayload() throws {
        let details = PlayCoverRuntimeErrorDetails(
            category: "lookup",
            phase: "lookup",
            retryable: false,
            fatal: false,
            target: PlayCoverRuntimeWaitTarget(
                label: "Continue",
                traits: "Button",
                cindex: nil
            ),
            candidateCount: 2,
            candidates: [
                PlayCoverRuntimeErrorCandidate(
                    element: PlayCoverRuntimeErrorElement(
                        elemType: 1,
                        label: "Continue",
                        rect: PlayCoverRuntimeRect(
                            x: 1.2,
                            y: 2.5,
                            w: 30.6,
                            h: 40.4
                        ),
                        traits: ["Button"],
                        value: "",
                        ancestors: ["Demo"]
                    ),
                    rejectedBy: ["trait_mismatch"]
                ),
            ],
            suggestions: ["Pass --cindex"]
        )
        let client = PlayCoverDriverClient(
            session: makeSession(),
            runtimeScreenshotRequester: { self.makePayload() },
            runtimeWaitForRequester: { _, _ in
                throw PlayCoverRuntimeClientError.remoteError(
                    code: "element_ambiguous",
                    message: "multiple elements matched",
                    details: details
                )
            }
        )

        XCTAssertThrowsError(
            try client.waitFor(
                label: "Continue",
                timeout: 1,
                traits: "Button",
                cindex: nil
            )
        ) {
            guard case DriverClientError.driverError(
                let message,
                let payload
            ) = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertEqual(message, "multiple elements matched")
            XCTAssertEqual(payload.category, "lookup")
            XCTAssertEqual(payload.code, "element_ambiguous")
            XCTAssertEqual(payload.phase, "lookup")
            XCTAssertFalse(payload.retryable)
            XCTAssertFalse(payload.fatal)
            XCTAssertEqual(payload.target?.label, "Continue")
            XCTAssertEqual(payload.candidateCount, 2)
            XCTAssertEqual(payload.candidates.count, 1)
            XCTAssertEqual(payload.candidates[0].element.rect?.x, 1)
            XCTAssertEqual(payload.candidates[0].element.rect?.y, 3)
            XCTAssertEqual(
                payload.candidates[0].rejectedBy,
                ["trait_mismatch"]
            )
            XCTAssertEqual(payload.suggestions, ["Pass --cindex"])
        }
    }

    func testCLIScreenshotRoutesToPlayCoverClientFactory() throws {
        let root = "/tmp/iosuse-pc-shot-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let session = makeSession()
        try SessionService.writeDriverLock(info: session, paths: paths)
        let jpeg = try makeJPEG(width: 1_290, height: 2_796)
        var factorySession: SessionService.Info?
        IOSUseCLI.playCoverDriverClientFactoryForTesting = { actualSession in
            factorySession = actualSession
            return PlayCoverDriverClient(
                session: actualSession,
                runtimeScreenshotRequester: {
                    self.makePayload(
                        capabilities: ["screenshot"],
                        screenshot: self.makeScreenshotPayload(
                            jpeg: jpeg
                        )
                    )
                }
            )
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": root]
        ).run(
            arguments: [
                "screenshot",
                "--name", "playcover-route",
                "--no-ocr",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(factorySession, session)
        XCTAssertTrue(result.stdout.contains(".jpg"))
    }

    func testCLIRoutesDOMInspectAndWaitForToPlayCoverClient() throws {
        let root = "/tmp/iosuse-pc-dom-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        let session = makeSession()
        try SessionService.writeDriverLock(info: session, paths: paths)
        let jpeg = try makeJPEG(width: 1_290, height: 2_796)
        var routedCommands: [String] = []
        IOSUseCLI.playCoverDriverClientFactoryForTesting = {
            actualSession in
            XCTAssertEqual(actualSession, session)
            return PlayCoverDriverClient(
                session: actualSession,
                runtimeScreenshotRequester: {
                    routedCommands.append("screenshot")
                    return self.makePayload(
                        capabilities: ["screenshot"],
                        screenshot: self.makeScreenshotPayload(
                            jpeg: jpeg
                        )
                    )
                },
                runtimeDOMRequester: { _ in
                    routedCommands.append("dom")
                    return self.makePayload(
                        capabilities: ["dom"],
                        dom: self.makeDOMPayload()
                    )
                },
                runtimeWaitForRequester: { _, _ in
                    routedCommands.append("waitFor")
                    return self.makePayload(
                        capabilities: ["waitFor"],
                        waitFor: self.makeWaitForPayload()
                    )
                }
            )
        }
        let cli = IOSUseCLI(
            environment: ["IOS_USE_HOME": root]
        )

        let dom = cli.run(arguments: ["dom"])
        let wait = cli.run(
            arguments: [
                "waitFor", "Continue",
                "--timeout", "1s",
            ]
        )
        let inspect = cli.run(arguments: ["dom", "--ocr"])

        XCTAssertEqual(dom.exitCode, 0, dom.stderr)
        XCTAssertTrue(dom.stdout.contains("Application, Demo"))
        XCTAssertEqual(wait.exitCode, 0, wait.stderr)
        XCTAssertTrue(wait.stdout.contains("Continue"))
        XCTAssertEqual(inspect.exitCode, 0, inspect.stderr)
        XCTAssertTrue(inspect.stdout.contains("Visual evidence"))
        XCTAssertEqual(
            routedCommands,
            ["dom", "waitFor", "screenshot", "dom"]
        )
    }

    func testPlayCoverRecoverableDriverErrorNeverEntersXCTestRecovery() throws {
        let root = "/tmp/iosuse-pc-no-xctest-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try SessionService.writeDriverLock(info: makeSession(), paths: paths)
        var playCoverFactoryCalls = 0
        IOSUseCLI.playCoverDriverClientFactoryForTesting = { session in
            playCoverFactoryCalls += 1
            return PlayCoverDriverClient(
                session: session,
                runtimeScreenshotRequester: {
                    throw DriverClientError.connectFailed(61)
                }
            )
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("PlayCover recovery must never construct an XCTest client")
            return PlayCoverDriverClient(
                session: self.makeSession(),
                runtimeScreenshotRequester: { self.makePayload() }
            )
        }

        let result = IOSUseCLI(
            environment: ["IOS_USE_HOME": root]
        ).run(
            arguments: [
                "screenshot",
                "--name", "playcover-no-xctest-recovery",
                "--no-ocr",
            ]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("driver TCP connect failed"))
        XCTAssertEqual(playCoverFactoryCalls, 1)
    }

    private func makeSession() -> SessionService.Info {
        SessionService.Info(
            udid: "playcover:com.example.runtime",
            deviceName: "iPhone16,2",
            deviceVersion: "Mac Catalyst",
            deviceType: PlayCoverSessionService.deviceType,
            runnerPid: 4_242,
            startMode: "direct",
            bundleId: "com.example.runtime",
            playCoverAppPath: "/work/Prepared.app",
            profileHash: "profile-hash",
            playCoverRuntimeSocketPath: "/tmp/runtime.sock",
            playCoverLaunchNonce: "launch-nonce",
            playCoverPreparedGenerationID: "generation-1",
            playCoverRuntimeInstanceID: "runtime-1"
        )
    }

    private func makePayload(
        pid: Int32 = 4_242,
        bundleIdentifier: String = "com.example.runtime",
        profileHash: String = "profile-hash",
        preparedGenerationID: String = "generation-1",
        runtimeSocketPath: String = "/tmp/runtime.sock",
        runtimeInstanceID: String = "runtime-1",
        launchNonce: String = "launch-nonce",
        capabilities: [String] = ["hello", "ping", "diagnostics"],
        screenshot: PlayCoverRuntimeScreenshotPayload? = nil,
        dom: PlayCoverRuntimeDOMPayload? = nil,
        waitFor: PlayCoverRuntimeWaitForPayload? = nil
    ) -> PlayCoverRuntimeResponsePayload {
        PlayCoverRuntimeResponsePayload(
            protocolVersion: 1,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            profileHash: profileHash,
            preparedGenerationID: preparedGenerationID,
            runtimeSocketPath: runtimeSocketPath,
            runtimeInstanceID: runtimeInstanceID,
            launchNonce: launchNonce,
            capabilities: capabilities,
            logicalWidth: 430,
            logicalHeight: 932,
            nativeWidth: 1_290,
            nativeHeight: 2_796,
            scale: 3,
            windowWidth: 430,
            windowHeight: 932,
            stage: "window-configured",
            observed: nil,
            diagnostics: nil,
            screenshot: screenshot,
            dom: dom,
            waitFor: waitFor
        )
    }

    private func makeScreenshotPayload(
        jpeg: Data? = nil,
        jpegBase64: String? = nil,
        pixelWidth: Int = 1_290,
        pixelHeight: Int = 2_796,
        logicalWidth: Double = 430,
        logicalHeight: Double = 932,
        scale: Double = 3,
        source: String = "cgwindow-self",
        complete: Bool = true
    ) -> PlayCoverRuntimeScreenshotPayload {
        PlayCoverRuntimeScreenshotPayload(
            jpegBase64:
                jpegBase64 ?? jpeg?.base64EncodedString() ?? "",
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            scale: scale,
            source: source,
            complete: complete
        )
    }

    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let image = try makeImage(width: width, height: height)
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                output,
                "public.jpeg" as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImageDestinationLossyCompressionQuality: 0.9,
            ] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func makeDOMPayload() -> PlayCoverRuntimeDOMPayload {
        PlayCoverRuntimeDOMPayload(
            app: "Demo",
            windowSize: PlayCoverRuntimePoint(x: 430, y: 932),
            raw: "Application, Demo",
            snapshotGeneration: 7,
            elements: [
                PlayCoverRuntimeDOMElement(
                    nodeId: "g7-n1",
                    elemType: 1,
                    traits: ["Button"],
                    childCount: 0,
                    label: "Continue",
                    value: "Ready",
                    rect: PlayCoverRuntimeRect(
                        x: 12.25,
                        y: 34.5,
                        w: 120.75,
                        h: 44
                    )
                ),
            ]
        )
    }

    private func makeWaitForPayload() -> PlayCoverRuntimeWaitForPayload {
        PlayCoverRuntimeWaitForPayload(
            element: PlayCoverRuntimeElementSummary(
                elemType: 1,
                label: "Continue",
                rect: PlayCoverRuntimeRect(
                    x: 10,
                    y: 20,
                    w: 30,
                    h: 40
                ),
                ancestors: ["Demo"]
            ),
            waited: 0.25,
            snapshotGeneration: 8
        )
    }

}

private func makeImage(width: Int, height: Int) throws -> CGImage {
    let context = try XCTUnwrap(
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    )
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try XCTUnwrap(context.makeImage())
}

private func jpegPixelSize(_ data: Data) throws -> CGSize {
    let source = try XCTUnwrap(
        CGImageSourceCreateWithData(data as CFData, nil)
    )
    let properties = try XCTUnwrap(
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
    )
    let width = try XCTUnwrap(
        properties[kCGImagePropertyPixelWidth] as? NSNumber
    )
    let height = try XCTUnwrap(
        properties[kCGImagePropertyPixelHeight] as? NSNumber
    )
    return CGSize(
        width: width.doubleValue,
        height: height.doubleValue
    )
}
