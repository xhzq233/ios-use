import XCTest
@testable import SelfRunnerCore

final class LoopbackPacketTests: XCTestCase {
    func testReflectionPreservesChecksumsPortsAndPayload() throws {
        // IPv4 header with a UDP datagram; checksums are left untouched because
        // swapping addresses leaves both one's-complement sums unchanged.
        let original = Data([0x45,0,0,30,0,1,0,0,64,17,0x66,0xb8,10,7,0,2,10,7,0,1,
                             0xc0,0x01,0xf2,0x7e,0,10,0x35,0x17,0xab,0xcd])
        let reflected = try XCTUnwrap(LoopbackPacket.reflect(original))
        XCTAssertEqual(Array(reflected[12..<20]), [10,7,0,1,10,7,0,2])
        XCTAssertEqual(reflected.prefix(12), original.prefix(12))
        XCTAssertEqual(reflected.suffix(10), original.suffix(10))
        func sum(_ data: Data) -> Int { stride(from: 0, to: data.count, by: 2).reduce(0) { $0 + (Int(data[$1]) << 8 | Int(data[$1+1])) } }
        XCTAssertEqual(sum(reflected), sum(original))
    }
    func testRejectsOtherRoutesAndMalformedPackets() {
        for bytes in [[UInt8](), [UInt8](repeating: 0, count: 30),
                      [0x45,0,0,20,0,0,0,0,64,6,0,0,10,7,0,2,8,8,8,8],
                      [0x45,0,0,30,0,0,0,0,64,6,0,0,10,7,0,2,10,7,0,1]] {
            XCTAssertNil(LoopbackPacket.reflect(Data(bytes)))
        }
    }
}
