import XCTest
import IOSUseProtocol
@testable import IOSUseCLI

final class FlowServiceTests: XCTestCase {
    func testMissingFlowFileFailsBeforeDriverWork() {
        let result = IOSUseCLI(environment: ["IOS_USE_HOME": "/tmp/ios-use-swift-flow"]).run(arguments: ["flow", "/tmp/no-such-flow.yaml"])

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("Flow file not found"))
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
        driver.findPayload = ForyFindPayload(matches: [ForyFindMatch(label: "InjectedLabel", value: "value")])

        let result = try FlowService.runForTesting(file: parent.path, externalVars: ["label": "InjectedLabel"], paths: fixture.paths, driver: driver)

        XCTAssertTrue(result.stdout.contains("Running flow: parent"))
        XCTAssertTrue(result.stdout.contains("Running flow: child"))
        XCTAssertEqual(driver.findLabels, ["InjectedLabel"])
        let found = try XCTUnwrap(result.outputs["found"] as? [String: Any])
        let first = try XCTUnwrap(found["firstMatch"] as? [String: Any])
        XCTAssertEqual(first["label"] as? String, "InjectedLabel")
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

    func testDomCandidatesRespectCandidatePriorityAndSaveDerivedJson() throws {
        let fixture = try FlowFixture()
        let flow = try fixture.write("dom.yaml", """
        name: dom-flow
        outputs: page
        steps:
          - action: dom
            save: true
            name: page
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

        let saved = "\(fixture.paths.artifacts)/page.json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved))
        let savedText = try String(contentsOfFile: saved)
        XCTAssertTrue(savedText.contains("\"firstMatch\""))
        XCTAssertTrue(savedText.contains("\"Close\""))
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

    func write(_ name: String, _ content: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private final class FakeFlowDriver: FlowDriver {
    var findPayload = ForyFindPayload()
    var domPayload = ForyDomPayload()
    var findLabels: [String] = []
    var swipes: [(to: ForyTarget, from: ForyTarget, distance: Double?, dir: String?, traits: String?)] = []

    func activateApp(bundleId: String) throws {}
    func terminateApp(bundleId: String) throws {}
    func home() throws {}
    func openURL(url: String) throws -> ForySimpleStringPayload { ForySimpleStringPayload(value: url) }
    func dismissAlert(index: Int?) throws -> ForyAlertPayload { ForyAlertPayload(dismissed: true) }
    func waitFor(label: String, timeout: Double?, traits: String?) throws -> ForyWaitForPayload { ForyWaitForPayload(label: label) }
    func find(label: String, traits: String?) throws -> ForyFindPayload {
        findLabels.append(label)
        return findPayload
    }
    func dom(raw: Bool, fresh: Bool) throws -> ForyDomPayload { domPayload }
    func tap(target: ForyTarget, traits: String?, offset: ForyPoint?, ratio: ForyPoint) throws -> ForyElementPayload { ForyElementPayload(label: target.label) }
    func input(label: String, content: String, traits: String?) throws {}
    func swipe(to: ForyTarget, from: ForyTarget, distance: Double?, dir: String?, traits: String?) throws -> ForySwipePayload {
        swipes.append((to, from, distance, dir, traits))
        return ForySwipePayload(label: to.label, scrolls: 1)
    }
    func screenshot() throws -> Data { Data([0xff, 0xd8, 0xff]) }
}
