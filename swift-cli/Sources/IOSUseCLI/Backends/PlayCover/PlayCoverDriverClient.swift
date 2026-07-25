import CoreGraphics
import Foundation
import ImageIO
import IOSUseProtocol

enum PlayCoverDriverClientError: Error, Equatable, CustomStringConvertible, Sendable {
    case incompleteSessionIdentity(String)
    case runtimeIdentityMismatch(String)
    case runtimeCapabilityUnavailable(String)
    case runtimeGeometryMismatch(String)
    case malformedRuntimePayload(String)
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
        case .malformedRuntimePayload(let field):
            return "PlayCover Runtime returned a malformed \(field) payload"
        case .capabilityUnavailable(let command):
            return "PlayCover Runtime capability `\(command)` is not implemented yet"
        case .lifecycleCommandUnsupported(let command):
            return "PlayCover does not support Driver `\(command)`; use `ios-use start --playcover` and `ios-use stop` for App lifecycle"
        }
    }
}

final class PlayCoverDriverClient: DriverCommandClient {
    static let logicalSize = CGSize(width: 430, height: 932)
    static let nativePixelSize = CGSize(width: 1_290, height: 2_796)
    static let profileScale = 3.0
    static let maximumRuntimeJPEGBytes = 11 * 1024 * 1024
    static let maximumRuntimeBase64Bytes = 15 * 1024 * 1024

    private let session: SessionService.Info
    private let runtimeScreenshotRequester:
        () throws -> PlayCoverRuntimeResponsePayload
    private let runtimeDOMRequester:
        (PlayCoverRuntimeDOMArguments) throws
            -> PlayCoverRuntimeResponsePayload
    private let runtimeWaitForRequester:
        (PlayCoverRuntimeWaitForArguments, TimeInterval) throws
            -> PlayCoverRuntimeResponsePayload

    convenience init(session: SessionService.Info) {
        self.init(
            session: session,
            runtimeScreenshotRequester: {
                try Self.runtimeClient(
                    for: session,
                    timeoutSeconds:
                        PlayCoverRuntimeClient.screenshotTimeoutSeconds
                ).screenshot()
            },
            runtimeDOMRequester: { arguments in
                try Self.runtimeClient(
                    for: session,
                    timeoutSeconds:
                        PlayCoverRuntimeClient.defaultTimeoutSeconds
                ).dom(arguments)
            },
            runtimeWaitForRequester: { arguments, timeoutSeconds in
                try Self.runtimeClient(
                    for: session,
                    timeoutSeconds: timeoutSeconds
                ).waitFor(arguments)
            }
        )
    }

    init(
        session: SessionService.Info,
        runtimeScreenshotRequester:
            @escaping () throws -> PlayCoverRuntimeResponsePayload,
        runtimeDOMRequester:
            @escaping (PlayCoverRuntimeDOMArguments) throws
                -> PlayCoverRuntimeResponsePayload = { _ in
                    throw PlayCoverDriverClientError
                        .capabilityUnavailable("dom")
                },
        runtimeWaitForRequester:
            @escaping (
                PlayCoverRuntimeWaitForArguments,
                TimeInterval
            ) throws -> PlayCoverRuntimeResponsePayload = { _, _ in
                throw PlayCoverDriverClientError
                    .capabilityUnavailable("waitFor")
            }
    ) {
        self.session = session
        self.runtimeScreenshotRequester = runtimeScreenshotRequester
        self.runtimeDOMRequester = runtimeDOMRequester
        self.runtimeWaitForRequester = runtimeWaitForRequester
    }

    func close() {}

    func screenshot() throws -> Data {
        try screenshotCapture().jpeg
    }

