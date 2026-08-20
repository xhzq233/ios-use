import Darwin
import Foundation
import IOSUsePlayDevice
import XCTest
@testable import IOSUseCLI

final class PlayCoverRuntimeClientTests: XCTestCase {
    private let sessionID = "runtime-session"
    private let bundleIdentifier = "com.example.runtime"

    func testTapEncodingOmitsAbsentSemanticRatio() throws {
        let arguments = PlayCoverRuntimeTapArguments(
            target: .init(label: "Continue"),
            offset: nil,
            ratio: nil
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(arguments)
            ) as? [String: Any]
        )
        XCTAssertNil(object["offset"])
        XCTAssertNil(object["ratio"])

        let explicit = PlayCoverRuntimeTapArguments(
            target: .init(label: "Continue"),
            offset: nil,
            ratio: .init(x: 0.5, y: 0.5)
        )
        let explicitObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(explicit)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            (explicitObject["ratio"] as? [String: Any])?["x"]
                as? Double,
            0.5
        )
        XCTAssertEqual(
            (explicitObject["ratio"] as? [String: Any])?["y"]
                as? Double,
            0.5
        )
    }

    func testSwipeEncodingOmitsAbsentAnchor() throws {
        let arguments = PlayCoverRuntimeSwipeArguments(
            toTarget: .init(label: "Later Cell"),
            fromTarget: nil,
            distance: 0,
            direction: -1,
            durationMs: nil
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(arguments)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            (object["toTarget"] as? [String: Any])?["label"]
                as? String,
            "Later Cell"
        )
        XCTAssertNil(object["fromTarget"])
    }

    func testUITreeEncodingKeepsExplicitNullTarget() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    PlayCoverRuntimeUITreeArguments(
                        target: nil,
                        depth: 8
                    )
                )
            ) as? [String: Any]
        )

        XCTAssertTrue(object["target"] is NSNull)
        XCTAssertEqual(object["depth"] as? Int, 8)
    }

    func testEveryCommandUsesExactSingleSessionEnvelopeAndTypedPayload()
        throws
    {
        let cases: [(
            PlayCoverRuntimeCommand,
            PlayCoverRuntimeRequestArguments,
            ([String: Any]) throws -> Void
        )] = [
            (.hello, .empty(), { XCTAssertTrue($0.isEmpty) }),
            (.ping, .empty(), { XCTAssertTrue($0.isEmpty) }),
            (.diagnostics, .empty(), { XCTAssertTrue($0.isEmpty) }),
            (.screenshot, .empty(), { XCTAssertTrue($0.isEmpty) }),
            (
                .dom,
                .dom(.init(
                    raw: true,
                    fresh: false,
                    waitQuiescence: true
                )),
                {
                    XCTAssertEqual($0["raw"] as? Bool, true)
                    XCTAssertEqual($0["fresh"] as? Bool, false)
                    XCTAssertEqual(
                        $0["waitQuiescence"] as? Bool,
                        true
                    )
                }
            ),
            (
                .uiTree,
                .uiTree(.init(target: "Continue", depth: 6)),
                {
                    XCTAssertEqual($0["target"] as? String, "Continue")
                    XCTAssertEqual($0["depth"] as? Int, 6)
                }
            ),
            (
                .waitFor,
                .waitFor(.init(
                    target: .init(
                        label: "Continue",
                        traits: "Button",
                        cindex: 2
                    ),
                    timeout: 7,
                    gone: true,
                    matchMode: 1
                )),
                {
                    XCTAssertEqual($0["timeout"] as? Double, 7)
                    XCTAssertEqual($0["gone"] as? Bool, true)
                    let target = try XCTUnwrap(
                        $0["target"] as? [String: Any]
                    )
                    XCTAssertEqual(
                        target["label"] as? String,
                        "Continue"
                    )
                    XCTAssertEqual(target["traits"] as? String, "Button")
                    XCTAssertEqual(target["cindex"] as? Int, 2)
                    XCTAssertNil(target["point"])
                    XCTAssertNil(target["matchMode"])
                }
            ),
            (
                .tap,
                .tap(.init(
                    target: .init(label: "Continue"),
                    offset: .init(x: 2, y: 3),
                    ratio: .init(x: 0.5, y: 0.75)
                )),
                {
                    XCTAssertEqual(
                        ($0["target"] as? [String: Any])?["label"]
                            as? String,
                        "Continue"
                    )
                    XCTAssertEqual(
                        ($0["offset"] as? [String: Any])?["x"]
                            as? Double,
                        2
                    )
                    XCTAssertEqual(
                        ($0["ratio"] as? [String: Any])?["y"]
                            as? Double,
                        0.75
                    )
                }
            ),
            (
                .longPress,
                .longPress(.init(
                    target: .init(label: "Photo"),
                    durationMs: 800
                )),
                {
                    XCTAssertEqual($0["durationMs"] as? Int, 800)
                }
            ),
            (
                .swipe,
                .swipe(.init(
                    toTarget: .init(label: "Developer"),
                    fromTarget: .init(label: "Bluetooth"),
                    distance: 300,
                    direction: -1,
                    durationMs: 420
                )),
                {
                    XCTAssertEqual($0["distance"] as? Double, 300)
                    XCTAssertEqual($0["direction"] as? Int, -1)
                    XCTAssertEqual($0["durationMs"] as? Int, 420)
                    XCTAssertEqual(
                        ($0["toTarget"] as? [String: Any])?["label"]
                            as? String,
                        "Developer"
                    )
                    XCTAssertEqual(
                        ($0["fromTarget"] as? [String: Any])?["label"]
                            as? String,
                        "Bluetooth"
                    )
                }
            ),
            (
                .input,
                .input(.init(
                    target: .init(label: "Search"),
                    content: "hello",
                    deleteCount: 3,
                    enter: true
                )),
                {
                    XCTAssertEqual($0["content"] as? String, "hello")
                    XCTAssertEqual($0["deleteCount"] as? Int, 3)
                    XCTAssertEqual($0["enter"] as? Bool, true)
                    XCTAssertEqual(
                        ($0["target"] as? [String: Any])?["label"]
                            as? String,
                        "Search"
                    )
                }
            ),
            (
                .dismissAlert,
                .dismissAlert(.init(index: 1)),
                {
                    XCTAssertEqual($0["index"] as? Int, 1)
                    XCTAssertEqual(
                        $0["selection"] as? String,
                        "index"
                    )
                    XCTAssertNil($0["label"])
                }
            ),
            (
                .dismissAlertByLabel,
                .dismissAlertByLabel(.init(
                    label: "Allow Full Access"
                )),
                {
                    XCTAssertNil($0["index"])
                    XCTAssertEqual(
                        $0["label"] as? String,
                        "Allow Full Access"
                    )
                }
            ),
        ]

        for (command, arguments, validate) in cases {
            let fixture = try RuntimeClientFixture()
            defer { fixture.remove() }
            let server = try FakeUnixRuntimeServer(
                socketPath: fixture.socketPath
            ) { request in
                XCTAssertEqual(
                    Set(request.keys),
                    Set([
                        "requestId",
                        "sessionID",
                        "command",
                        "arguments",
                    ])
                )
                XCTAssertEqual(
                    request["sessionID"] as? String,
                    self.sessionID
                )
                XCTAssertEqual(
                    request["command"] as? String,
                    command.rawValue
                )
                XCTAssertNil(request["refreshAlertStatus"])
                let requestID = try XCTUnwrap(
                    request["requestId"] as? String
                )
                XCTAssertNotNil(UUID(uuidString: requestID))
                let body = try XCTUnwrap(
                    request["arguments"] as? [String: Any]
                )
                try validate(body)
                let payload = self.payload(for: command)
                if ![.hello, .ping, .diagnostics].contains(command) {
                    XCTAssertTrue(
                        Set(payload.keys).isDisjoint(
                            with: [
                                "pid",
                                "bundleIdentifier",
                                "executablePath",
                                "capabilities",
                                "geometry",
                                "stage",
                                "observed",
                            ]
                        ),
                        "\(command.rawValue) returned session-wide evidence"
                    )
                }
                return .body(try self.successResponse(
                    requestID: requestID,
                    payload: payload
                ))
            }

            _ = try makeClient(socketPath: fixture.socketPath)
                .request(command, arguments: arguments)
            try server.wait()
            XCTAssertEqual(server.peerUID, geteuid())
        }
    }

    func testAlertRefreshMetadataIsRecordedForReadCommand()
        throws
    {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let server = try FakeUnixRuntimeServer(
            socketPath: fixture.socketPath
        ) { request in
            XCTAssertEqual(
                request["refreshAlertStatus"] as? Bool,
                true
            )
            let requestID = try XCTUnwrap(
                request["requestId"] as? String
            )
            return .body(
                try JSONSerialization.data(withJSONObject: [
                    "requestId": requestID,
                    "sessionID": self.sessionID,
                    "ok": true,
                    "payload": [
                        "dom": self.domPayload(generation: 71),
                    ],
                    "interactionState": [
                        "refreshComplete": true,
                        "blocking": true,
                        "interactions": [[
                            "type": "inProcessAlert",
                            "owner": "targetApp",
                            "visible": true,
                            "actionableByIOSUse": true,
                            "source": "appkitNative",
                            "text": "Fixture Alert",
                            "actions": [[
                                "index": 0,
                                "label": "Confirm",
                            ]],
                            "suggestedCommand":
                                "ios-use dismissAlert --label Confirm",
                        ]],
                    ],
                    "performance": [
                        "alertRefreshElapsedMs": 1.25,
                    ],
                ])
            )
        }
        let invocationState = CLIInvocationState()
        let performanceCollector =
            CLIInvocationPerformanceCollector()
        let payload =
            try CLIInvocationContext
                .$current.withValue(invocationState) {
                    try CLIInvocationPerformanceContext
                        .$current.withValue(
                            performanceCollector
                        ) {
                            try makeClient(
                                socketPath: fixture.socketPath,
                                refreshAlertStatus: true
                            ).dom(
                                .init(
                                    raw: false,
                                    fresh: true,
                                    waitQuiescence: false
                                )
                            )
                        }
                }
        try server.wait()

        XCTAssertEqual(payload.snapshotGeneration, 71)
        let performanceSnapshot =
            performanceCollector.snapshot()
        XCTAssertEqual(
            performanceSnapshot.alertRefreshElapsedMs,
            1.25
        )
        let invocationSnapshot = invocationState.snapshot()
        XCTAssertNotNil(invocationSnapshot.interactionState)
        XCTAssertEqual(invocationSnapshot.warnings.count, 1)
        XCTAssertTrue(
            invocationSnapshot.warnings[0].contains(
                "dismissAlert"
            )
        )
    }

    func testWaitForDefersAlertRefreshToPreserveItsTimeout()
        throws
    {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let server = try FakeUnixRuntimeServer(
            socketPath: fixture.socketPath
        ) { request in
            XCTAssertNil(request["refreshAlertStatus"])
            let requestID = try XCTUnwrap(
                request["requestId"] as? String
            )
            return .body(try self.successResponse(
                requestID: requestID,
                payload: self.payload(for: .waitFor)
            ))
        }
        _ = try makeClient(
            socketPath: fixture.socketPath,
            refreshAlertStatus: true
        ).request(
            .waitFor,
            arguments: .waitFor(.init(
                target: .init(
                    label: "Ready",
                    traits: "",
                    cindex: nil
                ),
                timeout: 1,
                gone: false,
                matchMode: 0
            ))
        )
        try server.wait()
    }

    func testRemoteInteractionStateDoesNotRequirePerformanceCollector()
        throws
    {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let server = try FakeUnixRuntimeServer(
            socketPath: fixture.socketPath
        ) { request in
            let requestID = try XCTUnwrap(
                request["requestId"] as? String
            )
            return .body(
                try JSONSerialization.data(withJSONObject: [
                    "requestId": requestID,
                    "sessionID": self.sessionID,
                    "ok": false,
                    "error": [
                        "code":
                            "photos_permission_interaction_required",
                        "message":
                            "Photos authorization is pending",
                        "details": [
                            "category": "interaction",
                            "phase": "precondition",
                            "retryable": false,
                            "fatal": false,
                            "candidateCount": 0,
                            "candidates": [],
                            "suggestions": [
                                "Handle the prompt manually.",
                            ],
                        ],
                    ],
                    "interactionState": [
                        "refreshComplete": true,
                        "blocking": true,
                        "interactions": [[
                            "type":
                                "pendingExternalInteraction",
                            "kind": "photosAuthorization",
                            "pending": true,
                            "visibility": "unknown",
                            "actionableByIOSUse": false,
                            "outstandingCount": 1,
                            "sequence": 8,
                            "api": "requestAuthorization:",
                            "accessLevel": 2,
                            "authorizationStatus": 0,
                            "ageMicroseconds": 500,
                            "resolution":
                                "manual_or_computer_use",
                        ]],
                    ],
                    "performance": [
                        "alertRefreshElapsedMs": 0.5,
                    ],
                ])
            )
        }
        let invocationState = CLIInvocationState()

        XCTAssertThrowsError(
            try CLIInvocationContext
                .$current.withValue(invocationState) {
                    try makeClient(
                        socketPath: fixture.socketPath,
                        refreshAlertStatus: true
                    ).tap(
                        .init(
                            target: .init(label: "Underlay"),
                            offset: nil,
                            ratio: nil
                        )
                    )
                }
        ) {
            guard case .remoteError(let code, _, _) =
                    $0 as? PlayCoverRuntimeClientError else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertEqual(
                code,
                "photos_permission_interaction_required"
            )
        }
        try server.wait()
        let snapshot = invocationState.snapshot()
        guard case .object(let interaction) =
                snapshot.interactionState else {
            return XCTFail("missing interaction state")
        }
        guard case .array(let interactions) =
                interaction["interactions"],
              case .object(let photos) = interactions.first else {
            return XCTFail("missing Photos interaction")
        }
        XCTAssertEqual(photos["accessLevel"], .integer(2))
        XCTAssertEqual(
            photos["authorizationStatus"],
            .integer(0)
        )
        XCTAssertEqual(snapshot.warnings.count, 1)
        XCTAssertTrue(
            snapshot.warnings[0].contains("Computer Use")
        )
    }

    func testDecodesCommandSpecificScreenshotAndDOMPayload() throws {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let server = try FakeUnixRuntimeServer(
            socketPath: fixture.socketPath
        ) { request in
            let requestID = try XCTUnwrap(
                request["requestId"] as? String
            )
            let dom = self.domPayload(generation: 41)
            let screenshot: [String: Any] = [
                "jpegBase64": jpeg.base64EncodedString(),
                "pixelWidth": Int(
                    IOSUsePlayDeviceNativeWidth
                ),
                "pixelHeight": Int(
                    IOSUsePlayDeviceNativeHeight
                ),
                "logicalWidth": Int(
                    IOSUsePlayDeviceLogicalWidth
                ),
                "logicalHeight": Int(
                    IOSUsePlayDeviceLogicalHeight
                ),
                "scale": Int(IOSUsePlayDeviceScale),
                "source": "window-compositor",
                "complete": true,
                "syntheticChrome": false,
                "fullFrame": self.fullFramePayload(),
                "snapshotGeneration": 41,
                "captureGeneration": 9,
                "compositor": [
                    "syntheticChrome": false,
                    "fullFrame": self.fullFramePayload(),
                ],
            ]
            return .body(try self.successResponse(
                requestID: requestID,
                payload: [
                    "screenshot": screenshot,
                    "dom": dom,
                ]
            ), chunkSize: 1)
        }

        let result = try makeClient(
            socketPath: fixture.socketPath,
            timeout: 2
        ).screenshot()
        try server.wait()

        XCTAssertEqual(result.screenshot.snapshotGeneration, 41)
        XCTAssertEqual(result.screenshot.captureGeneration, 9)
        XCTAssertEqual(result.screenshot.syntheticChrome, false)
        XCTAssertEqual(
            result.screenshot.fullFrame.logicalRect,
            .init(
                x: 0,
                y: 0,
                width: Double(IOSUsePlayDeviceLogicalWidth),
                height: Double(IOSUsePlayDeviceLogicalHeight)
            )
        )
        let element = try XCTUnwrap(result.dom.elements.first)
        XCTAssertEqual(element.nodeID, "n-41")
        XCTAssertEqual(element.type, "Button")
        XCTAssertEqual(element.elementType, 1)
        XCTAssertEqual(element.label, "Continue")
        XCTAssertEqual(element.class, "UIButton")
        XCTAssertEqual(element.frame?.width, 120)
        XCTAssertEqual(element.hierarchy.depth, 1)
        XCTAssertEqual(element.state.visible, true)
    }

    func testActionPayloadContainsOnlyDeliveryEvidence() throws {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let server = try FakeUnixRuntimeServer(
            socketPath: fixture.socketPath
        ) { request in
            let requestID = try XCTUnwrap(
                request["requestId"] as? String
            )
            return .body(try self.successResponse(
                requestID: requestID,
                payload: [
                    "tap": self.actionPayload(generation: 42),
                ]
            ))
        }

        let result = try makeClient(
            socketPath: fixture.socketPath
        ).tap(
            .init(
                target: .init(label: "Continue"),
                offset: nil,
                ratio: .init(x: 0.5, y: 0.5)
            )
        )
        try server.wait()

        XCTAssertEqual(result.hitView.class, "UIButton")
        XCTAssertEqual(result.finalState.touchID, 77)
    }

    func testRejectsSessionRequestAndRuntimeIdentityMismatches() throws {
        enum Mutation: Equatable {
            case request
            case session
            case pid
            case bundle
            case executable
        }
        for mutation in [
            Mutation.request,
            .session,
            .pid,
            .bundle,
            .executable,
        ] {
            let fixture = try RuntimeClientFixture()
            defer { fixture.remove() }
            let server = try FakeUnixRuntimeServer(
                socketPath: fixture.socketPath
            ) { request in
                let requestID = try XCTUnwrap(
                    request["requestId"] as? String
                )
                var payload = self.helloPayload()
                if case .pid = mutation {
                    payload["pid"] = Int(getpid()) + 1
                }
                if case .bundle = mutation {
                    payload["bundleIdentifier"] = "other.bundle"
                }
                if case .executable = mutation {
                    payload["executablePath"] = "/bin/false"
                }
                var envelope: [String: Any] = [
                    "requestId": mutation == .request
                        ? UUID().uuidString
                        : requestID,
                    "sessionID": mutation == .session
                        ? "other-session"
                        : self.sessionID,
                    "ok": true,
                    "payload": payload,
                ]
                if mutation == .request {
                    envelope["requestId"] = UUID().uuidString
                }
                return .body(
                    try JSONSerialization.data(
                        withJSONObject: envelope
                    )
                )
            }

            XCTAssertThrowsError(
                try makeClient(socketPath: fixture.socketPath).hello()
            ) { error in
                guard let runtimeError =
                        error as? PlayCoverRuntimeClientError else {
                    return XCTFail("unexpected error: \(error)")
                }
                switch mutation {
                case .request:
                    XCTAssertEqual(runtimeError, .requestIDMismatch)
                case .session:
                    XCTAssertEqual(runtimeError, .sessionIDMismatch)
                case .pid:
                    XCTAssertEqual(
                        runtimeError,
                        .responseIdentityMismatch("PID")
                    )
                case .bundle:
                    XCTAssertEqual(
                        runtimeError,
                        .responseIdentityMismatch(
                            "bundle identifier"
                        )
                    )
                case .executable:
                    XCTAssertEqual(
                        runtimeError,
                        .responseIdentityMismatch("executable")
                    )
                }
            }
            try server.wait()
        }
    }

    func testDiagnosticsValidatesFreshRuntimeIdentity() throws {
        let cases: [(String, PlayCoverRuntimeClientError)] = [
            ("pid", .responseIdentityMismatch("PID")),
            (
                "bundle",
                .responseIdentityMismatch("bundle identifier")
            ),
            (
                "executable",
                .responseIdentityMismatch("executable")
            ),
        ]
        for (mutation, expected) in cases {
            let fixture = try RuntimeClientFixture()
            defer { fixture.remove() }
            let server = try FakeUnixRuntimeServer(
                socketPath: fixture.socketPath
            ) { request in
                let requestID = try XCTUnwrap(
                    request["requestId"] as? String
                )
                var payload = self.payload(for: .diagnostics)
                switch mutation {
                case "pid":
                    payload["pid"] = Int(getpid()) + 1
                case "bundle":
                    payload["bundleIdentifier"] = "other.bundle"
                default:
                    payload["executablePath"] = "/bin/false"
                }
                return .body(try self.successResponse(
                    requestID: requestID,
                    payload: payload
                ))
            }

            XCTAssertThrowsError(
                try makeClient(
                    socketPath: fixture.socketPath
                ).diagnostics()
            ) {
                XCTAssertEqual(
                    $0 as? PlayCoverRuntimeClientError,
                    expected
                )
            }
            try server.wait()
        }
    }

    func testPingValidatesFreshRuntimeIdentity() throws {
        let cases: [(String, PlayCoverRuntimeClientError)] = [
            ("pid", .responseIdentityMismatch("PID")),
            (
                "bundle",
                .responseIdentityMismatch("bundle identifier")
            ),
            (
                "executable",
                .responseIdentityMismatch("executable")
            ),
        ]
        for (mutation, expected) in cases {
            let fixture = try RuntimeClientFixture()
            defer { fixture.remove() }
            let server = try FakeUnixRuntimeServer(
                socketPath: fixture.socketPath
            ) { request in
                let requestID = try XCTUnwrap(
                    request["requestId"] as? String
                )
                var payload = self.payload(for: .ping)
                switch mutation {
                case "pid":
                    payload["pid"] = Int(getpid()) + 1
                case "bundle":
                    payload["bundleIdentifier"] = "other.bundle"
                default:
                    payload["executablePath"] = "/bin/false"
                }
                return .body(try self.successResponse(
                    requestID: requestID,
                    payload: payload
                ))
            }

            XCTAssertThrowsError(
                try makeClient(socketPath: fixture.socketPath).ping()
            ) {
                XCTAssertEqual(
                    $0 as? PlayCoverRuntimeClientError,
                    expected
                )
            }
            try server.wait()
        }
    }

    func testPingRejectsIncompleteIdentity() throws {
        for includedIdentityKey in [
            nil,
            "pid",
            "bundleIdentifier",
            "executablePath",
        ] as [String?] {
            let fixture = try RuntimeClientFixture()
            defer { fixture.remove() }
            let server = try FakeUnixRuntimeServer(
                socketPath: fixture.socketPath
            ) { request in
                let requestID = try XCTUnwrap(
                    request["requestId"] as? String
                )
                var payload: [String: Any] = ["pong": true]
                if let includedIdentityKey {
                    payload[includedIdentityKey] =
                        self.payload(for: .ping)[includedIdentityKey]
                }
                return .body(try self.successResponse(
                    requestID: requestID,
                    payload: payload
                ))
            }

            XCTAssertThrowsError(
                try makeClient(socketPath: fixture.socketPath).ping()
            ) {
                XCTAssertEqual(
                    $0 as? PlayCoverRuntimeClientError,
                    .malformedResponse("ping identity is incomplete")
                )
            }
            try server.wait()
        }
    }

    func testRemoteErrorPreservesTypedDetailsAndRedactsSession() throws {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let server = try FakeUnixRuntimeServer(
            socketPath: fixture.socketPath
        ) { request in
            let requestID = try XCTUnwrap(
                request["requestId"] as? String
            )
            return .body(
                try JSONSerialization.data(withJSONObject: [
                    "requestId": requestID,
                    "sessionID": self.sessionID,
                    "ok": false,
                    "error": [
                        "code": "element_not_found",
                        "message":
                            "\(self.sessionID) element is absent",
                        "details": [
                            "category": "lookup",
                            "phase": "lookup",
                            "retryable": true,
                            "fatal": false,
                            "target": [
                                "label": "Continue",
                                "traits": "Button",
                            ],
                            "candidateCount": 0,
                            "candidates": [],
                            "suggestions": ["Refresh DOM"],
                        ],
                    ],
                ])
            )
        }

        XCTAssertThrowsError(
            try makeClient(socketPath: fixture.socketPath).hello()
        ) { error in
            guard case .remoteError(
                let code,
                let message,
                let details?
            ) = error as? PlayCoverRuntimeClientError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(code, "element_not_found")
            XCTAssertFalse(message.contains(self.sessionID))
            XCTAssertTrue(message.contains("<redacted>"))
            XCTAssertEqual(details.category, "lookup")
            XCTAssertEqual(details.target?.label, "Continue")
            XCTAssertEqual(details.suggestions, ["Refresh DOM"])
        }
        try server.wait()
    }

    func testPeerPIDAndExecutableAreAuthenticatedBeforeRequest()
        throws
    {
        for mismatch in ["pid", "executable"] {
            let fixture = try RuntimeClientFixture()
            defer { fixture.remove() }
            var handledRequests = 0
            let server = try FakeUnixRuntimeServer(
                socketPath: fixture.socketPath
            ) { request in
                handledRequests += 1
                let requestID = try XCTUnwrap(
                    request["requestId"] as? String
                )
                return .body(try self.successResponse(
                    requestID: requestID,
                    payload: self.helloPayload()
                ))
            }
            let executable = try XCTUnwrap(
                PlayCoverRuntimeClient.executablePath(
                    for: getpid()
                )
            )
            let client = PlayCoverRuntimeClient(
                socketPath: fixture.socketPath,
                sessionID: sessionID,
                expectedPID:
                    mismatch == "pid"
                    ? getpid() + 1
                    : getpid(),
                expectedBundleIdentifier: bundleIdentifier,
                expectedExecutablePath:
                    mismatch == "executable"
                    ? "/bin/false"
                    : executable,
                timeoutSeconds: 1
            )

            XCTAssertThrowsError(try client.hello()) { error in
                if mismatch == "pid" {
                    guard case .peerPIDMismatch =
                            error as? PlayCoverRuntimeClientError else {
                        return XCTFail(
                            "unexpected error: \(error)"
                        )
                    }
                } else {
                    XCTAssertEqual(
                        error as? PlayCoverRuntimeClientError,
                        .processExecutableMismatch
                    )
                }
            }
            _ = try? server.wait()
            XCTAssertEqual(handledRequests, 0)
        }
    }

    func testMalformedResponseFrameIsRejected() throws {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let server = try FakeUnixRuntimeServer(
            socketPath: fixture.socketPath
        ) { _ in
            .body(Data(#"{"requestId":"broken""#.utf8))
        }

        XCTAssertThrowsError(
            try makeClient(socketPath: fixture.socketPath).hello()
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverRuntimeClientError,
                .responseDecodingFailed
            )
        }
        try server.wait()
    }

    func testHelloRequiresTheCurrentControlPayload() throws {
        for missingKey in [
            "installRevision",
            "controlStage",
            "uiState",
            "stdio",
        ] {
            let fixture = try RuntimeClientFixture()
            defer { fixture.remove() }
            let server = try FakeUnixRuntimeServer(
                socketPath: fixture.socketPath
            ) { request in
                let requestID = try XCTUnwrap(
                    request["requestId"] as? String
                )
                var payload = self.helloPayload()
                payload.removeValue(forKey: missingKey)
                return .body(try self.successResponse(
                    requestID: requestID,
                    payload: payload
                ))
            }

            XCTAssertThrowsError(
                try makeClient(socketPath: fixture.socketPath).hello(),
                missingKey
            ) {
                XCTAssertEqual(
                    $0 as? PlayCoverRuntimeClientError,
                    .responseDecodingFailed
                )
            }
            try server.wait()
        }
    }

    func testRuntimeUINotReadyRemainsATypeableRetryableError()
        throws
    {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let server = try FakeUnixRuntimeServer(
            socketPath: fixture.socketPath
        ) { request in
            let requestID = try XCTUnwrap(
                request["requestId"] as? String
            )
            return .body(
                try JSONSerialization.data(withJSONObject: [
                    "requestId": requestID,
                    "sessionID": self.sessionID,
                    "ok": false,
                    "error": [
                        "code": "runtime_ui_not_ready",
                        "message": "Runtime UI is still initializing",
                        "details": [
                            "category": "precondition",
                            "phase": "waiting-for-window",
                            "retryable": true,
                            "fatal": false,
                            "candidateCount": 0,
                            "candidates": [],
                            "suggestions": ["retry the same UI command"],
                        ],
                    ],
                    "interactionState": [
                        "refreshComplete": false,
                        "refreshError": "runtime_ui_not_ready",
                        "blocking": false,
                        "interactions": [],
                    ],
                    "performance": [
                        "alertRefreshElapsedMs": 0.0,
                    ],
                ])
            )
        }

        XCTAssertThrowsError(
            try makeClient(
                socketPath: fixture.socketPath,
                refreshAlertStatus: true
            ).dom(
                .init(raw: false, fresh: true, waitQuiescence: false)
            )
        ) {
            guard case .remoteError(let code, _, let details) =
                    $0 as? PlayCoverRuntimeClientError else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertEqual(code, "runtime_ui_not_ready")
            XCTAssertEqual(details?.phase, "waiting-for-window")
            XCTAssertEqual(details?.retryable, true)
            XCTAssertEqual(details?.fatal, false)
        }
        try server.wait()
    }

    func testRuntimeUIBackgroundedRemainsATypeableRetryableError()
        throws
    {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        let server = try FakeUnixRuntimeServer(
            socketPath: fixture.socketPath
        ) { request in
            let requestID = try XCTUnwrap(
                request["requestId"] as? String
            )
            return .body(
                try JSONSerialization.data(withJSONObject: [
                    "requestId": requestID,
                    "sessionID": self.sessionID,
                    "ok": false,
                    "error": [
                        "code": "runtime_ui_backgrounded",
                        "message": "Runtime UI is not available",
                        "details": [
                            "category": "precondition",
                            "phase": "inactive-space",
                            "reason": "inactive-space",
                            "retryable": true,
                            "fatal": false,
                            "candidateCount": 0,
                            "candidates": [],
                            "suggestions": [],
                        ],
                    ],
                    "interactionState": [
                        "refreshComplete": false,
                        "refreshError": "runtime_ui_backgrounded",
                        "blocking": false,
                        "interactions": [],
                    ],
                    "performance": [
                        "alertRefreshElapsedMs": 0.0,
                    ],
                ])
            )
        }

        XCTAssertThrowsError(
            try makeClient(
                socketPath: fixture.socketPath,
                refreshAlertStatus: true
            ).dom(
                .init(raw: false, fresh: true, waitQuiescence: false)
            )
        ) {
            guard case .remoteError(let code, _, let details) =
                    $0 as? PlayCoverRuntimeClientError else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertEqual(code, "runtime_ui_backgrounded")
            XCTAssertEqual(details?.phase, "inactive-space")
            XCTAssertEqual(details?.retryable, true)
            XCTAssertEqual(details?.fatal, false)
        }
        try server.wait()
    }

    func testMutationTransportFailureIsNeverReplayed() throws {
        let fixture = try RuntimeClientFixture()
        defer { fixture.remove() }
        var requestCount = 0
        let server = try FakeUnixRuntimeServer(
            socketPath: fixture.socketPath
        ) { request in
            requestCount += 1
            XCTAssertEqual(
                request["command"] as? String,
                "tap"
            )
            return .body(Data(#"{"broken":true"#.utf8))
        }

        XCTAssertThrowsError(
            try makeClient(socketPath: fixture.socketPath).tap(
                .init(
                    target: .init(label: "Continue"),
                    offset: nil,
                    ratio: .init(x: 0.5, y: 0.5)
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverRuntimeClientError,
                .responseDecodingFailed
            )
        }
        try server.wait()
        XCTAssertEqual(requestCount, 1)
    }

    func testTransportBoundsAndAbsoluteDeadlineAreEnforced() throws {
        XCTAssertEqual(
            try? makeClient(socketPath: "").hello(),
            nil
        )
        XCTAssertThrowsError(
            try makeClient(socketPath: "").hello()
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverRuntimeClientError,
                .invalidSocketPath(.empty)
            )
        }
        XCTAssertThrowsError(
            try makeClient(
                socketPath: "/tmp/not-used.sock",
                timeout: 0
            ).hello()
        ) {
            XCTAssertEqual(
                $0 as? PlayCoverRuntimeClientError,
                .invalidTimeout
            )
        }
        XCTAssertThrowsError(
            try makeClient(
                socketPath: "/tmp/not-used.sock"
            ).input(.init(
                target: nil,
                content: String(
                    repeating: "x",
                    count:
                        PlayCoverRuntimeClient
                            .maximumRequestBodyBytes
                )
            ))
        ) {
            guard case .requestFrameTooLarge =
                    $0 as? PlayCoverRuntimeClientError else {
                return XCTFail("unexpected error: \($0)")
            }
        }

        let oversized = try RuntimeClientFixture()
        defer { oversized.remove() }
        let oversizedServer = try FakeUnixRuntimeServer(
            socketPath: oversized.socketPath
        ) { _ in
            .lengthOnly(
                UInt32(
                    PlayCoverRuntimeClient
                        .maximumResponseBodyBytes + 1
                )
            )
        }
        XCTAssertThrowsError(
            try makeClient(socketPath: oversized.socketPath).hello()
        ) {
            guard case .responseFrameTooLarge =
                    $0 as? PlayCoverRuntimeClientError else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        try oversizedServer.wait()

        let deadline = try RuntimeClientFixture()
        defer { deadline.remove() }
        let deadlineServer = try FakeUnixRuntimeServer(
            socketPath: deadline.socketPath
        ) { _ in
            .drip(
                Data(repeating: 0x20, count: 64),
                delayMicroseconds: 10_000
            )
        }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(
            try makeClient(
                socketPath: deadline.socketPath,
                timeout: 0.05
            ).hello()
        ) {
            guard case .timeout =
                    $0 as? PlayCoverRuntimeClientError else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - started,
            0.4
        )
        _ = try? deadlineServer.wait()
    }

    private func makeClient(
        socketPath: String,
        timeout: TimeInterval = 1,
        refreshAlertStatus: Bool = false
    ) throws -> PlayCoverRuntimeClient {
        let executable = try XCTUnwrap(
            PlayCoverRuntimeClient.executablePath(for: getpid())
        )
        return PlayCoverRuntimeClient(
            socketPath: socketPath,
            sessionID: sessionID,
            expectedPID: getpid(),
            expectedBundleIdentifier: bundleIdentifier,
            expectedExecutablePath: executable,
            timeoutSeconds: timeout,
            refreshAlertStatus: refreshAlertStatus
        )
    }

    private func payload(
        for command: PlayCoverRuntimeCommand
    ) -> [String: Any] {
        switch command {
        case .hello:
            return helloPayload()
        case .ping:
            let identity = basePayload()
            return [
                "pid": identity["pid"]!,
                "bundleIdentifier":
                    identity["bundleIdentifier"]!,
                "executablePath":
                    identity["executablePath"]!,
                "pong": true,
            ]
        case .diagnostics:
            var payload = basePayload()
            payload["diagnostics"] = [
                "runtime": ["stage": "ready"],
            ]
            return payload
        case .screenshot:
            let dom = domPayload(generation: 1)
            return [
                "screenshot": screenshotPayload(
                    generation: 1,
                    captureGeneration: 1
                ),
                "dom": dom,
            ]
        case .dom:
            return ["dom": domPayload(generation: 1)]
        case .uiTree:
            return [
                "uiTree": [
                    "target": "Continue",
                    "maxDepth": 6,
                    "nodeCount": 1,
                    "truncated": false,
                    "roots": [[
                        "childCount": 0,
                        "class": "UILabel",
                        "viewControllerClass": NSNull(),
                        "frame": [
                            "x": 1,
                            "y": 2,
                            "width": 100,
                            "height": 30,
                        ],
                        "bounds": [
                            "x": 0,
                            "y": 0,
                            "width": 100,
                            "height": 30,
                        ],
                        "hidden": false,
                        "alpha": 1,
                        "userInteractionEnabled": false,
                        "clipsToBounds": false,
                        "contentMode": "scaleToFill",
                        "accessibilityIdentifier": NSNull(),
                        "accessibilityLabel": "Continue",
                        "layout": [
                            "ambiguous": false,
                            "translatesAutoresizingMaskIntoConstraints": false,
                            "constraintCount": 1,
                        ],
                        "properties": ["text": "Continue"],
                        "subviews": [],
                    ]],
                ],
            ]
        case .waitFor:
            return [
                "waitFor": [
                    "element": elementPayload(generation: 1),
                    "waited": 0.1,
                    "snapshotGeneration": 1,
                ],
            ]
        case .tap:
            return ["tap": actionPayload(generation: 2)]
        case .longPress:
            return ["longPress": actionPayload(generation: 2)]
        case .swipe:
            var swipe = actionPayload(generation: 2)
            swipe["scrolls"] = 1
            swipe["direction"] = "forth"
            return ["swipe": swipe]
        case .input:
            return ["input": actionPayload(generation: 2)]
        case .dismissAlert:
            return [
                "dismissAlert": [
                    "dismissed": true,
                    "text": "Notice",
                    "button": "OK",
                    "reason": "button",
                ],
            ]
        case .dismissAlertByLabel:
            return [
                "dismissAlertByLabel": [
                    "dismissed": true,
                    "text": "Notice",
                    "button": "OK",
                    "reason": "label",
                ],
            ]
        case .debug:
            return [
                "debug": [
                    "display": "test",
                    "events": [],
                    "agent": "test-agent",
                ],
            ]
        }
    }

    private func helloPayload() -> [String: Any] {
        [
            "pid": Int(getpid()),
            "bundleIdentifier": bundleIdentifier,
            "executablePath":
                PlayCoverRuntimeClient.executablePath(for: getpid())
                ?? ProcessInfo.processInfo.arguments[0],
            "installRevision": String(repeating: "a", count: 64),
            "capabilities":
                PlayCoverRuntimeCommand.allCasesForTesting
                    .map(\.rawValue),
            "controlStage": "ready",
            "controlFailure": NSNull(),
            "uiState": [
                "state": "initializing",
                "stage": "waiting-for-window",
                "failure": NSNull(),
            ],
            "stdio": [
                "status": "disabled",
                "path": NSNull(),
                "device": NSNull(),
                "inode": NSNull(),
                "failureStage": NSNull(),
                "errorNumber": NSNull(),
            ],
        ]
    }

    private func basePayload() -> [String: Any] {
        [
            "pid": Int(getpid()),
            "bundleIdentifier": bundleIdentifier,
            "executablePath":
                PlayCoverRuntimeClient.executablePath(for: getpid())
                ?? ProcessInfo.processInfo.arguments[0],
            "capabilities":
                PlayCoverRuntimeCommand.allCasesForTesting
                    .map(\.rawValue),
            "geometry": [
                "logical": [
                    "width": Int(IOSUsePlayDeviceLogicalWidth),
                    "height": Int(IOSUsePlayDeviceLogicalHeight),
                ],
                "native": [
                    "width": Int(IOSUsePlayDeviceNativeWidth),
                    "height": Int(IOSUsePlayDeviceNativeHeight),
                ],
                "scale": Int(IOSUsePlayDeviceScale),
                "window": [
                    "width": Int(IOSUsePlayDeviceLogicalWidth),
                    "height": Int(IOSUsePlayDeviceLogicalHeight),
                ],
                "safeArea": [
                    "top": 17,
                    "left": 3,
                    "bottom": 29,
                    "right": 4,
                ],
            ],
            "stage": "ready",
            "uiState": [
                "state": "ready",
                "stage": "ready",
                "failure": NSNull(),
            ],
            "stdio": [
                "status": "disabled",
                "path": NSNull(),
                "device": NSNull(),
                "inode": NSNull(),
                "failureStage": NSNull(),
                "errorNumber": NSNull(),
            ],
        ]
    }

    private func screenshotPayload(
        generation: Int,
        captureGeneration: Int
    ) -> [String: Any] {
        [
            "jpegBase64": Data([
                0xFF, 0xD8, 0xFF, 0xD9,
            ]).base64EncodedString(),
            "pixelWidth": Int(IOSUsePlayDeviceNativeWidth),
            "pixelHeight": Int(IOSUsePlayDeviceNativeHeight),
            "logicalWidth": Int(IOSUsePlayDeviceLogicalWidth),
            "logicalHeight": Int(IOSUsePlayDeviceLogicalHeight),
            "scale": Int(IOSUsePlayDeviceScale),
            "source": "window-compositor",
            "complete": true,
            "syntheticChrome": false,
            "fullFrame": fullFramePayload(),
            "snapshotGeneration": generation,
            "captureGeneration": captureGeneration,
            "compositor": [
                "syntheticChrome": false,
                "fullFrame": fullFramePayload(),
            ],
        ]
    }

    private func domPayload(generation: Int) -> [String: Any] {
        [
            "app": "Demo",
            "windowSize": [
                "x": Int(IOSUsePlayDeviceLogicalWidth),
                "y": Int(IOSUsePlayDeviceLogicalHeight),
            ],
            "raw": "Application, Demo",
            "snapshotGeneration": generation,
            "elements": [elementPayload(generation: generation)],
        ]
    }

    private func elementPayload(generation: Int) -> [String: Any] {
        [
            "nodeID": "n-\(generation)",
            "type": "Button",
            "elementType": 1,
            "elemType": 1,
            "label": "Continue",
            "value": "",
            "identifier": "continue",
            "hint": "Advance",
            "class": "UIButton",
            "traits": ["Button"],
            "state": [
                "enabled": true,
                "visible": true,
                "selected": false,
                "focused": false,
                "opaque": true,
            ],
            "frame": [
                "x": 20,
                "y": 100,
                "width": 120,
                "height": 44,
            ],
            "rect": ["x": 20, "y": 100, "w": 120, "h": 44],
            "hierarchy": [
                "parentID": "root",
                "depth": 1,
                "index": 0,
                "path": ["root", "n-\(generation)"],
            ],
            "ancestors": ["Application"],
            "zOrder": 2,
            "snapshotGeneration": generation,
        ]
    }

    private func actionPayload(generation: Int) -> [String: Any] {
        [
            "element": elementPayload(generation: generation),
            "hitView": [
                "class": "UIButton",
                "frame": [
                    "x": 20,
                    "y": 100,
                    "width": 120,
                    "height": 44,
                ],
                "accessibilityIdentifier": "continue",
                "label": "Continue",
            ],
            "finalState": [
                "point": ["x": 80, "y": 122],
                "touchID": 77,
                "phase": "ended",
                "firstResponderClass": "UIButton",
            ],
        ]
    }

    private func fullFramePayload() -> [String: Any] {
        [
            "logicalRect": [
                "x": 0,
                "y": 0,
                "width": Int(IOSUsePlayDeviceLogicalWidth),
                "height": Int(IOSUsePlayDeviceLogicalHeight),
            ],
            "pixelWidth": Int(IOSUsePlayDeviceNativeWidth),
            "pixelHeight": Int(IOSUsePlayDeviceNativeHeight),
            "scale": Int(IOSUsePlayDeviceScale),
            "uncropped": true,
            "safeAreaCropped": false,
            "nativeCanvas": true,
        ]
    }

    private func successResponse(
        requestID: String,
        payload: [String: Any]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "requestId": requestID,
            "sessionID": sessionID,
            "ok": true,
            "payload": payload,
        ])
    }
}

private extension PlayCoverRuntimeCommand {
    static let allCasesForTesting: [PlayCoverRuntimeCommand] = [
        .hello,
        .ping,
        .diagnostics,
        .screenshot,
        .dom,
        .uiTree,
        .waitFor,
        .tap,
        .longPress,
        .swipe,
        .input,
        .dismissAlert,
        .dismissAlertByLabel,
        .debug,
    ]
}

private struct RuntimeClientFixture {
    let root: String
    let socketPath: String

    init() throws {
        root = "/tmp/iosuse-pc-\(UUID().uuidString.prefix(8))"
        socketPath = "\(root)/r.sock"
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

private final class FakeUnixRuntimeServer {
    enum Reply {
        case body(Data, chunkSize: Int = .max)
        case lengthOnly(UInt32)
        case drip(Data, delayMicroseconds: useconds_t)
    }

    private let socketPath: String
    private let listener: Int32
    private let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var runError: Error?
    private var recordedPeerUID: uid_t?

    var peerUID: uid_t? {
        lock.withLock { recordedPeerUID }
    }

    init(
        socketPath: String,
        handler: @escaping ([String: Any]) throws -> Reply
    ) throws {
        self.socketPath = socketPath
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw FakeUnixRuntimeServerError.systemCall(
                "socket",
                errno
            )
        }

        do {
            var enabled: Int32 = 1
            guard Darwin.setsockopt(
                listener,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &enabled,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw FakeUnixRuntimeServerError.systemCall(
                    "setsockopt",
                    errno
                )
            }
            var address = try Self.address(for: socketPath)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) {
                    Darwin.bind(
                        listener,
                        $0,
                        socklen_t(
                            MemoryLayout<sockaddr_un>.size
                        )
                    )
                }
            }
            guard result == 0 else {
                throw FakeUnixRuntimeServerError.systemCall(
                    "bind",
                    errno
                )
            }
            guard Darwin.listen(listener, 1) == 0 else {
                throw FakeUnixRuntimeServerError.systemCall(
                    "listen",
                    errno
                )
            }
        } catch {
            Darwin.close(listener)
            Darwin.unlink(socketPath)
            throw error
        }

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                Darwin.close(self.listener)
                Darwin.unlink(self.socketPath)
                self.completion.signal()
            }
            do {
                try self.run(handler: handler)
            } catch {
                self.lock.withLock {
                    self.runError = error
                }
            }
        }
    }

    deinit {
        Darwin.unlink(socketPath)
    }

    func wait(timeout: TimeInterval = 2) throws {
        guard completion.wait(
            timeout: .now() + timeout
        ) == .success else {
            throw FakeUnixRuntimeServerError.timedOut
        }
        if let error = lock.withLock({ runError }) {
            throw error
        }
    }

    private func run(
        handler: ([String: Any]) throws -> Reply
    ) throws {
        let client: Int32
        while true {
            let accepted = Darwin.accept(listener, nil, nil)
            if accepted >= 0 {
                client = accepted
                break
            }
            if errno != EINTR {
                throw FakeUnixRuntimeServerError.systemCall(
                    "accept",
                    errno
                )
            }
        }
        defer { Darwin.close(client) }

        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(
            client,
            &peerUID,
            &peerGID
        ) == 0 else {
            throw FakeUnixRuntimeServerError.systemCall(
                "getpeereid",
                errno
            )
        }
        lock.withLock {
            recordedPeerUID = peerUID
        }

        let body = try Self.readFrame(from: client)
        let object = try JSONSerialization.jsonObject(with: body)
        guard let request = object as? [String: Any] else {
            throw FakeUnixRuntimeServerError.invalidRequest
        }

        switch try handler(request) {
        case .body(let body, let chunkSize):
            var length = UInt32(body.count).bigEndian
            let header = withUnsafeBytes(of: &length) {
                Data($0)
            }
            try Self.write(
                header + body,
                to: client,
                maximumChunkSize: chunkSize
            )
        case .drip(let body, let delay):
            var length = UInt32(body.count).bigEndian
            let header = withUnsafeBytes(of: &length) {
                Data($0)
            }
            try Self.write(
                header + body,
                to: client,
                maximumChunkSize: 1,
                delayMicroseconds: delay
            )
        case .lengthOnly(var length):
            length = length.bigEndian
            try withUnsafeBytes(of: &length) {
                try Self.write(
                    Data($0),
                    to: client,
                    maximumChunkSize: .max
                )
            }
        }
    }

    private static func address(
        for path: String
    ) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(
            ofValue: address.sun_path
        )
        guard bytes.count + 1 <= capacity else {
            throw FakeUnixRuntimeServerError.pathTooLong
        }
        address.sun_len = UInt8(
            MemoryLayout<sockaddr_un>.size
        )
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.initializeMemory(
                as: UInt8.self,
                repeating: 0
            )
            $0.copyBytes(from: bytes)
        }
        return address
    }

    private static func readFrame(
        from descriptor: Int32
    ) throws -> Data {
        let header = try read(
            byteCount: 4,
            from: descriptor
        )
        let length = header.reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard length > 0,
              length <= UInt32(64 * 1_024) else {
            throw FakeUnixRuntimeServerError.invalidRequest
        }
        return try read(
            byteCount: Int(length),
            from: descriptor
        )
    }

    private static func read(
        byteCount: Int,
        from descriptor: Int32
    ) throws -> Data {
        var data = Data(count: byteCount)
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < byteCount {
                let count = Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    min(3, byteCount - offset)
                )
                if count > 0 {
                    offset += count
                } else if count == 0 {
                    throw FakeUnixRuntimeServerError.invalidRequest
                } else if errno != EINTR {
                    throw FakeUnixRuntimeServerError.systemCall(
                        "read",
                        errno
                    )
                }
            }
        }
        return data
    }

    private static func write(
        _ data: Data,
        to descriptor: Int32,
        maximumChunkSize: Int,
        delayMicroseconds: useconds_t = 0
    ) throws {
        var enabled: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        )
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let requested = min(
                    maximumChunkSize,
                    buffer.count - offset
                )
                let count = Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    requested
                )
                if count > 0 {
                    offset += count
                    if delayMicroseconds > 0 {
                        usleep(delayMicroseconds)
                    }
                } else if count == 0 {
                    throw FakeUnixRuntimeServerError.systemCall(
                        "write",
                        EIO
                    )
                } else if errno != EINTR {
                    throw FakeUnixRuntimeServerError.systemCall(
                        "write",
                        errno
                    )
                }
            }
        }
    }
}

private enum FakeUnixRuntimeServerError: Error {
    case systemCall(String, Int32)
    case invalidRequest
    case pathTooLong
    case timedOut
}
