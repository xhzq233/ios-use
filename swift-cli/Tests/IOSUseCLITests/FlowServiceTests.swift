import XCTest
import IOSUseProtocol
@testable import IOSUseCLI

final class FlowServiceTests: XCTestCase {
    func testMissingFlowFileFailsBeforeDriverWork() {
        let result = IOSUseCLI(environment: ["IOS_USE_HOME": "/tmp/ios-use-swift-flow"]).run(arguments: ["flow", "/tmp/no-such-flow.yaml"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Flow file not found"))
    }

    func testOpenStepUsesHostSideSimulatorOpen() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("open.yaml", """
        name: open-url
        steps:
          - action: open
            url: retouch://debug
        """)
        let driver = FakeFlowDriver()
        var shellCalls: [(String, [String])] = []
        Shell.runResultOverrideForTesting = { executable, arguments, _ in
            shellCalls.append((executable, arguments))
            return Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }
        addTeardownBlock {
            Shell.runResultOverrideForTesting = nil
        }

        let result = try FlowService.runForTesting(
            file: flow.path,
            paths: fixture.paths,
            driver: driver,
            udid: "SIM-1",
            deviceType: "simulator"
        )

        XCTAssertTrue(result.stdout.contains("Step 1/1: open"))
        XCTAssertEqual(shellCalls.count, 1)
        XCTAssertEqual(shellCalls.first?.0, "xcrun")
        XCTAssertEqual(shellCalls.first?.1, ["simctl", "openurl", "SIM-1", "retouch://debug"])
    }

    func testOpenStepRealDeviceUsesNativeLauncher() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("open.yaml", """
        name: open-url
        steps:
          - action: open
            url: https://example.com
        """)
        let driver = FakeFlowDriver()
        OpenURLService.SchemeRegistry.lookupOverrideForTesting = { scheme, _ in
            if scheme == "https" {
                return OpenURLService.SchemeRegistry.LookupResult(registeredHandlers: ["com.apple.mobilesafari"], lookupFailed: false)
            }
            return nil
        }
        var nativeLaunches: [(String, String)] = []
        OpenURLService.realDeviceURLLauncherForTesting = { url, udid in
            nativeLaunches.append((url, udid))
        }
        Shell.runOverrideForTesting = { executable, arguments, _, _ in
            if executable == "xcrun", arguments.contains("devicectl") {
                XCTFail("real-device flow open must not call devicectl")
            }
            return ""
        }
        addTeardownBlock {
            Shell.runOverrideForTesting = nil
            OpenURLService.SchemeRegistry.lookupOverrideForTesting = nil
            OpenURLService.realDeviceURLLauncherForTesting = nil
        }

        let result = try FlowService.runForTesting(
            file: flow.path,
            paths: fixture.paths,
            driver: driver,
            udid: "REAL-1",
            deviceType: "real"
        )

        XCTAssertTrue(result.stdout.contains("Step 1/1: open"))
        XCTAssertEqual(nativeLaunches.map(\.0), ["https://example.com"])
        XCTAssertEqual(nativeLaunches.map(\.1), ["REAL-1"])
    }

    func testRunFlowBindsDeclaredOutputsAndExternalVarsOverrideDefaults() throws {
        let fixture = try FlowFixture()
        let child = try fixture.write("child.yaml", """
        name: child
        vars:
          label: ChildDefault
        outputs: found
        steps:
          - action: find
            label: ${vars.label}
            outputs: found
        """)
        let parent = try fixture.write("parent.yaml", """
        name: parent
        vars:
          label: ParentDefault
        outputs: found
        steps:
          - action: runFlow
            file: \(child.lastPathComponent)
            vars:
              label: ${vars.label}
            outputs: found
        """)
        let driver = FakeFlowDriver()
        driver.findPayload = ForyFindPayload(matches: [ForyFindMatch(elemType: 9, label: "InjectedLabel", value: "value")])

        let result = try FlowService.runForTesting(file: parent.path, externalVars: ["label": "InjectedLabel"], paths: fixture.paths, driver: driver)

        XCTAssertTrue(result.stdout.contains("Running flow: parent (1 steps)"))
        XCTAssertTrue(result.stdout.contains("Step 1/1: runFlow"))
        XCTAssertTrue(result.stdout.contains("Running flow: child (1 steps)"))
        XCTAssertTrue(result.stdout.contains("Step 1/1: InjectedLabel"))
        XCTAssertTrue(result.stdout.contains("Flow completed: 1 steps executed"))
        XCTAssertEqual(driver.findLabels, ["InjectedLabel"])
        let found = try XCTUnwrap(result.outputs["found"] as? [String: Any])
        let first = try XCTUnwrap(found["firstMatch"] as? [String: Any])
        XCTAssertEqual(first["label"] as? String, "InjectedLabel")
        XCTAssertEqual(first["type"] as? String, "Button")
        XCTAssertTrue(result.stdout.contains("Find \"InjectedLabel\""))
    }

