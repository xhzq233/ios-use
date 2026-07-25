import CoreGraphics
import Foundation
import ImageIO
import IOSUseProtocol
import ScreenCaptureKit
import XCTest
@testable import IOSUseCLI

final class PlayCoverDriverClientTests: XCTestCase {
    override func tearDown() {
        IOSUseCLI.playCoverDriverClientFactoryForTesting = nil
        IOSUseCLI.driverClientFactoryForTesting = nil
        super.tearDown()
    }

    func testScreenshotVerifiesIdentityAndCapturesExactAppKitWindow() throws {
        let session = makeSession()
        let payload = makePayload()
        let provider = FakePlayCoverScreenshotProvider(
            image: try makeImage(width: 1_290, height: 2_880)
        )
        let client = PlayCoverDriverClient(
            session: session,
            screenshotProvider: provider,
            runtimeDiagnosticsRequester: { payload }
        )

        let capture = try client.screenshotCapture()

        XCTAssertEqual(provider.requests, [
            PlayCoverWindowCaptureRequest(
                pid: 4_242,
                windowNumber: 77,
                windowFrame: CGRect(x: 100, y: 200, width: 430, height: 960),
                contentLayoutRect: CGRect(x: 0, y: 0, width: 430, height: 932),
                targetPixelSize: CGSize(width: 1_290, height: 2_796)
            ),
        ])
        XCTAssertEqual(capture.pixelSize?.x, 1_290)
        XCTAssertEqual(capture.pixelSize?.y, 2_796)
        XCTAssertEqual(capture.logicalSize?.x, 430)
        XCTAssertEqual(capture.logicalSize?.y, 932)
        XCTAssertEqual(capture.scale, 3)
        XCTAssertEqual(
            capture.geometrySource,
            "playcover-runtime-appkit+screencapturekit-window"
        )
        XCTAssertEqual(try jpegPixelSize(capture.jpeg), CGSize(width: 1_290, height: 2_796))
    }

    func testScreenshotAcceptsScaled332By718Presentation() throws {
        let observed = appKitObserved(
            contentWidth: 332,
            contentHeight: 718,
            frameHeight: 746
        )
        let payload = makePayload(
            windowWidth: 332,
            windowHeight: 718,
            observed: observed
        )
        let provider = FakePlayCoverScreenshotProvider(
            image: try makeImage(width: 1_291, height: 2_902)
        )
        let client = PlayCoverDriverClient(
            session: makeSession(),
            screenshotProvider: provider,
            runtimeDiagnosticsRequester: { payload }
        )

        let capture = try client.screenshotCapture()

        XCTAssertEqual(provider.requests, [
            PlayCoverWindowCaptureRequest(
                pid: 4_242,
                windowNumber: 77,
                windowFrame: CGRect(x: 100, y: 200, width: 332, height: 746),
                contentLayoutRect: CGRect(x: 0, y: 0, width: 332, height: 718),
                targetPixelSize: CGSize(width: 1_290, height: 2_796)
            ),
        ])
        XCTAssertEqual(
            try jpegPixelSize(capture.jpeg),
            CGSize(width: 1_290, height: 2_796)
        )
        XCTAssertEqual(capture.logicalSize?.x, 430)
        XCTAssertEqual(capture.logicalSize?.y, 932)
        XCTAssertEqual(capture.scale, 3)
    }

