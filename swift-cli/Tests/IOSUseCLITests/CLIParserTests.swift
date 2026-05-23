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

        XCTAssertEqual(
            try CLIParser.parse(["start", "SIM-1", "--verbose"]),
            .start(StartOptions(udid: "SIM-1", verbose: true))
        )
    }

    func testParsesDriverReadCommands() throws {
        XCTAssertEqual(
            try CLIParser.parse(["dom", "--raw", "--fresh", "--udid", "SIM-1"]),
            .driver(.dom(raw: true, fresh: true, session: SessionOptions(udid: "SIM-1", verbose: false)))
        )

        XCTAssertEqual(
            try CLIParser.parse(["find", "General", "--traits", "Cell,selected", "--cindex", "-1", "--verbose"]),
            .driver(.find(label: "General", traits: "Cell,selected", cindex: -1, session: SessionOptions(udid: nil, verbose: true)))
        )

        XCTAssertEqual(
            try CLIParser.parse(["waitFor", "--label", "Ready", "--timeout", "1.5", "--traits", "StaticText", "--cindex", "0"]),
            .driver(.waitFor(label: "Ready", timeout: 1.5, traits: "StaticText", cindex: 0, session: SessionOptions()))
        )
    }

    func testParsesDriverMutationCommands() throws {
        XCTAssertEqual(
            try CLIParser.parse(["tap", "General", "--offset", "1,2", "--offset-ratio", ".5,.25", "--traits", "Cell", "--cindex", "2"]),
            .driver(.tap(target: "General", offset: "1,2", offsetRatio: ".5,.25", traits: "Cell", cindex: 2, session: SessionOptions()))
        )

        XCTAssertEqual(
            try CLIParser.parse(["longpress", "General", "--duration", "500", "--traits", "Icon", "--cindex", "-2"]),
            .driver(.longPress(target: "General", duration: 500, traits: "Icon", cindex: -2, session: SessionOptions()))
        )

        XCTAssertEqual(
            try CLIParser.parse(["input", "--label", "First name", "--content", "Alpha", "--traits", "TextField", "--cindex", "0"]),
            .driver(.input(label: "First name", content: "Alpha", traits: "TextField", cindex: 0, session: SessionOptions()))
        )

        XCTAssertEqual(
            try CLIParser.parse(["swipe", "--to", "General", "--from", "Settings", "--dir", "forth", "--distance", "200", "--traits", "Cell", "--cindex", "-1"]),
            .driver(.swipe(to: "General", from: "Settings", dir: "forth", distance: 200, traits: "Cell", cindex: -1, session: SessionOptions()))
        )
    }

    func testParsesAppAndUtilityDriverCommands() throws {
        XCTAssertEqual(
            try CLIParser.parse(["activateApp", "com.apple.Preferences", "--udid", "DEVICE-1"]),
            .driver(.activateApp(bundleId: "com.apple.Preferences", session: SessionOptions(udid: "DEVICE-1", verbose: false)))
        )

        XCTAssertEqual(
            try CLIParser.parse(["open", "https://example.com"]),
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

        XCTAssertEqual(
            try CLIParser.parse(["oslog", "--timeout", "0", "--udid", "DEVICE-1"]),
            .driver(.oslog(pattern: nil, flags: nil, timeout: 0, name: nil, clear: false, bundleId: nil, session: SessionOptions(udid: "DEVICE-1")))
        )
    }

    func testParsesFlowNSLogAndProxyCommands() throws {
        XCTAssertEqual(
            try CLIParser.parse(["flow", "flows/test_flow.yaml", "--udid", "SIM-1", "--verbose", "--server", "192.168.1.10", "--port", "8080"]),
            .flow(FlowOptions(file: "flows/test_flow.yaml", udid: "SIM-1", verbose: true, externalVars: ["server": "192.168.1.10", "port": "8080"]))
        )

        XCTAssertEqual(
            try CLIParser.parse(["flow", "flows/test_flow.yaml", "--udid=SIM-1", "--server=192.168.1.10", "--flag=-value"]),
            .flow(FlowOptions(file: "flows/test_flow.yaml", udid: "SIM-1", externalVars: ["server": "192.168.1.10", "flag": "-value"]))
        )

        XCTAssertEqual(
            try CLIParser.parse(["flow", "flows/test_flow.yaml", "--literal=--value"]),
            .flow(FlowOptions(file: "flows/test_flow.yaml", externalVars: ["literal": "--value"]))
        )

        XCTAssertEqual(
            try CLIParser.parse(["nslog", "--name=ios-use"]),
            .nslog(NSLogOptions(name: "ios-use"))
        )

        XCTAssertEqual(
            try CLIParser.parse(["nslog", "start", "--name=ios-use"]),
            .nslog(NSLogOptions(command: .start, name: "ios-use"))
        )

        XCTAssertEqual(
            try CLIParser.parse(["nslog", "read", "--pattern=ready", "--flags=i", "--timeout", "1.5", "--clearAfterRead", "--last", "5"]),
            .nslog(NSLogOptions(command: .read, pattern: "ready", flags: "i", timeout: 1.5, clearAfterRead: true, last: 5))
        )

        XCTAssertEqual(
            try CLIParser.parse(["nslog", "stop"]),
            .nslog(NSLogOptions(command: .stop))
        )

        XCTAssertEqual(
            try CLIParser.parse(["proxy", "start", "--udid=DEVICE-1", "--interface=en0"]),
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
            try CLIParser.parse(["proxy", "read", "--filter", "~m POST", "--raw", "--last", "5"]),
            .proxy(.read(filter: "~m POST", raw: true, last: 5))
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

        XCTAssertThrowsError(try CLIParser.parse(["start"])) { error in
            XCTAssertEqual(error as? CLIParseError, .missingRequiredArgument("udid"))
        }

        let legacyOpenCommand = "open" + "URL"
        XCTAssertThrowsError(try CLIParser.parse([legacyOpenCommand, "--url", "https://example.com"])) { error in
            XCTAssertEqual(error as? CLIParseError, .unknownCommand(legacyOpenCommand))
        }

        XCTAssertThrowsError(try CLIParser.parse(["flow", "flows/test_flow.yaml", "--server", "--port", "9080"])) { error in
            XCTAssertEqual(error as? CLIParseError, .missingOptionValue("--server"))
        }
    }

    func testParsesDashPrefixedOptionValuesWhereSemanticallyValid() throws {
        XCTAssertEqual(
            try CLIParser.parse(["input", "--label", "First name", "--content", "-Alpha"]),
            .driver(.input(label: "First name", content: "-Alpha", traits: nil, cindex: nil, session: SessionOptions()))
        )

        XCTAssertEqual(
            try CLIParser.parse(["tap", "General", "--offset", "-1,2", "--offset-ratio", "-.5,.25"]),
            .driver(.tap(target: "General", offset: "-1,2", offsetRatio: "-.5,.25", traits: nil, cindex: nil, session: SessionOptions()))
        )

        XCTAssertEqual(
            try CLIParser.parse(["tap", "General", "--cindex", "-1"]),
            .driver(.tap(target: "General", offset: nil, offsetRatio: nil, traits: nil, cindex: -1, session: SessionOptions()))
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
        XCTAssertThrowsError(try CLIParser.parse(["find", "General", "--cindex", "1.2"])) { error in
            XCTAssertEqual(error as? CLIParseError, .invalidValue("Invalid integer: \"1.2\""))
        }
        XCTAssertThrowsError(try CLIParser.parse(["find", "General", "--cindex", "2147483648"])) { error in
            XCTAssertEqual(error as? CLIParseError, .invalidValue("--cindex is out of Int32 range"))
        }
        XCTAssertThrowsError(try CLIParser.parse(["dismissAlert", "--index", "-1"])) { error in
            XCTAssertEqual(error as? CLIParseError, .invalidValue("--index must be non-negative"))
        }
        XCTAssertThrowsError(try CLIParser.parse(["proxy", "read", "--last", "0"])) { error in
            XCTAssertEqual(error as? CLIParseError, .invalidValue("--last must be greater than 0"))
        }
        XCTAssertThrowsError(try CLIParser.parse(["nslog", "--grep", "ready"])) { error in
            XCTAssertEqual(error as? CLIParseError, .invalidValue("--grep moved to `ios-use nslog read`. Use `ios-use nslog read --pattern <regex> --flags <flags>`."))
        }
    }

    func testRejectsInvalidFlowExternalVariableNames() {
        XCTAssertThrowsError(try CLIParser.parse(["flow", "flows/test_flow.yaml", "--foo.bar", "value"])) { error in
            XCTAssertEqual(error as? CLIParseError, .invalidValue("Invalid flow external variable name: foo.bar"))
        }
    }
}
