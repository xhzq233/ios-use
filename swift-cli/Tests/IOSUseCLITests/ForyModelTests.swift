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
}
