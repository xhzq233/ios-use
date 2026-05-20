import Darwin
import Foundation

public enum DaemonClientError: Error, Equatable, CustomStringConvertible {
    case unexpectedMessage
    case connectionClosedBeforeExit
    case socketPathTooLong
    case socketFailure(String)

    public var description: String {
        switch self {
        case .unexpectedMessage:
            return "daemon returned an unexpected control message"
        case .connectionClosedBeforeExit:
            return "daemon connection closed before exit response"
        case .socketPathTooLong:
            return "daemon socket path is too long"
        case .socketFailure(let detail):
            return detail
        }
    }
}

public final class DaemonClient {
    private let paths: IOSUsePaths

    public init(paths: IOSUsePaths) {
        self.paths = paths
    }

    public func canConnect() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        do {
            try connect(fd: fd, path: paths.daemonSocket)
            return true
        } catch {
            return false
        }
    }

    public func send(
        _ request: DaemonRequest,
        stdoutFileDescriptor: Int32? = nil,
        stderrFileDescriptor: Int32? = nil
    ) throws -> DaemonExit {
        try send(.request(request), fileDescriptors: [stdoutFileDescriptor, stderrFileDescriptor].compactMap { $0 })
    }

    public func send(_ message: DaemonControlMessage, fileDescriptors: [Int32] = []) throws -> DaemonExit {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonClientError.socketFailure(errnoMessage("socket")) }
        defer { close(fd) }

        try connect(fd: fd, path: paths.daemonSocket)
        try sendFrame(message, fileDescriptors: fileDescriptors, fd: fd)
        let response = try readFrame(fd: fd)
        guard case .exit(let exit) = try DaemonControlProtocol.decode(response) else {
            throw DaemonClientError.unexpectedMessage
        }
        return exit
    }

    private func connect(fd: Int32, path: String) throws {
        var address = try unixAddress(path: path)
        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, length)
            }
        }
        guard result == 0 else { throw DaemonClientError.socketFailure(errnoMessage("connect")) }
    }

    private func sendFrame(_ message: DaemonControlMessage, fileDescriptors: [Int32], fd: Int32) throws {
        let data = try DaemonControlProtocol.encode(message)
        try data.withUnsafeBytes { dataPointer in
            var iov = iovec(
                iov_base: UnsafeMutableRawPointer(mutating: dataPointer.baseAddress),
                iov_len: data.count
            )
            try withUnsafeMutablePointer(to: &iov) { iovPointer in
                var header = msghdr()
                header.msg_iov = iovPointer
                header.msg_iovlen = 1

                var control = [UInt8]()
                if !fileDescriptors.isEmpty {
                    control = [UInt8](repeating: 0, count: cmsgSpace(fileDescriptors.count))
                    try control.withUnsafeMutableBytes { controlPointer in
                        header.msg_control = controlPointer.baseAddress
                        header.msg_controllen = socklen_t(controlPointer.count)
                        guard let first = firstCmsg(&header) else {
                            throw DaemonClientError.socketFailure("failed to create daemon fd control header")
                        }
                        first.pointee.cmsg_len = socklen_t(cmsgLength(fileDescriptors.count))
                        first.pointee.cmsg_level = SOL_SOCKET
                        first.pointee.cmsg_type = SCM_RIGHTS
                        let fdPointer = cmsgData(first).assumingMemoryBound(to: Int32.self)
                        for (index, descriptor) in fileDescriptors.enumerated() {
                            fdPointer[index] = descriptor
                        }
                        guard sendmsg(fd, &header, 0) == data.count else {
                            throw DaemonClientError.socketFailure(errnoMessage("sendmsg"))
                        }
                    }
                } else {
                    guard sendmsg(fd, &header, 0) == data.count else {
                        throw DaemonClientError.socketFailure(errnoMessage("sendmsg"))
                    }
                }
            }
        }
    }

    private func readFrame(fd: Int32) throws -> Data {
        var data = Data()
        var byte = UInt8(0)
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 {
                data.append(byte)
                if byte == 0x0a { return data }
            } else if count == 0 {
                throw DaemonClientError.connectionClosedBeforeExit
            } else if errno != EINTR {
                throw DaemonClientError.socketFailure(errnoMessage("read"))
            }
        }
    }
}

func unixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < maxPathLength else {
        throw DaemonClientError.socketPathTooLong
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

func cmsgSpace(_ fdCount: Int) -> Int {
    cmsgAlign(MemoryLayout<cmsghdr>.size) + cmsgAlign(MemoryLayout<Int32>.stride * fdCount)
}

func cmsgLength(_ fdCount: Int) -> Int {
    cmsgAlign(MemoryLayout<cmsghdr>.size) + MemoryLayout<Int32>.stride * fdCount
}

func cmsgAlign(_ length: Int) -> Int {
    let alignment = MemoryLayout<Int>.stride
    return (length + alignment - 1) & ~(alignment - 1)
}

func cmsgData(_ header: UnsafeMutablePointer<cmsghdr>) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer(header).advanced(by: cmsgAlign(MemoryLayout<cmsghdr>.size))
}

func firstCmsg(_ header: inout msghdr) -> UnsafeMutablePointer<cmsghdr>? {
    guard header.msg_controllen >= MemoryLayout<cmsghdr>.size,
          let control = header.msg_control else {
        return nil
    }
    return control.assumingMemoryBound(to: cmsghdr.self)
}

func errnoMessage(_ operation: String) -> String {
    "\(operation) failed: \(String(cString: strerror(errno)))"
}
