import CoreGraphics
import Foundation
import ImageIO
import IOSUsePlayDevice
import IOSUseProtocol

enum PlayCoverDriverClientError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case incompleteSessionIdentity(String)
    case runtimeGeometryMismatch(String)
    case malformedRuntimePayload(String)
    case capabilityUnavailable(String)
    case lifecycleCommandUnsupported(String)

    var description: String {
        switch self {
        case .incompleteSessionIdentity(let field):
            return "active PlayCover session is missing \(field)"
        case .runtimeGeometryMismatch(let field):
            return "PlayCover Runtime geometry does not match the fixed device contract: \(field)"
        case .malformedRuntimePayload(let field):
            return "PlayCover Runtime returned a malformed \(field) payload"
        case .capabilityUnavailable(let command):
            return "PlayCover Runtime capability `\(command)` is unavailable"
        case .lifecycleCommandUnsupported(let command):
            return "PlayCover does not support Driver `\(command)`; use `ios-use start --playcover` and `ios-use stop` for App lifecycle"
        }
    }
}

final class PlayCoverDriverClient: DriverCommandClient {
    typealias RuntimeRequester = (
        PlayCoverRuntimeCommand,
        PlayCoverRuntimeRequestArguments,
        TimeInterval
    ) throws -> PlayCoverRuntimeResponsePayload

    static let logicalSize = CGSize(
        width: Int(IOSUsePlayDeviceLogicalWidth),
        height: Int(IOSUsePlayDeviceLogicalHeight)
    )
    static let nativePixelSize = CGSize(
        width: Int(IOSUsePlayDeviceNativeWidth),
        height: Int(IOSUsePlayDeviceNativeHeight)
    )
    static let deviceScale = Double(IOSUsePlayDeviceScale)
    static let maximumRuntimeJPEGBytes = 11 * 1024 * 1024
    static let maximumRuntimeBase64Bytes = 15 * 1024 * 1024

    private let session: SessionService.Info
    private let runtimeRequester: RuntimeRequester

    convenience init(session: SessionService.Info) {
        self.init(
            session: session,
            runtimeRequester: { command, arguments, timeout in
                try Self.runtimeClient(
                    for: session,
                    timeoutSeconds: timeout
                ).request(command, arguments: arguments)
            }
        )
    }

    init(
        session: SessionService.Info,
        runtimeRequester: @escaping RuntimeRequester
    ) {
        self.session = session
        self.runtimeRequester = runtimeRequester
    }

    func close() {}

    func screenshot() throws -> Data {
        try screenshotCapture().jpeg
    }

