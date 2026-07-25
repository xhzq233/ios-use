import CoreGraphics
import Foundation
import IOSUseProtocol

enum PlayCoverDriverClientError: Error, Equatable, CustomStringConvertible, Sendable {
    case incompleteSessionIdentity(String)
    case runtimeIdentityMismatch(String)
    case runtimeCapabilityUnavailable(String)
    case runtimeGeometryMismatch(String)
    case missingDiagnostics(String)
    case capabilityUnavailable(String)
    case lifecycleCommandUnsupported(String)

    var description: String {
        switch self {
        case .incompleteSessionIdentity(let field):
            return "active PlayCover session is missing \(field)"
        case .runtimeIdentityMismatch(let field):
            return "PlayCover Runtime diagnostics do not match active-session \(field)"
        case .runtimeCapabilityUnavailable(let capability):
            return "PlayCover Runtime does not advertise required capability `\(capability)`"
        case .runtimeGeometryMismatch(let field):
            return "PlayCover Runtime geometry does not match the fixed profile: \(field)"
        case .missingDiagnostics(let field):
            return "PlayCover Runtime diagnostics are missing \(field)"
        case .capabilityUnavailable(let command):
            return "PlayCover Runtime capability `\(command)` is not implemented yet"
        case .lifecycleCommandUnsupported(let command):
            return "PlayCover does not support Driver `\(command)`; use `ios-use start --playcover` and `ios-use stop` for App lifecycle"
        }
    }
}

struct PlayCoverRuntimeAppKitDiagnostics: Equatable, Sendable {
    let windowNumber: Int
    let windowFrame: CGRect
    let contentLayoutRect: CGRect
    let contentViewBounds: CGRect
    let backingScaleFactor: Double

    static func decode(
        from payload: PlayCoverRuntimeResponsePayload
    ) throws -> PlayCoverRuntimeAppKitDiagnostics {
        guard let observed = payload.observed ?? payload.diagnostics else {
            throw PlayCoverDriverClientError.missingDiagnostics("observed")
        }
        guard let appKit = observed["appKit"]?.objectValue else {
            throw PlayCoverDriverClientError.missingDiagnostics(
                "observed.appKit"
            )
        }
        guard appKit["available"]?.boolValue == true else {
            throw PlayCoverDriverClientError.missingDiagnostics(
                "an available AppKit window"
            )
        }
        guard let windowNumberValue = appKit["windowNumber"]?.numberValue,
              windowNumberValue.isFinite,
              windowNumberValue.rounded() == windowNumberValue,
              windowNumberValue > 0,
              windowNumberValue <= Double(UInt32.max) else {
            throw PlayCoverDriverClientError.missingDiagnostics(
                "observed.appKit.windowNumber"
            )
        }
        let frame = try decodeRectangle(
            appKit["frame"],
            field: "observed.appKit.frame"
        )
        let contentLayoutRect = try decodeRectangle(
            appKit["contentLayoutRect"],
            field: "observed.appKit.contentLayoutRect"
        )
        let contentViewBounds: CGRect
        if let directBounds = appKit["contentViewBounds"] {
            contentViewBounds = try decodeRectangle(
                directBounds,
                field: "observed.appKit.contentViewBounds"
            )
        } else if let contentView = appKit["contentView"]?.objectValue {
            contentViewBounds = try decodeRectangle(
                contentView["bounds"],
                field: "observed.appKit.contentView.bounds"
            )
        } else {
            throw PlayCoverDriverClientError.missingDiagnostics(
                "observed.appKit.contentViewBounds"
            )
        }
        guard let backingScaleFactor = appKit["backingScaleFactor"]?.numberValue,
              backingScaleFactor.isFinite,
              backingScaleFactor > 0 else {
            throw PlayCoverDriverClientError.missingDiagnostics(
                "observed.appKit.backingScaleFactor"
            )
        }
        return PlayCoverRuntimeAppKitDiagnostics(
            windowNumber: Int(windowNumberValue),
            windowFrame: frame,
            contentLayoutRect: contentLayoutRect,
            contentViewBounds: contentViewBounds,
            backingScaleFactor: backingScaleFactor
        )
    }

