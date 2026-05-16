import XCTest
import IOSUseCLI

final class CLIParserTests: XCTestCase {
    func testParsesDeviceAndConfigCommands() throws {
        XCTAssertEqual(
            try CLIParser.parse(["devices", "--simulator", "--verbose"]),
            .devices(DeviceOptions(simulator: true, verbose: true))
        )

        XCTAssertEqual(
            try CLIParser.parse(["config", "--simulator", "--udid", "SIM-1", "--apple-id", "user@example.com", "--password", "secret", "--verbose"]),
            .config(ConfigOptions(udid: "SIM-1", list: false, simulator: true, appleId: "user@example.com", password: "secret", verbose: true))
        )

        XCTAssertEqual(
            try CLIParser.parse(["config", "--list"]),
            .config(ConfigOptions(list: true))
        )
    }

    func testParsesDriverReadCommands() throws {
        XCTAssertEqual(
            try CLIParser.parse(["dom", "--raw", "--fresh", "--udid", "SIM-1"]),
            .driver(.dom(raw: true, fresh: true, session: SessionOptions(udid: "SIM-1", verbose: false)))
        )

        XCTAssertEqual(
            try CLIParser.parse(["find", "General", "--traits", "Cell,selected", "--verbose"]),
            .driver(.find(label: "General", traits: "Cell,selected", session: SessionOptions(udid: nil, verbose: true)))
        )

        XCTAssertEqual(
            try CLIParser.parse(["waitFor", "--label", "Ready", "--timeout", "1.5", "--traits", "StaticText"]),
            .driver(.waitFor(label: "Ready", timeout: 1.5, traits: "StaticText", session: SessionOptions()))
        )
    }

    func testParsesDriverMutationCommands() throws {
        XCTAssertEqual(
            try CLIParser.parse(["tap", "General", "--offset", "1,2", "--offset-ratio", ".5,.25", "--traits", "Cell"]),
            .driver(.tap(target: "General", offset: "1,2", offsetRatio: ".5,.25", traits: "Cell", session: SessionOptions()))
        )

        XCTAssertEqual(
            try CLIParser.parse(["longpress", "100,200", "--duration", "500", "--traits", "Icon"]),
            .driver(.longPress(target: "100,200", duration: 500, traits: "Icon", session: SessionOptions()))
        )

        XCTAssertEqual(
            try CLIParser.parse(["input", "--label", "First name", "--content", "Alpha", "--traits", "TextField"]),
            .driver(.input(label: "First name", content: "Alpha", traits: "TextField", session: SessionOptions()))
        )

        XCTAssertEqual(
            try CLIParser.parse(["swipe", "--to", "General", "--from", "Settings", "--dir", "forth", "--distance", "200", "--traits", "Cell"]),
            .driver(.swipe(to: "General", from: "Settings", dir: "forth", distance: 200, traits: "Cell", session: SessionOptions()))
        )
    }

    func testParsesAppAndUtilityDriverCommands() throws {
        XCTAssertEqual(
            try CLIParser.parse(["activateApp", "com.apple.Preferences", "--udid", "DEVICE-1"]),
            .driver(.activateApp(bundleId: "com.apple.Preferences", session: SessionOptions(udid: "DEVICE-1", verbose: false)))
        )

        XCTAssertEqual(
            try CLIParser.parse(["openURL", "--url", "https://example.com"]),
            .driver(.openURL(url: "https://example.com", session: SessionOptions()))
        )

        XCTAssertEqual(
            try CLIParser.parse(["dismissAlert", "--index", "0"]),
            .driver(.dismissAlert(index: 0, session: SessionOptions()))
        )

        XCTAssertEqual(
            try CLIParser.parse(["oslog", "--pattern", "ready", "--flags", "i", "--timeout", "3", "--name", "logs", "--clear", "--bundle-id", "com.demo"]),
            .driver(.oslog(pattern: "ready", flags: "i", timeout: 3, name: "logs", clear: true, bundleId: "com.demo", session: SessionOptions()))
        )
    }