    func screenshotCapture() throws -> ScreenshotCapture {
        guard case .screenshot(let result) = try request(
            .screenshot,
            arguments: .empty(),
            timeout: PlayCoverRuntimeClient.screenshotTimeoutSeconds
        ) else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("screenshot response type")
        }
        return try mapScreenshot(result.screenshot)
    }

    func evidenceSnapshot() throws -> DriverEvidenceSnapshot {
        guard case .screenshot(let result) = try request(
            .screenshot,
            arguments: .empty(),
            timeout: PlayCoverRuntimeClient.screenshotTimeoutSeconds
        ) else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("screenshot response type")
        }
        let runtimeScreenshot = result.screenshot
        let runtimeDOM = result.dom
        let screenshot = try mapScreenshot(runtimeScreenshot)
        guard runtimeScreenshot.snapshotGeneration
                == runtimeDOM.snapshotGeneration,
              screenshot.snapshotGeneration
                == runtimeDOM.snapshotGeneration else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload(
                    "atomic screenshot/DOM generation"
                )
        }
        return DriverEvidenceSnapshot(
            screenshot: screenshot,
            dom: try mapDOM(runtimeDOM)
        )
    }

    func dom(
        raw: Bool,
        fresh: Bool,
        waitQuiescence: Bool
    ) throws -> ForyDomPayload {
        guard case .dom(let payload) = try request(
            .dom,
            arguments: .dom(
                PlayCoverRuntimeDOMArguments(
                    raw: raw,
                    fresh: fresh,
                    waitQuiescence: waitQuiescence
                )
            )
        ) else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("dom response type")
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
        let requestedTimeout = timeout ?? 0
        guard case .waitFor(let payload) = try request(
            .waitFor,
            arguments: .waitFor(
                PlayCoverRuntimeWaitForArguments(
                    target: PlayCoverRuntimeTarget(
                        label: label,
                        traits: traits ?? "",
                        cindex: cindex
                    ),
                    timeout: requestedTimeout,
                    gone: gone,
                    matchMode: matchMode.rawValue
                )
            ),
            timeout: TimeInterval(
                IOSUseProtocol.waitForSocketReadTimeoutSeconds(
                    requestedTimeout
                )
            )
        ) else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("waitFor response type")
        }
        return ForyWaitForPayload(
            element: try mapSummary(payload.element),
            waited: payload.waited,
            snapshotGeneration: payload.snapshotGeneration
        )
    }

    func tap(
        target: ForyTarget,
        traits: String?,
        cindex: Int32?,
        offset: ForyPoint?,
        ratio: ForyPoint?
    ) throws -> ForyElementPayload {
        guard case .tap(let payload) = try request(
            .tap,
            arguments: .tap(
                PlayCoverRuntimeTapArguments(
                    target: mapTarget(
                        target,
                        traits: traits,
                        cindex: cindex
                    ),
                    offset: offset.map(mapPoint),
                    ratio: ratio.map(mapPoint)
                )
            )
        ) else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("tap response type")
        }
        return try mapAction(payload)
    }

    func longPress(
        target: ForyTarget,
        durationMs: Int?,
        traits: String?,
        cindex: Int32?
    ) throws -> ForyElementPayload {
        guard case .longPress(let payload) = try request(
            .longPress,
            arguments: .longPress(
                PlayCoverRuntimeLongPressArguments(
                    target: mapTarget(
                        target,
                        traits: traits,
                        cindex: cindex
                    ),
                    durationMs: durationMs ?? 0
                )
            )
        ) else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("longPress response type")
        }
        return try mapAction(payload)
    }

    func input(
        tap: ForyTarget?,
        content: String
    ) throws -> ForyElementPayload {
        try input(
            tap: tap,
            content: content,
            deleteCount: 0,
            enter: false,
            traits: nil,
            cindex: nil
        )
    }

    func input(
        tap: ForyTarget?,
        content: String,
        deleteCount: Int,
        enter: Bool,
        traits: String?,
        cindex: Int32?
    ) throws -> ForyElementPayload {
        guard (0...1_048_576).contains(deleteCount) else {
            throw CLIParseError.invalidValue(
                "input delete count must be between 0 and 1048576"
            )
        }
        guard case .input(let payload) = try request(
            .input,
            arguments: .input(
                PlayCoverRuntimeInputArguments(
                    target: tap.map {
                        mapTarget(
                            $0,
                            traits: traits,
                            cindex: cindex
                        )
                    },
                    content: content,
                    deleteCount: deleteCount,
                    enter: enter
                )
            )
        ) else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("input response type")
        }
        return try mapAction(payload)
    }

    func swipe(
        to: ForyTarget,
        from: ForyTarget,
        distance: Double?,
        dir: String?,
        traits: String?,
        cindex: Int32?
    ) throws -> ForySwipePayload {
        let direction: Int32
        switch dir {
        case "forth":
            direction = IOSUseProtocol.XCConstants.swipeDirectionForth
        case "back":
            direction = IOSUseProtocol.XCConstants.swipeDirectionBack
        default:
            direction =
                IOSUseProtocol.XCConstants.swipeDirectionUnspecified
        }
        guard case .swipe(let payload) = try request(
            .swipe,
            arguments: .swipe(
                PlayCoverRuntimeSwipeArguments(
                    toTarget: isEmptyTarget(to)
                        ? nil
                        : mapTarget(
                            to,
                            traits: traits,
                            cindex: cindex
                        ),
                    fromTarget: isEmptyTarget(from)
                        ? PlayCoverRuntimeTarget(
                            label: "",
                            point: PlayCoverRuntimePoint(
                                x: Double(
                                    IOSUsePlayDeviceLogicalWidth
                                ) / 2,
                                y: Double(
                                    IOSUsePlayDeviceLogicalHeight
                                ) / 2
                            )
                        )
                        : mapTarget(
                            from,
                            traits: nil,
                            cindex: nil
                        ),
                    distance: distance ?? 0,
                    direction: direction,
                    durationMs: nil
                )
            ),
            timeout: TimeInterval(
                IOSUseProtocol.swipeSocketReadTimeoutSeconds(
                    ForySwipeArgs(
                        toTarget: to,
                        fromTarget: from,
                        distance: distance ?? 0,
                        dir: direction
                    )
                )
            )
        ) else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("swipe response type")
        }
        return ForySwipePayload(
            element: try mapSummary(payload.element),
            hitView: try mapHitView(payload.hitView),
            finalState: mapFinalState(payload.finalState),
            postcondition: nil,
            scrolls: payload.scrolls,
            scrollDirection: payload.direction
        )
    }

    private func isEmptyTarget(_ target: ForyTarget) -> Bool {
        target.point == nil && target.label.isEmpty
    }

    func dismissAlert(index: Int?) throws -> ForyAlertPayload {
        try dismissAlert(index: index, label: nil)
    }

    func dismissAlert(
        index: Int?,
        label: String?
    ) throws -> ForyAlertPayload {
        let response: PlayCoverRuntimeResponsePayload
        if let label {
            response = try request(
                .dismissAlertByLabel,
                arguments: .dismissAlertByLabel(
                    PlayCoverRuntimeDismissAlertByLabelArguments(
                        label: label
                    )
                )
            )
        } else {
            response = try request(
                .dismissAlert,
                arguments: .dismissAlert(
                    PlayCoverRuntimeDismissAlertArguments(
                        index: index
                    )
                )
            )
        }
        let payload: PlayCoverRuntimeAlertPayload
        switch response {
        case .dismissAlert(let result),
             .dismissAlertByLabel(let result):
            payload = result
        default:
            throw PlayCoverDriverClientError
                .malformedRuntimePayload(
                    "dismissAlert response type"
                )
        }
        return ForyAlertPayload(
            dismissed: payload.dismissed,
            text: payload.text,
            button: payload.button,
            reason: payload.reason,
            hitView: try payload.hitView.map(mapHitView),
            finalState: payload.finalState.map(mapFinalState),
            postcondition: nil
        )
    }

    struct OpenResult {
        let delivered: Bool
        let url: String
    }

    func openURL(_ url: String) throws -> OpenResult {
        guard case .open(let payload) = try request(
            .open,
            arguments: .open(
                PlayCoverRuntimeOpenArguments(url: url)
            )
        ) else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("open response type")
        }
        guard payload.delivered else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload(
                    "open delivery acknowledgement"
                )
        }
        return OpenResult(
            delivered: payload.delivered,
            url: payload.url
        )
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
        throw PlayCoverDriverClientError
            .lifecycleCommandUnsupported("home")
    }

    func proxyCAPush(caBase64: String) throws -> ForyProxyPayload {
        throw PlayCoverDriverClientError
            .capabilityUnavailable("proxyCAPush")
    }

    func waitAppForeground(
        expectedBundleId: String,
        timeout: Double,
        returnDom: Bool
    ) throws -> ForyWaitAppForegroundPayload {
        throw PlayCoverDriverClientError
            .lifecycleCommandUnsupported("waitAppForeground")
    }

    func waitAppForeground(
        acceptedBundleIds: [String],
        timeout: Double,
        returnDom: Bool
    ) throws -> ForyWaitAppForegroundPayload {
        throw PlayCoverDriverClientError
            .lifecycleCommandUnsupported("waitAppForeground")
    }

    private func request(
        _ command: PlayCoverRuntimeCommand,
        arguments: PlayCoverRuntimeRequestArguments,
        timeout: TimeInterval =
            PlayCoverRuntimeClient.defaultTimeoutSeconds
    ) throws -> PlayCoverRuntimeResponsePayload {
        try translateRuntimeError {
            try runtimeRequester(command, arguments, timeout)
        }
    }

    static func runtimeClient(
        for session: SessionService.Info,
        timeoutSeconds: TimeInterval
    ) throws -> PlayCoverRuntimeClient {
        let expected = try ExpectedRuntimeIdentity(session: session)
        guard let socketPath = session.playCoverRuntimeSocketPath,
              !socketPath.isEmpty else {
            throw PlayCoverDriverClientError.incompleteSessionIdentity(
                "runtime socket path"
            )
        }
        guard let sessionID = session.sessionIdentifier,
              !sessionID.isEmpty else {
            throw PlayCoverDriverClientError.incompleteSessionIdentity(
                "sessionID"
            )
        }
        return PlayCoverRuntimeClient(
            socketPath: socketPath,
            sessionID: sessionID,
            expectedPID: expected.pid,
            expectedBundleIdentifier: expected.bundleIdentifier,
            expectedExecutablePath: expected.executablePath,
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
                    point: $0.point.map {
                        ForyPoint(x: $0.x, y: $0.y)
                    },
                    traits: $0.traits,
                    cindex: $0.cindex
                )
            }
            let candidates = try details.candidates.map { candidate in
                ForyErrorCandidate(
                    element: ForyFindMatch(
                        elemType: candidate.element.elemType,
                        label: candidate.element.label,
                        rect: try mapRect(
                            candidate.element.effectiveRect
                        ),
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

    private func mapScreenshot(
        _ screenshot: PlayCoverRuntimeScreenshotPayload
    ) throws -> ScreenshotCapture {
        guard screenshot.complete else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload(
                    "incomplete \(screenshot.source) screenshot"
                )
        }
        guard screenshot.snapshotGeneration > 0,
              screenshot.captureGeneration > 0 else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("screenshot generation")
        }
        try Self.validateScreenshotFullFrame(screenshot)
        let jpeg = try decodeRuntimeJPEG(screenshot)
        var runtimeEvidence:
            [String: PlayCoverRuntimeJSONValue] = [
                "source": .string(screenshot.source),
                "complete": .bool(screenshot.complete),
                "syntheticChrome": .bool(screenshot.syntheticChrome),
                "fullFrame": Self.fullFrameEvidence(
                    screenshot.fullFrame
                ),
                "snapshotGeneration":
                    .number(Double(screenshot.snapshotGeneration)),
                "captureGeneration":
                    .number(Double(screenshot.captureGeneration)),
            ]
        if let windowNumbers =
            screenshot.compositorWindowNumbers {
            runtimeEvidence["compositorWindowNumbers"] =
                .array(
                    windowNumbers.map {
                        .number(Double($0))
                    }
                )
        }
        if let backingSizes = screenshot.sourceBackingSizes {
            runtimeEvidence["sourceBackingSizes"] =
                .array(backingSizes)
        }
        if let appKit = screenshot.appKitWindowEvidence {
            runtimeEvidence["appKitWindowEvidence"] = appKit
        }
        if let compositor = screenshot.compositor {
            runtimeEvidence["compositor"] = compositor
        }
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
            warning: nil,
            snapshotGeneration: screenshot.snapshotGeneration,
            captureGeneration: screenshot.captureGeneration,
            runtimeEvidence: runtimeEvidence
        )
    }

    private func mapDOM(
        _ payload: PlayCoverRuntimeDOMPayload
    ) throws -> ForyDomPayload {
        guard Self.approximatelyEqual(
                  payload.windowSize.x,
                  Self.logicalSize.width
              ),
              Self.approximatelyEqual(
                  payload.windowSize.y,
                  Self.logicalSize.height
              ) else {
            throw PlayCoverDriverClientError
                .runtimeGeometryMismatch("DOM window size")
        }
        let childCounts = Dictionary(
            grouping: payload.elements.compactMap {
                $0.hierarchy.parentID
            },
            by: { $0 }
        ).mapValues(\.count)
        return ForyDomPayload(
            app: payload.app,
            windowSize: ForyPoint(
                x: payload.windowSize.x,
                y: payload.windowSize.y
            ),
            raw: payload.raw,
            snapshotGeneration: payload.snapshotGeneration,
            elements: try payload.elements.map {
                ForyDomElement(
                    nodeID: $0.nodeID,
                    type: $0.type,
                    elementType: $0.elementType,
                    traits: $0.traits,
                    childCount: Int32(
                        childCounts[$0.nodeID] ?? 0
                    ),
                    label: $0.label,
                    value: $0.value,
                    identifier: $0.identifier,
                    hint: $0.hint,
                    className: $0.class,
                    state: mapState($0.state),
                    hierarchy: mapHierarchy($0.hierarchy),
                    ancestors: $0.ancestors,
                    zOrder: $0.zOrder,
                    snapshotGeneration: $0.snapshotGeneration,
                    rect: try mapRect($0.effectiveRect)
                )
            }
        )
    }

    private func mapSummary(
        _ element: PlayCoverRuntimeElementSummary
    ) throws -> ForyElementSummary {
        ForyElementSummary(
            nodeID: element.nodeID,
            type: element.type,
            elemType: element.elemType,
            label: element.label,
            value: element.value,
            identifier: element.identifier,
            hint: element.hint,
            className: element.class,
            traits: element.traits,
            state: mapState(element.state),
            rect: try mapRect(element.effectiveRect),
            hierarchy: mapHierarchy(element.hierarchy),
            ancestors: element.ancestors,
            zOrder: element.zOrder,
            snapshotGeneration: element.snapshotGeneration
        )
    }

    private func mapState(
        _ state: PlayCoverRuntimeDOMState
    ) -> ForyElementState {
        ForyElementState(
            enabled: state.enabled,
            visible: state.visible,
            selected: state.selected,
            focused: state.focused,
            opaque: state.opaque
        )
    }

    private func mapHierarchy(
        _ hierarchy: PlayCoverRuntimeDOMHierarchy
    ) -> ForyElementHierarchy {
        ForyElementHierarchy(
            parentID: hierarchy.parentID ?? "",
            depth: hierarchy.depth,
            index: hierarchy.index,
            path: hierarchy.path
        )
    }

    private func mapHitView(
        _ view: PlayCoverRuntimeHitView
    ) throws -> ForyHitView {
        ForyHitView(
            className: view.class,
            rect: try mapRect(view.frame?.rect),
            accessibilityIdentifier: view.accessibilityIdentifier,
            label: view.label
        )
    }

    private func mapFinalState(
        _ state: PlayCoverRuntimeFinalState
    ) -> ForyTouchFinalState {
        ForyTouchFinalState(
            point: ForyPoint(
                x: state.point.x,
                y: state.point.y
            ),
            touchID: state.touchID,
            phase: state.phase,
            firstResponderClass:
                state.firstResponderClass ?? ""
        )
    }

    private func mapAction(
        _ payload: PlayCoverRuntimeActionPayload
    ) throws -> ForyElementPayload {
        ForyElementPayload(
            element: try mapSummary(payload.element),
            hitView: try mapHitView(payload.hitView),
            finalState: mapFinalState(payload.finalState),
            postcondition: nil
        )
    }

    private func mapTarget(
        _ target: ForyTarget,
        traits: String?,
        cindex: Int32?
    ) -> PlayCoverRuntimeTarget {
        PlayCoverRuntimeTarget(
            label: target.label,
            point: target.point.map(mapPoint),
            traits: traits ?? target.traits,
            cindex: cindex ?? target.cindex
        )
    }

    private func mapPoint(
        _ point: ForyPoint
    ) -> PlayCoverRuntimePoint {
        PlayCoverRuntimePoint(x: point.x, y: point.y)
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

    static func validateFixedDevice(
        _ geometry: PlayCoverRuntimeGeometry,
        stage: String
    ) throws {
        let checks: [(Bool, String)] = [
            (
                approximatelyEqual(
                    geometry.logical.width,
                    Self.logicalSize.width
                ),
                "logical width"
            ),
            (
                approximatelyEqual(
                    geometry.logical.height,
                    Self.logicalSize.height
                ),
                "logical height"
            ),
            (
                approximatelyEqual(
                    geometry.native.width,
                    Self.nativePixelSize.width
                ),
                "native width"
            ),
            (
                approximatelyEqual(
                    geometry.native.height,
                    Self.nativePixelSize.height
                ),
                "native height"
            ),
            (
                approximatelyEqual(
                    geometry.scale,
                    Self.deviceScale
                ),
                "scale"
            ),
            (
                approximatelyEqual(
                    geometry.window.width,
                    Self.logicalSize.width
                ),
                "window width"
            ),
            (
                approximatelyEqual(
                    geometry.window.height,
                    Self.logicalSize.height
                ),
                "window height"
            ),
            (
                validNaturalSafeArea(
                    geometry.safeArea,
                    logicalSize: geometry.logical
                ),
                "safe-area diagnostics"
            ),
            (
                stage == "window-configured"
                    || stage == "ready",
                "runtime stage"
            ),
        ]
        if let mismatch = checks.first(where: { !$0.0 }) {
            throw PlayCoverDriverClientError
                .runtimeGeometryMismatch(mismatch.1)
        }
        try validateSimulatorScaleHost(geometry.host)
    }

    private static func validNaturalSafeArea(
        _ safeArea: PlayCoverRuntimeSafeArea,
        logicalSize: PlayCoverRuntimeSize
    ) -> Bool {
        let values = [
            safeArea.top,
            safeArea.left,
            safeArea.bottom,
            safeArea.right,
        ]
        guard values.allSatisfy(\.isFinite),
              values.allSatisfy({ $0 >= 0 }),
              safeArea.top <= logicalSize.height,
              safeArea.bottom <= logicalSize.height,
              safeArea.left <= logicalSize.width,
              safeArea.right <= logicalSize.width else {
            return false
        }
        return safeArea.top + safeArea.bottom <= logicalSize.height
            && safeArea.left + safeArea.right <= logicalSize.width
    }

    private static func validateSimulatorScaleHost(
        _ host: PlayCoverRuntimeHostGeometry?
    ) throws {
        guard let host else {
            throw PlayCoverDriverClientError
                .runtimeGeometryMismatch(
                    "simulator-scale host diagnostics"
                )
        }
        guard let backingPixelCanvasRect =
                host.backingPixelCanvasRect,
              let backingScaleFactor = host.backingScaleFactor,
              let halfPixelTolerance = host.halfPixelTolerance,
              backingScaleFactor.isFinite,
              backingScaleFactor > 0,
              backingScaleFactor <= 4,
              halfPixelTolerance.isFinite,
              halfPixelTolerance > 0,
              host.displayScale.isFinite,
              host.displayScale > 0,
              abs(
                  halfPixelTolerance -
                      0.5 / backingScaleFactor
              ) <= 0.000_001 else {
            throw PlayCoverDriverClientError
                .runtimeGeometryMismatch(
                    "simulator-scale host display scale"
                )
        }
        let geometryTolerance = halfPixelTolerance
        let logicalTolerance =
            halfPixelTolerance / host.displayScale
        guard logicalTolerance.isFinite, logicalTolerance > 0 else {
            throw PlayCoverDriverClientError
                .runtimeGeometryMismatch(
                    "simulator-scale host display scale"
                )
        }
        let logicalEdgeTolerance = logicalTolerance
        func withinHost(_ lhs: Double, _ rhs: Double) -> Bool {
            abs(lhs - rhs) <= geometryTolerance
        }
        func withinLogical(_ lhs: Double, _ rhs: Double) -> Bool {
            abs(lhs - rhs) <= logicalEdgeTolerance
        }
        func backingAligned(_ value: Double) -> Bool {
            let pixels = value * backingScaleFactor
            return abs(pixels - pixels.rounded()) <= 0.000_001
        }
        let expectedCanvasWidth =
            Self.logicalSize.width * host.displayScale
        let expectedCanvasHeight =
            Self.logicalSize.height * host.displayScale
        let leftMargin =
            host.canvasRect.x - host.contentBounds.x
        let rightMargin =
            host.contentBounds.x + host.contentBounds.width -
                host.canvasRect.x - host.canvasRect.width
        let bottomMargin =
            host.canvasRect.y - host.contentBounds.y
        let topMargin =
            host.contentBounds.y + host.contentBounds.height -
                host.canvasRect.y - host.canvasRect.height
        let horizontalSurplus = max(0, leftMargin + rightMargin)
        let verticalSurplus = max(0, bottomMargin + topMargin)
        // UIKitMacHelper can fold both centered subpixel edge margins into
        // one positive private render-view extent. Derive each axis from the
        // actual host surplus, bound it by those same two half-pixel edges,
        // and keep origins/undersize at one-edge tolerance. Input still uses
        // the ideal canvas transform rather than this raster extent.
        let privateWidthTolerance = max(
            logicalEdgeTolerance,
            min(
                horizontalSurplus / host.displayScale,
                logicalEdgeTolerance * 2
            )
        )
        let privateHeightTolerance = max(
            logicalEdgeTolerance,
            min(
                verticalSurplus / host.displayScale,
                logicalEdgeTolerance * 2
            )
        )
        let privateRenderRects = [
            host.sceneRenderViewFrame,
            host.sceneRenderViewBounds,
            host.inputRenderViewFrame,
            host.inputRenderViewBounds,
        ]
        let privateRenderRectsAgree =
            privateRenderRects.dropFirst().allSatisfy {
                approximatelyEqual(
                    $0.x,
                    privateRenderRects[0].x
                ) &&
                    approximatelyEqual(
                        $0.y,
                        privateRenderRects[0].y
                    ) &&
                    approximatelyEqual(
                        $0.width,
                        privateRenderRects[0].width
                    ) &&
                    approximatelyEqual(
                        $0.height,
                        privateRenderRects[0].height
                    )
            }
        let checks: [(Bool, String)] = [
            (
                host.status == "configured" && host.hostPolicy,
                "simulator-scale host policy"
            ),
            (
                host.opaque && host.publicTitleBar && host.titleVisible &&
                    host.resizable,
                "simulator-scale host presentation"
            ),
            (
                !host.title.isEmpty && host.title == host.titleExpected,
                "simulator-scale host title"
            ),
            (
                host.displayScale.isFinite && host.displayScale > 0 &&
                    host.inverseDisplayScale.isFinite &&
                    host.inverseDisplayScale > 0 &&
                    approximatelyEqual(
                        host.displayScale * host.inverseDisplayScale,
                        1
                    ) &&
                    host.idiomScale.isFinite &&
                    approximatelyEqual(host.idiomScale, 1) &&
                    approximatelyEqual(host.windowScale, 1) &&
                    !host.downscaleWindowIfNecessary,
                "simulator-scale host display scale"
            ),
            (
                validHostFrame(host.canvasBounds) &&
                    abs(host.canvasBounds.x) <= logicalEdgeTolerance &&
                    abs(host.canvasBounds.y) <= logicalEdgeTolerance &&
                    withinLogical(
                        host.canvasBounds.width,
                        Self.logicalSize.width
                    ) &&
                    withinLogical(
                        host.canvasBounds.height,
                        Self.logicalSize.height
                    ),
                "simulator-scale fixed canvas bounds"
            ),
            (
                fixedLogicalCanvasRect(
                    host.renderViewBounds,
                    tolerance: logicalTolerance
                ),
                "simulator-scale logical render-view bounds"
            ),
            (
                pixelQuantizedPrivateCanvasRect(
                    host.sceneRenderViewFrame,
                    originTolerance: logicalEdgeTolerance,
                    positiveWidthTolerance: privateWidthTolerance,
                    positiveHeightTolerance: privateHeightTolerance
                ),
                "simulator-scale logical scene-render frame"
            ),
            (
                pixelQuantizedPrivateCanvasRect(
                    host.sceneRenderViewBounds,
                    originTolerance: logicalEdgeTolerance,
                    positiveWidthTolerance: privateWidthTolerance,
                    positiveHeightTolerance: privateHeightTolerance
                ),
                "simulator-scale logical scene-render bounds"
            ),
            (
                pixelQuantizedPrivateCanvasRect(
                    host.inputRenderViewFrame,
                    originTolerance: logicalEdgeTolerance,
                    positiveWidthTolerance: privateWidthTolerance,
                    positiveHeightTolerance: privateHeightTolerance
                ),
                "simulator-scale logical input-render frame"
            ),
            (
                pixelQuantizedPrivateCanvasRect(
                    host.inputRenderViewBounds,
                    originTolerance: logicalEdgeTolerance,
                    positiveWidthTolerance: privateWidthTolerance,
                    positiveHeightTolerance: privateHeightTolerance
                ),
                "simulator-scale logical input-render bounds"
            ),
            (
                privateRenderRectsAgree,
                "simulator-scale private render-view consistency"
            ),
            (
                validHostFrame(host.frame) &&
                    validHostFrame(host.contentBounds) &&
                    validHostFrame(host.canvasRect) &&
                    validHostFrame(backingPixelCanvasRect) &&
                    backingAligned(backingPixelCanvasRect.x) &&
                    backingAligned(backingPixelCanvasRect.y) &&
                    backingAligned(
                        backingPixelCanvasRect.x +
                            backingPixelCanvasRect.width
                    ) &&
                    backingAligned(
                        backingPixelCanvasRect.y +
                            backingPixelCanvasRect.height
                    ) &&
                    withinHost(
                        host.canvasRect.width,
                        expectedCanvasWidth
                    ) &&
                    withinHost(
                        host.canvasRect.height,
                        expectedCanvasHeight
                    ) &&
                    hostFrameContains(
                        host.contentBounds,
                        host.canvasRect,
                        tolerance: geometryTolerance
                    ) &&
                    leftMargin >= -geometryTolerance &&
                    rightMargin >= -geometryTolerance &&
                    bottomMargin >= -geometryTolerance &&
                    topMargin >= -geometryTolerance &&
                    leftMargin + rightMargin <=
                        geometryTolerance * 2 &&
                    bottomMargin + topMargin <=
                        geometryTolerance * 2 &&
                    withinHost(leftMargin, rightMargin) &&
                    withinHost(bottomMargin, topMargin) &&
                    hostFrameContains(
                        host.contentBounds,
                        backingPixelCanvasRect,
                        tolerance: geometryTolerance
                    ) &&
                    withinHost(
                        backingPixelCanvasRect.x,
                        host.canvasRect.x
                    ) &&
                    withinHost(
                        backingPixelCanvasRect.y,
                        host.canvasRect.y
                    ) &&
                    withinHost(
                        backingPixelCanvasRect.x +
                            backingPixelCanvasRect.width,
                        host.canvasRect.x + host.canvasRect.width
                    ) &&
                    withinHost(
                        backingPixelCanvasRect.y +
                            backingPixelCanvasRect.height,
                        host.canvasRect.y + host.canvasRect.height
                    ),
                "simulator-scale host canvas layout"
            ),
            (
                host.capture.ready && host.capture.error == nil &&
                    (host.capture.hostWindowNumber ?? 0) > 0 &&
                    validHostFrame(host.capture.hostContentCGWindowRect) &&
                    validHostFrame(host.capture.hostCGWindowBounds) &&
                    validHostFrame(host.capture.canvasCGWindowRect) &&
                    withinHost(
                        host.capture.hostCGWindowBounds.width,
                        host.frame.width
                    ) &&
                    withinHost(
                        host.capture.hostCGWindowBounds.height,
                        host.frame.height
                    ) &&
                    withinHost(
                        host.capture.hostContentCGWindowRect.width,
                        host.contentBounds.width
                    ) &&
                    withinHost(
                        host.capture.hostContentCGWindowRect.height,
                        host.contentBounds.height
                    ) &&
                    withinHost(
                        host.capture.canvasCGWindowRect.width,
                        backingPixelCanvasRect.width
                    ) &&
                    withinHost(
                        host.capture.canvasCGWindowRect.height,
                        backingPixelCanvasRect.height
                    ) &&
                    hostFrameContains(
                        host.capture.hostCGWindowBounds,
                        host.capture.hostContentCGWindowRect,
                        tolerance: geometryTolerance
                    ) &&
                    hostFrameContains(
                        host.capture.hostCGWindowBounds,
                        host.capture.canvasCGWindowRect,
                        tolerance: geometryTolerance
                    ) &&
                    withinHost(
                        host.capture.canvasCGWindowRect.x,
                        host.capture.hostContentCGWindowRect.x +
                            backingPixelCanvasRect.x -
                            host.contentBounds.x
                    ) &&
                    withinHost(
                        host.capture.canvasCGWindowRect.y,
                        host.capture.hostContentCGWindowRect.y +
                            (host.contentBounds.y +
                                host.contentBounds.height -
                                backingPixelCanvasRect.y -
                                backingPixelCanvasRect.height)
                    ),
                "simulator-scale host canvas capture"
            ),
        ]
        if let mismatch = checks.first(where: { !$0.0 }) {
            throw PlayCoverDriverClientError
                .runtimeGeometryMismatch(mismatch.1)
        }
    }

    private static func validHostFrame(
        _ frame: PlayCoverRuntimeFrame
    ) -> Bool {
        [frame.x, frame.y, frame.width, frame.height]
            .allSatisfy(\.isFinite) &&
            frame.width > 0 && frame.height > 0
    }

    private static func fixedLogicalCanvasRect(
        _ frame: PlayCoverRuntimeFrame,
        tolerance: Double
    ) -> Bool {
        return abs(frame.x) <= tolerance &&
            abs(frame.y) <= tolerance &&
            abs(frame.width - logicalSize.width) <= tolerance &&
            abs(frame.height - logicalSize.height) <= tolerance
    }

    private static func pixelQuantizedPrivateCanvasRect(
        _ frame: PlayCoverRuntimeFrame,
        originTolerance: Double,
        positiveWidthTolerance: Double,
        positiveHeightTolerance: Double
    ) -> Bool {
        let widthDelta = frame.width - logicalSize.width
        let heightDelta = frame.height - logicalSize.height
        let maximumXDelta =
            frame.x + frame.width - logicalSize.width
        let maximumYDelta =
            frame.y + frame.height - logicalSize.height
        return abs(frame.x) <= originTolerance &&
            abs(frame.y) <= originTolerance &&
            widthDelta >= -originTolerance &&
            widthDelta <= positiveWidthTolerance + 0.000_001 &&
            heightDelta >= -originTolerance &&
            heightDelta <= positiveHeightTolerance + 0.000_001 &&
            maximumXDelta >= -originTolerance &&
            maximumXDelta <= positiveWidthTolerance + 0.000_001 &&
            maximumYDelta >= -originTolerance &&
            maximumYDelta <= positiveHeightTolerance + 0.000_001
    }

    private static func hostFrameContains(
        _ container: PlayCoverRuntimeFrame,
        _ candidate: PlayCoverRuntimeFrame,
        tolerance: Double
    ) -> Bool {
        return candidate.x >= container.x - tolerance &&
            candidate.y >= container.y - tolerance &&
            candidate.x + candidate.width <=
                container.x + container.width + tolerance &&
            candidate.y + candidate.height <=
                container.y + container.height + tolerance
    }

    private static func validateScreenshotFullFrame(
        _ screenshot: PlayCoverRuntimeScreenshotPayload
    ) throws {
        guard screenshot.syntheticChrome == false else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("synthetic chrome screenshot")
        }
        let fullFrame = screenshot.fullFrame
        let logicalRect = fullFrame.logicalRect
        guard approximatelyEqual(logicalRect.x, 0),
              approximatelyEqual(logicalRect.y, 0),
              approximatelyEqual(
                  logicalRect.width,
                  Self.logicalSize.width
              ),
              approximatelyEqual(
                  logicalRect.height,
                  Self.logicalSize.height
              ),
              fullFrame.pixelWidth == Int(Self.nativePixelSize.width),
              fullFrame.pixelHeight == Int(Self.nativePixelSize.height),
              approximatelyEqual(fullFrame.scale, Self.deviceScale),
              fullFrame.uncropped,
              fullFrame.safeAreaCropped == false,
              fullFrame.identityMapping else {
            throw PlayCoverDriverClientError
                .runtimeGeometryMismatch("screenshot full frame")
        }
        let expectedFullFrame = fullFrameEvidence(fullFrame)
        guard let compositor = screenshot.compositor,
              case .object(let compositorEvidence) = compositor,
              compositorEvidence["syntheticChrome"] == .bool(false),
              compositorEvidence["fullFrame"] == expectedFullFrame else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload(
                    "screenshot compositor full-frame evidence"
                )
        }
        try validateScreenshotCompositorCompleteness(
            compositorEvidence: compositorEvidence
        )
        try validateScreenshotCompositorInventory(
            screenshot,
            compositorEvidence: compositorEvidence
        )
    }

    private static func validateScreenshotCompositorCompleteness(
        compositorEvidence:
            [String: PlayCoverRuntimeJSONValue]
    ) throws {
        let invalid = PlayCoverDriverClientError
            .malformedRuntimePayload(
                "screenshot compositor completeness evidence"
            )
        guard compositorEvidence["complete"] == .bool(true),
              let completenessValue =
                compositorEvidence["completeness"],
              case .object(let completeness) =
                completenessValue else {
            throw invalid
        }

        let requiredTrue = [
            "allVisibleUIKitWindowsMapped",
            "allVisibleNativeWindowsOrdered",
            "requestedCapturedCountMatch",
            "baseWindowCoversDevice",
            "nativeWindowsCroppedToCanvas",
            "hostDecorationsExcluded",
            "fullFrameUncropped",
            "allWindowGeometryInsideDevice",
            "appKitCGWindowSizesMatch",
            "cgWindowPlacementAuthoritative",
            "windowSetStableDuringCapture",
        ]
        let requiredFalse = [
            "syntheticChrome",
            "safeAreaCropped",
        ]
        guard requiredTrue.allSatisfy({
                  completeness[$0] == .bool(true)
              }),
              requiredFalse.allSatisfy({
                  completeness[$0] == .bool(false)
              }) else {
            throw invalid
        }
    }

    private static func validateScreenshotCompositorInventory(
        _ screenshot: PlayCoverRuntimeScreenshotPayload,
        compositorEvidence:
            [String: PlayCoverRuntimeJSONValue]
    ) throws {
        let invalid = PlayCoverDriverClientError
            .malformedRuntimePayload(
                "screenshot compositor window inventory"
            )
        guard let windowCount = jsonInteger(
                  compositorEvidence["windowCount"]
              ),
              let visibleUIKitWindowCount = jsonInteger(
                  compositorEvidence[
                      "visibleUIKitWindowCount"
                  ]
              ),
              let mappedUIKitWindowCount = jsonInteger(
                  compositorEvidence[
                      "mappedUIKitWindowCount"
                  ]
              ),
              let requestedWindowCount = jsonInteger(
                  compositorEvidence["requestedWindowCount"]
              ),
              let capturedWindowCount = jsonInteger(
                  compositorEvidence["capturedWindowCount"]
              ),
              let baseWindowNumber = jsonInteger(
                  compositorEvidence["baseWindowNumber"]
              ),
              windowCount > 0,
              visibleUIKitWindowCount ==
                mappedUIKitWindowCount,
              windowCount == requestedWindowCount,
              requestedWindowCount == capturedWindowCount,
              let windowsValue =
                compositorEvidence["windows"],
              case .array(let windows) = windowsValue,
              windows.count == windowCount else {
            throw invalid
        }

        var evidenceWindowNumbers: [Int] = []
        var evidenceMappedUIKitWindowCount = 0
        var evidenceBackingSizes: [(width: Int, height: Int)] = []
        for value in windows {
            guard case .object(let window) = value,
                  let windowNumber = jsonInteger(
                      window["windowNumber"]
                  ),
                  windowNumber > 0,
                  windowNumber <= Int(UInt32.max),
                  let mappedCount = jsonInteger(
                      window["mappedUIKitWindowCount"]
                  ),
                  let uiWindowsValue = window["uiWindows"],
                  case .array(let uiWindows) = uiWindowsValue,
                  uiWindows.count == mappedCount,
                  let captureGeometryValue =
                    window["captureGeometry"],
                  case .object(let captureGeometry) =
                    captureGeometryValue,
                  let sourcePixelWidth = jsonInteger(
                      captureGeometry["sourcePixelWidth"]
                  ),
                  let sourcePixelHeight = jsonInteger(
                      captureGeometry["sourcePixelHeight"]
                  ),
                  jsonInteger(
                      captureGeometry["windowNumber"]
                  ) == windowNumber,
                  sourcePixelWidth > 0,
                  sourcePixelHeight > 0 else {
                throw invalid
            }
            evidenceWindowNumbers.append(windowNumber)
            evidenceBackingSizes.append(
                (
                    width: sourcePixelWidth,
                    height: sourcePixelHeight
                )
            )
            let (mappedTotal, overflow) =
                evidenceMappedUIKitWindowCount
                    .addingReportingOverflow(mappedCount)
            guard !overflow else {
                throw invalid
            }
            evidenceMappedUIKitWindowCount = mappedTotal
        }
        guard Set(evidenceWindowNumbers).count == windowCount,
              evidenceWindowNumbers.contains(baseWindowNumber),
              evidenceMappedUIKitWindowCount ==
                mappedUIKitWindowCount,
              let compositorWindowNumbers =
                screenshot.compositorWindowNumbers,
              compositorWindowNumbers == evidenceWindowNumbers,
              let sourceBackingSizes =
                screenshot.sourceBackingSizes,
              sourceBackingSizes.count == windowCount else {
            throw invalid
        }
        for index in sourceBackingSizes.indices {
            guard case .object(let size) =
                    sourceBackingSizes[index],
                  jsonInteger(size["width"]) ==
                    evidenceBackingSizes[index].width,
                  jsonInteger(size["height"]) ==
                    evidenceBackingSizes[index].height else {
                throw invalid
            }
        }
    }

    private static func jsonInteger(
        _ value: PlayCoverRuntimeJSONValue?
    ) -> Int? {
        guard case .number(let number)? = value,
              number.isFinite,
              number >= 0,
              number.rounded(.towardZero) == number,
              number <= Double(Int.max) else {
            return nil
        }
        return Int(number)
    }

    private static func fullFrameEvidence(
        _ fullFrame: PlayCoverRuntimeFullFrame
    ) -> PlayCoverRuntimeJSONValue {
        .object([
            "logicalRect": .object([
                "x": .number(fullFrame.logicalRect.x),
                "y": .number(fullFrame.logicalRect.y),
                "width": .number(fullFrame.logicalRect.width),
                "height": .number(fullFrame.logicalRect.height),
            ]),
            "pixelWidth": .number(Double(fullFrame.pixelWidth)),
            "pixelHeight": .number(Double(fullFrame.pixelHeight)),
            "scale": .number(fullFrame.scale),
            "uncropped": .bool(fullFrame.uncropped),
            "safeAreaCropped": .bool(fullFrame.safeAreaCropped),
            "identityMapping": .bool(fullFrame.identityMapping),
        ])
    }

    private func decodeRuntimeJPEG(
        _ screenshot: PlayCoverRuntimeScreenshotPayload
    ) throws -> Data {
        guard screenshot.pixelWidth
                == Int(Self.nativePixelSize.width),
              screenshot.pixelHeight
                == Int(Self.nativePixelSize.height),
              Self.approximatelyEqual(
                  screenshot.logicalWidth,
                  Self.logicalSize.width
              ),
              Self.approximatelyEqual(
                  screenshot.logicalHeight,
                  Self.logicalSize.height
              ),
              Self.approximatelyEqual(
                  screenshot.scale,
                  Self.deviceScale
              ) else {
            throw PlayCoverDriverClientError
                .runtimeGeometryMismatch("screenshot geometry")
        }
        guard screenshot.source == "window-compositor" else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("screenshot source")
        }
        guard !screenshot.jpegBase64.isEmpty,
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

    private static func approximatelyEqual(
        _ lhs: Double,
        _ rhs: Double
    ) -> Bool {
        abs(lhs - rhs) < 0.01
    }
}

private struct ExpectedRuntimeIdentity {
    let pid: Int32
    let bundleIdentifier: String
    let executablePath: String

    init(session: SessionService.Info) throws {
        guard let runnerPID = session.runnerPid,
              runnerPID > 0,
              runnerPID <= Int(Int32.max) else {
            throw PlayCoverDriverClientError
                .incompleteSessionIdentity("PID")
        }
        guard let bundleIdentifier = session.bundleId,
              !bundleIdentifier.isEmpty else {
            throw PlayCoverDriverClientError
                .incompleteSessionIdentity("bundle ID")
        }
        guard let executablePath =
                session.playCoverExecutablePath,
              !executablePath.isEmpty else {
            throw PlayCoverDriverClientError
                .incompleteSessionIdentity("executable path")
        }
        pid = Int32(runnerPID)
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
    }
}
