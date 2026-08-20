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
                        finalState: self.makeFinalState()
                    )
                )
            case .dismissAlertByLabel:
                return self.makePayload(
                    capability: command,
                    dismissAlertByLabel: .init(
                        dismissed: true,
                        text: "Allow access?",
                        button: "Allow",
                        reason: "label",
                        hitView: self.makeHitView(),
                        finalState: self.makeFinalState()
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
        XCTAssertEqual(dom.snapshotGeneration, 10)
        XCTAssertEqual(dom.elements.first?.nodeID, "n-10")
        XCTAssertEqual(dom.elements.first?.className, "UIButton")
        XCTAssertEqual(dom.elements.first?.state.visible, true)
        XCTAssertEqual(dom.elements.first?.hierarchy.depth, 1)
        XCTAssertEqual(wait.snapshotGeneration, 11)
        XCTAssertEqual(wait.element.identifier, "continue")
        XCTAssertEqual(tap.hitView?.className, "UIButton")
        XCTAssertEqual(tap.finalState?.touchID, 77)
        XCTAssertNil(tap.postcondition)
        XCTAssertNil(longPress.postcondition)
        XCTAssertEqual(swipe.scrolls, 3)
        XCTAssertEqual(swipe.scrollDirection, "forth")
        XCTAssertNil(swipe.postcondition)
        XCTAssertEqual(input.element.snapshotGeneration, 15)
        XCTAssertNil(input.postcondition)
        XCTAssertTrue(alert.dismissed)
        XCTAssertEqual(alert.button, "Allow")
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
        XCTAssertEqual(tapArgs.ratio?.x, 0.5)
        XCTAssertEqual(tapArgs.ratio?.y, 0.75)
        guard case .longPress(let longArgs) = requests[3].1 else {
            return XCTFail("missing longPress arguments")
        }
        XCTAssertEqual(longArgs.durationMs, 800)
        guard case .swipe(let swipeArgs) = requests[4].1 else {
            return XCTFail("missing swipe arguments")
        }
        XCTAssertEqual(swipeArgs.toTarget?.label, "Developer")
        XCTAssertEqual(swipeArgs.fromTarget?.label, "Bluetooth")
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
        XCTAssertEqual(dismissArgs.selection, "index")
    }

    func testDismissAlertForwardsExactLabelWithoutIndex() throws {
        var captured:
            PlayCoverRuntimeDismissAlertByLabelArguments?
        let client = PlayCoverDriverClient(
            session: makeSession()
        ) { command, arguments, _ in
            XCTAssertEqual(command, .dismissAlertByLabel)
            guard case .dismissAlertByLabel(let dismiss) = arguments
            else {
                XCTFail("missing dismissAlert arguments")
                return self.makePayload(capability: command)
            }
            captured = dismiss
            return self.makePayload(
                capability: command,
                dismissAlertByLabel: .init(
                    dismissed: true,
                    text: "Photo Access",
                    button: "Allow Full Access",
                    reason: "label",
                    hitView: nil,
                    finalState: nil
                )
            )
        }

        let result = try client.dismissAlert(
            index: nil,
            label: "Allow Full Access"
        )

        XCTAssertEqual(captured?.label, "Allow Full Access")
        XCTAssertEqual(result.button, "Allow Full Access")
    }

    func testDismissAlertLabelNeverFallsBackToLegacyCommand() {
        var commands: [PlayCoverRuntimeCommand] = []
        let client = PlayCoverDriverClient(
            session: makeSession()
        ) { command, _, _ in
            commands.append(command)
            throw PlayCoverRuntimeClientError.remoteError(
                code: "unsupported_command",
                message: "unsupported",
                details: nil
            )
        }

        XCTAssertThrowsError(
            try client.dismissAlert(
                index: nil,
                label: "Allow Full Access"
            )
        )
        XCTAssertEqual(commands, [.dismissAlertByLabel])
    }

    func testDismissAlertForwardsGuardedSelectionModes() throws {
        var captured: [PlayCoverRuntimeDismissAlertArguments] = []
        let client = PlayCoverDriverClient(
            session: makeSession()
        ) { command, arguments, _ in
            XCTAssertEqual(command, .dismissAlert)
            guard case .dismissAlert(let dismiss) = arguments
            else {
                XCTFail("missing dismissAlert arguments")
                return self.makePayload(capability: command)
            }
            captured.append(dismiss)
            return self.makePayload(
                capability: command,
                dismissAlert: .init(
                    dismissed: true,
                    text: "Fixture Alert",
                    button: "Confirm",
                    reason: dismiss.selection,
                    hitView: nil,
                    finalState: nil
                )
            )
        }

        _ = try client.dismissAlert(
            args: ForyDismissAlertArgs(
                selection:
                    IOSUseAlertSelectionMode.onlyButton.rawValue
            )
        )
        _ = try client.dismissAlert(
            args: ForyDismissAlertArgs(
                selection:
                    IOSUseAlertSelectionMode.visualPrimary.rawValue
            )
        )

        XCTAssertEqual(
            captured,
            [
                .init(selection: "onlyButton"),
                .init(selection: "visualPrimary"),
            ]
        )
    }

    func testTapPreservesAbsentRatioForRuntimePlacement() throws {
        var captured: PlayCoverRuntimeTapArguments?
        let client = PlayCoverDriverClient(
            session: makeSession()
        ) { command, arguments, _ in
            XCTAssertEqual(command, .tap)
            guard case .tap(let tap) = arguments else {
                XCTFail("missing tap arguments")
                return self.makePayload(capability: command)
            }
            captured = tap
            return self.makePayload(
                capability: command,
                tap: self.makeAction(generation: 12)
            )
        }

        _ = try client.tap(
            target: ForyTarget(label: "Continue"),
            traits: nil,
            cindex: nil,
            offset: nil,
            ratio: nil
        )

        XCTAssertNil(captured?.offset)
        XCTAssertNil(captured?.ratio)
    }

    func testFixedDistanceSwipeLeavesDestinationAndAnchorAbsent()
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
        XCTAssertNil(captured?.fromTarget)
        XCTAssertEqual(captured?.distance, 240)
    }

    func testSemanticSwipeWithoutAnchorKeepsAnchorAbsent() throws {
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
                    element: self.makeSummary(generation: 21),
                    hitView: self.makeHitView(),
                    finalState: self.makeFinalState(),
                    scrolls: 0,
                    direction: ""
                )
            )
        }

        _ = try client.swipe(
            to: ForyTarget(label: "Later Cell"),
            from: ForyTarget(),
            distance: nil,
            dir: nil,
            traits: nil,
            cindex: nil
        )

        XCTAssertEqual(captured?.toTarget?.label, "Later Cell")
        XCTAssertNil(captured?.fromTarget)
    }

    func testScreenshotRequiresCompleteFullFrameAndGeneration()
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
            compositorEvidence(valid.fullFrame)
        )
        XCTAssertEqual(
            capture.runtimeEvidence?["syntheticChrome"],
            .bool(false)
        )
        XCTAssertEqual(
            capture.runtimeEvidence?["fullFrame"],
            fullFrameEvidence(valid.fullFrame)
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
                    screenshot: makeScreenshot(
                        jpeg: jpeg,
                        syntheticChrome: true
                    )
                ),
                .malformedRuntimePayload("synthetic chrome screenshot")
            ),
            (
                makePayload(
                    capability: .screenshot,
                    screenshot: makeScreenshot(
                        jpeg: jpeg,
                        fullFrame: makeFullFrame(
                            logicalRect: .init(
                                x: 1,
                                y: 0,
                                width: Double(
                                    IOSUsePlayDeviceLogicalWidth
                                ),
                                height: Double(
                                    IOSUsePlayDeviceLogicalHeight
                                )
                            )
                        )
                    )
                ),
                .runtimeGeometryMismatch("screenshot full frame")
            ),
            (
                makePayload(
                    capability: .screenshot,
                    screenshot: makeScreenshot(
                        jpeg: jpeg,
                        compositor: .object([
                            "syntheticChrome": .bool(false),
                        ])
                    )
                ),
                .malformedRuntimePayload(
                    "screenshot compositor full-frame evidence"
                )
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

    func testScreenshotRequiresEveryCompositorCompletenessField()
        throws
    {
        let jpeg = try makeJPEG(
            width: Int(IOSUsePlayDeviceNativeWidth),
            height: Int(IOSUsePlayDeviceNativeHeight)
        )
        let fullFrame = makeFullFrame()
        let expected = PlayCoverDriverClientError
            .malformedRuntimePayload(
                "screenshot compositor completeness evidence"
            )
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
        var invalidEvidence = [
            compositorEvidence(
                fullFrame,
                omittedTopLevelKeys: ["complete"]
            ),
            compositorEvidence(
                fullFrame,
                topLevelOverrides: ["complete": .bool(false)]
            ),
            compositorEvidence(
                fullFrame,
                topLevelOverrides: ["completeness": .null]
            ),
        ]
        for key in requiredTrue {
            invalidEvidence.append(
                compositorEvidence(
                    fullFrame,
                    completenessOverrides: [
                        key: .bool(false),
                    ]
                )
            )
            invalidEvidence.append(
                compositorEvidence(
                    fullFrame,
                    omittedCompletenessKeys: [key]
                )
            )
        }
        for key in requiredFalse {
            invalidEvidence.append(
                compositorEvidence(
                    fullFrame,
                    completenessOverrides: [
                        key: .bool(true),
                    ]
                )
            )
            invalidEvidence.append(
                compositorEvidence(
                    fullFrame,
                    omittedCompletenessKeys: [key]
                )
            )
        }
        for compositor in invalidEvidence {
            let client = makeClient(
                response: makePayload(
                    capability: .screenshot,
                    screenshot: makeScreenshot(
                        jpeg: jpeg,
                        compositor: compositor
                    )
                )
            )
            XCTAssertThrowsError(try client.screenshotCapture()) {
                XCTAssertEqual(
                    $0 as? PlayCoverDriverClientError,
                    expected
                )
            }
        }

        let forwardCompatible = compositorEvidence(
            fullFrame,
            topLevelOverrides: [
                "futureTopLevelEvidence": .string("preserved"),
            ],
            completenessOverrides: [
                "futureCompletenessEvidence": .bool(true),
            ]
        )
        XCTAssertNoThrow(
            try makeClient(
                response: makePayload(
                    capability: .screenshot,
                    screenshot: makeScreenshot(
                        jpeg: jpeg,
                        compositor: forwardCompatible
                    )
                )
            ).screenshotCapture()
        )
    }

    func testScreenshotRequiresConsistentCompositorWindowInventory()
        throws
    {
        let jpeg = try makeJPEG(
            width: Int(IOSUsePlayDeviceNativeWidth),
            height: Int(IOSUsePlayDeviceNativeHeight)
        )
        let fullFrame = makeFullFrame()
        let validBackingSize = PlayCoverRuntimeJSONValue.object([
            "width": .number(1290),
            "height": .number(2796),
        ])
        let invalidScreenshots = [
            makeScreenshot(
                jpeg: jpeg,
                compositor: compositorEvidence(
                    fullFrame,
                    topLevelOverrides: [
                        "windowCount": .number(2.5),
                    ]
                )
            ),
            makeScreenshot(
                jpeg: jpeg,
                compositor: compositorEvidence(
                    fullFrame,
                    topLevelOverrides: [
                        "requestedWindowCount": .null,
                    ]
                )
            ),
            makeScreenshot(
                jpeg: jpeg,
                compositor: compositorEvidence(
                    fullFrame,
                    topLevelOverrides: [
                        "capturedWindowCount": .number(1),
                    ]
                )
            ),
            makeScreenshot(
                jpeg: jpeg,
                compositor: compositorEvidence(
                    fullFrame,
                    topLevelOverrides: [
                        "mappedUIKitWindowCount": .number(2),
                    ]
                )
            ),
            makeScreenshot(
                jpeg: jpeg,
                compositor: compositorEvidence(
                    fullFrame,
                    topLevelOverrides: [
                        "visibleUIKitWindowCount": .number(2),
                        "mappedUIKitWindowCount": .number(2),
                    ]
                )
            ),
            makeScreenshot(
                jpeg: jpeg,
                compositor: compositorEvidence(
                    fullFrame,
                    topLevelOverrides: [
                        "windows": compositorWindowsEvidence(
                            windowNumbers: [71],
                            captureWindowNumbers: [71]
                        ),
                    ]
                ),
                compositorWindowNumbers: [71],
                sourceBackingSizes: [validBackingSize]
            ),
            makeScreenshot(
                jpeg: jpeg,
                compositor: compositorEvidence(
                    fullFrame,
                    topLevelOverrides: [
                        "windows": compositorWindowsEvidence(
                            windowNumbers: [0, 42],
                            captureWindowNumbers: [0, 42]
                        ),
                    ]
                ),
                compositorWindowNumbers: [0, 42]
            ),
            makeScreenshot(
                jpeg: jpeg,
                compositor: compositorEvidence(
                    fullFrame,
                    topLevelOverrides: [
                        "windows": compositorWindowsEvidence(
                            windowNumbers: [71, 71],
                            captureWindowNumbers: [71, 71]
                        ),
                    ]
                ),
                compositorWindowNumbers: [71, 71]
            ),
            makeScreenshot(
                jpeg: jpeg,
                compositor: compositorEvidence(
                    fullFrame,
                    topLevelOverrides: [
                        "windows": compositorWindowsEvidence(
                            mappedCounts: [2, 1],
                            uiWindowCounts: [1, 1]
                        ),
                    ]
                )
            ),
            makeScreenshot(
                jpeg: jpeg,
                compositor: compositorEvidence(
                    fullFrame,
                    topLevelOverrides: [
                        "windows": compositorWindowsEvidence(
                            captureWindowNumbers: [71, 99]
                        ),
                    ]
                )
            ),
            makeScreenshot(
                jpeg: jpeg,
                compositor: compositorEvidence(
                    fullFrame,
                    topLevelOverrides: [
                        "baseWindowNumber": .number(99),
                    ]
                )
            ),
            makeScreenshot(
                jpeg: jpeg,
                compositorWindowNumbers: [71, 99]
            ),
            makeScreenshot(
                jpeg: jpeg,
                compositorWindowNumbers: [42, 71]
            ),
            makeScreenshot(
                jpeg: jpeg,
                compositorWindowNumbers: nil
            ),
            makeScreenshot(
                jpeg: jpeg,
                sourceBackingSizes: [validBackingSize]
            ),
            makeScreenshot(
                jpeg: jpeg,
                sourceBackingSizes: [
                    validBackingSize,
                    .object([
                        "width": .number(781),
                        "height": .number(657),
                    ]),
                ]
            ),
            makeScreenshot(
                jpeg: jpeg,
                sourceBackingSizes: [
                    validBackingSize,
                    .object([
                        "width": .number(0),
                        "height": .number(657),
                    ]),
                ]
            ),
            makeScreenshot(
                jpeg: jpeg,
                includeSourceBackingSizes: false
            ),
        ]
        let expected = PlayCoverDriverClientError
            .malformedRuntimePayload(
                "screenshot compositor window inventory"
            )
        for screenshot in invalidScreenshots {
            XCTAssertThrowsError(
                try makeClient(
                    response: makePayload(
                        capability: .screenshot,
                        screenshot: screenshot
                    )
                ).screenshotCapture()
            ) {
                XCTAssertEqual(
                    $0 as? PlayCoverDriverClientError,
                    expected
                )
            }
        }

        let zeroUIKitWindows = compositorEvidence(
            fullFrame,
            topLevelOverrides: [
                "visibleUIKitWindowCount": .number(0),
                "mappedUIKitWindowCount": .number(0),
                "windows": compositorWindowsEvidence(
                    mappedCounts: [0, 0],
                    uiWindowCounts: [0, 0]
                ),
            ]
        )
        XCTAssertNoThrow(
            try makeClient(
                response: makePayload(
                    capability: .screenshot,
                    screenshot: makeScreenshot(
                        jpeg: jpeg,
                        compositor: zeroUIKitWindows
                    )
                )
            ).screenshotCapture()
        )
    }

    func testDOMUsesOnlyCommandPayloadAndValidatesItsOwnWindowSize()
        throws
    {
        let valid = makeClient(
            response: .dom(makeDOM(generation: 1))
        )
        XCTAssertNoThrow(
            try valid.dom(
                raw: false,
                fresh: true,
                waitQuiescence: false
            )
        )

        let badDOM = PlayCoverRuntimeDOMPayload(
            app: "Demo",
            windowSize: .init(
                x: Double(IOSUsePlayDeviceLogicalWidth) + 1,
                y: Double(IOSUsePlayDeviceLogicalHeight)
            ),
            raw: "Application, Demo",
            snapshotGeneration: 1,
            elements: [makeElement(generation: 1)]
        )
        let invalid = makeClient(response: .dom(badDOM))
        XCTAssertThrowsError(
            try invalid.dom(
                raw: false,
                fresh: true,
                waitQuiescence: false
            )
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverDriverClientError,
                .runtimeGeometryMismatch("DOM window size")
            )
        }
    }

    func testActionSucceedsWithoutGenericVisualPostcondition()
        throws
    {
        let action = PlayCoverRuntimeActionPayload(
            element: makeSummary(generation: 40),
            hitView: makeHitView(),
            finalState: makeFinalState()
        )
        let client = makeClient(response: .tap(action))

        let result = try client.tap(
            target: ForyTarget(label: "Continue"),
            traits: nil,
            cindex: nil,
            offset: nil,
            ratio: ForyPoint(x: 0.5, y: 0.5)
        )

        XCTAssertEqual(result.element.snapshotGeneration, 40)
        XCTAssertEqual(result.finalState?.phase, "ended")
        XCTAssertNil(result.postcondition)
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

    func testMediaImportUsesHostAdapterWithoutRuntimeRequest()
        throws
    {
        var runtimeRequestCount = 0
        var imported: ForyMediaImportArgs?
        let expected = ForyMediaImportPayload(
            kind: "photo",
            originalFilename: "fixture.heic",
            byteCount: 4,
            assetLocalIdentifier: "asset/local/id",
            permissionPromptHandled: false
        )
        let client = PlayCoverDriverClient(
            session: makeSession(),
            runtimeRequester: { _, _, _ in
                runtimeRequestCount += 1
                return self.makePayload(capability: .hello)
            },
            mediaImporter: {
                imported = $0
                return expected
            }
        )
        let args = ForyMediaImportArgs(
            kind: "photo",
            originalFilename: "fixture.heic",
            uniformTypeIdentifier: "public.heic",
            byteCount: 4,
            data: Data([1, 2, 3, 4])
        )

        let result = try client.mediaImport(args: args)

        XCTAssertEqual(result.assetLocalIdentifier, "asset/local/id")
        XCTAssertEqual(imported?.kind, args.kind)
        XCTAssertEqual(
            imported?.originalFilename,
            args.originalFilename
        )
        XCTAssertEqual(
            imported?.uniformTypeIdentifier,
            args.uniformTypeIdentifier
        )
        XCTAssertEqual(imported?.byteCount, args.byteCount)
        XCTAssertEqual(imported?.data, args.data)
        XCTAssertEqual(runtimeRequestCount, 0)
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
            udid: "mac",
            deviceName: "iPhone16,2",
            deviceVersion: "Mac Catalyst",
            deviceType: PlayCoverSessionService.deviceType,
            runnerPid: 4_242,
            startMode: PlayCoverSessionService.deviceType,
            sessionIdentifier: "session-v3",
            bundleId: "com.example.runtime",
            macAppPath:
                "/tmp/apps/com.example.runtime/Runtime.app",
            macExecutablePath:
                "/tmp/apps/com.example.runtime/Runtime.app/Demo",
            macInstallRevision: String(repeating: "a", count: 64),
            macRuntimeSocketPath: "/tmp/run/s-sessionv3.sock"
        )
    }

    private func makeNativeCatalystHostGeometry(
        status: String = "configured",
        hostPolicy: Bool = true,
        title: String = "Fixture",
        titleExpected: String = "Fixture",
        captureReady: Bool = true,
        captureError: String? = nil,
        backingScaleFactor: Double = 2,
        sceneRasterizationScale: Double = 2,
        fixedBackingScale: Double = 0,
        opaque: Bool = true,
        resizable: Bool = false,
        contentWidth: Double = 331,
        contentHeight: Double = 718,
        hostFrameWidth: Double? = nil,
        canvasCGX: Double = 40,
        canvasCGY: Double = 38
    ) -> PlayCoverRuntimeHostGeometry {
        let frameWidth = hostFrameWidth ?? contentWidth
        return .init(
            status: status,
            hostPolicy: hostPolicy,
            frame: .init(
                x: 40,
                y: 10,
                width: frameWidth,
                height: contentHeight + 28
            ),
            contentBounds: .init(
                x: 0,
                y: 0,
                width: contentWidth,
                height: contentHeight
            ),
            canvasBounds: .init(x: 0, y: 0, width: 430, height: 932),
            backingScaleFactor: backingScaleFactor,
            sceneRasterizationScale: sceneRasterizationScale,
            fixedBackingScale: fixedBackingScale,
            opaque: opaque,
            publicTitleBar: true,
            titleVisible: true,
            resizable: resizable,
            title: title,
            titleExpected: titleExpected,
            capture: .init(
                ready: captureReady,
                error: captureError,
                hostContentCGWindowRect: .init(
                    x: 40,
                    y: 38,
                    width: contentWidth,
                    height: contentHeight
                ),
                hostCGWindowBounds: .init(
                    x: 40,
                    y: 10,
                    width: frameWidth,
                    height: contentHeight + 28
                ),
                canvasCGWindowRect: .init(
                    x: canvasCGX,
                    y: canvasCGY,
                    width: contentWidth,
                    height: contentHeight
                ),
                hostWindowNumber: 17
            )
        )
    }

    private func makeGeometry(
        logicalWidth: Double =
            Double(IOSUsePlayDeviceLogicalWidth),
        safeArea: PlayCoverRuntimeSafeArea = .init(
            top: 17,
            left: 3,
            bottom: 29,
            right: 4
        )
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
            safeArea: safeArea,
            host: makeNativeCatalystHostGeometry()
        )
    }

    func testFixedDeviceAcceptsNaturalSafeAreaDiagnostics()
        throws
    {
        XCTAssertNoThrow(
            try PlayCoverDriverClient.validateFixedDevice(
                makeGeometry(
                    safeArea: .init(
                        top: 17,
                        left: 3,
                        bottom: 29,
                        right: 4
                    )
                ),
                stage: "ready"
            )
        )

        let invalid: [(PlayCoverRuntimeSafeArea, String)] = [
            (.init(top: -1, left: 0, bottom: 0, right: 0), "negative"),
            (.init(top: 500, left: 0, bottom: 500, right: 0), "vertical"),
            (.init(top: 0, left: 300, bottom: 0, right: 300), "horizontal"),
        ]
        for (safeArea, label) in invalid {
            XCTAssertThrowsError(
                try PlayCoverDriverClient.validateFixedDevice(
                    makeGeometry(safeArea: safeArea),
                    stage: "ready"
                ),
                "expected invalid \(label) safe-area diagnostics"
            ) { error in
                XCTAssertEqual(
                    error as? PlayCoverDriverClientError,
                    .runtimeGeometryMismatch("safe-area diagnostics")
                )
            }
        }
    }

    func testFixedDeviceAcceptsNativeCatalystBacking() throws {
        let base = makeGeometry()
        XCTAssertNoThrow(
            try PlayCoverDriverClient.validateFixedDevice(
                base,
                stage: "ready"
            )
        )
        let threeX = PlayCoverRuntimeGeometry(
            logical: base.logical,
            native: base.native,
            scale: base.scale,
            window: base.window,
            safeArea: base.safeArea,
            host: makeNativeCatalystHostGeometry(
                sceneRasterizationScale: 3,
                fixedBackingScale: 3
            )
        )
        XCTAssertNoThrow(
            try PlayCoverDriverClient.validateFixedDevice(
                threeX,
                stage: "ready"
            )
        )
        XCTAssertEqual(base.host?.contentBounds.width, 331)
        XCTAssertEqual(base.host?.contentBounds.height, 718)
        XCTAssertEqual(base.host?.resizable, false)
    }

    func testFixedDeviceRejectsInvalidNativeCatalystHost() throws {
        let base = makeGeometry()
        let invalidHosts: [PlayCoverRuntimeHostGeometry?] = [
            nil,
            makeNativeCatalystHostGeometry(hostPolicy: false),
            makeNativeCatalystHostGeometry(resizable: true),
            makeNativeCatalystHostGeometry(
                sceneRasterizationScale: 3,
                fixedBackingScale: 0
            ),
            makeNativeCatalystHostGeometry(canvasCGX: 41),
            makeNativeCatalystHostGeometry(hostFrameWidth: 320),
            makeNativeCatalystHostGeometry(opaque: false),
        ]
        for host in invalidHosts {
            let geometry = PlayCoverRuntimeGeometry(
                logical: base.logical,
                native: base.native,
                scale: base.scale,
                window: base.window,
                safeArea: base.safeArea,
                host: host
            )
            XCTAssertThrowsError(
                try PlayCoverDriverClient.validateFixedDevice(
                    geometry,
                    stage: "ready"
                )
            )
        }
    }

    func testRuntimeGeometryDecodesNativeCatalystHostFromJSON()
        throws
    {
        let json = Data(
            """
            {
              "logical":{"width":430,"height":932},
              "native":{"width":1290,"height":2796},
              "scale":3,
              "window":{"width":430,"height":932},
              "safeArea":{"top":0,"left":0,"bottom":0,"right":0},
              "host":{
                "status":"configured","hostPolicy":true,
                "frame":{"x":40,"y":10,"width":331,"height":746},
                "contentBounds":{"x":0,"y":0,"width":331,"height":718},
                "canvasBounds":{"x":0,"y":0,"width":430,"height":932},
                "backingScaleFactor":2,
                "sceneRasterizationScale":2,
                "fixedBackingScale":0,
                "opaque":true,
                "publicTitleBar":true,"titleVisible":true,"resizable":false,
                "title":"Fixture","titleExpected":"Fixture",
                "capture":{
                  "ready":true,"error":null,"hostWindowNumber":17,
                  "hostContentCGWindowRect":{"x":40,"y":38,"width":331,"height":718},
                  "hostCGWindowBounds":{"x":40,"y":10,"width":331,"height":746},
                  "canvasCGWindowRect":{"x":40,"y":38,"width":331,"height":718}
                }
              }
            }
            """.utf8
        )
        let geometry = try JSONDecoder().decode(
            PlayCoverRuntimeGeometry.self,
            from: json
        )
        XCTAssertEqual(geometry.host?.status, "configured")
        XCTAssertEqual(geometry.host?.backingScaleFactor, 2)
        XCTAssertEqual(geometry.host?.sceneRasterizationScale, 2)
        XCTAssertEqual(geometry.host?.fixedBackingScale, 0)
        XCTAssertEqual(geometry.host?.resizable, false)
        XCTAssertEqual(geometry.host?.capture.ready, true)
        XCTAssertEqual(geometry.host?.capture.hostWindowNumber, 17)
    }

    func testRuntimeGeometryDecodesUnavailableCanvasCaptureFromJSON()
        throws
    {
        let json = Data(
            """
            {
              "logical":{"width":430,"height":932},
              "native":{"width":1290,"height":2796},
              "scale":3,
              "window":{"width":430,"height":932},
              "safeArea":{"top":0,"left":0,"bottom":0,"right":0},
              "host":{
                "status":"configured","hostPolicy":true,
                "frame":{"x":40,"y":10,"width":331,"height":746},
                "contentBounds":{"x":0,"y":0,"width":331,"height":718},
                "canvasBounds":{"x":0,"y":0,"width":430,"height":932},
                "backingScaleFactor":2,
                "sceneRasterizationScale":2,
                "fixedBackingScale":0,
                "opaque":true,
                "publicTitleBar":true,"titleVisible":true,"resizable":false,
                "title":"Fixture","titleExpected":"Fixture",
                "capture":{
                  "ready":false,"error":"canvas capture unavailable",
                  "hostWindowNumber":null,
                  "hostContentCGWindowRect":{"x":0,"y":0,"width":0,"height":0},
                  "hostCGWindowBounds":{"x":0,"y":0,"width":0,"height":0},
                  "canvasCGWindowRect":{"x":0,"y":0,"width":0,"height":0}
                }
              }
            }
            """.utf8
        )
        let geometry = try JSONDecoder().decode(
            PlayCoverRuntimeGeometry.self,
            from: json
        )
        XCTAssertEqual(geometry.host?.capture.ready, false)
        XCTAssertEqual(
            geometry.host?.capture.error,
            "canvas capture unavailable"
        )
        XCTAssertThrowsError(
            try PlayCoverDriverClient.validateFixedDevice(
                geometry,
                stage: "ready"
            )
        )
    }

    private func makePayload(
        capability: PlayCoverRuntimeCommand,
        screenshot: PlayCoverRuntimeScreenshotPayload? = nil,
        dom: PlayCoverRuntimeDOMPayload? = nil,
        waitFor: PlayCoverRuntimeWaitForPayload? = nil,
        tap: PlayCoverRuntimeActionPayload? = nil,
        longPress: PlayCoverRuntimeActionPayload? = nil,
        swipe: PlayCoverRuntimeSwipePayload? = nil,
        input: PlayCoverRuntimeActionPayload? = nil,
        dismissAlert: PlayCoverRuntimeAlertPayload? = nil,
        dismissAlertByLabel:
            PlayCoverRuntimeAlertPayload? = nil
    ) -> PlayCoverRuntimeResponsePayload {
        switch capability {
        case .hello:
            return .hello(
                .init(
                    pid: 4_242,
                    bundleIdentifier: "com.example.runtime",
                    executablePath:
                        "/tmp/apps/com.example.runtime/Runtime.app/Demo",
                    installRevision: String(repeating: "a", count: 64),
                    capabilities: ["hello"],
                    controlStage: "ready",
                    controlFailure: nil,
                    uiState: .init(
                        state: "ready",
                        stage: "ready",
                        failure: nil
                    ),
                    stdio: .init(
                        status: "disabled",
                        path: nil,
                        device: nil,
                        inode: nil,
                        failureStage: nil,
                        errorNumber: nil
                    )
                )
            )
        case .ping:
            return .ping(.init(
                pid: 4_242,
                bundleIdentifier: "com.example.runtime",
                executablePath:
                    "/tmp/prepared/generation/com.example.runtime.app/Demo",
                pong: true
            ))
        case .diagnostics:
            return .diagnostics(
                .init(
                    pid: 4_242,
                    bundleIdentifier: "com.example.runtime",
                    executablePath:
                        "/tmp/prepared/generation/com.example.runtime.app/Demo",
                    capabilities: ["diagnostics"],
                    geometry: makeGeometry(),
                    stage: "ready",
                    uiState: .init(
                        state: "ready",
                        stage: "ready",
                        failure: nil
                    ),
                    diagnostics: [:],
                    stdio: .init(
                        status: "disabled",
                        path: nil,
                        device: nil,
                        inode: nil,
                        failureStage: nil,
                        errorNumber: nil
                    )
                )
            )
        case .screenshot:
            guard let screenshot else {
                preconditionFailure("missing screenshot test payload")
            }
            return .screenshot(
                .init(
                    screenshot: screenshot,
                    dom: dom ?? makeDOM(
                        generation:
                            screenshot.snapshotGeneration
                    )
                )
            )
        case .dom:
            guard let dom else {
                preconditionFailure("missing DOM test payload")
            }
            return .dom(dom)
        case .uiTree:
            preconditionFailure(
                "uiTree is not routed through DriverCommandClient"
            )
        case .waitFor:
            guard let waitFor else {
                preconditionFailure("missing waitFor test payload")
            }
            return .waitFor(waitFor)
        case .tap:
            guard let tap else {
                preconditionFailure("missing tap test payload")
            }
            return .tap(tap)
        case .longPress:
            guard let longPress else {
                preconditionFailure("missing longPress test payload")
            }
            return .longPress(longPress)
        case .swipe:
            guard let swipe else {
                preconditionFailure("missing swipe test payload")
            }
            return .swipe(swipe)
        case .input:
            guard let input else {
                preconditionFailure("missing input test payload")
            }
            return .input(input)
        case .dismissAlert:
            guard let dismissAlert else {
                preconditionFailure(
                    "missing dismissAlert test payload"
                )
            }
            return .dismissAlert(dismissAlert)
        case .dismissAlertByLabel:
            guard let dismissAlertByLabel else {
                preconditionFailure(
                    "missing dismissAlertByLabel test payload"
                )
            }
            return .dismissAlertByLabel(
                dismissAlertByLabel
            )
        case .debug:
            return .debug(
                PlayCoverRuntimeDebugPayload(
                    display: "test",
                    events: [],
                    agent: "test-agent"
                )
            )
        }
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

    private func makeAction(
        generation: Int64
    ) -> PlayCoverRuntimeActionPayload {
        .init(
            element: makeSummary(generation: generation),
            hitView: makeHitView(),
            finalState: makeFinalState()
        )
    }

    private func makeScreenshot(
        jpeg: Data,
        complete: Bool = true,
        syntheticChrome: Bool = false,
        fullFrame: PlayCoverRuntimeFullFrame? = nil,
        compositor: PlayCoverRuntimeJSONValue? = nil,
        compositorWindowNumbers: [Int]? = [71, 42],
        sourceBackingSizes:
            [PlayCoverRuntimeJSONValue]? = nil,
        includeSourceBackingSizes: Bool = true,
        snapshotGeneration: Int64 = 20,
        captureGeneration: Int64 = 8,
        source: String = "window-compositor",
        logicalWidth: Double =
            Double(IOSUsePlayDeviceLogicalWidth)
    ) -> PlayCoverRuntimeScreenshotPayload {
        let resolvedFullFrame = fullFrame ?? makeFullFrame()
        let resolvedSourceBackingSizes =
            includeSourceBackingSizes
            ? sourceBackingSizes ?? [
                .object([
                    "width": .number(
                        Double(IOSUsePlayDeviceNativeWidth)
                    ),
                    "height": .number(
                        Double(IOSUsePlayDeviceNativeHeight)
                    ),
                ]),
                .object([
                    "width": .number(780),
                    "height": .number(657),
                ]),
            ]
            : nil
        return .init(
            jpegBase64: jpeg.base64EncodedString(),
            pixelWidth: Int(IOSUsePlayDeviceNativeWidth),
            pixelHeight: Int(IOSUsePlayDeviceNativeHeight),
            logicalWidth: logicalWidth,
            logicalHeight:
                Double(IOSUsePlayDeviceLogicalHeight),
            scale: Double(IOSUsePlayDeviceScale),
            source: source,
            complete: complete,
            syntheticChrome: syntheticChrome,
            fullFrame: resolvedFullFrame,
            snapshotGeneration: snapshotGeneration,
            captureGeneration: captureGeneration,
            compositorWindowNumbers: compositorWindowNumbers,
            sourceBackingSizes: resolvedSourceBackingSizes,
            appKitWindowEvidence: .object([
                "ready": .bool(true),
            ]),
            compositor: compositor ??
                compositorEvidence(resolvedFullFrame)
        )
    }

    private func makeFullFrame(
        logicalRect: PlayCoverRuntimeFrame = .init(
            x: 0,
            y: 0,
            width: Double(IOSUsePlayDeviceLogicalWidth),
            height: Double(IOSUsePlayDeviceLogicalHeight)
        ),
        pixelWidth: Int = Int(IOSUsePlayDeviceNativeWidth),
        pixelHeight: Int = Int(IOSUsePlayDeviceNativeHeight),
        scale: Double = Double(IOSUsePlayDeviceScale),
        uncropped: Bool = true,
        safeAreaCropped: Bool = false,
        nativeCanvas: Bool = true
    ) -> PlayCoverRuntimeFullFrame {
        .init(
            logicalRect: logicalRect,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            scale: scale,
            uncropped: uncropped,
            safeAreaCropped: safeAreaCropped,
            nativeCanvas: nativeCanvas
        )
    }

    private func fullFrameEvidence(
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
            "nativeCanvas": .bool(fullFrame.nativeCanvas),
        ])
    }

    private func compositorEvidence(
        _ fullFrame: PlayCoverRuntimeFullFrame,
        topLevelOverrides:
            [String: PlayCoverRuntimeJSONValue] = [:],
        completenessOverrides:
            [String: PlayCoverRuntimeJSONValue] = [:],
        omittedTopLevelKeys: Set<String> = [],
        omittedCompletenessKeys: Set<String> = []
    ) -> PlayCoverRuntimeJSONValue {
        var completeness:
            [String: PlayCoverRuntimeJSONValue] = [
                "allVisibleUIKitWindowsMapped": .bool(true),
                "allVisibleNativeWindowsOrdered": .bool(true),
                "requestedCapturedCountMatch": .bool(true),
                "baseWindowCoversDevice": .bool(true),
                "nativeWindowsCroppedToCanvas": .bool(true),
                "hostDecorationsExcluded": .bool(true),
                "syntheticChrome": .bool(false),
                "fullFrameUncropped": .bool(true),
                "safeAreaCropped": .bool(false),
                "allWindowGeometryInsideDevice": .bool(true),
                "appKitCGWindowSizesMatch": .bool(true),
                "cgWindowPlacementAuthoritative": .bool(true),
                "windowSetStableDuringCapture": .bool(true),
            ]
        for (key, value) in completenessOverrides {
            completeness[key] = value
        }
        for key in omittedCompletenessKeys {
            completeness.removeValue(forKey: key)
        }
        var evidence:
            [String: PlayCoverRuntimeJSONValue] = [
                "complete": .bool(true),
                "syntheticChrome": .bool(false),
                "fullFrame": fullFrameEvidence(fullFrame),
                "windowCount": .number(2),
                "visibleUIKitWindowCount": .number(3),
                "mappedUIKitWindowCount": .number(3),
                "requestedWindowCount": .number(2),
                "capturedWindowCount": .number(2),
                "baseWindowNumber": .number(71),
                "windows": compositorWindowsEvidence(),
                "completeness": .object(completeness),
            ]
        for (key, value) in topLevelOverrides {
            evidence[key] = value
        }
        for key in omittedTopLevelKeys {
            evidence.removeValue(forKey: key)
        }
        return .object(evidence)
    }

    private func compositorWindowsEvidence(
        windowNumbers: [Int] = [71, 42],
        mappedCounts: [Int] = [2, 1],
        uiWindowCounts: [Int] = [2, 1],
        captureWindowNumbers: [Int] = [71, 42],
        sourcePixelWidths: [Int] = [1290, 780],
        sourcePixelHeights: [Int] = [2796, 657]
    ) -> PlayCoverRuntimeJSONValue {
        .array(
            windowNumbers.indices.map { index in
                let mappedCount = index < mappedCounts.count
                    ? mappedCounts[index]
                    : 0
                let uiWindowCount = index < uiWindowCounts.count
                    ? uiWindowCounts[index]
                    : 0
                let sourcePixelWidth =
                    index < sourcePixelWidths.count
                    ? sourcePixelWidths[index]
                    : 0
                let sourcePixelHeight =
                    index < sourcePixelHeights.count
                    ? sourcePixelHeights[index]
                    : 0
                let captureWindowNumber =
                    index < captureWindowNumbers.count
                    ? captureWindowNumbers[index]
                    : 0
                return .object([
                    "windowNumber":
                        .number(Double(windowNumbers[index])),
                    "mappedUIKitWindowCount":
                        .number(Double(mappedCount)),
                    "uiWindows": .array(
                        Array(
                            repeating: .object([:]),
                            count: uiWindowCount
                        )
                    ),
                    "captureGeometry": .object([
                        "windowNumber":
                            .number(Double(captureWindowNumber)),
                        "sourcePixelWidth":
                            .number(Double(sourcePixelWidth)),
                        "sourcePixelHeight":
                            .number(Double(sourcePixelHeight)),
                    ]),
                ])
            }
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