    func testScreenshotRejectsNonUniformAppKitPresentation() throws {
        let payload = makePayload(
            windowWidth: 332,
            windowHeight: 718,
            observed: appKitObserved(
                contentWidth: 332,
                contentHeight: 700,
                frameHeight: 728
            )
        )
        let provider = FakePlayCoverScreenshotProvider(
            image: try makeImage(width: 1_290, height: 2_796)
        )
        let client = PlayCoverDriverClient(
            session: makeSession(),
            screenshotProvider: provider,
            runtimeDiagnosticsRequester: { payload }
        )

        XCTAssertThrowsError(try client.screenshotCapture()) {
            XCTAssertEqual(
                $0 as? PlayCoverDriverClientError,
                .runtimeGeometryMismatch(
                    "AppKit content layout presentation"
                )
            )
        }
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testScreenshotRejectsEveryStaleRuntimeIdentityBeforeCapture() throws {
        let variants: [(String, PlayCoverRuntimeResponsePayload)] = [
            ("pid", makePayload(pid: 99)),
            ("bundle ID", makePayload(bundleIdentifier: "wrong.bundle")),
            ("profile hash", makePayload(profileHash: "wrong-profile")),
            (
                "prepared generation",
                makePayload(preparedGenerationID: "wrong-generation")
            ),
            ("socket path", makePayload(runtimeSocketPath: "/tmp/wrong.sock")),
            (
                "runtime instance",
                makePayload(runtimeInstanceID: "wrong-runtime")
            ),
            ("launch nonce", makePayload(launchNonce: "wrong-nonce")),
        ]

        for (field, payload) in variants {
            let provider = FakePlayCoverScreenshotProvider(
                image: try makeImage(width: 1_290, height: 2_880)
            )
            let client = PlayCoverDriverClient(
                session: makeSession(),
                screenshotProvider: provider,
                runtimeDiagnosticsRequester: { payload }
            )

            XCTAssertThrowsError(try client.screenshotCapture(), field) {
                XCTAssertEqual(
                    $0 as? PlayCoverDriverClientError,
                    .runtimeIdentityMismatch(field)
                )
            }
            XCTAssertTrue(provider.requests.isEmpty)
        }
    }

    func testScreenshotRequiresExactWindowDiagnostics() throws {
        let provider = FakePlayCoverScreenshotProvider(
            image: try makeImage(width: 1_290, height: 2_880)
        )
        let payload = makePayload(observed: [
            "appKit": .object([
                "available": .bool(false),
            ]),
        ])
        let client = PlayCoverDriverClient(
            session: makeSession(),
            screenshotProvider: provider,
            runtimeDiagnosticsRequester: { payload }
        )

        XCTAssertThrowsError(try client.screenshotCapture()) {
            XCTAssertEqual(
                $0 as? PlayCoverDriverClientError,
                .missingDiagnostics("an available AppKit window")
            )
        }
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testProviderPermissionErrorRemainsStructured() throws {
        let provider = FakePlayCoverScreenshotProvider(
            error: PlayCoverScreenCaptureError.screenRecordingPermissionDenied
        )
        let client = PlayCoverDriverClient(
            session: makeSession(),
            screenshotProvider: provider,
            runtimeDiagnosticsRequester: { self.makePayload() }
        )

        XCTAssertThrowsError(try client.screenshotCapture()) {
            XCTAssertEqual(
                $0 as? PlayCoverScreenCaptureError,
                .screenRecordingPermissionDenied
            )
            XCTAssertTrue(
                String(describing: $0).contains(
                    "System Settings > Privacy & Security"
                )
            )
        }
    }

    func testNonScreenshotCapabilitiesRemainExplicitlyUnsupported() throws {
        let client = PlayCoverDriverClient(
            session: makeSession(),
            screenshotProvider: FakePlayCoverScreenshotProvider(
                image: try makeImage(width: 1, height: 1)
            ),
            runtimeDiagnosticsRequester: { self.makePayload() }
        )

        XCTAssertThrowsError(
            try client.dom(raw: false, fresh: true, waitQuiescence: false)
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverDriverClientError,
                .capabilityUnavailable("dom")
            )
        }
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
        let provider = FakePlayCoverScreenshotProvider(
            image: try makeImage(width: 1_290, height: 2_880)
        )
        var factorySession: SessionService.Info?
        IOSUseCLI.playCoverDriverClientFactoryForTesting = { actualSession in
            factorySession = actualSession
            return PlayCoverDriverClient(
                session: actualSession,
                screenshotProvider: provider,
                runtimeDiagnosticsRequester: { self.makePayload() }
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
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertTrue(result.stdout.contains(".jpg"))
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
        let provider = FakePlayCoverScreenshotProvider(
            error: DriverClientError.connectFailed(61)
        )
        var playCoverFactoryCalls = 0
        IOSUseCLI.playCoverDriverClientFactoryForTesting = { session in
            playCoverFactoryCalls += 1
            return PlayCoverDriverClient(
                session: session,
                screenshotProvider: provider,
                runtimeDiagnosticsRequester: { self.makePayload() }
            )
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("PlayCover recovery must never construct an XCTest client")
            return PlayCoverDriverClient(
                session: self.makeSession(),
                screenshotProvider: provider,
                runtimeDiagnosticsRequester: { self.makePayload() }
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
        XCTAssertEqual(provider.requests.count, 1)
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
        windowWidth: Double = 430,
        windowHeight: Double = 932,
        observed: [String: PlayCoverRuntimeJSONValue]? = nil
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
            capabilities: ["hello", "ping", "diagnostics"],
            logicalWidth: 430,
            logicalHeight: 932,
            nativeWidth: 1_290,
            nativeHeight: 2_796,
            scale: 3,
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            stage: "window-configured",
            observed: observed ?? appKitObserved(),
            diagnostics: nil
        )
    }

    private func appKitObserved(
        contentWidth: Double = 430,
        contentHeight: Double = 932,
        frameHeight: Double = 960
    ) -> [String: PlayCoverRuntimeJSONValue] {
        [
            "appKit": .object([
                "available": .bool(true),
                "windowNumber": .number(77),
                "frame": jsonRectangle(
                    CGRect(
                        x: 100,
                        y: 200,
                        width: contentWidth,
                        height: frameHeight
                    )
                ),
                "contentLayoutRect": jsonRectangle(
                    CGRect(
                        x: 0,
                        y: 0,
                        width: contentWidth,
                        height: contentHeight
                    )
                ),
                "contentViewBounds": jsonRectangle(
                    CGRect(
                        x: 0,
                        y: 0,
                        width: contentWidth,
                        height: contentHeight
                    )
                ),
                "backingScaleFactor": .number(2),
            ]),
        ]
    }

    private func jsonRectangle(
        _ rectangle: CGRect
    ) -> PlayCoverRuntimeJSONValue {
        .object([
            "x": .number(rectangle.minX),
            "y": .number(rectangle.minY),
            "width": .number(rectangle.width),
            "height": .number(rectangle.height),
        ])
    }
}

final class PlayCoverScreenshotNormalizerTests: XCTestCase {
    func testScaledPresentationUsesUniformContentToTargetCaptureScale() throws {
        let scale = try PlayCoverScreenshotNormalizer.uniformCaptureScale(
            targetPixelSize: CGSize(width: 1_290, height: 2_796),
            contentSize: CGSize(width: 332, height: 718)
        )

        XCTAssertEqual(scale, 3.8898, accuracy: 0.0001)
        XCTAssertNotEqual(scale, 3, accuracy: 0.01)
    }

    func testNonUniformContentToTargetCaptureScaleIsRejected() {
        XCTAssertThrowsError(
            try PlayCoverScreenshotNormalizer.uniformCaptureScale(
                targetPixelSize: CGSize(width: 1_290, height: 2_796),
                contentSize: CGSize(width: 332, height: 700)
            )
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverScreenCaptureError,
                .invalidGeometry(
                    "content-to-target capture scale is not approximately uniform"
                )
            )
        }
    }

    func testCropRectangleRemovesTopTitlebarAtCaptureScale() throws {
        let crop = try PlayCoverScreenshotNormalizer.cropRectangle(
            imagePixelSize: CGSize(width: 1_290, height: 2_880),
            windowFrame: CGRect(x: 100, y: 200, width: 430, height: 960),
            contentLayoutRect: CGRect(x: 0, y: 0, width: 430, height: 932)
        )

        XCTAssertEqual(crop, CGRect(x: 0, y: 84, width: 1_290, height: 2_796))
    }

    func testNormalizationProducesExactNativeJPEGDimensions() throws {
        let image = try makeImage(width: 860, height: 1_920)

        let jpeg = try PlayCoverScreenshotNormalizer.normalizeJPEG(
            image: image,
            windowFrame: CGRect(x: 0, y: 0, width: 430, height: 960),
            contentLayoutRect: CGRect(x: 0, y: 0, width: 430, height: 932),
            targetPixelSize: CGSize(width: 1_290, height: 2_796)
        )

        XCTAssertEqual(try jpegPixelSize(jpeg), CGSize(width: 1_290, height: 2_796))
    }

    func testInvalidContentCropIsRejected() throws {
        XCTAssertThrowsError(
            try PlayCoverScreenshotNormalizer.cropRectangle(
                imagePixelSize: CGSize(width: 1_290, height: 2_880),
                windowFrame: CGRect(x: 0, y: 0, width: 430, height: 960),
                contentLayoutRect: CGRect(x: 0, y: 0, width: 500, height: 932)
            )
        ) {
            guard case .invalidGeometry =
                    $0 as? PlayCoverScreenCaptureError else {
                return XCTFail("unexpected error: \($0)")
            }
        }
    }

    func testNonUniformCapturedRasterIsRejectedBeforeCropping() throws {
        XCTAssertThrowsError(
            try PlayCoverScreenshotNormalizer.cropRectangle(
                imagePixelSize: CGSize(width: 1_290, height: 2_600),
                windowFrame: CGRect(x: 0, y: 0, width: 430, height: 960),
                contentLayoutRect: CGRect(x: 0, y: 0, width: 430, height: 932)
            )
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverScreenCaptureError,
                .invalidGeometry(
                    "captured image-to-window scale is not approximately uniform"
                )
            )
        }
    }

    func testScreenCaptureKitPermissionErrorMappingIsExplicit() {
        let denied = NSError(
            domain: SCStreamErrorDomain,
            code: -3_801
        )
        XCTAssertEqual(
            PlayCoverScreenCaptureKitProvider.mapScreenCaptureKitError(
                denied,
                hasScreenCaptureAccess: true
            ),
            .screenRecordingPermissionDenied
        )
        XCTAssertEqual(
            PlayCoverScreenCaptureKitProvider.mapScreenCaptureKitError(
                NSError(domain: "fixture", code: 7),
                hasScreenCaptureAccess: false
            ),
            .screenRecordingPermissionDenied
        )
    }

    func testShareableContentErrorsKeepEnumerationPhase() {
        let fixture = NSError(
            domain: "fixture",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "enumeration failed"]
        )
        XCTAssertEqual(
            PlayCoverScreenCaptureKitProvider.mapShareableContentError(
                fixture,
                hasScreenCaptureAccess: true
            ),
            .shareableContentFailed("fixture 7: enumeration failed")
        )
        XCTAssertEqual(
            PlayCoverScreenCaptureKitProvider.mapShareableContentError(
                fixture,
                hasScreenCaptureAccess: false
            ),
            .screenRecordingPermissionDenied
        )
    }
}

private final class FakePlayCoverScreenshotProvider:
    PlayCoverWindowScreenshotProviding {
    private let image: CGImage?
    private let error: Error?
    private(set) var requests: [PlayCoverWindowCaptureRequest] = []

    init(image: CGImage) {
        self.image = image
        error = nil
    }

    init(error: Error) {
        image = nil
        self.error = error
    }

    func captureWindow(
        _ request: PlayCoverWindowCaptureRequest
    ) throws -> CGImage {
        requests.append(request)
        if let error {
            throw error
        }
        return try XCTUnwrap(image)
    }
}

private func makeImage(width: Int, height: Int) throws -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw PlayCoverScreenCaptureError.imageCreationFailed
    }
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
