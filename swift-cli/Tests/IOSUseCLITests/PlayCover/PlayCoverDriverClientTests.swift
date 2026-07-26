import CoreGraphics
import Foundation
import ImageIO
import IOSUsePlayDevice
import IOSUseProtocol
import XCTest
@testable import IOSUseCLI

final class PlayCoverDriverClientTests: XCTestCase {
    func testFixedDeviceContractIsCompileTimeIPhone15ProMax() {
        XCTAssertEqual(
            PlayCoverDriverClient.logicalSize,
            CGSize(
                width: CGFloat(IOSUsePlayDeviceLogicalWidth),
                height: CGFloat(IOSUsePlayDeviceLogicalHeight)
            )
        )
        XCTAssertEqual(
            PlayCoverDriverClient.nativePixelSize,
            CGSize(
                width: CGFloat(IOSUsePlayDeviceNativeWidth),
                height: CGFloat(IOSUsePlayDeviceNativeHeight)
            )
        )
        XCTAssertEqual(
            PlayCoverDriverClient.deviceScale,
            Double(IOSUsePlayDeviceScale)
        )
    }

    func testAllUICommandsMapTypedArgumentsAndPreserveResults()
        throws
    {
        var requests: [(
            PlayCoverRuntimeCommand,
            PlayCoverRuntimeRequestArguments,
            TimeInterval
        )] = []
        let client = PlayCoverDriverClient(
            session: makeSession()
        ) { command, arguments, timeout in
            requests.append((command, arguments, timeout))
            switch command {
            case .dom:
                return self.makePayload(
                    capability: command,
                    dom: self.makeDOM(generation: 10)
                )
            case .waitFor:
                return self.makePayload(
                    capability: command,
                    waitFor: .init(
                        element: self.makeSummary(generation: 11),
                        waited: 0.25,
                        snapshotGeneration: 11
                    )
                )
            case .tap:
                return self.makePayload(
                    capability: command,
                    tap: self.makeAction(generation: 12)
                )
            case .longPress:
                return self.makePayload(
                    capability: command,
                    longPress: self.makeAction(generation: 13)
                )
            case .swipe:
                return self.makePayload(
                    capability: command,
                    swipe: .init(
                        element: self.makeSummary(generation: 14),
                        hitView: self.makeHitView(),
                        finalState: self.makeFinalState(),
                        postcondition:
                            self.makePostcondition(generation: 15),
                        scrolls: 3,
                        direction: "forth"
                    )
                )
            case .input:
                return self.makePayload(
                    capability: command,
                    input: self.makeAction(generation: 15)
                )
            case .dismissAlert:
                return self.makePayload(
                    capability: command,
                    dismissAlert: .init(
                        dismissed: true,
                        text: "Allow access?",
                        button: "Allow",
                        reason: "button",
                        hitView: self.makeHitView(),
                        finalState: self.makeFinalState(),
                        postcondition:
                            self.makePostcondition(generation: 16)
                    )
                )
            case .open:
                return self.makePayload(
                    capability: command,
                    open: .init(
                        delivered: true,
                        url: "demo://route",
                        postcondition:
                            self.makePostcondition(generation: 17)
                    )
                )
            default:
                return self.makePayload(capability: command)
            }
        }

        let dom = try client.dom(
            raw: true,
            fresh: false,
            waitQuiescence: true
        )
        let wait = try client.waitFor(
            label: "Continue",
            timeout: 2,
            traits: "Button",
            cindex: 1,
            gone: true,
            matchMode: .regex
        )
        let tap = try client.tap(
            target: ForyTarget(
                label: "Continue",
                point: ForyPoint(x: 20, y: 30)
            ),
            traits: "Button",
            cindex: 2,
            offset: ForyPoint(x: 4, y: 5),
            ratio: ForyPoint(x: 0.5, y: 0.75)
        )
        let longPress = try client.longPress(
            target: ForyTarget(label: "Photo"),
            durationMs: 800,
            traits: nil,
            cindex: nil
        )
        let swipe = try client.swipe(
            to: ForyTarget(label: "Developer"),
            from: ForyTarget(label: "Bluetooth"),
            distance: 300,
            dir: "forth",
            traits: "StaticText",
            cindex: 3
        )
        let input = try client.input(
            tap: ForyTarget(label: "Search"),
            content: "hello",
            deleteCount: 4,
            enter: true,
            traits: "TextField",
            cindex: 2
        )
        let alert = try client.dismissAlert(index: 1)
        let open = try client.openURL("demo://route")

        XCTAssertEqual(dom.snapshotGeneration, 10)
        XCTAssertEqual(dom.elements.first?.nodeID, "n-10")
        XCTAssertEqual(dom.elements.first?.className, "UIButton")
        XCTAssertEqual(dom.elements.first?.state.visible, true)
        XCTAssertEqual(dom.elements.first?.hierarchy.depth, 1)
        XCTAssertEqual(wait.snapshotGeneration, 11)
        XCTAssertEqual(wait.element.identifier, "continue")
        XCTAssertEqual(tap.hitView?.className, "UIButton")
        XCTAssertEqual(tap.finalState?.touchID, 77)
        XCTAssertEqual(
            tap.postcondition?.snapshotGeneration,
            13
        )
        XCTAssertEqual(
            longPress.postcondition?.snapshotGeneration,
            14
        )
        XCTAssertEqual(swipe.scrolls, 3)
        XCTAssertEqual(swipe.scrollDirection, "forth")
        XCTAssertEqual(input.element.snapshotGeneration, 15)
        XCTAssertTrue(alert.dismissed)
        XCTAssertEqual(alert.button, "Allow")
        XCTAssertTrue(open.delivered)
        XCTAssertEqual(open.url, "demo://route")
        XCTAssertEqual(open.postcondition.snapshotGeneration, 17)

        XCTAssertEqual(
            requests.map(\.0),
            [
                .dom,
                .waitFor,
                .tap,
                .longPress,
                .swipe,
                .input,
                .dismissAlert,
                .open,
            ]
        )
        guard case .dom(let domArgs) = requests[0].1 else {
            return XCTFail("missing DOM arguments")
        }
        XCTAssertTrue(domArgs.raw)
        XCTAssertFalse(domArgs.fresh)
        XCTAssertTrue(domArgs.waitQuiescence)
        guard case .waitFor(let waitArgs) = requests[1].1 else {
            return XCTFail("missing waitFor arguments")
        }
        XCTAssertEqual(waitArgs.target.label, "Continue")
        XCTAssertEqual(waitArgs.target.traits, "Button")
        XCTAssertEqual(waitArgs.target.cindex, 1)
        XCTAssertNil(waitArgs.target.point)
        XCTAssertNil(waitArgs.target.matchMode)
        XCTAssertEqual(waitArgs.matchMode, IOSUseWaitForMatchMode.regex.rawValue)
        XCTAssertTrue(waitArgs.gone)
        XCTAssertGreaterThan(requests[1].2, 2)
        guard case .tap(let tapArgs) = requests[2].1 else {
            return XCTFail("missing tap arguments")
        }
        XCTAssertEqual(tapArgs.target.point?.x, 20)
        XCTAssertEqual(tapArgs.target.point?.y, 30)
        XCTAssertEqual(tapArgs.target.traits, "Button")
        XCTAssertEqual(tapArgs.offset?.x, 4)
        XCTAssertEqual(tapArgs.offset?.y, 5)
        XCTAssertEqual(tapArgs.ratio.x, 0.5)
        XCTAssertEqual(tapArgs.ratio.y, 0.75)
        guard case .longPress(let longArgs) = requests[3].1 else {
            return XCTFail("missing longPress arguments")
        }
        XCTAssertEqual(longArgs.durationMs, 800)
        guard case .swipe(let swipeArgs) = requests[4].1 else {
            return XCTFail("missing swipe arguments")
        }
        XCTAssertEqual(swipeArgs.toTarget?.label, "Developer")
        XCTAssertEqual(swipeArgs.fromTarget.label, "Bluetooth")
        XCTAssertEqual(swipeArgs.distance, 300)
        XCTAssertEqual(
            swipeArgs.direction,
            IOSUseProtocol.XCConstants.swipeDirectionForth
        )
        guard case .input(let inputArgs) = requests[5].1 else {
            return XCTFail("missing input arguments")
        }
        XCTAssertEqual(inputArgs.target?.label, "Search")
        XCTAssertEqual(inputArgs.target?.traits, "TextField")
        XCTAssertEqual(inputArgs.target?.cindex, 2)
        XCTAssertEqual(inputArgs.content, "hello")
        XCTAssertEqual(inputArgs.deleteCount, 4)
        XCTAssertTrue(inputArgs.enter)
        guard case .dismissAlert(let dismissArgs) = requests[6].1
        else {
            return XCTFail("missing dismissAlert arguments")
        }
        XCTAssertEqual(dismissArgs.index, 1)
        guard case .open(let openArgs) = requests[7].1 else {
            return XCTFail("missing open arguments")
        }
        XCTAssertEqual(openArgs.url, "demo://route")
    }

