import XCTest
import IOSUseCLI

final class NSLogServiceTests: XCTestCase {
    func testParseAndFormatLogMessage() {
        let data = makeMessage(parts: [
            (0, 3, int32Data(0)),
            (5, 0, stringData("driver")),
            (6, 3, int32Data(2)),
            (7, 0, stringData("ready")),
            (11, 0, stringData("File.swift")),
            (12, 3, int32Data(42)),
            (13, 0, stringData("boot"))
        ])

        let parsed = NSLogService.parseMessage(data)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.consumed, data.count)

        let formatted = NSLogService.formatLogEntry(parsed?.parts ?? [:])
        XCTAssertTrue(formatted.contains("[driver]"))
        XCTAssertTrue(formatted.contains("L2"))
        XCTAssertTrue(formatted.contains("File.swift:42"))
        XCTAssertTrue(formatted.contains("boot()"))
        XCTAssertTrue(formatted.contains("ready"))
    }

    func testParseMessageWaitsForCompleteFrame() {
        let data = makeMessage(parts: [(7, 0, stringData("ready"))])
        let partial = data.prefix(data.count - 1)

        XCTAssertNil(NSLogService.parseMessage(Data(partial)))
    }

    private func makeMessage(parts: [(UInt8, UInt8, Data)]) -> Data {
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

    private func int32Data(_ value: Int32) -> Data {
        uint32Data(UInt32(bitPattern: value))
    }

    private func uint32Data(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ])
    }
}
