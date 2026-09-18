import Foundation
import XCTest
@testable import IOSUseCLI

final class CoreDeviceChecksumTests: XCTestCase {
    func testInternetChecksumWordOrderPaddingCarryAndDataSlices() {
        XCTAssertEqual(CoreDeviceIPv6TCPCodec.internetChecksum(Data()), 0xffff)
        XCTAssertEqual(CoreDeviceIPv6TCPCodec.internetChecksum(Data([0xff])), 0x00ff)
        XCTAssertEqual(CoreDeviceIPv6TCPCodec.internetChecksum(Data([1, 2, 3])), 0xfbfd)
        for count in [1, 2, 59, 60, 1260, 4095, 65535] {
            let bytes = (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 73 &+ 19) }
            let words = stride(from: 0, to: count, by: 2).map {
                UInt64(bytes[$0]) * 256 + ($0 + 1 < count ? UInt64(bytes[$0 + 1]) : 0)
            }
            var reference = words.reduce(0, +)
            while reference > 65535 { reference = (reference & 65535) + (reference >> 16) }
            let expected = UInt16(reference ^ 65535)
            let padded = Data([0xaa, 0xbb, 0xcc] + bytes)
            XCTAssertEqual(CoreDeviceIPv6TCPCodec.internetChecksum(padded.dropFirst(3)), expected)
        }
    }
}