    func testFixedDistanceSwipeUsesNoDestinationAndScreenCenterAnchor()
        throws
    {
        var captured: PlayCoverRuntimeSwipeArguments?
        let client = PlayCoverDriverClient(
            session: makeSession()
        ) { command, arguments, _ in
            XCTAssertEqual(command, .swipe)
            guard case .swipe(let swipe) = arguments else {
                throw PlayCoverDriverClientError
                    .malformedRuntimePayload("swipe arguments")
            }
            captured = swipe
            return self.makePayload(
                capability: .swipe,
                swipe: .init(
                    element: self.makeSummary(generation: 20),
                    hitView: self.makeHitView(),
                    finalState: self.makeFinalState(),
                    postcondition:
                        self.makePostcondition(generation: 21),
                    scrolls: 1,
                    direction: "forth"
                )
            )
        }

        _ = try client.swipe(
            to: ForyTarget(),
            from: ForyTarget(),
            distance: 240,
            dir: "forth",
            traits: nil,
            cindex: nil
        )

        XCTAssertNil(captured?.toTarget)
        XCTAssertEqual(
            captured?.fromTarget.point?.x,
            Double(IOSUsePlayDeviceLogicalWidth) / 2
        )
        XCTAssertEqual(
            captured?.fromTarget.point?.y,
            Double(IOSUsePlayDeviceLogicalHeight) / 2
        )
        XCTAssertEqual(captured?.distance, 240)
    }

