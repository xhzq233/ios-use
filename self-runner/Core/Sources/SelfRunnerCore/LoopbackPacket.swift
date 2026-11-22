import Foundation

public enum LoopbackPacket {
    /// The kernel emits both client requests and service responses through the
    /// peer route. Reflection exchanges their IP addresses without changing the
    /// transport checksum's pseudo-header sum. No Internet route is accepted.
    public static func reflect(_ packet: Data) -> Data? {
        let bytes = [UInt8](packet)
        guard bytes.count >= 20, bytes[0] >> 4 == 4 else { return nil }
        let headerSize = Int(bytes[0] & 15) * 4
        let totalSize = Int(bytes[2]) << 8 | Int(bytes[3])
        guard headerSize >= 20, totalSize >= headerSize, totalSize == bytes.count,
              bytes[16..<20].elementsEqual([10, 7, 0, 1]) else { return nil }
        var result = bytes
        result.replaceSubrange(12..<16, with: bytes[16..<20])
        result.replaceSubrange(16..<20, with: bytes[12..<16])
        return Data(result)
    }
}