    private static func decodeRectangle(
        _ value: PlayCoverRuntimeJSONValue?,
        field: String
    ) throws -> CGRect {
        guard let fields = value?.objectValue,
              let x = fields["x"]?.numberValue,
              let y = fields["y"]?.numberValue,
              let width = fields["width"]?.numberValue,
              let height = fields["height"]?.numberValue,
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0 else {
            throw PlayCoverDriverClientError.missingDiagnostics(field)
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

final class PlayCoverDriverClient: DriverCommandClient {
    static let logicalSize = CGSize(width: 430, height: 932)
    static let nativePixelSize = CGSize(width: 1_290, height: 2_796)
    static let profileScale = 3.0

    private let session: SessionService.Info
    private let screenshotProvider: PlayCoverWindowScreenshotProviding
    private let runtimeDiagnosticsRequester:
        () throws -> PlayCoverRuntimeResponsePayload

    convenience init(session: SessionService.Info) {
        self.init(
            session: session,
            screenshotProvider: PlayCoverScreenCaptureKitProvider()
        ) {
            guard let socketPath = session.playCoverRuntimeSocketPath,
                  !socketPath.isEmpty else {
                throw PlayCoverDriverClientError.incompleteSessionIdentity(
                    "runtime socket path"
                )
            }
            guard let launchNonce = session.playCoverLaunchNonce,
                  !launchNonce.isEmpty else {
                throw PlayCoverDriverClientError.incompleteSessionIdentity(
                    "launch nonce"
                )
            }
            return try PlayCoverRuntimeClient(
                socketPath: socketPath,
                launchNonce: launchNonce
            ).diagnostics()
        }
    }

    init(
        session: SessionService.Info,
        screenshotProvider: PlayCoverWindowScreenshotProviding,
        runtimeDiagnosticsRequester:
            @escaping () throws -> PlayCoverRuntimeResponsePayload
    ) {
        self.session = session
        self.screenshotProvider = screenshotProvider
        self.runtimeDiagnosticsRequester = runtimeDiagnosticsRequester
    }

    func close() {}

    func screenshot() throws -> Data {
        try screenshotCapture().jpeg
    }

    func screenshotCapture() throws -> ScreenshotCapture {
        let expected = try ExpectedRuntimeIdentity(session: session)
        let payload = try runtimeDiagnosticsRequester()
        try validateRuntime(payload, expected: expected)
        let appKit = try PlayCoverRuntimeAppKitDiagnostics.decode(from: payload)
        try validateGeometry(payload, appKit: appKit)

        let request = PlayCoverWindowCaptureRequest(
            pid: payload.pid,
            windowNumber: appKit.windowNumber,
            windowFrame: appKit.windowFrame,
            contentLayoutRect: appKit.contentLayoutRect,
            targetPixelSize: Self.nativePixelSize
        )
        let rawImage = try screenshotProvider.captureWindow(request)
        let jpeg = try PlayCoverScreenshotNormalizer.normalizeJPEG(
            image: rawImage,
            windowFrame: appKit.windowFrame,
            contentLayoutRect: appKit.contentLayoutRect,
            targetPixelSize: Self.nativePixelSize
        )
        return ScreenshotCapture(
            jpeg: jpeg,
            pixelSize: ForyPoint(
                x: Self.nativePixelSize.width,
                y: Self.nativePixelSize.height
            ),
            logicalSize: ForyPoint(
                x: Self.logicalSize.width,
                y: Self.logicalSize.height
            ),
            scale: Self.profileScale,
            geometrySource:
                "playcover-runtime-appkit+screencapturekit-window"
        )
    }

    func dom(
        raw: Bool,
        fresh: Bool,
        waitQuiescence: Bool
    ) throws -> ForyDomPayload {
        try unavailable("dom")
    }

    func waitFor(
        label: String,
        timeout: Double?,
        traits: String?,
        cindex: Int32?
    ) throws -> ForyWaitForPayload {
        try unavailable("waitFor")
    }

    func waitFor(
        label: String,
        timeout: Double?,
        traits: String?,
        cindex: Int32?,
        gone: Bool
    ) throws -> ForyWaitForPayload {
        try unavailable("waitFor")
    }

    func waitFor(
        label: String,
        timeout: Double?,
        traits: String?,
        cindex: Int32?,
        gone: Bool,
        matchMode: IOSUseWaitForMatchMode
    ) throws -> ForyWaitForPayload {
        try unavailable("waitFor")
    }

    func tap(
        target: ForyTarget,
        traits: String?,
        cindex: Int32?,
        offset: ForyPoint?,
        ratio: ForyPoint
    ) throws -> ForyElementPayload {
        try unavailable("tap")
    }

    func longPress(
        target: ForyTarget,
        durationMs: Int?,
        traits: String?,
        cindex: Int32?
    ) throws -> ForyElementPayload {
        try unavailable("longPress")
    }

    func input(tap: ForyTarget?, content: String) throws {
        throw PlayCoverDriverClientError.capabilityUnavailable("input")
    }

    func swipe(
        to: ForyTarget,
        from: ForyTarget,
        distance: Double?,
        dir: String?,
        traits: String?,
        cindex: Int32?
    ) throws -> ForySwipePayload {
        try unavailable("swipe")
    }

    func activateApp(bundleId: String) throws {
        throw PlayCoverDriverClientError.lifecycleCommandUnsupported(
            "activateApp"
        )
    }

    func terminateApp(bundleId: String) throws {
        throw PlayCoverDriverClientError.lifecycleCommandUnsupported(
            "terminateApp"
        )
    }

    func home() throws {
        throw PlayCoverDriverClientError.lifecycleCommandUnsupported("home")
    }

    func dismissAlert(index: Int?) throws -> ForyAlertPayload {
        try unavailable("dismissAlert")
    }

    func proxyCAPush(caBase64: String) throws -> ForyProxyPayload {
        try unavailable("proxyCAPush")
    }

    func waitAppForeground(
        expectedBundleId: String,
        timeout: Double,
        returnDom: Bool
    ) throws -> ForyWaitAppForegroundPayload {
        try unavailable("waitAppForeground")
    }

    func waitAppForeground(
        acceptedBundleIds: [String],
        timeout: Double,
        returnDom: Bool
    ) throws -> ForyWaitAppForegroundPayload {
        try unavailable("waitAppForeground")
    }

    private func unavailable<T>(_ command: String) throws -> T {
        throw PlayCoverDriverClientError.capabilityUnavailable(command)
    }

    private func validateRuntime(
        _ payload: PlayCoverRuntimeResponsePayload,
        expected: ExpectedRuntimeIdentity
    ) throws {
        let checks: [(Bool, String)] = [
            (
                payload.protocolVersion == PlayCoverRuntimeClient.schemaVersion,
                "protocol version"
            ),
            (payload.pid == expected.pid, "pid"),
            (payload.bundleIdentifier == expected.bundleIdentifier, "bundle ID"),
            (payload.profileHash == expected.profileHash, "profile hash"),
            (
                payload.preparedGenerationID == expected.preparedGenerationID,
                "prepared generation"
            ),
            (payload.runtimeSocketPath == expected.socketPath, "socket path"),
            (
                payload.runtimeInstanceID == expected.runtimeInstanceID,
                "runtime instance"
            ),
            (payload.launchNonce == expected.launchNonce, "launch nonce"),
        ]
        if let mismatch = checks.first(where: { !$0.0 }) {
            throw PlayCoverDriverClientError.runtimeIdentityMismatch(mismatch.1)
        }
        guard payload.capabilities.contains("diagnostics") else {
            throw PlayCoverDriverClientError.runtimeCapabilityUnavailable(
                "diagnostics"
            )
        }
    }

    private func validateGeometry(
        _ payload: PlayCoverRuntimeResponsePayload,
        appKit: PlayCoverRuntimeAppKitDiagnostics
    ) throws {
        let profileChecks: [(Bool, String)] = [
            (
                approximatelyEqual(payload.logicalWidth, Self.logicalSize.width),
                "logical width"
            ),
            (
                approximatelyEqual(payload.logicalHeight, Self.logicalSize.height),
                "logical height"
            ),
            (
                approximatelyEqual(
                    payload.nativeWidth,
                    Self.nativePixelSize.width
                ),
                "native width"
            ),
            (
                approximatelyEqual(
                    payload.nativeHeight,
                    Self.nativePixelSize.height
                ),
                "native height"
            ),
            (
                approximatelyEqual(payload.scale, Self.profileScale),
                "scale"
            ),
            (payload.stage == "window-configured", "runtime stage"),
        ]
        if let mismatch = profileChecks.first(where: { !$0.0 }) {
            throw PlayCoverDriverClientError.runtimeGeometryMismatch(
                mismatch.1
            )
        }

        guard let windowWidth = payload.windowWidth,
              let windowHeight = payload.windowHeight else {
            throw PlayCoverDriverClientError.runtimeGeometryMismatch(
                "window presentation size"
            )
        }
        let reportedScale = try presentationScale(
            width: windowWidth,
            height: windowHeight,
            field: "reported window presentation"
        )
        let layoutScale = try presentationScale(
            width: appKit.contentLayoutRect.width,
            height: appKit.contentLayoutRect.height,
            field: "AppKit content layout presentation"
        )
        let contentViewScale = try presentationScale(
            width: appKit.contentViewBounds.width,
            height: appKit.contentViewBounds.height,
            field: "AppKit content-view presentation"
        )
        guard approximatelyUniform(reportedScale, layoutScale),
              approximatelyUniform(layoutScale, contentViewScale) else {
            throw PlayCoverDriverClientError.runtimeGeometryMismatch(
                "AppKit presentation surfaces disagree"
            )
        }
    }

    private func approximatelyEqual(
        _ lhs: Double,
        _ rhs: Double
    ) -> Bool {
        abs(lhs - rhs) < 0.01
    }

    private func presentationScale(
        width: Double,
        height: Double,
        field: String
    ) throws -> Double {
        let horizontal = width / Self.logicalSize.width
        let vertical = height / Self.logicalSize.height
        guard horizontal.isFinite, vertical.isFinite,
              horizontal > 0, vertical > 0,
              horizontal <= 1, vertical <= 1,
              approximatelyUniform(horizontal, vertical) else {
            throw PlayCoverDriverClientError.runtimeGeometryMismatch(field)
        }
        return (horizontal + vertical) / 2
    }

    private func approximatelyUniform(
        _ lhs: Double,
        _ rhs: Double
    ) -> Bool {
        let largest = max(lhs, rhs)
        return largest > 0 && abs(lhs - rhs) / largest <= 0.01
    }
}

private struct ExpectedRuntimeIdentity {
    let pid: Int32
    let bundleIdentifier: String
    let profileHash: String
    let preparedGenerationID: String
    let socketPath: String
    let runtimeInstanceID: String
    let launchNonce: String

    init(session: SessionService.Info) throws {
        guard let runnerPID = session.runnerPid,
              runnerPID > 0,
              runnerPID <= Int(Int32.max) else {
            throw PlayCoverDriverClientError.incompleteSessionIdentity("pid")
        }
        guard let bundleIdentifier = session.bundleId,
              !bundleIdentifier.isEmpty else {
            throw PlayCoverDriverClientError.incompleteSessionIdentity(
                "bundle ID"
            )
        }
        guard let profileHash = session.profileHash,
              !profileHash.isEmpty else {
            throw PlayCoverDriverClientError.incompleteSessionIdentity(
                "profile hash"
            )
        }
        guard let preparedGenerationID =
                session.playCoverPreparedGenerationID,
              !preparedGenerationID.isEmpty else {
            throw PlayCoverDriverClientError.incompleteSessionIdentity(
                "prepared generation"
            )
        }
        guard let socketPath = session.playCoverRuntimeSocketPath,
              !socketPath.isEmpty else {
            throw PlayCoverDriverClientError.incompleteSessionIdentity(
                "runtime socket path"
            )
        }
        guard let runtimeInstanceID = session.playCoverRuntimeInstanceID,
              !runtimeInstanceID.isEmpty else {
            throw PlayCoverDriverClientError.incompleteSessionIdentity(
                "runtime instance"
            )
        }
        guard let launchNonce = session.playCoverLaunchNonce,
              !launchNonce.isEmpty else {
            throw PlayCoverDriverClientError.incompleteSessionIdentity(
                "launch nonce"
            )
        }
        pid = Int32(runnerPID)
        self.bundleIdentifier = bundleIdentifier
        self.profileHash = profileHash
        self.preparedGenerationID = preparedGenerationID
        self.socketPath = socketPath
        self.runtimeInstanceID = runtimeInstanceID
        self.launchNonce = launchNonce
    }
}

private extension PlayCoverRuntimeJSONValue {
    var objectValue: [String: PlayCoverRuntimeJSONValue]? {
        guard case .object(let value) = self else {
            return nil
        }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else {
            return nil
        }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else {
            return nil
        }
        return value
    }
}
