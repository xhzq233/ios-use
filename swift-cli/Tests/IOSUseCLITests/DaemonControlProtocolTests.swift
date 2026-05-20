import XCTest
@testable import IOSUseDaemonRuntime

final class DaemonControlProtocolTests: XCTestCase {
    func testRequestRoundTripCarriesRawArguments() throws {
        let argv = ["find", "General", "--traits", "Button", "--cindex", "0", "--udid", "SIM-1"]
        let request = DaemonRequest(id: "request-1", argv: argv, cwd: "/tmp/work", environment: ["IOS_USE_HOME": "/tmp/home"])
        let message = DaemonControlMessage.request(request)

        let decoded = try DaemonControlProtocol.decode(try DaemonControlProtocol.encode(message))

        XCTAssertEqual(decoded, message)
        if case .request(let decodedRequest) = decoded {
            XCTAssertEqual(decodedRequest.argv, argv)
            XCTAssertEqual(decodedRequest.cwd, "/tmp/work")
            XCTAssertEqual(decodedRequest.environment["IOS_USE_HOME"], "/tmp/home")
        } else {
            XCTFail("expected request")
        }
    }

    func testInterruptAndExitRoundTrip() throws {
        let interrupt = DaemonControlMessage.interrupt(DaemonInterrupt(id: "request-2", signal: "SIGINT"))
        let exit = DaemonControlMessage.exit(DaemonExit(id: "request-2", exitCode: 130))

        XCTAssertEqual(try DaemonControlProtocol.decode(try DaemonControlProtocol.encode(interrupt)), interrupt)
        XCTAssertEqual(try DaemonControlProtocol.decode(try DaemonControlProtocol.encode(exit)), exit)
    }

    func testRejectsUnsupportedProtocolVersion() throws {
        let message = DaemonControlMessage.exit(DaemonExit(version: 999, id: "bad-version", exitCode: 0))
        let data = try DaemonControlProtocol.encode(message)

        XCTAssertThrowsError(try DaemonControlProtocol.decode(data)) { error in
            XCTAssertTrue(String(describing: error).contains("unsupported daemon protocol version"))
        }
    }
}
