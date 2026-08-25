import XCTest
import IOSUseProtocol

final class ForyModelTests: XCTestCase {
    func testForyRegistryCanSerializeRequestFrame() throws {
        let fory = ForyRegistry.create()
        let payload = try fory.serialize(ForyWaitForArgs(
            target: ForyTarget(label: "General", traits: "Cell", cindex: -1),
            timeout: 1.5,
            gone: true,
            matchMode: IOSUseWaitForMatchMode.regex.rawValue
        ))
        let frame = ForyRequestFrame(command: DriverCommand.waitFor.rawValue, payload: payload)
        let encoded = try fory.serialize(frame)
        let decoded = try fory.deserialize(encoded, as: ForyRequestFrame.self)

        XCTAssertEqual(decoded.command, "waitFor")
        let args = try fory.deserialize(decoded.payload, as: ForyWaitForArgs.self)
        XCTAssertEqual(args.target.label, "General")
        XCTAssertEqual(args.target.traits, "Cell")
        XCTAssertEqual(args.target.cindex, -1)
        XCTAssertEqual(args.timeout, 1.5)
        XCTAssertTrue(args.gone)
        XCTAssertEqual(args.matchMode, IOSUseWaitForMatchMode.regex.rawValue)
    }

    func testWaitAppForegroundModelsRoundTripBackendNeutralStateAndOptionalDom() throws {
        let fory = ForyRegistry.create()
        let args = ForyWaitAppForegroundArgs(
            acceptedBundleIds: ["com.example.app", "com.example.other"],
            timeout: 4.5,
            returnDom: true
        )
        let decodedArgs = try fory.deserialize(try fory.serialize(args), as: ForyWaitAppForegroundArgs.self)
        XCTAssertEqual(decodedArgs.expectedBundleId, "")
        XCTAssertEqual(decodedArgs.acceptedBundleIds, ["com.example.app", "com.example.other"])
        XCTAssertEqual(decodedArgs.timeout, 4.5)
        XCTAssertTrue(decodedArgs.returnDom)

        let payload = ForyWaitAppForegroundPayload(
            expectedBundleId: "com.example.app",
            activeBundleId: "com.apple.springboard",
            appState: IOSUseAppState.foreground.rawValue,
            snapshotReady: true,
            elapsed: 0.125,
            dom: ForyDomPayload(app: "com.apple.springboard")
        )
        let decodedPayload = try fory.deserialize(
            try fory.serialize(payload),
            as: ForyWaitAppForegroundPayload.self
        )
        XCTAssertEqual(decodedPayload.expectedBundleId, "com.example.app")
        XCTAssertEqual(decodedPayload.activeBundleId, "com.apple.springboard")
        XCTAssertEqual(decodedPayload.appState, IOSUseAppState.foreground.rawValue)
        XCTAssertTrue(decodedPayload.snapshotReady)
        XCTAssertEqual(decodedPayload.elapsed, 0.125)
        XCTAssertEqual(decodedPayload.dom?.app, "com.apple.springboard")
    }

    func testMediaImportModelsRoundTripBinaryPayloadAndReceipt() throws {
        let fory = ForyRegistry.create()
        let args = ForyMediaImportArgs(
            kind: "photo",
            originalFilename: "fixture.heic",
            uniformTypeIdentifier: "public.heic",
            byteCount: 4,
            data: Data([0, 1, 2, 3])
        )
        let decodedArgs = try fory.deserialize(
            try fory.serialize(args),
            as: ForyMediaImportArgs.self
        )
        XCTAssertEqual(decodedArgs.kind, "photo")
        XCTAssertEqual(decodedArgs.originalFilename, "fixture.heic")
        XCTAssertEqual(decodedArgs.uniformTypeIdentifier, "public.heic")
        XCTAssertEqual(decodedArgs.byteCount, 4)
        XCTAssertEqual(decodedArgs.data, Data([0, 1, 2, 3]))

        let payload = ForyMediaImportPayload(
            kind: "photo",
            originalFilename: "fixture.heic",
            byteCount: 4,
            assetLocalIdentifier: "asset/1",
            permissionPromptHandled: true
        )
        let decodedPayload = try fory.deserialize(
            try fory.serialize(payload),
            as: ForyMediaImportPayload.self
        )
        XCTAssertEqual(decodedPayload.assetLocalIdentifier, "asset/1")
        XCTAssertTrue(decodedPayload.permissionPromptHandled)
    }

    func testGuardedAlertModelsRoundTripSelectionCandidatesAndErrorContext() throws {
        let fory = ForyRegistry.create()
        let args = ForyDismissAlertArgs(
            selection: IOSUseAlertSelectionMode.visualPrimary.rawValue,
            scope: IOSUseAlertScope.springboard.rawValue,
            wait: 3
        )
        let decodedArgs = try fory.deserialize(
            try fory.serialize(args),
            as: ForyDismissAlertArgs.self
        )
        XCTAssertEqual(decodedArgs.selection, IOSUseAlertSelectionMode.visualPrimary.rawValue)
        XCTAssertEqual(decodedArgs.scope, IOSUseAlertScope.springboard.rawValue)
        XCTAssertEqual(decodedArgs.wait, 3)

        let alert = ForyAlertPayload(
            dismissed: false,
            surface: "springboard",
            kind: "alert",
            text: "Runner request",
            buttonCount: 2,
            buttons: [
                ForyAlertButton(
                    queryIndex: 1,
                    label: "Allow",
                    identifier: "allow",
                    hittable: true,
                    frame: ForyRect(x: 100, y: 200, w: 80, h: 44)
                ),
            ],
            requestedSelection: "visualPrimary",
            selectionStrategy: "visualPrimaryHeuristic",
            selectedIndex: 1,
            button: "Allow",
            layoutDirection: "leftToRight",
            layoutDirectionSource: "runnerEffective",
            reason: "fixture"
        )
        let error = ForyErrorPayload(
            category: IOSUseErrorCategory.lookup,
            code: IOSUseErrorCode.alertAmbiguous,
            phase: IOSUseErrorPhase.lookup,
            alert: alert
        )
        let decodedError = try fory.deserialize(
            try fory.serialize(error),
            as: ForyErrorPayload.self
        )

        XCTAssertEqual(decodedError.alert?.surface, "springboard")
        XCTAssertEqual(decodedError.alert?.buttonCount, 2)
        XCTAssertEqual(decodedError.alert?.buttons.first?.queryIndex, 1)
        XCTAssertEqual(decodedError.alert?.buttons.first?.frame?.w, 80)
        XCTAssertEqual(decodedError.alert?.layoutDirectionSource, "runnerEffective")
    }
}
