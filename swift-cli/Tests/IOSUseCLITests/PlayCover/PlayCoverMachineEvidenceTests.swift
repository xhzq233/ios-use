import IOSUsePlayDevice
import IOSUseProtocol
import XCTest
@testable import IOSUseCLI

final class PlayCoverMachineEvidenceTests: XCTestCase {
    func testOpenMachineDataIncludesReturnedDOM() {
        let dom = ForyDomPayload(
            app: "Fixture",
            windowSize: ForyPoint(
                x: Double(IOSUsePlayDeviceLogicalWidth),
                y: Double(IOSUsePlayDeviceLogicalHeight)
            ),
            snapshotGeneration: 41,
            elements: [
                ForyDomElement(
                    nodeID: "fixture-node",
                    label: "Fixture"
                ),
            ]
        )
        let value = OpenURLService.machineData(
            .init(message: "opened", dom: dom)
        )

        guard case .object(let root) = value,
              case .object(let machineDOM)? = root["dom"]
        else {
            return XCTFail("missing DOM machine payload")
        }
        XCTAssertEqual(
            machineDOM["snapshotGeneration"],
            .integer(41)
        )
        XCTAssertEqual(
            Set(root.keys),
            Set([
                "url",
                "deviceUdid",
                "deviceType",
                "mutationDispatched",
                "schemeLookupVerified",
                "registeredHandlers",
                "readiness",
                "dom",
            ])
        )
    }

    func testScreenshotMachineOutputKeepsFullFrameRuntimeEvidence() {
        let artifact = ScreenshotArtifactService.Result(
            stdout: "",
            imagePath: "/tmp/evidence.jpg",
            ocrSidecarPath: nil,
            warning: nil,
            pixelSize: ForyPoint(
                x: Double(IOSUsePlayDeviceNativeWidth),
                y: Double(IOSUsePlayDeviceNativeHeight)
            ),
            logicalSize: ForyPoint(
                x: Double(IOSUsePlayDeviceLogicalWidth),
                y: Double(IOSUsePlayDeviceLogicalHeight)
            ),
            scale: Double(IOSUsePlayDeviceScale),
            geometrySource: "playcover-runtime-window-compositor",
            performance: nil,
            snapshotGeneration: 72,
            captureGeneration: 9,
            runtimeEvidence: [
                "syntheticChrome": .bool(false),
                "fullFrame": .object([
                    "logicalRect": .object([
                        "x": .number(0),
                        "y": .number(0),
                        "width": .number(
                            Double(IOSUsePlayDeviceLogicalWidth)
                        ),
                        "height": .number(
                            Double(IOSUsePlayDeviceLogicalHeight)
                        ),
                    ]),
                    "pixelWidth": .number(
                        Double(IOSUsePlayDeviceNativeWidth)
                    ),
                    "pixelHeight": .number(
                        Double(IOSUsePlayDeviceNativeHeight)
                    ),
                    "scale": .number(Double(IOSUsePlayDeviceScale)),
                    "uncropped": .bool(true),
                    "safeAreaCropped": .bool(false),
                    "identityMapping": .bool(true),
                ]),
            ]
        )
        let output = DriverCommandResult(
            stdout: "",
            payload: nil,
            artifact: artifact
        ).machineOutput(
            for: .screenshot(name: nil, ocr: false)
        ).data

        guard case .object(let root) = output,
              case .object(let evidence)? =
                root["runtimeEvidence"]
        else {
            return XCTFail("missing Runtime evidence")
        }
        XCTAssertEqual(root["snapshotGeneration"], .integer(72))
        XCTAssertEqual(root["captureGeneration"], .integer(9))
        XCTAssertEqual(
            evidence["syntheticChrome"],
            .boolean(false)
        )
        guard case .object(let fullFrame)? = evidence["fullFrame"]
        else {
            return XCTFail("missing full-frame runtime evidence")
        }
        XCTAssertEqual(fullFrame["uncropped"], .boolean(true))
        XCTAssertEqual(fullFrame["safeAreaCropped"], .boolean(false))
        XCTAssertEqual(fullFrame["identityMapping"], .boolean(true))
    }

    func testRuntimeJSONEvidenceConversionPreservesShape() {
        XCTAssertEqual(
            StatusService.playCoverRuntimeJSONMachineValue(
                .object([
                    "windowNumbers": .array([
                        .number(7),
                        .number(8),
                    ]),
                    "opaque": .bool(true),
                ])
            ),
            .object([
                "windowNumbers": .array([
                    .double(7),
                    .double(8),
                ]),
                "opaque": .boolean(true),
            ])
        )
    }

    func testStatusMachineValueIncludesRuntimeDiagnostics() {
        let payload = PlayCoverRuntimeDiagnosticsPayload(
            pid: 42,
            bundleIdentifier: "com.iosuse.playfixture",
            executablePath: "/tmp/Fixture",
            capabilities: ["diagnostics"],
            geometry: PlayCoverRuntimeGeometry(
                logical: .init(
                    width: Double(
                        IOSUsePlayDeviceLogicalWidth
                    ),
                    height: Double(
                        IOSUsePlayDeviceLogicalHeight
                    )
                ),
                native: .init(
                    width: Double(IOSUsePlayDeviceNativeWidth),
                    height: Double(IOSUsePlayDeviceNativeHeight)
                ),
                scale: Double(IOSUsePlayDeviceScale),
                window: .init(
                    width: Double(
                        IOSUsePlayDeviceLogicalWidth
                    ),
                    height: Double(
                        IOSUsePlayDeviceLogicalHeight
                    )
                ),
                safeArea: .init(
                    top: 17,
                    left: 3,
                    bottom: 29,
                    right: 4
                ),
                host: nil
            ),
            stage: "ready",
            diagnostics: [
                "window": .object([
                    "class": .string("_NSAlertPanel"),
                ]),
            ]
        )

        guard case .object(let root) =
                StatusService.playCoverRuntimeMachineValue(payload),
              case .object(let diagnostics)? =
                root["diagnostics"]
        else {
            return XCTFail("missing diagnostics")
        }
        XCTAssertEqual(
            diagnostics["window"],
            .object(["class": .string("_NSAlertPanel")])
        )
    }
}