    func testScreenshotRequiresCompleteStrictFixedGeometryAndGeneration()
        throws
    {
        let jpeg = try makeJPEG(
            width: Int(IOSUsePlayDeviceNativeWidth),
            height: Int(IOSUsePlayDeviceNativeHeight)
        )
        let valid = makeScreenshot(jpeg: jpeg)
        let client = makeClient(
            response: makePayload(
                capability: .screenshot,
                screenshot: valid
            )
        )

        let capture = try client.screenshotCapture()

        XCTAssertEqual(capture.jpeg, jpeg)
        XCTAssertEqual(
            capture.pixelSize?.x,
            Double(IOSUsePlayDeviceNativeWidth)
        )
        XCTAssertEqual(
            capture.pixelSize?.y,
            Double(IOSUsePlayDeviceNativeHeight)
        )
        XCTAssertEqual(
            capture.logicalSize?.x,
            Double(IOSUsePlayDeviceLogicalWidth)
        )
        XCTAssertEqual(
            capture.logicalSize?.y,
            Double(IOSUsePlayDeviceLogicalHeight)
        )
        XCTAssertEqual(
            capture.scale,
            Double(IOSUsePlayDeviceScale)
        )
        XCTAssertEqual(capture.snapshotGeneration, 20)
        XCTAssertEqual(capture.captureGeneration, 8)
        XCTAssertEqual(
            capture.runtimeEvidence?["source"],
            .string("window-compositor")
        )
        XCTAssertEqual(
            capture.runtimeEvidence?["compositorWindowNumbers"],
            .array([.number(71), .number(42)])
        )
        XCTAssertEqual(
            capture.runtimeEvidence?["compositor"],
            .object([
                "complete": .bool(true),
            ])
        )
        XCTAssertNil(capture.warning)

        let invalid: [(
            PlayCoverRuntimeResponsePayload,
            PlayCoverDriverClientError
        )] = [
            (
                makePayload(
                    capability: .screenshot,
                    screenshot: makeScreenshot(
                        jpeg: jpeg,
                        complete: false
                    )
                ),
                .malformedRuntimePayload(
                    "incomplete window-compositor screenshot"
                )
            ),
            (
                makePayload(
                    capability: .screenshot,
                    screenshot: makeScreenshot(
                        jpeg: jpeg,
                        snapshotGeneration: 0
                    )
                ),
                .malformedRuntimePayload("screenshot generation")
            ),
            (
                makePayload(
                    capability: .screenshot,
                    screenshot: makeScreenshot(
                        jpeg: jpeg,
                        source: "draw-view-hierarchy"
                    )
                ),
                .malformedRuntimePayload("screenshot source")
            ),
            (
                makePayload(
                    capability: .screenshot,
                    screenshot: makeScreenshot(
                        jpeg: jpeg,
                        source: "cgwindow-self"
                    )
                ),
                .malformedRuntimePayload("screenshot source")
            ),
            (
                makePayload(
                    capability: .screenshot,
                    screenshot: makeScreenshot(
                        jpeg: jpeg,
                        logicalWidth: 431
                    )
                ),
                .runtimeGeometryMismatch("screenshot geometry")
            ),
            (
                makePayload(
                    capability: .screenshot,
                    geometry: makeGeometry(logicalWidth: 431),
                    screenshot: valid
                ),
                .runtimeGeometryMismatch("logical width")
            ),
        ]
        for (payload, expected) in invalid {
            XCTAssertThrowsError(
                try makeClient(response: payload).screenshotCapture()
            ) {
                XCTAssertEqual(
                    $0 as? PlayCoverDriverClientError,
                    expected
                )
            }
        }
    }