    func testParsesFlowNSLogAndProxyCommands() throws {
        XCTAssertEqual(
            try CLIParser.parse(["flow", "flows/test_flow.yaml", "--udid", "SIM-1", "--verbose", "--server", "192.168.1.10", "--port", "8080"]),
            .flow(FlowOptions(file: "flows/test_flow.yaml", udid: "SIM-1", verbose: true, externalVars: ["server": "192.168.1.10", "port": "8080"]))
        )

        XCTAssertEqual(
            try CLIParser.parse(["nslog", "--name", "ios-use", "--grep", "ready", "--flags", "i"]),
            .nslog(NSLogOptions(name: "ios-use", grep: "ready", flags: "i"))
        )

        XCTAssertEqual(
            try CLIParser.parse(["proxy", "start", "--udid", "DEVICE-1", "--interface", "en0"]),
            .proxy(.start(udid: "DEVICE-1", interfaceName: "en0"))
        )

        XCTAssertEqual(
            try CLIParser.parse(["proxy", "start", "--udid", "DEVICE-1", "-i", "en1"]),
            .proxy(.start(udid: "DEVICE-1", interfaceName: "en1"))
        )

        XCTAssertEqual(
            try CLIParser.parse(["proxy", "configca", "--udid", "DEVICE-1"]),
            .proxy(.configca(udid: "DEVICE-1"))
        )

        XCTAssertEqual(
            try CLIParser.parse(["proxy", "stop", "--udid", "DEVICE-1"]),
            .proxy(.stop(udid: "DEVICE-1"))
        )

        XCTAssertEqual(
            try CLIParser.parse(["proxy", "doctor"]),
            .proxy(.doctor)
        )
    }

    func testRejectsInvalidValuesAndUnknownOptions() {
        XCTAssertThrowsError(try CLIParser.parse(["swipe", "--dir", "forward"])) { error in
            XCTAssertEqual(error as? CLIParseError, .invalidValue("Invalid swipe dir: \"forward\", expected \"forth\" or \"back\""))
        }

        XCTAssertThrowsError(try CLIParser.parse(["waitFor", "--label", "Ready", "--timeout", "abc"])) { error in
            XCTAssertEqual(error as? CLIParseError, .invalidValue("Invalid number: \"abc\""))
        }

        XCTAssertThrowsError(try CLIParser.parse(["config", "--ipa", "driver.ipa"])) { error in
            XCTAssertEqual(error as? CLIParseError, .unknownOption("--ipa"))
        }
    }

    func testParsesDashPrefixedOptionValuesWhereSemanticallyValid() throws {
        XCTAssertEqual(
            try CLIParser.parse(["input", "--label", "First name", "--content", "-Alpha"]),
            .driver(.input(label: "First name", content: "-Alpha", traits: nil, session: SessionOptions()))
        )

        XCTAssertEqual(
            try CLIParser.parse(["tap", "General", "--offset", "-1,2", "--offset-ratio", "-.5,.25"]),
            .driver(.tap(target: "General", offset: "-1,2", offsetRatio: "-.5,.25", traits: nil, session: SessionOptions()))
        )

        XCTAssertEqual(
            try CLIParser.parse(["flow", "flows/test_flow.yaml", "--flag", "-value"]),
            .flow(FlowOptions(file: "flows/test_flow.yaml", externalVars: ["flag": "-value"]))
        )
    }

    func testRejectsNegativeNumericOptionsThatMeanDefaultsInDriver() {
        XCTAssertThrowsError(try CLIParser.parse(["longpress", "General", "--duration", "-1"])) { error in
            XCTAssertEqual(error as? CLIParseError, .invalidValue("--duration must be non-negative"))
        }
        XCTAssertThrowsError(try CLIParser.parse(["waitFor", "--label", "General", "--timeout", "-1"])) { error in
            XCTAssertEqual(error as? CLIParseError, .invalidValue("--timeout must be non-negative"))
        }
        XCTAssertThrowsError(try CLIParser.parse(["oslog", "--timeout", "0", "--udid", "DEVICE-1"])) { error in
            XCTAssertEqual(error as? CLIParseError, .invalidValue("--timeout must be greater than 0"))
        }
        XCTAssertThrowsError(try CLIParser.parse(["dismissAlert", "--index", "-1"])) { error in
            XCTAssertEqual(error as? CLIParseError, .invalidValue("--index must be non-negative"))
        }
    }

    func testRejectsInvalidFlowExternalVariableNames() {
        XCTAssertThrowsError(try CLIParser.parse(["flow", "flows/test_flow.yaml", "--foo.bar", "value"])) { error in
            XCTAssertEqual(error as? CLIParseError, .invalidValue("Invalid flow external variable name: foo.bar"))
        }
    }
}