    func screenshotCapture() throws -> ScreenshotCapture {
        let expected = try ExpectedRuntimeIdentity(session: session)
        let payload = try runtimeScreenshotRequester()
        try validateRuntime(
            payload,
            expected: expected,
            requiredCapability:
                PlayCoverRuntimeCommand.screenshot.rawValue
        )
        try validateFixedProfile(payload)
        guard let screenshot = payload.screenshot else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("screenshot")
        }
        let jpeg = try decodeRuntimeJPEG(screenshot)
        let warning = screenshot.complete
            ? nil
            : "PlayCover Runtime reported an incomplete \(screenshot.source) screenshot"
        return ScreenshotCapture(
            jpeg: jpeg,
            pixelSize: ForyPoint(
                x: Double(screenshot.pixelWidth),
                y: Double(screenshot.pixelHeight)
            ),
            logicalSize: ForyPoint(
                x: screenshot.logicalWidth,
                y: screenshot.logicalHeight
            ),
            scale: screenshot.scale,
            geometrySource:
                "playcover-runtime-\(screenshot.source)",
            warning: warning
        )
    }

    func dom(
        raw: Bool,
        fresh: Bool,
        waitQuiescence: Bool
    ) throws -> ForyDomPayload {
        let expected = try ExpectedRuntimeIdentity(session: session)
        let arguments = PlayCoverRuntimeDOMArguments(
            raw: raw,
            fresh: fresh,
            waitQuiescence: waitQuiescence
        )
        let response = try translateRuntimeError {
            try runtimeDOMRequester(arguments)
        }
        try validateRuntime(
            response,
            expected: expected,
            requiredCapability: PlayCoverRuntimeCommand.dom.rawValue
        )
        guard let payload = response.dom else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("dom")
        }
        return try mapDOM(payload)
    }

    func waitFor(
        label: String,
        timeout: Double?,
        traits: String?,
        cindex: Int32?
    ) throws -> ForyWaitForPayload {
        try waitFor(
            label: label,
            timeout: timeout,
            traits: traits,
            cindex: cindex,
            gone: false
        )
    }

    func waitFor(
        label: String,
        timeout: Double?,
        traits: String?,
        cindex: Int32?,
        gone: Bool
    ) throws -> ForyWaitForPayload {
        try waitFor(
            label: label,
            timeout: timeout,
            traits: traits,
            cindex: cindex,
            gone: gone,
            matchMode: .standard
        )
    }

    func waitFor(
        label: String,
        timeout: Double?,
        traits: String?,
        cindex: Int32?,
        gone: Bool,
        matchMode: IOSUseWaitForMatchMode
    ) throws -> ForyWaitForPayload {
        let expected = try ExpectedRuntimeIdentity(session: session)
        let requestedTimeout = timeout ?? 0
        let arguments = PlayCoverRuntimeWaitForArguments(
            target: PlayCoverRuntimeWaitTarget(
                label: label,
                traits: traits ?? "",
                cindex: cindex
            ),
            timeout: requestedTimeout,
            gone: gone,
            matchMode: matchMode.rawValue
        )
        let response = try translateRuntimeError {
            try runtimeWaitForRequester(
                arguments,
                TimeInterval(
                    IOSUseProtocol.waitForSocketReadTimeoutSeconds(
                        requestedTimeout
                    )
                )
            )
        }
        try validateRuntime(
            response,
            expected: expected,
            requiredCapability: PlayCoverRuntimeCommand.waitFor.rawValue
        )
        guard let payload = response.waitFor else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("waitFor")
        }
        return ForyWaitForPayload(
            element: ForyElementSummary(
                elemType: payload.element.elemType,
                label: payload.element.label,
                rect: try mapRect(payload.element.rect),
                ancestors: payload.element.ancestors
            ),
            waited: payload.waited
        )
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
        expected: ExpectedRuntimeIdentity,
        requiredCapability: String =
            PlayCoverRuntimeCommand.diagnostics.rawValue
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
        guard payload.capabilities.contains(requiredCapability) else {
            throw PlayCoverDriverClientError.runtimeCapabilityUnavailable(
                requiredCapability
            )
        }
    }

    private static func runtimeClient(
        for session: SessionService.Info,
        timeoutSeconds: TimeInterval
    ) throws -> PlayCoverRuntimeClient {
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
        return PlayCoverRuntimeClient(
            socketPath: socketPath,
            launchNonce: launchNonce,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func translateRuntimeError<T>(
        _ operation: () throws -> T
    ) throws -> T {
        do {
            return try operation()
        } catch let error as PlayCoverRuntimeClientError {
            guard case .remoteError(
                let code,
                let message,
                let details?
            ) = error else {
                throw error
            }
            let target = details.target.map {
                ForyTarget(
                    label: $0.label,
                    traits: $0.traits,
                    cindex: $0.cindex
                )
            }
            let candidates = try details.candidates.map { candidate in
                ForyErrorCandidate(
                    element: ForyFindMatch(
                        elemType: candidate.element.elemType,
                        label: candidate.element.label,
                        rect: try mapRect(candidate.element.rect),
                        traits: candidate.element.traits,
                        value: candidate.element.value,
                        ancestors: candidate.element.ancestors
                    ),
                    rejectedBy: candidate.rejectedBy
                )
            }
            throw DriverClientError.driverError(
                message: message,
                payload: ForyErrorPayload(
                    category: details.category,
                    code: code,
                    phase: details.phase,
                    retryable: details.retryable,
                    fatal: details.fatal,
                    target: target,
                    candidateCount: details.candidateCount,
                    suggestions: details.suggestions,
                    candidates: candidates
                )
            )
        }
    }

    private func mapDOM(
        _ payload: PlayCoverRuntimeDOMPayload
    ) throws -> ForyDomPayload {
        ForyDomPayload(
            app: payload.app,
            windowSize: ForyPoint(
                x: payload.windowSize.x,
                y: payload.windowSize.y
            ),
            raw: payload.raw,
            elements: try payload.elements.map {
                ForyDomElement(
                    traits: $0.traits,
                    childCount: $0.childCount,
                    label: $0.label,
                    value: $0.value,
                    rect: try mapRect($0.rect)
                )
            }
        )
    }

    private func mapRect(
        _ rectangle: PlayCoverRuntimeRect?
    ) throws -> ForyRect? {
        guard let rectangle else {
            return nil
        }
        let values = [
            rectangle.x,
            rectangle.y,
            rectangle.w,
            rectangle.h,
        ]
        guard values.allSatisfy(\.isFinite),
              values.allSatisfy({
                  $0.rounded() >= Double(Int32.min)
                      && $0.rounded() <= Double(Int32.max)
              }) else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("rectangle")
        }
        return ForyRect(
            x: Int32(rectangle.x.rounded()),
            y: Int32(rectangle.y.rounded()),
            w: Int32(rectangle.w.rounded()),
            h: Int32(rectangle.h.rounded())
        )
    }

    private func validateFixedProfile(
        _ payload: PlayCoverRuntimeResponsePayload
    ) throws {
        let checks: [(Bool, String)] = [
            (
                approximatelyEqual(
                    payload.logicalWidth,
                    Self.logicalSize.width
                ),
                "logical width"
            ),
            (
                approximatelyEqual(
                    payload.logicalHeight,
                    Self.logicalSize.height
                ),
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
        if let mismatch = checks.first(where: { !$0.0 }) {
            throw PlayCoverDriverClientError.runtimeGeometryMismatch(
                mismatch.1
            )
        }
    }

    private func decodeRuntimeJPEG(
        _ screenshot: PlayCoverRuntimeScreenshotPayload
    ) throws -> Data {
        guard screenshot.pixelWidth
                == Int(Self.nativePixelSize.width),
              screenshot.pixelHeight
                == Int(Self.nativePixelSize.height),
              approximatelyEqual(
                  screenshot.logicalWidth,
                  Self.logicalSize.width
              ),
              approximatelyEqual(
                  screenshot.logicalHeight,
                  Self.logicalSize.height
              ),
              approximatelyEqual(
                  screenshot.scale,
                  Self.profileScale
              ) else {
            throw PlayCoverDriverClientError
                .runtimeGeometryMismatch("screenshot geometry")
        }
        let allowedSources: Set<String> = [
            "cgwindow-self",
            "_UICreateScreenUIImage",
            "UICreateScreenImage",
            "draw-view-hierarchy",
        ]
        guard allowedSources.contains(screenshot.source) else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("screenshot source")
        }
        guard screenshot.jpegBase64.utf8.count > 0,
              screenshot.jpegBase64.utf8.count
                <= Self.maximumRuntimeBase64Bytes,
              let jpeg = Data(
                  base64Encoded: screenshot.jpegBase64
              ),
              jpeg.base64EncodedString()
                == screenshot.jpegBase64 else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("screenshot base64")
        }
        guard jpeg.count > 4,
              jpeg.count <= Self.maximumRuntimeJPEGBytes,
              jpeg.prefix(3) == Data([0xFF, 0xD8, 0xFF]),
              jpeg.suffix(2) == Data([0xFF, 0xD9]),
              let source = CGImageSourceCreateWithData(
                  jpeg as CFData,
                  nil
              ),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String?
                == "public.jpeg",
              CGImageSourceGetStatusAtIndex(source, 0)
                == .statusComplete,
              let properties =
                CGImageSourceCopyPropertiesAtIndex(
                    source,
                    0,
                    nil
                ) as? [CFString: Any],
              let width =
                properties[kCGImagePropertyPixelWidth]
                    as? NSNumber,
              let height =
                properties[kCGImagePropertyPixelHeight]
                    as? NSNumber,
              width.intValue == screenshot.pixelWidth,
              height.intValue == screenshot.pixelHeight else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("screenshot JPEG")
        }
        return jpeg
    }

    private func approximatelyEqual(
        _ lhs: Double,
        _ rhs: Double
    ) -> Bool {
        abs(lhs - rhs) < 0.01
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
