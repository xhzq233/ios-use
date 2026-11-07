import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// A device-side connection to local developer services, authenticated using an
/// imported host identity. Scoped to one operation, never persisted by the CLI.
struct DirectDeviceConnection {
    let host: String
    let pairRecord: PairRecord
    var eventSink: ((String) -> Void)? = nil

    @TaskLocal static var current: DirectDeviceConnection?

    static func connect(udid: String, port: Int) throws -> Int32 {
        if let direct = current {
            let fd = try TCPConnector.connect(host: direct.host, port: port)
            if let eventSink = direct.eventSink {
                var address = sockaddr_storage()
                var length = socklen_t(MemoryLayout.size(ofValue: address))
                withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        if posixGetsockname(fd, socketAddress, &length) == 0 {
                            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                            if getnameinfo(socketAddress, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                                eventSink("Local developer TCP source=\(String(cString: host)) destination=\(direct.host):\(port)")
                            }
                        }
                    }
                }
            }
            return fd
        }
        return try Usbmux.connect(udid: udid, port: port)
    }
}
