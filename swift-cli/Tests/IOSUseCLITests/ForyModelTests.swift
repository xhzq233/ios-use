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

    func testForyRegistryCanSerializeResponseFrame() throws {
        let fory = ForyRegistry.create()
        let frame = ForyResponseFrame(ok: true, payload: Data([1, 2, 3]))

        let encoded = try fory.serialize(frame)
        let decoded = try fory.deserialize(encoded, as: ForyResponseFrame.self)

        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.payload, Data([1, 2, 3]))
    }

    func testScreenshotPayloadCarriesLogicalScreenGeometry() throws {
        let fory = ForyRegistry.create()
        let payload = ForyScreenshotPayload(
            jpeg: Data([1, 2, 3]),
            logicalSize: ForyPoint(x: 402, y: 874),
            scale: 3
        )

        let decoded = try fory.deserialize(try fory.serialize(payload), as: ForyScreenshotPayload.self)

        XCTAssertEqual(decoded.jpeg, Data([1, 2, 3]))
        XCTAssertEqual(decoded.logicalSize.x, 402)
        XCTAssertEqual(decoded.logicalSize.y, 874)
        XCTAssertEqual(decoded.scale, 3)
    }

    func testForyTargetSerializesNilAndPositiveCindex() throws {
        let fory = ForyRegistry.create()
        let nilEncoded = try fory.serialize(ForyTarget(label: "General", traits: "Cell"))
        let nilDecoded = try fory.deserialize(nilEncoded, as: ForyTarget.self)
        XCTAssertEqual(nilDecoded.label, "General")
        XCTAssertEqual(nilDecoded.traits, "Cell")
        XCTAssertNil(nilDecoded.cindex)

        let positiveEncoded = try fory.serialize(ForyTarget(label: "General", traits: "Cell", cindex: 2))
        let positiveDecoded = try fory.deserialize(positiveEncoded, as: ForyTarget.self)
        XCTAssertEqual(positiveDecoded.cindex, 2)
    }

    func testForyDomArgsSerializesWaitQuiescence() throws {
        let fory = ForyRegistry.create()
        let encoded = try fory.serialize(ForyDomArgs(raw: false, fresh: true, waitQuiescence: true))
        let decoded = try fory.deserialize(encoded, as: ForyDomArgs.self)

        XCTAssertFalse(decoded.raw)
        XCTAssertTrue(decoded.fresh)
        XCTAssertTrue(decoded.waitQuiescence)
    }

    func testForyInputArgsRoundTripDeleteEnterAndLookup() throws {
        let fory = ForyRegistry.create()
        let encoded = try fory.serialize(
            ForyInputArgs(
                target: ForyTarget(
                    label: "Fixture Input",
                    traits: "TextField",
                    cindex: 2
                ),
                content: "replacement",
                deleteCount: 17,
                enter: true
            )
        )
        let decoded = try fory.deserialize(
            encoded,
            as: ForyInputArgs.self
        )

        XCTAssertEqual(decoded.target.label, "Fixture Input")
        XCTAssertEqual(decoded.target.traits, "TextField")
        XCTAssertEqual(decoded.target.cindex, 2)
        XCTAssertEqual(decoded.content, "replacement")
        XCTAssertEqual(decoded.deleteCount, 17)
        XCTAssertTrue(decoded.enter)
    }

    func testDismissAlertByLabelArgsRoundTripExactLabel() throws {
        let fory = ForyRegistry.create()
        let encoded = try fory.serialize(
            ForyDismissAlertByLabelArgs(
                label: "Allow Full Access"
            )
        )
        let decoded = try fory.deserialize(
            encoded,
            as: ForyDismissAlertByLabelArgs.self
        )

        XCTAssertEqual(decoded.label, "Allow Full Access")
    }

    func testForyRegistryCanSerializeProxyCAPushArgs() throws {
        let fory = ForyRegistry.create()
        let encoded = try fory.serialize(ForyProxyCAPushArgs(caBase64: "abc123"))
        let decoded = try fory.deserialize(encoded, as: ForyProxyCAPushArgs.self)

        XCTAssertEqual(decoded.caBase64, "abc123")
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