    func testReturnIfSupportsNullBooleanMatchAndNoOp() throws {
        let fixture = try FlowFixture()
        let nullFlow = try fixture.write("null.yaml", """
        name: null-return
        steps:
          - action: dom
            candidates:
              - Missing
            outputs: page
          - action: returnIf
            value: ${page.firstMatch}
            is: null
          - action: find
            label: ShouldNotRun
        """)
        let falseFlow = try fixture.write("false.yaml", """
        name: false-return
        vars:
          shouldStop: false
        steps:
          - action: returnIf
            value: ${vars.shouldStop}
            is: false
          - action: find
            label: ShouldNotRun
        """)
        let noOpFlow = try fixture.write("noop.yaml", """
        name: noop-return
        vars:
          shouldStop: false
        steps:
          - action: returnIf
            value: ${vars.shouldStop}
            is: true
          - action: find
            label: ShouldRun
        """)
        let driver = FakeFlowDriver()
        driver.domPayload = ForyDomPayload(app: "com.example", elements: [])

        _ = try FlowService.runForTesting(file: nullFlow.path, paths: fixture.paths, driver: driver)
        _ = try FlowService.runForTesting(file: falseFlow.path, paths: fixture.paths, driver: driver)
        _ = try FlowService.runForTesting(file: noOpFlow.path, paths: fixture.paths, driver: driver)

        XCTAssertEqual(driver.findLabels, ["ShouldRun"])
    }

    func testDomCandidatesRespectCandidatePriorityAndBindOutput() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("dom.yaml", """
        name: dom-flow
        outputs: page
        steps:
          - action: dom
            candidates:
              - Close
              - Cancel
            outputs: page
        """)
        let driver = FakeFlowDriver()
        driver.domPayload = ForyDomPayload(
            app: "com.example",
            windowSize: ForyPoint(x: 390, y: 844),
            elements: [
                ForyDomElement(traits: ["Button"], label: "Cancel"),
                ForyDomElement(traits: ["Button"], label: "Close"),
            ]
        )

