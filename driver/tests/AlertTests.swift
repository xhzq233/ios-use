import CoreGraphics
import XCTest

final class AlertTests: XCTestCase {
    func testOnlyButtonRequiresExactlyOneHittableCandidate() throws {
        let single = snapshot(buttons: [
            button(0, "OK", frame: CGRect(x: 20, y: 100, width: 200, height: 44)),
            button(1, "Hidden", hittable: false, frame: CGRect(x: 20, y: 150, width: 200, height: 44)),
        ])

        XCTAssertEqual(
            try resolve(.onlyButton, in: single).queryIndex,
            0
        )
        XCTAssertEqual(
            failure(.onlyButton, in: snapshot(buttons: [
                button(0, "Cancel", frame: CGRect(x: 20, y: 100, width: 100, height: 44)),
                button(1, "Continue", frame: CGRect(x: 120, y: 100, width: 100, height: 44)),
            ])),
            .multipleHittableButtons(2)
        )
    }

    func testIndexUsesQueryIndexAndRequiresHittability() throws {
        let value = snapshot(buttons: [
            button(7, "First", frame: CGRect(x: 20, y: 100, width: 100, height: 44)),
            button(3, "Second", frame: CGRect(x: 120, y: 100, width: 100, height: 44)),
        ])

        XCTAssertEqual(try resolve(.index(3), in: value).queryIndex, 3)
        XCTAssertEqual(failure(.index(1), in: value), .invalidIndex(1))
    }

    func testLabelUsesExactCompatibilityNormalizedMatch() throws {
        let value = snapshot(buttons: [
            button(0, "  Ａllow\nAccess  ", frame: CGRect(x: 20, y: 100, width: 100, height: 44)),
            button(1, "Don't Allow", frame: CGRect(x: 120, y: 100, width: 100, height: 44)),
        ])

        XCTAssertEqual(try resolve(.label("allow access"), in: value).queryIndex, 0)
        XCTAssertEqual(
            failure(.label("Allow"), in: value),
            .labelNotFound("Allow")
        )
    }

    func testDuplicateLabelIsAmbiguous() {
        let value = snapshot(buttons: [
            button(0, "OK", frame: CGRect(x: 20, y: 100, width: 100, height: 44)),
            button(1, "ok", frame: CGRect(x: 120, y: 100, width: 100, height: 44)),
        ])

        XCTAssertEqual(
            failure(.label("OK"), in: value),
            .duplicateLabel("OK", count: 2)
        )
    }

    func testVisualPrimaryHorizontalUsesTrailingGeometryNotQueryOrder() throws {
        let left = button(9, "Left", frame: CGRect(x: 20, y: 100, width: 100, height: 44))
        let right = button(2, "Right", frame: CGRect(x: 120, y: 100, width: 100, height: 44))
        let shuffled = snapshot(buttons: [right, left])

        let ltr = try resolve(.visualPrimary, in: shuffled, direction: .leftToRight)
        let rtl = try resolve(.visualPrimary, in: shuffled, direction: .rightToLeft)

        XCTAssertEqual(ltr.queryIndex, 2)
        XCTAssertEqual(rtl.queryIndex, 9)
        XCTAssertEqual(ltr.strategy, "visualPrimaryHeuristic")
        XCTAssertEqual(ltr.layoutDirection, .leftToRight)
        XCTAssertEqual(ltr.layoutDirectionSource, .runnerEffective)
    }

    func testVisualPrimaryVerticalUsesTopGeometry() throws {
        let bottom = button(0, "Bottom", frame: CGRect(x: 20, y: 144, width: 200, height: 44))
        let top = button(1, "Top", frame: CGRect(x: 20, y: 100, width: 200, height: 44))

        XCTAssertEqual(
            try resolve(.visualPrimary, in: snapshot(buttons: [bottom, top])).queryIndex,
            1
        )
    }

    func testVisualPrimaryAcceptsOneHittableCandidateAndIgnoresNonHittableCandidates() throws {
        let value = snapshot(buttons: [
            button(0, "Hidden", hittable: false, frame: .zero),
            button(1, "Continue", frame: CGRect(x: 20, y: 100, width: 200, height: 44)),
        ])

        XCTAssertEqual(try resolve(.visualPrimary, in: value).queryIndex, 1)
    }

    func testVisualPrimaryRejectsThreeButtonsInvalidFramesAndMixedLayout() {
        XCTAssertEqual(
            failure(.visualPrimary, in: snapshot(buttons: [
                button(0, "A", frame: CGRect(x: 20, y: 100, width: 60, height: 44)),
                button(1, "B", frame: CGRect(x: 80, y: 100, width: 60, height: 44)),
                button(2, "C", frame: CGRect(x: 140, y: 100, width: 60, height: 44)),
            ])),
            .unsupportedVisualCandidateCount(3)
        )
        XCTAssertEqual(
            failure(.visualPrimary, in: snapshot(buttons: [
                button(0, "A", frame: .zero),
            ])),
            .invalidVisualGeometry(index: 0)
        )
        XCTAssertEqual(
            failure(.visualPrimary, in: snapshot(buttons: [
                button(
                    0,
                    "A",
                    frame: CGRect(x: 20, y: 100, width: CGFloat.infinity, height: 44)
                ),
            ])),
            .invalidVisualGeometry(index: 0)
        )
        XCTAssertEqual(
            failure(.visualPrimary, in: snapshot(buttons: [
                button(0, "A", frame: CGRect(x: 20, y: 100, width: 80, height: 44)),
                button(1, "B", frame: CGRect(x: 140, y: 180, width: 80, height: 44)),
            ])),
            .ambiguousVisualLayout
        )
        XCTAssertEqual(
            failure(.visualPrimary, in: snapshot(buttons: [
                button(0, "A", frame: CGRect(x: 20, y: 100, width: 100, height: 44)),
                button(1, "B", frame: CGRect(x: 20, y: 100, width: 100, height: 44)),
            ])),
            .ambiguousVisualLayout
        )
    }

