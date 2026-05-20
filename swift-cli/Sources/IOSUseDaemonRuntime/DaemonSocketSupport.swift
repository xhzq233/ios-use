import Darwin
import Foundation

enum DaemonSocketError: Error, Equatable, CustomStringConvertible {
    case connectionClosedBeforeExit
    case socketPathTooLong
    case socketFailure(String)

    var description: String {
        switch self {
        case .connectionClosedBeforeExit:
            return "daemon connection closed before exit response"
        case .socketPathTooLong:
            return "daemon socket path is too long"
        case .socketFailure(let detail):
            return detail
        }
    }
}

func daemonSocketCanConnect(path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    do {
        var address = try daemonUnixAddress(path: path)
        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, length)
            }
        }
        return result == 0
    } catch {
        return false
    }
}

func daemonUnixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < maxPathLength else {
        throw DaemonSocketError.socketPathTooLong
    }
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
            path.withCString { source in
                strncpy(destination, source, maxPathLength - 1)
            }
        }
    }
    return address
}

func daemonCmsgSpace(_ fdCount: Int) -> Int {
    daemonCmsgAlign(MemoryLayout<cmsghdr>.size) + daemonCmsgAlign(MemoryLayout<Int32>.stride * fdCount)
}

func daemonCmsgLength(_ fdCount: Int) -> Int {
    daemonCmsgAlign(MemoryLayout<cmsghdr>.size) + MemoryLayout<Int32>.stride * fdCount
}

func daemonCmsgAlign(_ length: Int) -> Int {
    let alignment = MemoryLayout<Int>.stride
    return (length + alignment - 1) & ~(alignment - 1)
}

func daemonCmsgData(_ header: UnsafeMutablePointer<cmsghdr>) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer(header).advanced(by: daemonCmsgAlign(MemoryLayout<cmsghdr>.size))
}

func daemonFirstCmsg(_ header: inout msghdr) -> UnsafeMutablePointer<cmsghdr>? {
    guard header.msg_controllen >= MemoryLayout<cmsghdr>.size,
          let control = header.msg_control else {
        return nil
    }
    return control.assumingMemoryBound(to: cmsghdr.self)
}

func daemonErrnoMessage(_ operation: String) -> String {
    "\(operation) failed: \(String(cString: strerror(errno)))"
}