        let result = try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: driver)

        let page = try XCTUnwrap(result.outputs["page"] as? [String: Any])
        let first = try XCTUnwrap(page["firstMatch"] as? [String: Any])
        XCTAssertEqual(first["label"] as? String, "Close")
        XCTAssertEqual(first["type"] as? String, "Button")
        XCTAssertTrue(result.stdout.contains("App: com.example"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.artifacts))
    }

    func testDomOutputUsesPresentationScrollDirection() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("dom-direction.yaml", """
        name: dom-direction-flow
        outputs: page
        steps:
          - action: dom
            outputs: page
        """)
        let driver = FakeFlowDriver()
        driver.domPayload = ForyDomPayload(
            app: "com.example",
            windowSize: ForyPoint(x: 390, y: 844),
            elements: [
                ForyDomElement(traits: ["Scroll"], childCount: 2),
                ForyDomElement(traits: ["Cell"], label: "First", rect: ForyRect(x: 0, y: 100, w: 390, h: 44)),
                ForyDomElement(traits: ["Cell"], label: "Second", rect: ForyRect(x: 0, y: 200, w: 390, h: 44)),
            ]
        )

        let result = try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: driver)

        let page = try XCTUnwrap(result.outputs["page"] as? [String: Any])
        let dom = try XCTUnwrap(page["dom"] as? [String: Any])
        let elements = try XCTUnwrap(dom["elements"] as? [[String: Any]])
        let traits = try XCTUnwrap(elements.first?["traits"] as? [String])
        XCTAssertEqual(traits, ["Scroll", "vertical"])
    }

    func testMissingTemplateValueFailsFast() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("missing-template.yaml", """
        name: missing-template
        steps:
          - action: find
            label: ${vars.missing}
        """)

        XCTAssertThrowsError(try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("Missing template value"))
        }
    }

    func testSwipePassesToFromTargetsToDriver() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("swipe.yaml", """
        name: swipe-flow
        steps:
          - action: swipe
            to: Keyboard
            from: 200,650
            dir: forth
            distance: 300
            traits: Cell
            cindex: -1
        """)
        let driver = FakeFlowDriver()

        _ = try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: driver)

        let swipe = try XCTUnwrap(driver.swipes.first)
        XCTAssertEqual(swipe.to.label, "Keyboard")
        XCTAssertEqual(swipe.from.point?.x, 200)
        XCTAssertEqual(swipe.from.point?.y, 650)
        XCTAssertEqual(swipe.dir, "forth")
        XCTAssertEqual(swipe.distance, 300)
        XCTAssertEqual(swipe.traits, "Cell")
        XCTAssertEqual(swipe.cindex, -1)
    }

    func testSwipeCanBindStructuredOutput() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("swipe-output.yaml", """
        name: swipe-output
        outputs: result
        steps:
          - action: swipe
            to: Developer
            from: Bluetooth
            dir: forth
            outputs: result
        """)
        let driver = FakeFlowDriver()

        let result = try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: driver)
        let output = try XCTUnwrap(result.outputs["result"] as? [String: Any])
        let element = try XCTUnwrap(output["element"] as? [String: Any])

        XCTAssertEqual(output["scrolls"] as? Int32, 1)
        XCTAssertEqual(output["scrollDirection"] as? String, "down")
        XCTAssertEqual(element["label"] as? String, "Developer")
        XCTAssertEqual(element["type"] as? String, "Cell")
    }

    func testFlowTargetsUseCLIStringCoordinatesAndRejectArrayPoints() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("targets.yaml", """
        name: targets
        steps:
          - action: tap
            label: A,B
          - action: tap
            label: 100,200
          - action: swipe
            to: 10,20
            from: A,B
        """)
        let bad = try fixture.write("bad-targets.yaml", """
        name: bad-targets
        steps:
          - action: tap
            label: [100, 200]
        """)
        let driver = FakeFlowDriver()

        _ = try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: driver)

        XCTAssertEqual(driver.taps[0].target.label, "A,B")
        XCTAssertNil(driver.taps[0].target.point)
        XCTAssertEqual(driver.taps[1].target.point?.x, 100)
        XCTAssertEqual(driver.taps[1].target.point?.y, 200)
        XCTAssertEqual(driver.swipes[0].to.point?.x, 10)
        XCTAssertEqual(driver.swipes[0].from.label, "A,B")
        XCTAssertThrowsError(try FlowService.runForTesting(file: bad.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("tap.label must be a string"))
        }
    }

    func testFlowLongpressPassesDurationAndTraits() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("longpress.yaml", """
        name: longpress-flow
        steps:
          - action: longpress
            label: General
            duration: 750
            traits: Cell
            cindex: 2
        """)
        let driver = FakeFlowDriver()

        _ = try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: driver)

        let press = try XCTUnwrap(driver.longPresses.first)
        XCTAssertEqual(press.target.label, "General")
        XCTAssertEqual(press.durationMs, 750)
        XCTAssertEqual(press.traits, "Cell")
        XCTAssertEqual(press.cindex, 2)
    }

    func testFlowPassesCindexForFindTapInputAndWaitFor() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("cindex.yaml", """
        name: cindex-flow
        steps:
          - action: find
            label: General
            traits: Cell
            cindex: -1
          - action: waitFor
            label: Ready
            traits: Text
            cindex: 0
          - action: tap
            label: Settings
            traits: Cell
            cindex: 1
          - action: input
            tap: Name
            content: Alpha
            traits: Input
            cindex: 0
        """)
        let driver = FakeFlowDriver()

        _ = try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: driver)

        XCTAssertEqual(driver.finds.first?.label, "General")
        XCTAssertEqual(driver.finds.first?.traits, "Cell")
        XCTAssertEqual(driver.finds.first?.cindex, -1)
        XCTAssertEqual(driver.waits.first?.label, "Ready")
        XCTAssertEqual(driver.waits.first?.cindex, 0)
        XCTAssertEqual(driver.taps.first?.target.label, "Settings")
        XCTAssertEqual(driver.taps.first?.cindex, 1)
        XCTAssertEqual(driver.inputs.first?.tap?.label, "Name")
        XCTAssertEqual(driver.inputs.first?.cindex, 0)
    }

    func testFlowPostDomForHighFrequencyMutations() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("post-dom.yaml", """
        name: post-dom-flow
        steps:
          - action: tap
            label: Continue
            dom: 100
        """)
        let driver = FakeFlowDriver()
        driver.domPayload = ForyDomPayload(
            app: "com.example",
            elements: [ForyDomElement(traits: ["Text"], label: "Next")]
        )

        let result = try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: driver)

        XCTAssertEqual(driver.commands, ["tap", "dom"])
        XCTAssertTrue(result.stdout.contains("DOM after 100ms"))
        XCTAssertTrue(result.stdout.contains("App: com.example"))
        XCTAssertTrue(result.stdout.contains("- Next [Text]"))
    }

    func testFlowRejectsPostDomBelowMinimum() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("bad-post-dom.yaml", """
        name: bad-post-dom
        steps:
          - action: tap
            label: Continue
            dom: 0
        """)

        XCTAssertThrowsError(try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertEqual(error as? CLIParseError, .invalidValue("tap.dom must be at least 100ms"))
        }
    }

    func testFlowRejectsCindexOnPointTarget() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("bad-cindex.yaml", """
        name: bad-cindex
        steps:
          - action: tap
            label: 100,200
            cindex: 0
        """)

        XCTAssertThrowsError(try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("point target does not support traits or cindex"))
        }
    }

    func testFlowRejectsInputTraitsWithoutTap() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("bad-input-traits.yaml", """
        name: bad-input-traits
        steps:
          - action: input
            content: Alpha
            traits: Input
        """)

        XCTAssertThrowsError(try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("--traits or --cindex require --tap with a label target"))
        }
    }

    func testFlowRejectsInputLegacyLabelField() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("bad-input-label.yaml", """
        name: bad-input-label
        steps:
          - action: input
            label: Name
            content: Alpha
        """)

        XCTAssertThrowsError(try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("input has unknown field \"label\""))
        }
    }

    func testFlowNSLogStepUsesSharedServerAndClearsBuffer() throws {
        let fixture = try FlowFixture()
        let child = try fixture.write("child.yaml", """
        name: child
        steps:
          - action: nslog
            pattern: ready
            flags: i
            name: child-nslog
            clearAfterRead: true
        """)
        let parent = try fixture.write("parent.yaml", """
        name: parent
        needNSLog: true
        steps:
          - action: runFlow
            file: \(child.lastPathComponent)
        """)
        let server = try NSLoggerServer(paths: fixture.paths)
        server.ingestForTesting(makeNSLogMessage(message: "Driver READY"))

        let result = try FlowService.runForTesting(file: parent.path, paths: fixture.paths, driver: FakeFlowDriver(), nsloggerServer: server)

        XCTAssertTrue(result.stdout.contains("Running flow: parent"))
        XCTAssertTrue(result.stdout.contains("Running flow: child"))
        XCTAssertTrue(result.stdout.contains("1 matched /ready/"))
        XCTAssertTrue(result.stdout.contains("buffer cleared"))
        XCTAssertEqual(server.logCount, 0)
        let saved = "\(fixture.paths.artifacts)/child-nslog.log"
        XCTAssertTrue(try String(contentsOfFile: saved).contains("Driver READY"))
    }

    func testFlowNSLogNameTemplateMustResolveToString() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("bad-nslog-name.yaml", """
        name: bad-nslog-name
        needNSLog: true
        steps:
          - action: nslog
            pattern: ready
            name: "${vars.name}"
        """)
        let server = try NSLoggerServer(paths: fixture.paths)
        server.ingestForTesting(makeNSLogMessage(message: "Driver READY"))

        XCTAssertThrowsError(try FlowService.runForTesting(file: flow.path, externalVars: ["name": 42], paths: fixture.paths, driver: FakeFlowDriver(), nsloggerServer: server)) { error in
            XCTAssertTrue(String(describing: error).contains("nslog.name must be a string"))
        }
    }

    func testRunFlowInheritsParentAppForLifecycleSteps() throws {
        let fixture = try FlowFixture()
        let child = try fixture.write("child.yaml", """
        name: child
        steps:
          - action: terminateApp
          - action: activateApp
        """)
        let parent = try fixture.write("parent.yaml", """
        name: parent
        app: com.example.Target
        steps:
          - action: runFlow
            file: \(child.lastPathComponent)
        """)
        let driver = FakeFlowDriver()

        _ = try FlowService.runForTesting(file: parent.path, paths: fixture.paths, driver: driver)

        XCTAssertEqual(driver.terminatedApps, ["com.example.Target"])
        XCTAssertEqual(driver.activatedApps, ["com.example.Target"])
    }

    func testFlowTerminateAppIgnoresAlreadyNotRunningError() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("terminate-not-running.yaml", """
        name: terminate-not-running
        app: com.example.Target
        steps:
          - action: terminateApp
        """)
        let driver = FakeFlowDriver()
        driver.terminateError = CLIParseError.invalidValue("Application is not running")

        _ = try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: driver)

        XCTAssertEqual(driver.terminatedApps, ["com.example.Target"])
    }

    func testNeedNSLogRejectsPortAndSSLConfiguration() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("nslog-invalid.yaml", """
        name: invalid-nslog
        needNSLog:
          port: 0
          ssl: false
        steps:
          - action: sleep
        """)

        XCTAssertThrowsError(try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("does not support port or ssl configuration"))
        }
    }

    func testNeedNSLogRejectsInvalidMaxBufferSize() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("nslog-invalid-buffer.yaml", """
        name: invalid-nslog-buffer
        needNSLog:
          maxBufferSize: 0
        steps:
          - action: sleep
        """)

        XCTAssertThrowsError(try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("needNSLog.maxBufferSize must be greater than 0"))
        }
    }

    func testArtifactNamesStayInsideArtifactsDirectory() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("artifact-name.yaml", """
        name: artifact-name
        steps:
          - action: screenshot
            name: ../outside
        """)

        _ = try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: FakeFlowDriver())

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(fixture.paths.artifacts)/outside.jpg"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(fixture.paths.root)/outside.jpg"))
    }

    func testSleepRejectsNonFiniteNumbersInsteadOfCrashing() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("non-finite-sleep.yaml", """
        name: non-finite-sleep
        steps:
          - action: sleep
            ms: .inf
        """)

        XCTAssertThrowsError(try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("sleep.ms must be an integer"))
        }
    }

    func testTapSupportsPartialAbsoluteAndRatioOffsets() throws {
        let fixture = try FlowFixture()
        let absolute = try fixture.write("partial-absolute.yaml", """
        name: partial-absolute
        steps:
          - action: tap
            label: General
            offset: "12,"
        """)
        let ratio = try fixture.write("partial-ratio.yaml", """
        name: partial-ratio
        steps:
          - action: tap
            label: General
            offsetRatio: "0.2,"
        """)
        let absoluteDriver = FakeFlowDriver()
        let ratioDriver = FakeFlowDriver()

        _ = try FlowService.runForTesting(file: absolute.path, paths: fixture.paths, driver: absoluteDriver)
        let absoluteTap = try XCTUnwrap(absoluteDriver.taps.first)
        XCTAssertEqual(absoluteTap.offset?.x, 12)
        XCTAssertEqual(absoluteTap.offset?.y, 0)
        XCTAssertEqual(absoluteTap.ratio.x, 0.5)
        XCTAssertEqual(absoluteTap.ratio.y, 0.5)

        _ = try FlowService.runForTesting(file: ratio.path, paths: fixture.paths, driver: ratioDriver)
        let ratioTap = try XCTUnwrap(ratioDriver.taps.first)
        XCTAssertNil(ratioTap.offset)
        XCTAssertEqual(ratioTap.ratio.x, 0.2)
        XCTAssertEqual(ratioTap.ratio.y, 0.5)
    }

    func testInvalidFlowNumericFieldsFailInsteadOfDefaulting() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("invalid-numbers.yaml", """
        name: invalid-numbers
        steps:
          - action: waitFor
            label: General
            timeout: soon
        """)

        XCTAssertThrowsError(try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("waitFor.timeout must be a finite number"))
        }
    }

    func testFlowCompileRejectsUnknownKeysBeforeExecution() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("unknown-key.yaml", """
        name: unknown-key
        steps:
          - action: find
            label: General
          - action: tap
            label: General
            tpyo: true
        """)
        let driver = FakeFlowDriver()

        XCTAssertThrowsError(try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: driver)) { error in
            XCTAssertTrue(String(describing: error).contains("tap has unknown field \"tpyo\""))
        }
        XCTAssertTrue(driver.finds.isEmpty)
        XCTAssertTrue(driver.taps.isEmpty)
    }

    func testFlowCompileRejectsStrictTypesBeforeExecution() throws {
        let fixture = try FlowFixture()
        let stringOffset = try fixture.write("string-offset.yaml", """
        name: string-offset
        steps:
          - action: find
            label: General
          - action: tap
            label: General
            offset: "-50,-50"
        """)
        let rawString = try fixture.write("raw-string.yaml", """
        name: raw-string
        steps:
          - action: dom
            raw: "true"
        """)
        let badOffsetDict = try fixture.write("bad-offset-dict.yaml", """
        name: bad-offset-dict
        steps:
          - action: find
            label: General
          - action: tap
            label: General
            offset:
              x: -50
              y: -50
        """)
        let driver = FakeFlowDriver()

        _ = try FlowService.runForTesting(file: stringOffset.path, paths: fixture.paths, driver: driver)
        XCTAssertEqual(driver.finds.map(\.label), ["General"])
        XCTAssertEqual(driver.taps.first?.offset?.x, -50)
        XCTAssertEqual(driver.taps.first?.offset?.y, -50)
        XCTAssertThrowsError(try FlowService.runForTesting(file: rawString.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("dom.raw must be a boolean"))
        }
        XCTAssertThrowsError(try FlowService.runForTesting(file: badOffsetDict.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("tap.offset must be a string"))
        }
    }

    func testFlowCompileValidatesNestedRunFlowBeforeParentExecution() throws {
        let fixture = try FlowFixture()
        _ = try fixture.write("child.yaml", """
        name: child
        steps:
          - action: waitFor
            label: General
            debgu: true
        """)
        let parent = try fixture.write("parent.yaml", """
        name: parent
        steps:
          - action: find
            label: General
          - action: runFlow
            file: child.yaml
        """)
        let driver = FakeFlowDriver()

        XCTAssertThrowsError(try FlowService.runForTesting(file: parent.path, paths: fixture.paths, driver: driver)) { error in
            XCTAssertTrue(String(describing: error).contains("waitFor has unknown field \"debgu\""))
        }
        XCTAssertTrue(driver.finds.isEmpty)
    }

    func testFlowRejectsInvalidSwipeDirAndFractionalAlertIndex() throws {
        let fixture = try FlowFixture()
        let invalidDir = try fixture.write("invalid-dir.yaml", """
        name: invalid-dir
        steps:
          - action: swipe
            dir: backwards
        """)
        let fractionalIndex = try fixture.write("fractional-index.yaml", """
        name: fractional-index
        steps:
          - action: dismissAlert
            index: 1.9
        """)

        XCTAssertThrowsError(try FlowService.runForTesting(file: invalidDir.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("Invalid swipe dir"))
        }
        XCTAssertThrowsError(try FlowService.runForTesting(file: fractionalIndex.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("dismissAlert.index must be an integer"))
        }
    }

    func testFlowRejectsHugeSleepAndTreatsInvalidPointLikeTargetAsCLILabel() throws {
        let fixture = try FlowFixture()
        let hugeSleep = try fixture.write("huge-sleep.yaml", """
        name: huge-sleep
        steps:
          - action: sleep
            ms: 1e100
        """)
        let overflowingSleep = try fixture.write("overflowing-sleep.yaml", """
        name: overflowing-sleep
        steps:
          - action: sleep
            ms: 4294968
        """)
        let invalidPoint = try fixture.write("invalid-point.yaml", """
        name: invalid-point
        steps:
          - action: tap
            label: inf,0
        """)
        let driver = FakeFlowDriver()

        XCTAssertThrowsError(try FlowService.runForTesting(file: hugeSleep.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("sleep.ms must be an integer"))
        }
        XCTAssertThrowsError(try FlowService.runForTesting(file: overflowingSleep.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("sleep.ms is too large"))
        }
        _ = try FlowService.runForTesting(file: invalidPoint.path, paths: fixture.paths, driver: driver)
        XCTAssertEqual(driver.taps.first?.target.label, "inf,0")
    }

    func testFlowRejectsInvalidDomCandidatesAndNegativeOslogTimeout() throws {
        let fixture = try FlowFixture()
        let nonArrayCandidates = try fixture.write("dom-candidates-object.yaml", """
        name: dom-candidates-object
        steps:
          - action: dom
            candidates: Close
            outputs: page
        """)
        let nonStringCandidate = try fixture.write("dom-candidates-number.yaml", """
        name: dom-candidates-number
        steps:
          - action: dom
            candidates:
              - 1
            outputs: page
        """)
        let negativeOslogTimeout = try fixture.write("oslog-negative-timeout.yaml", """
        name: oslog-negative-timeout
        steps:
          - action: oslog
            pattern: ready
            timeout: -1
        """)
        let zeroOslogTimeout = try fixture.write("oslog-zero-timeout.yaml", """
        name: oslog-zero-timeout
        steps:
          - action: oslog
            pattern: ready
            timeout: 0
        """)
        let oslogProcessAndPid = try fixture.write("oslog-process-pid.yaml", """
        name: oslog-process-pid
        steps:
          - action: oslog
            process: Demo
            pid: 123
        """)
        let oslogBundleId = try fixture.write("oslog-bundle-id.yaml", """
        name: oslog-bundle-id
        steps:
          - action: oslog
            bundleId: com.example
        """)

        XCTAssertThrowsError(try FlowService.runForTesting(file: nonArrayCandidates.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("dom.candidates must be a string array"))
        }
        XCTAssertThrowsError(try FlowService.runForTesting(file: nonStringCandidate.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("dom.candidates must contain only non-empty strings"))
        }
        XCTAssertThrowsError(try FlowService.runForTesting(file: negativeOslogTimeout.path, paths: fixture.paths, driver: FakeFlowDriver(), udid: "SIM-1")) { error in
            XCTAssertTrue(String(describing: error).contains("oslog.timeout must be greater than 0"))
        }
        XCTAssertThrowsError(try FlowService.runForTesting(file: zeroOslogTimeout.path, paths: fixture.paths, driver: FakeFlowDriver(), udid: "SIM-1")) { error in
            XCTAssertTrue(String(describing: error).contains("oslog.timeout must be greater than 0"))
        }
        XCTAssertThrowsError(try FlowService.runForTesting(file: oslogProcessAndPid.path, paths: fixture.paths, driver: FakeFlowDriver(), udid: "SIM-1")) { error in
            XCTAssertTrue(String(describing: error).contains("oslog.process and oslog.pid are mutually exclusive"))
        }
        XCTAssertThrowsError(try FlowService.runForTesting(file: oslogBundleId.path, paths: fixture.paths, driver: FakeFlowDriver(), udid: "SIM-1")) { error in
            XCTAssertTrue(String(describing: error).contains("oslog has unknown field \"bundleId\""))
        }
    }

    func testFlowOslogLowersProcessAndPidFilters() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("oslog-source-filters.yaml", """
        name: oslog-source-filters
        steps:
          - action: oslog
            pattern: ready
            flags: i
            process: Demo
            timeout: 1
          - action: oslog
            pattern: ready
            pid: 123
            timeout: 1
        """)
        var sources: [OSLogOptions.SourceFilter] = []
        OSLogService.simulatorLogCollector = { _, _, source in
            sources.append(source)
            return ["May 16 10:00:00 iPhone Demo(Demo)[123] <Notice>: ready"]
        }
        addTeardownBlock {
            OSLogService.resetSimulatorLogCollectorForTesting()
        }

        let result = try FlowService.runForTesting(
            file: flow.path,
            paths: fixture.paths,
            driver: FakeFlowDriver(),
            udid: "SIM-1",
            deviceType: "simulator"
        )

        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[0], OSLogOptions.SourceFilter(process: "Demo"))
        XCTAssertEqual(sources[1], OSLogOptions.SourceFilter(pid: 123))
        XCTAssertTrue(result.stdout.contains("ready"))
    }

    func testUnsupportedFlowOutputsFail() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("unsupported-outputs.yaml", """
        name: unsupported-outputs
        steps:
          - action: tap
            label: General
            outputs: tapped
        """)

        XCTAssertThrowsError(try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: FakeFlowDriver())) { error in
            XCTAssertTrue(String(describing: error).contains("tap does not support outputs"))
        }
    }

    func testDomWithoutOutputsOrJsonSaveDoesNotMaterializeDerivedDom() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("dom-no-output.yaml", """
        name: dom-no-output
        steps:
          - action: dom
            candidates:
              - Match
        """)
        let driver = FakeFlowDriver()
        driver.domPayload = ForyDomPayload(
            app: "com.example",
            elements: [ForyDomElement(label: "Match")]
        )

        let result = try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: driver)

        XCTAssertTrue(result.outputs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.artifacts))
    }

    func testFlowFailureIncludesStepContext() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("failure-context.yaml", """
        name: failure-context
        steps:
          - action: find
            label: Missing
        """)
        let driver = FakeFlowDriver()
        driver.findError = CLIParseError.invalidValue("not found")

        XCTAssertThrowsError(try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: driver)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Step 1 [action: find] failed"))
            XCTAssertTrue(message.contains("not found"))
        }
    }

    func testFlowStepLogUsesCommentField() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("text-log.yaml", """
        name: text-log
        steps:
          - action: find
            comment: Open Settings
            label: General
        """)

        let result = try FlowService.runForTesting(file: flow.path, paths: fixture.paths, driver: FakeFlowDriver())

        XCTAssertTrue(result.stdout.contains("Step 1/1: Open Settings"))
    }

    func testFlowDriverBackedStepsReuseOneDriverClientAndSendOnlyTargetCommands() throws {
        let fixture = try FlowFixture()
        try writeDriverLock(udid: "SIM-FLOW", deviceType: "simulator", paths: fixture.paths)
        let flow = try fixture.write("driver-backed.yaml", """
        name: driver-backed
        steps:
          - action: tap
            label: General
            offset: "1,2"
          - action: dom
          - action: swipe
            to: 10,20
            from: General
        """)
        let client = FakeFlowDriver()
        var factoryCalls = 0
        IOSUseCLI.driverClientFactoryForTesting = { session in
            factoryCalls += 1
            XCTAssertEqual(session.udid, "SIM-FLOW")
            XCTAssertEqual(session.deviceType, "simulator")
            return client
        }
        addTeardownBlock {
            IOSUseCLI.driverClientFactoryForTesting = nil
        }

        _ = try FlowService.run(file: flow.path, options: FlowOptions(file: flow.path), paths: fixture.paths)

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(client.commands, ["tap", "dom", "swipe"])
    }

    func testProductionFlowDriverBackedStepsReuseOneTCPConnection() throws {
        let fixture = try FlowFixture()
        try writeDriverLock(udid: "SIM-FLOW-TCP", deviceType: "simulator", paths: fixture.paths)
        let flow = try fixture.write("driver-backed-tcp.yaml", """
        name: driver-backed-tcp
        steps:
          - action: tap
            label: General
          - action: dom
          - action: swipe
            to: 10,20
            from: General
        """)
        let fory = ForyRegistry.create()
        let server = try FakeDriverServer(responses: [
            ForyResponseFrame(ok: true, payload: try fory.serialize(ForyElementPayload(label: "General"))),
            ForyResponseFrame(ok: true, payload: try fory.serialize(ForyDomPayload(app: "com.example"))),
            ForyResponseFrame(ok: true, payload: try fory.serialize(ForySwipePayload(label: "10,20", scrolls: 1, scrollDirection: "forth"))),
        ])
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            DriverClient(port: UInt16(server.port))
        }
        addTeardownBlock {
            IOSUseCLI.driverClientFactoryForTesting = nil
            server.stop()
        }

        _ = try FlowService.run(file: flow.path, options: FlowOptions(file: flow.path), paths: fixture.paths)

        XCTAssertEqual(server.acceptCount, 1)
        XCTAssertEqual(server.requestCommands, ["tap", "dom", "swipe"])
        XCTAssertTrue(server.waitForDisconnect(timeout: 1.0))
    }

    func testFlowRequiresActiveDriverLockBeforeRunning() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("host-only.yaml", """
        name: host-only
        steps:
          - action: oslog
            timeout: 1
        """)

        XCTAssertThrowsError(try FlowService.run(file: flow.path, options: FlowOptions(file: flow.path), paths: fixture.paths)) { error in
            XCTAssertTrue(String(describing: error).contains("ios-use start"))
        }
    }

    func testHostOnlyFlowWithLockDoesNotCreateDriverClient() throws {
        let fixture = try FlowFixture()
        try writeDriverLock(udid: "SIM-FLOW", deviceType: "simulator", paths: fixture.paths)
        let flow = try fixture.write("host-only.yaml", """
        name: host-only
        steps:
          - action: oslog
            pattern: ready
            timeout: 1
        """)
        OSLogService.simulatorLogCollector = { _, _, _ in
            ["May 16 10:00:00 iPhone Demo(Demo)[1] <Notice>: ready"]
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("host-only flow must not create a driver client")
            return FakeFlowDriver()
        }
        addTeardownBlock {
            IOSUseCLI.driverClientFactoryForTesting = nil
            OSLogService.resetSimulatorLogCollectorForTesting()
        }

        let output = try FlowService.run(file: flow.path, options: FlowOptions(file: flow.path), paths: fixture.paths)

        XCTAssertTrue(output.contains("ready"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.driverLock))
    }

    func testProductionFlowOpenUsesActiveDriverLockUdidWithoutDriverClient() throws {
        let fixture = try FlowFixture()
        try writeDriverLock(udid: "SIM-FLOW", deviceType: "simulator", paths: fixture.paths)
        let flow = try fixture.write("open.yaml", """
        name: open-url
        steps:
          - action: open
            url: retouch://debug
        """)
        var shellCalls: [(String, [String])] = []
        Shell.runResultOverrideForTesting = { executable, arguments, _ in
            shellCalls.append((executable, arguments))
            return Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }
        IOSUseCLI.driverClientFactoryForTesting = { _ in
            XCTFail("flow open should use host-side URL opening without creating a driver client")
            return FakeFlowDriver()
        }
        addTeardownBlock {
            Shell.runResultOverrideForTesting = nil
            IOSUseCLI.driverClientFactoryForTesting = nil
        }

        let output = try FlowService.run(file: flow.path, options: FlowOptions(file: flow.path), paths: fixture.paths)

        XCTAssertTrue(output.contains("Step 1/1: open"))
        XCTAssertEqual(shellCalls.count, 1)
        XCTAssertEqual(shellCalls.first?.0, "xcrun")
        XCTAssertEqual(shellCalls.first?.1, ["simctl", "openurl", "SIM-FLOW", "retouch://debug"])
    }

    func testFlowCommentTemplateDoesNotSkipDriverValidation() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("comment-template-validation.yaml", """
        name: comment-template-validation
        steps:
          - action: tap
            comment: "${vars.comment}"
            label: General
            offset: bad
        """)

        XCTAssertThrowsError(try FlowService.compileForTesting(file: flow.path)) { error in
            XCTAssertTrue(String(describing: error).contains("Invalid point pair"))
        }
    }

    func testRepoFlowsCompileWithCurrentDSL() throws {
        let repoRoot = repositoryRootForTest()
        let flowFiles = [
            "flows/proxy_clear_wifi_proxy.yaml",
            "flows/proxy_set_wifi_proxy.yaml",
            "flows/proxy_configca.yaml",
            "flows/subflow_wait_and_find.yaml",
            "flows/test_flow.yaml",
            "flows/tmp_nslog_perf.yaml",
        ]

        for relativePath in flowFiles {
            try FlowService.compileForTesting(file: repoRoot.appendingPathComponent(relativePath).path)
        }
    }

    private func writeDriverLock(udid: String, deviceType: String, paths: IOSUsePaths) throws {
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: udid,
                deviceName: "Test Device",
                deviceVersion: "1.0",
                deviceType: deviceType,
                startedAt: 1
            ),
            paths: paths
        )
    }

    private func repositoryRootForTest() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        return url
    }
}

