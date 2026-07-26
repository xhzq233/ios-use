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
            return "PlayCover Runtime identity does not match active-session \(field)"
        case .runtimeCapabilityUnavailable(let capability):
            return "PlayCover Runtime does not advertise required capability `\(capability)`"
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
        let response = try request(
            .screenshot,
            arguments: .empty(),
            timeout: PlayCoverRuntimeClient.screenshotTimeoutSeconds
        )
        return try mapScreenshot(response)
    }

    func evidenceSnapshot() throws -> DriverEvidenceSnapshot {
        let response = try request(
            .screenshot,
            arguments: .empty(),
            timeout: PlayCoverRuntimeClient.screenshotTimeoutSeconds
        )
        let screenshot = try mapScreenshot(response)
        guard let runtimeScreenshot = response.screenshot,
              let runtimeDOM = runtimeScreenshot.dom ?? response.dom else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("atomic screenshot DOM")
        }
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
        let response = try request(
            .dom,
            arguments: .dom(
                PlayCoverRuntimeDOMArguments(
                    raw: raw,
                    fresh: fresh,
                    waitQuiescence: waitQuiescence
                )
            )
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
        let requestedTimeout = timeout ?? 0
        let response = try request(
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
        )
        guard let payload = response.waitFor else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("waitFor")
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
        ratio: ForyPoint
    ) throws -> ForyElementPayload {
        let response = try request(
            .tap,
            arguments: .tap(
                PlayCoverRuntimeTapArguments(
                    target: mapTarget(
                        target,
                        traits: traits,
                        cindex: cindex
                    ),
                    offset: offset.map(mapPoint),
                    ratio: mapPoint(ratio)
                )
            )
        )
        guard let payload = response.tap else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("tap")
        }
        return try mapAction(payload)
    }

    func longPress(
        target: ForyTarget,
        durationMs: Int?,
        traits: String?,
        cindex: Int32?
    ) throws -> ForyElementPayload {
        let response = try request(
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
        )
        guard let payload = response.longPress else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("longPress")
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
        let response = try request(
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
        )
        guard let payload = response.input else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("input")
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
        let response = try request(
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
        )
        guard let payload = response.swipe else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("swipe")
        }
        return ForySwipePayload(
            element: try mapSummary(payload.element),
            hitView: try mapHitView(payload.hitView),
            finalState: mapFinalState(payload.finalState),
            postcondition: try mapPostcondition(
                payload.postcondition,
                originalElement: payload.element
            ),
            scrolls: payload.scrolls,
            scrollDirection: payload.direction
        )
    }

    private func isEmptyTarget(_ target: ForyTarget) -> Bool {
        target.point == nil && target.label.isEmpty
    }

    func dismissAlert(index: Int?) throws -> ForyAlertPayload {
        let response = try request(
            .dismissAlert,
            arguments: .dismissAlert(
                PlayCoverRuntimeDismissAlertArguments(index: index)
            )
        )
        guard let payload = response.dismissAlert else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("dismissAlert")
        }
        return ForyAlertPayload(
            dismissed: payload.dismissed,
            text: payload.text,
            button: payload.button,
            reason: payload.reason,
            hitView: try payload.hitView.map(mapHitView),
            finalState: payload.finalState.map(mapFinalState),
            postcondition: try mapPostcondition(payload.postcondition)
        )
    }

    struct OpenResult {
        let delivered: Bool
        let url: String
        let postcondition: ForyActionPostcondition
    }

    func openURL(_ url: String) throws -> OpenResult {
        let response = try request(
            .open,
            arguments: .open(
                PlayCoverRuntimeOpenArguments(url: url)
            )
        )
        guard let payload = response.open else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("open")
        }
        guard payload.delivered else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload(
                    "open delivery acknowledgement"
                )
        }
        return OpenResult(
            delivered: payload.delivered,
            url: payload.url,
            postcondition: try mapPostcondition(
                payload.postcondition
            )
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
        let expected = try ExpectedRuntimeIdentity(session: session)
        let response = try translateRuntimeError {
            try runtimeRequester(command, arguments, timeout)
        }
        try validateRuntime(
            response,
            expected: expected,
            requiredCapability: command.rawValue
        )
        return response
    }

    private func validateRuntime(
        _ payload: PlayCoverRuntimeResponsePayload,
        expected: ExpectedRuntimeIdentity,
        requiredCapability: String
    ) throws {
        let checks: [(Bool, String)] = [
            (payload.pid == expected.pid, "PID"),
            (
                payload.bundleIdentifier == expected.bundleIdentifier,
                "bundle ID"
            ),
            (
                PlayCoverRuntimeClient.canonicalPath(
                    payload.executablePath
                ) == PlayCoverRuntimeClient.canonicalPath(
                    expected.executablePath
                ),
                "executable"
            ),
        ]
        if let mismatch = checks.first(where: { !$0.0 }) {
            throw PlayCoverDriverClientError
                .runtimeIdentityMismatch(mismatch.1)
        }
        guard payload.capabilities.contains(requiredCapability) else {
            throw PlayCoverDriverClientError
                .runtimeCapabilityUnavailable(requiredCapability)
        }
        try Self.validateFixedDevice(
            payload.geometry,
            stage: payload.stage
        )
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
        _ response: PlayCoverRuntimeResponsePayload
    ) throws -> ScreenshotCapture {
        guard let screenshot = response.screenshot else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload("screenshot")
        }
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

    private func validPixelHash(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.unicodeScalars.allSatisfy {
                (48...57).contains($0.value)
                    || (97...102).contains($0.value)
            }
    }

    private func validPixelEvidence(
        _ evidence: PlayCoverRuntimePixelEvidence
    ) -> Bool {
        let before = evidence.before
        let after = evidence.after
        return before.algorithm
                == "sha256-bgra8-premultiplied"
            && after.algorithm == before.algorithm
            && validPixelHash(before.hash)
            && validPixelHash(after.hash)
            && before.logicalRect == after.logicalRect
            && before.nativePixelRect == after.nativePixelRect
            && before.pixelWidth > 0
            && before.pixelHeight > 0
            && after.pixelWidth == before.pixelWidth
            && after.pixelHeight == before.pixelHeight
            && before.captureGeneration
                < after.captureGeneration
            && before.source == "window-compositor"
            && after.source == before.source
            && before.complete
            && after.complete
            && evidence.changed
                == (before.hash != after.hash)
    }

    private func mapPostcondition(
        _ postcondition: PlayCoverRuntimePostcondition,
        originalElement:
            PlayCoverRuntimeElementSummary? = nil
    ) throws -> ForyActionPostcondition {
        let evidence = postcondition.stateEvidence
        guard evidence.beforeSnapshotGeneration
                < evidence.afterSnapshotGeneration,
              evidence.afterSnapshotGeneration
                == postcondition.snapshotGeneration,
              evidence.beforeElementCount >= 0,
              evidence.afterElementCount >= 0,
              evidence.changedElementCount >= 0,
              (
                evidence.changedElementCount
                    <= evidence.beforeElementCount
                    || evidence.changedElementCount
                        - evidence.beforeElementCount
                        <= evidence.afterElementCount
              ),
              evidence.changes.count
                <= min(16, evidence.changedElementCount),
              postcondition.changed
                == (
                    evidence.changedElementCount > 0
                        || postcondition.pixelEvidence?.changed == true
                ),
              postcondition.pixelEvidence.map(validPixelEvidence)
                ?? true else {
            throw PlayCoverDriverClientError
                .malformedRuntimePayload(
                    "mutation full-DOM state evidence"
                )
        }
        if let originalElement {
            guard postcondition.snapshotGeneration
                    > originalElement.snapshotGeneration,
                  evidence.beforeSnapshotGeneration
                    == originalElement.snapshotGeneration else {
                throw PlayCoverDriverClientError
                    .malformedRuntimePayload(
                        "mutation postcondition is not a fresh snapshot"
                    )
            }
        }
        let mappedPixelEvidence: ForyPixelPostcondition?
        if let pixel = postcondition.pixelEvidence {
            mappedPixelEvidence = ForyPixelPostcondition(
                beforeHash: pixel.before.hash,
                afterHash: pixel.after.hash,
                beforeCaptureGeneration:
                    pixel.before.captureGeneration,
                afterCaptureGeneration:
                    pixel.after.captureGeneration,
                logicalX: pixel.before.logicalRect.x,
                logicalY: pixel.before.logicalRect.y,
                logicalWidth: pixel.before.logicalRect.width,
                logicalHeight: pixel.before.logicalRect.height,
                changed: pixel.changed
            )
        } else {
            mappedPixelEvidence = nil
        }
        return ForyActionPostcondition(
            snapshotGeneration:
                postcondition.snapshotGeneration,
            element: try postcondition.element.map(mapSummary),
            changed: postcondition.changed,
            domChanged: evidence.changedElementCount > 0,
            pixelEvidence: mappedPixelEvidence
        )
    }

    private func mapAction(
        _ payload: PlayCoverRuntimeActionPayload
    ) throws -> ForyElementPayload {
        ForyElementPayload(
            element: try mapSummary(payload.element),
            hitView: try mapHitView(payload.hitView),
            finalState: mapFinalState(payload.finalState),
            postcondition: try mapPostcondition(
                payload.postcondition,
                originalElement: payload.element
            )
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
        try validateTransparentHost(geometry.host)
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

    private static func validateTransparentHost(
        _ host: PlayCoverRuntimeHostGeometry?
    ) throws {
        guard let host else {
            throw PlayCoverDriverClientError
                .runtimeGeometryMismatch("transparent host diagnostics")
        }
        let expectedCanvasWidth =
            Self.logicalSize.width * host.displayScale
        let expectedCanvasHeight =
            Self.logicalSize.height * host.displayScale
        let checks: [(Bool, String)] = [
            (
                host.status == "configured" && host.hostPolicy,
                "transparent host policy"
            ),
            (
                host.transparent && host.publicTitleBar &&
                    host.titleVisible && host.resizable,
                "transparent host presentation"
            ),
            (
                !host.title.isEmpty && host.title == host.titleExpected,
                "transparent host title"
            ),
            (
                host.displayScale.isFinite && host.displayScale >= 0.5 &&
                    host.inverseDisplayScale.isFinite &&
                    approximatelyEqual(
                        host.inverseDisplayScale,
                        1 / host.displayScale
                    ),
                "transparent host display scale"
            ),
            (
                approximatelyEqual(host.transparentSpacer, 8),
                "transparent host spacer"
            ),
            (
                validHostFrame(host.canvasBounds) &&
                    approximatelyEqual(host.canvasBounds.x, 0) &&
                    approximatelyEqual(host.canvasBounds.y, 0) &&
                    approximatelyEqual(
                        host.canvasBounds.width,
                        Self.logicalSize.width
                    ) &&
                    approximatelyEqual(
                        host.canvasBounds.height,
                        Self.logicalSize.height
                    ),
                "fixed canvas bounds"
            ),
            (
                validHostFrame(host.frame) &&
                    validHostFrame(host.contentBounds) &&
                    validHostFrame(host.canvasRect) &&
                    approximatelyEqual(
                        host.canvasRect.width,
                        expectedCanvasWidth
                    ) &&
                    approximatelyEqual(
                        host.canvasRect.height,
                        expectedCanvasHeight
                    ) &&
                    hostFrameContains(
                        host.contentBounds,
                        host.canvasRect
                    ) &&
                    approximatelyEqual(
                        host.canvasRect.y + host.canvasRect.height +
                            host.transparentSpacer,
                        host.contentBounds.y + host.contentBounds.height
                    ),
                "transparent host canvas layout"
            ),
            (
                host.capture.ready && host.capture.error == nil &&
                    (host.capture.hostWindowNumber ?? 0) > 0 &&
                    validHostFrame(host.capture.hostContentCGWindowRect) &&
                    validHostFrame(host.capture.hostCGWindowBounds) &&
                    validHostFrame(host.capture.canvasCGWindowRect) &&
                    approximatelyEqual(
                        host.capture.hostCGWindowBounds.width,
                        host.frame.width
                    ) &&
                    approximatelyEqual(
                        host.capture.hostCGWindowBounds.height,
                        host.frame.height
                    ) &&
                    approximatelyEqual(
                        host.capture.hostContentCGWindowRect.width,
                        host.contentBounds.width
                    ) &&
                    approximatelyEqual(
                        host.capture.hostContentCGWindowRect.height,
                        host.contentBounds.height
                    ) &&
                    approximatelyEqual(
                        host.capture.canvasCGWindowRect.width,
                        host.canvasRect.width
                    ) &&
                    approximatelyEqual(
                        host.capture.canvasCGWindowRect.height,
                        host.canvasRect.height
                    ) &&
                    hostFrameContains(
                        host.capture.hostCGWindowBounds,
                        host.capture.hostContentCGWindowRect
                    ) &&
                    hostFrameContains(
                        host.capture.hostCGWindowBounds,
                        host.capture.canvasCGWindowRect
                    ) &&
                    approximatelyEqual(
                        host.capture.canvasCGWindowRect.x,
                        host.capture.hostContentCGWindowRect.x +
                            host.canvasRect.x - host.contentBounds.x
                    ) &&
                    approximatelyEqual(
                        host.capture.canvasCGWindowRect.y,
                        host.capture.hostContentCGWindowRect.y +
                            (host.contentBounds.y +
                                host.contentBounds.height -
                                host.canvasRect.y -
                                host.canvasRect.height)
                    ),
                "transparent host canvas capture"
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

    private static func hostFrameContains(
        _ container: PlayCoverRuntimeFrame,
        _ candidate: PlayCoverRuntimeFrame
    ) -> Bool {
        let tolerance = 0.01
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