    func testAtomicEvidenceRequiresSameScreenshotAndDOMGeneration()
        throws
    {
        let jpeg = try makeJPEG(
            width: Int(IOSUsePlayDeviceNativeWidth),
            height: Int(IOSUsePlayDeviceNativeHeight)
        )
        let matchingDOM = makeDOM(generation: 31)
        let matching = makeScreenshot(
            jpeg: jpeg,
            snapshotGeneration: 31,
            captureGeneration: 4,
            dom: matchingDOM
        )
        let snapshot = try makeClient(
            response: makePayload(
                capability: .screenshot,
                screenshot: matching
            )
        ).evidenceSnapshot()

        XCTAssertEqual(snapshot.screenshot.snapshotGeneration, 31)
        XCTAssertEqual(snapshot.dom.snapshotGeneration, 31)

        let mismatched = makeScreenshot(
            jpeg: jpeg,
            snapshotGeneration: 31,
            captureGeneration: 5,
            dom: makeDOM(generation: 32)
        )
        XCTAssertThrowsError(
            try makeClient(
                response: makePayload(
                    capability: .screenshot,
                    screenshot: mismatched
                )
            ).evidenceSnapshot()
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverDriverClientError,
                .malformedRuntimePayload(
                    "atomic screenshot/DOM generation"
                )
            )
        }
    }

    func testRuntimeIdentityCapabilityAndGeometryAreValidated()
        throws
    {
        let variants: [(
            PlayCoverRuntimeResponsePayload,
            PlayCoverDriverClientError
        )] = [
            (
                makePayload(capability: .dom, pid: 999),
                .runtimeIdentityMismatch("PID")
            ),
            (
                makePayload(
                    capability: .dom,
                    bundleIdentifier: "other.bundle"
                ),
                .runtimeIdentityMismatch("bundle ID")
            ),
            (
                makePayload(
                    capability: .dom,
                    executablePath: "/tmp/other"
                ),
                .runtimeIdentityMismatch("executable")
            ),
            (
                makePayload(
                    capability: .hello,
                    dom: makeDOM(generation: 1)
                ),
                .runtimeCapabilityUnavailable("dom")
            ),
            (
                makePayload(
                    capability: .dom,
                    stage: "booting",
                    dom: makeDOM(generation: 1)
                ),
                .runtimeGeometryMismatch("runtime stage")
            ),
        ]
        for (payload, expected) in variants {
            let client = makeClient(response: payload)
            XCTAssertThrowsError(
                try client.dom(
                    raw: false,
                    fresh: true,
                    waitQuiescence: false
                )
            ) {
                XCTAssertEqual(
                    $0 as? PlayCoverDriverClientError,
                    expected
                )
            }
        }
    }

    func testMutationAllowsWholeDOMChangeWithStableTargetSummary()
        throws
    {
        let original = makeSummary(generation: 40)
        let siblingChanged = PlayCoverRuntimeActionPayload(
            element: original,
            hitView: makeHitView(),
            finalState: makeFinalState(),
            postcondition: .init(
                snapshotGeneration: 41,
                element: makeSummary(generation: 41),
                changed: true,
                stateEvidence: makeStateEvidence(
                    beforeGeneration: 40,
                    afterGeneration: 41,
                    changedElementCount: 1,
                    targetChanged: false
                )
            )
        )
        let client = makeClient(
            response: makePayload(
                capability: .tap,
                tap: siblingChanged
            )
        )

        let result = try client.tap(
            target: ForyTarget(label: "Continue"),
            traits: nil,
            cindex: nil,
            offset: nil,
            ratio: ForyPoint(x: 0.5, y: 0.5)
        )

        XCTAssertEqual(result.postcondition?.changed, true)
        XCTAssertEqual(
            result.postcondition?.snapshotGeneration,
            41
        )
    }

    func testMutationAllowsFullSceneReplacementSymmetricDifference()
        throws
    {
        let original = makeSummary(generation: 42)
        let replaced = PlayCoverRuntimeActionPayload(
            element: original,
            hitView: makeHitView(),
            finalState: makeFinalState(),
            postcondition: .init(
                snapshotGeneration: 43,
                element: nil,
                changed: true,
                stateEvidence: .init(
                    beforeSnapshotGeneration: 42,
                    afterSnapshotGeneration: 43,
                    beforeElementCount: 1,
                    afterElementCount: 1,
                    changedElementCount: 2,
                    changes: [
                        .object(["beforeCount": .number(1)]),
                        .object(["afterCount": .number(1)]),
                    ],
                    targetChanged: true
                )
            )
        )
        let client = makeClient(
            response: makePayload(
                capability: .tap,
                tap: replaced
            )
        )

        let result = try client.tap(
            target: ForyTarget(label: "Continue"),
            traits: nil,
            cindex: nil,
            offset: nil,
            ratio: ForyPoint(x: 0.5, y: 0.5)
        )

        XCTAssertEqual(result.postcondition?.changed, true)
        XCTAssertNil(result.postcondition?.element)
    }

    func testMutationAllowsPixelChangeWithStableDOM() throws {
        let original = makeSummary(generation: 45)
        var postcondition = PlayCoverRuntimePostcondition(
            snapshotGeneration: 46,
            element: makeSummary(generation: 46),
            changed: true,
            stateEvidence: makeStateEvidence(
                beforeGeneration: 45,
                afterGeneration: 46,
                changedElementCount: 0,
                targetChanged: false
            )
        )
        postcondition.pixelEvidence = makePixelEvidence(
            beforeHash: String(repeating: "a", count: 64),
            afterHash: String(repeating: "b", count: 64)
        )
        let payload = PlayCoverRuntimeActionPayload(
            element: original,
            hitView: makeHitView(),
            finalState: makeFinalState(),
            postcondition: postcondition
        )
        let client = makeClient(
            response: makePayload(
                capability: .tap,
                tap: payload
            )
        )

        let result = try client.tap(
            target: ForyTarget(label: "Continue"),
            traits: nil,
            cindex: nil,
            offset: nil,
            ratio: ForyPoint(x: 0.5, y: 0.5)
        )

        XCTAssertEqual(result.postcondition?.changed, true)
    }

    func testMutationRejectsChangedFlagWithoutFullDOMDiff()
        throws
    {
        let original = makeSummary(generation: 50)
        let malformed = PlayCoverRuntimeActionPayload(
            element: original,
            hitView: makeHitView(),
            finalState: makeFinalState(),
            postcondition: .init(
                snapshotGeneration: 51,
                element: makeSummary(generation: 51),
                changed: true,
                stateEvidence: makeStateEvidence(
                    beforeGeneration: 50,
                    afterGeneration: 51,
                    changedElementCount: 0,
                    targetChanged: false
                )
            )
        )
        let client = makeClient(
            response: makePayload(
                capability: .tap,
                tap: malformed
            )
        )

        XCTAssertThrowsError(
            try client.tap(
                target: ForyTarget(label: "Continue"),
                traits: nil,
                cindex: nil,
                offset: nil,
                ratio: ForyPoint(x: 0.5, y: 0.5)
            )
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverDriverClientError,
                .malformedRuntimePayload(
                    "mutation full-DOM state evidence"
                )
            )
        }
    }

    func testRemoteTypedErrorTranslatesWithoutLosingEvidence()
        throws
    {
        let details = PlayCoverRuntimeErrorDetails(
            category: "lookup",
            phase: "lookup",
            retryable: true,
            fatal: false,
            target: PlayCoverRuntimeTarget(
                label: "Continue",
                traits: "Button",
                cindex: 2
            ),
            candidateCount: 1,
            candidates: [
                PlayCoverRuntimeErrorCandidate(
                    element: makeSummary(generation: 50),
                    rejectedBy: ["hidden"]
                ),
            ],
            suggestions: ["Refresh DOM"]
        )
        let client = PlayCoverDriverClient(
            session: makeSession()
        ) { _, _, _ in
            throw PlayCoverRuntimeClientError.remoteError(
                code: "element_not_found",
                message: "not found",
                details: details
            )
        }

        XCTAssertThrowsError(
            try client.tap(
                target: ForyTarget(label: "Continue"),
                traits: nil,
                cindex: nil,
                offset: nil,
                ratio: ForyPoint(x: 0.5, y: 0.5)
            )
        ) { error in
            guard case .driverError(let message, let payload) =
                    error as? DriverClientError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(message, "not found")
            XCTAssertEqual(payload.category, "lookup")
            XCTAssertEqual(payload.code, "element_not_found")
            XCTAssertEqual(payload.target?.label, "Continue")
            XCTAssertEqual(payload.target?.cindex, 2)
            XCTAssertEqual(payload.candidateCount, 1)
            XCTAssertEqual(
                payload.candidates.first?.element.label,
                "Continue"
            )
            XCTAssertEqual(
                payload.candidates.first?.rejectedBy,
                ["hidden"]
            )
        }
    }

    func testLifecycleCommandsRemainHostOnly() throws {
        let client = makeClient(
            response: makePayload(capability: .hello)
        )
        XCTAssertThrowsError(
            try client.activateApp(bundleId: "com.example.runtime")
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverDriverClientError,
                .lifecycleCommandUnsupported("activateApp")
            )
        }
        XCTAssertThrowsError(
            try client.terminateApp(bundleId: "com.example.runtime")
        )
        XCTAssertThrowsError(try client.home())
        XCTAssertThrowsError(
            try client.waitAppForeground(
                expectedBundleId: "com.example.runtime",
                timeout: 1,
                returnDom: false
            )
        )
    }

    private func makeClient(
        response: PlayCoverRuntimeResponsePayload
    ) -> PlayCoverDriverClient {
        PlayCoverDriverClient(
            session: makeSession()
        ) { _, _, _ in response }
    }

    private func makeSession() -> SessionService.Info {
        SessionService.Info(
            udid: "playcover:com.example.runtime",
            deviceName: "iPhone16,2",
            deviceVersion: "Mac Catalyst",
            deviceType: PlayCoverSessionService.deviceType,
            runnerPid: 4_242,
            startMode: PlayCoverSessionService.deviceType,
            sessionIdentifier: "session-v2",
            bundleId: "com.example.runtime",
            playCoverAppPath:
                "/tmp/prepared/generation/com.example.runtime.app",
            playCoverExecutablePath:
                "/tmp/prepared/generation/com.example.runtime.app/Demo",
            playCoverGenerationKey: "generation",
            playCoverRuntimeSocketPath: "/tmp/run/s-sessionv2.sock"
        )
    }

    private func makeGeometry(
        logicalWidth: Double =
            Double(IOSUsePlayDeviceLogicalWidth)
    ) -> PlayCoverRuntimeGeometry {
        PlayCoverRuntimeGeometry(
            logical: .init(
                width: logicalWidth,
                height: Double(IOSUsePlayDeviceLogicalHeight)
            ),
            native: .init(
                width: Double(IOSUsePlayDeviceNativeWidth),
                height: Double(IOSUsePlayDeviceNativeHeight)
            ),
            scale: Double(IOSUsePlayDeviceScale),
            window: .init(
                width: Double(IOSUsePlayDeviceLogicalWidth),
                height: Double(IOSUsePlayDeviceLogicalHeight)
            ),
            safeArea: .init(
                top: Double(IOSUsePlayDeviceSafeAreaTop),
                left: Double(IOSUsePlayDeviceSafeAreaLeft),
                bottom:
                    Double(IOSUsePlayDeviceSafeAreaBottom),
                right: Double(IOSUsePlayDeviceSafeAreaRight)
            )
        )
    }

    private func makePayload(
        capability: PlayCoverRuntimeCommand,
        pid: Int32 = 4_242,
        bundleIdentifier: String = "com.example.runtime",
        executablePath: String =
            "/tmp/prepared/generation/com.example.runtime.app/Demo",
        geometry: PlayCoverRuntimeGeometry? = nil,
        stage: String = "ready",
        screenshot: PlayCoverRuntimeScreenshotPayload? = nil,
        dom: PlayCoverRuntimeDOMPayload? = nil,
        waitFor: PlayCoverRuntimeWaitForPayload? = nil,
        tap: PlayCoverRuntimeActionPayload? = nil,
        longPress: PlayCoverRuntimeActionPayload? = nil,
        swipe: PlayCoverRuntimeSwipePayload? = nil,
        input: PlayCoverRuntimeActionPayload? = nil,
        dismissAlert: PlayCoverRuntimeAlertPayload? = nil,
        open: PlayCoverRuntimeOpenPayload? = nil
    ) -> PlayCoverRuntimeResponsePayload {
        PlayCoverRuntimeResponsePayload(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            executablePath: executablePath,
            capabilities: [capability.rawValue],
            geometry: geometry ?? makeGeometry(),
            stage: stage,
            screenshot: screenshot,
            dom: dom,
            waitFor: waitFor,
            tap: tap,
            longPress: longPress,
            swipe: swipe,
            input: input,
            dismissAlert: dismissAlert,
            open: open
        )
    }

    private func makeState() -> PlayCoverRuntimeDOMState {
        .init(
            enabled: true,
            visible: true,
            selected: false,
            focused: false,
            opaque: true
        )
    }

    private func makeHierarchy() -> PlayCoverRuntimeDOMHierarchy {
        .init(
            parentID: "root",
            depth: 1,
            index: 0,
            path: ["root", "continue"]
        )
    }

    private func makeElement(
        generation: Int64
    ) -> PlayCoverRuntimeDOMElement {
        .init(
            nodeID: "n-\(generation)",
            type: "Button",
            elementType: 1,
            elemType: 1,
            label: "Continue",
            value: "Ready",
            identifier: "continue",
            hint: "Advance",
            class: "UIButton",
            traits: ["Button"],
            state: makeState(),
            frame: .init(
                x: 12,
                y: 34,
                width: 121,
                height: 44
            ),
            rect: .init(x: 12, y: 34, w: 121, h: 44),
            hierarchy: makeHierarchy(),
            ancestors: ["Application"],
            zOrder: 2,
            snapshotGeneration: generation
        )
    }

    private func makeSummary(
        generation: Int64,
        value: String = "Ready"
    ) -> PlayCoverRuntimeElementSummary {
        .init(
            nodeID: "n-\(generation)",
            type: "Button",
            elementType: 1,
            elemType: 1,
            label: "Continue",
            value: value,
            identifier: "continue",
            hint: "Advance",
            class: "UIButton",
            traits: ["Button"],
            state: makeState(),
            frame: .init(
                x: 12,
                y: 34,
                width: 121,
                height: 44
            ),
            rect: .init(x: 12, y: 34, w: 121, h: 44),
            hierarchy: makeHierarchy(),
            zOrder: 2,
            snapshotGeneration: generation,
            ancestors: ["Application"]
        )
    }

    private func makeDOM(
        generation: Int64
    ) -> PlayCoverRuntimeDOMPayload {
        .init(
            app: "Demo",
            windowSize: .init(
                x: Double(IOSUsePlayDeviceLogicalWidth),
                y: Double(IOSUsePlayDeviceLogicalHeight)
            ),
            raw: "Application, Demo",
            snapshotGeneration: generation,
            elements: [makeElement(generation: generation)]
        )
    }

    private func makeHitView() -> PlayCoverRuntimeHitView {
        .init(
            class: "UIButton",
            frame: .init(
                x: 12,
                y: 34,
                width: 121,
                height: 44
            ),
            accessibilityIdentifier: "continue",
            label: "Continue"
        )
    }

    private func makeFinalState() -> PlayCoverRuntimeFinalState {
        .init(
            point: .init(x: 72, y: 56),
            touchID: 77,
            phase: "ended",
            firstResponderClass: "UIButton"
        )
    }

    private func makePostcondition(
        generation: Int64
    ) -> PlayCoverRuntimePostcondition {
        .init(
            snapshotGeneration: generation,
            element: makeSummary(
                generation: generation,
                value: "Updated"
            ),
            changed: true,
            stateEvidence: makeStateEvidence(
                beforeGeneration: generation - 1,
                afterGeneration: generation,
                changedElementCount: 1,
                targetChanged: true
            )
        )
    }

    private func makeStateEvidence(
        beforeGeneration: Int64,
        afterGeneration: Int64,
        changedElementCount: Int,
        targetChanged: Bool
    ) -> PlayCoverRuntimeStateEvidence {
        .init(
            beforeSnapshotGeneration: beforeGeneration,
            afterSnapshotGeneration: afterGeneration,
            beforeElementCount: 1,
            afterElementCount: 1,
            changedElementCount: changedElementCount,
            changes: changedElementCount == 0
                ? []
                : [.object(["index": .number(0)])],
            targetChanged: targetChanged
        )
    }

    private func makePixelEvidence(
        beforeHash: String,
        afterHash: String
    ) -> PlayCoverRuntimePixelEvidence {
        let logicalRect = PlayCoverRuntimeFrame(
            x: 0,
            y: Double(IOSUsePlayDeviceSafeAreaTop),
            width: Double(IOSUsePlayDeviceLogicalWidth),
            height: Double(
                IOSUsePlayDeviceLogicalHeight
                    - IOSUsePlayDeviceSafeAreaTop
                    - IOSUsePlayDeviceSafeAreaBottom
            )
        )
        let nativeRect = PlayCoverRuntimeFrame(
            x: 0,
            y: Double(
                IOSUsePlayDeviceSafeAreaTop
                    * IOSUsePlayDeviceScale
            ),
            width: Double(IOSUsePlayDeviceNativeWidth),
            height: Double(
                (
                    IOSUsePlayDeviceLogicalHeight
                        - IOSUsePlayDeviceSafeAreaTop
                        - IOSUsePlayDeviceSafeAreaBottom
                ) * IOSUsePlayDeviceScale
            )
        )
        func fingerprint(
            hash: String,
            generation: Int64
        ) -> PlayCoverRuntimePixelFingerprint {
            PlayCoverRuntimePixelFingerprint(
                algorithm: "sha256-bgra8-premultiplied",
                hash: hash,
                logicalRect: logicalRect,
                nativePixelRect: nativeRect,
                pixelWidth: Int(IOSUsePlayDeviceNativeWidth),
                pixelHeight: Int(
                    (
                        IOSUsePlayDeviceLogicalHeight
                            - IOSUsePlayDeviceSafeAreaTop
                            - IOSUsePlayDeviceSafeAreaBottom
                    ) * IOSUsePlayDeviceScale
                ),
                captureGeneration: generation,
                source: "window-compositor",
                complete: true,
                compositor: .object([:])
            )
        }
        return PlayCoverRuntimePixelEvidence(
            before: fingerprint(
                hash: beforeHash,
                generation: 10
            ),
            after: fingerprint(
                hash: afterHash,
                generation: 11
            ),
            changed: beforeHash != afterHash
        )
    }

    private func makeAction(
        generation: Int64
    ) -> PlayCoverRuntimeActionPayload {
        .init(
            element: makeSummary(generation: generation),
            hitView: makeHitView(),
            finalState: makeFinalState(),
            postcondition: makePostcondition(
                generation: generation + 1
            )
        )
    }

    private func makeScreenshot(
        jpeg: Data,
        complete: Bool = true,
        snapshotGeneration: Int64 = 20,
        captureGeneration: Int64 = 8,
        source: String = "window-compositor",
        logicalWidth: Double =
            Double(IOSUsePlayDeviceLogicalWidth),
        dom: PlayCoverRuntimeDOMPayload? = nil
    ) -> PlayCoverRuntimeScreenshotPayload {
        .init(
            jpegBase64: jpeg.base64EncodedString(),
            pixelWidth: Int(IOSUsePlayDeviceNativeWidth),
            pixelHeight: Int(IOSUsePlayDeviceNativeHeight),
            logicalWidth: logicalWidth,
            logicalHeight:
                Double(IOSUsePlayDeviceLogicalHeight),
            scale: Double(IOSUsePlayDeviceScale),
            source: source,
            complete: complete,
            snapshotGeneration: snapshotGeneration,
            captureGeneration: captureGeneration,
            dom: dom,
            compositorWindowNumbers: [71, 42],
            sourceBackingSizes: [
                .object([
                    "width": .number(
                        Double(IOSUsePlayDeviceNativeWidth)
                    ),
                    "height": .number(
                        Double(IOSUsePlayDeviceNativeHeight)
                    ),
                ]),
            ],
            appKitWindowEvidence: .object([
                "ready": .bool(true),
            ]),
            systemChromeEvidence: .object([
                "ready": .bool(true),
            ]),
            compositor: .object([
                "complete": .bool(true),
            ])
        )
    }

    private func makeJPEG(
        width: Int,
        height: Int
    ) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:
                    CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(
            CGColor(
                red: 0.2,
                green: 0.5,
                blue: 0.8,
                alpha: 1
            )
        )
        context.fill(
            CGRect(x: 0, y: 0, width: width, height: height)
        )
        let image = try XCTUnwrap(context.makeImage())
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
                kCGImageDestinationLossyCompressionQuality: 0.7,
            ] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