private func makeNSLogMessage(message: String) -> Data {
    let parts: [(UInt8, UInt8, Data)] = [
        (0, 3, uint32Data(0)),
        (7, 0, stringData(message))
    ]
    var body = Data()
    body.append(UInt8((parts.count >> 8) & 0xff))
    body.append(UInt8(parts.count & 0xff))
    for part in parts {
        body.append(part.0)
        body.append(part.1)
        body.append(part.2)
    }
    var data = Data()
    data.append(uint32Data(UInt32(body.count)))
    data.append(body)
    return data
}

private func stringData(_ value: String) -> Data {
    let bytes = Data(value.utf8)
    return uint32Data(UInt32(bytes.count)) + bytes
}

private func uint32Data(_ value: UInt32) -> Data {
    Data([
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ])
}

private final class FlowFixture {
    let root: URL
    let paths: IOSUsePaths

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-flow-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root.path])
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ name: String, _ content: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private final class FakeFlowDriver: FlowDriver {
    var findPayload = ForyFindPayload()
    var domPayload = ForyDomPayload()
    var findError: Error?
    var findLabels: [String] = []
    var finds: [(label: String, traits: String?, cindex: Int32?)] = []
    var waits: [(label: String, timeout: Double?, traits: String?, cindex: Int32?)] = []
    var inputs: [(tap: ForyTarget?, content: String, traits: String?, cindex: Int32?)] = []
    var activatedApps: [String] = []
    var terminatedApps: [String] = []
    var terminateError: Error?
    var swipes: [(to: ForyTarget, from: ForyTarget, distance: Double?, dir: String?, traits: String?, cindex: Int32?)] = []
    var taps: [(target: ForyTarget, traits: String?, cindex: Int32?, offset: ForyPoint?, ratio: ForyPoint)] = []
    var longPresses: [(target: ForyTarget, durationMs: Int?, traits: String?, cindex: Int32?)] = []
    var commands: [String] = []
    var domCalls = 0

    func close() {}
    func proxyCAPush(caBase64: String) throws -> ForyProxyPayload { ForyProxyPayload() }
    func activateApp(bundleId: String) throws {
        commands.append("activateApp")
        activatedApps.append(bundleId)
    }
    func terminateApp(bundleId: String) throws {
        commands.append("terminateApp")
        terminatedApps.append(bundleId)
        if let terminateError {
            throw terminateError
        }
    }
    func home() throws { commands.append("home") }
    func dismissAlert(index: Int?) throws -> ForyAlertPayload {
        commands.append("dismissAlert")
        return ForyAlertPayload(dismissed: true)
    }
    func waitFor(label: String, timeout: Double?, traits: String?, cindex: Int32?) throws -> ForyWaitForPayload {
        commands.append("waitFor")
        waits.append((label, timeout, traits, cindex))
        return ForyWaitForPayload(label: label)
    }
    func find(label: String, traits: String?, cindex: Int32?) throws -> ForyFindPayload {
        commands.append("find")
        findLabels.append(label)
        finds.append((label, traits, cindex))
        if let findError {
            throw findError
        }
        return findPayload
    }
    func dom(raw: Bool, fresh: Bool, waitQuiescence: Bool) throws -> ForyDomPayload {
        commands.append("dom")
        domCalls += 1
        return domPayload
    }
    func tap(target: ForyTarget, traits: String?, cindex: Int32?, offset: ForyPoint?, ratio: ForyPoint) throws -> ForyElementPayload {
        commands.append("tap")
        taps.append((target, traits, cindex, offset, ratio))
        return ForyElementPayload(label: target.label)
    }
    func longPress(target: ForyTarget, durationMs: Int?, traits: String?, cindex: Int32?) throws -> ForyElementPayload {
        commands.append("longpress")
        longPresses.append((target, durationMs, traits, cindex))
        return ForyElementPayload(label: target.label)
    }
    func input(tap: ForyTarget?, content: String) throws {
        commands.append("input")
        inputs.append((tap, content, tap?.traits.isEmpty == true ? nil : tap?.traits, tap?.cindex))
    }
    func swipe(to: ForyTarget, from: ForyTarget, distance: Double?, dir: String?, traits: String?, cindex: Int32?) throws -> ForySwipePayload {
        commands.append("swipe")
        swipes.append((to, from, distance, dir, traits, cindex))
        return ForySwipePayload(elemType: 75, label: to.label, scrolls: 1, scrollDirection: "down")
    }
    func screenshot() throws -> Data {
        commands.append("screenshot")
        return Data([0xff, 0xd8, 0xff])
    }
}