    func testVisualPrimaryTracksDynamicTypeRowToStackGeometry() throws {
        let row = snapshot(buttons: [
            button(0, "Cancel", frame: CGRect(x: 20, y: 100, width: 100, height: 44)),
            button(1, "Continue", frame: CGRect(x: 120, y: 100, width: 100, height: 44)),
        ])
        let stack = snapshot(buttons: [
            button(0, "Cancel", frame: CGRect(x: 20, y: 144, width: 200, height: 44)),
            button(1, "Continue", frame: CGRect(x: 20, y: 100, width: 200, height: 44)),
        ])

        XCTAssertEqual(try resolve(.visualPrimary, in: row).queryIndex, 1)
        XCTAssertEqual(try resolve(.visualPrimary, in: stack).queryIndex, 1)
    }

    func testPayloadBoundsPrivateTextAndCandidates() {
        let longText = String(repeating: "private", count: 100)
        let buttons = (0..<(IOSUseProtocol.errorCandidateLimit + 2)).map { index in
            button(
                index,
                "Button \(index)",
                frame: CGRect(
                    x: 20,
                    y: 100 + CGFloat(index * 44),
                    width: 200,
                    height: 44
                )
            )
        }

        let payload = AlertCommands.makePayload(
            snapshot: snapshot(text: longText, buttons: buttons),
            selection: .onlyButton,
            resolution: nil,
            dismissed: false,
            reason: longText
        )

        XCTAssertEqual(payload.buttonCount, Int32(buttons.count))
        XCTAssertEqual(payload.buttons.count, IOSUseProtocol.errorCandidateLimit)
        XCTAssertLessThanOrEqual(payload.text.count, IOSUseProtocol.alertTextLimit + 1)
        XCTAssertLessThanOrEqual(payload.reason.count, IOSUseProtocol.alertTextLimit + 1)
    }

    func testGenerationFingerprintUsesToleranceButRejectsStructuralChanges() {
        let first = snapshot(
            text: " Runner wants access ",
            frame: CGRect(x: 10, y: 20, width: 300, height: 180),
            buttons: [
                button(0, "Cancel", frame: CGRect(x: 10, y: 150, width: 150, height: 44)),
                button(1, "Allow", frame: CGRect(x: 160, y: 150, width: 150, height: 44)),
            ]
        )
        let animated = snapshot(
            text: "runner  wants\naccess",
            frame: CGRect(x: 11, y: 19, width: 301, height: 179),
            buttons: [
                button(0, "Cancel", hittable: false, frame: CGRect(x: 11, y: 151, width: 149, height: 44)),
                button(1, "Allow", frame: CGRect(x: 160, y: 149, width: 151, height: 45)),
            ]
        )
        var changedButtons = animated.buttons
        changedButtons[1] = button(
            1,
            "Deny",
            frame: CGRect(x: 160, y: 149, width: 151, height: 45)
        )

        XCTAssertTrue(AlertSelectionEngine.sameGeneration(first, animated))
        XCTAssertFalse(AlertSelectionEngine.sameGeneration(
            first,
            snapshot(text: animated.text, frame: animated.frame, buttons: changedButtons)
        ))
    }

    func testRunnerIdentityUsesTokenBoundaries() {
        XCTAssertTrue(AlertSelectionEngine.containsIdentity(
            "IOSUseDriver-Runner",
            in: "“IOSUseDriver-Runner” Would Like Access"
        ))
        XCTAssertFalse(AlertSelectionEngine.containsIdentity(
            "IOSUseDriver",
            in: "“IOSUseDriver-Runner” Would Like Access"
        ))
        XCTAssertFalse(AlertSelectionEngine.containsIdentity(
            "IOSUseDriver-Runner",
            in: "FakeIOSUseDriver-RunnerBackup"
        ))
    }

    private func resolve(
        _ selection: AlertButtonSelection,
        in snapshot: AlertSnapshot,
        direction: AlertLayoutDirection = .leftToRight
    ) throws -> AlertSelectionResolution {
        try AlertSelectionEngine.select(
            selection,
            in: snapshot,
            layoutDirection: direction
        ).get()
    }

    private func failure(
        _ selection: AlertButtonSelection,
        in snapshot: AlertSnapshot,
        direction: AlertLayoutDirection = .leftToRight
    ) -> AlertSelectionFailure? {
        switch AlertSelectionEngine.select(
            selection,
            in: snapshot,
            layoutDirection: direction
        ) {
        case .success:
            return nil
        case .failure(let error):
            return error
        }
    }

    private func snapshot(
        text: String = "Alert",
        frame: CGRect = CGRect(x: 10, y: 20, width: 300, height: 180),
        buttons: [AlertButtonSnapshot]
    ) -> AlertSnapshot {
        AlertSnapshot(
            surface: .springboard,
            kind: .alert,
            text: text,
            frame: frame,
            buttons: buttons
        )
    }

    private func button(
        _ index: Int,
        _ label: String,
        identifier: String = "",
        hittable: Bool = true,
        frame: CGRect
    ) -> AlertButtonSnapshot {
        AlertButtonSnapshot(
            queryIndex: index,
            label: label,
            identifier: identifier,
            isHittable: hittable,
            frame: frame
        )
    }
}
