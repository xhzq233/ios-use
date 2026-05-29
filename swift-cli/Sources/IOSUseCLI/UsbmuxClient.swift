import Darwin
import Foundation

enum Usbmux {
    struct Device: Equatable {
        let serialNumber: String
        let deviceID: Int
        let connectionType: String
        let properties: [String: Any]

        static func == (lhs: Device, rhs: Device) -> Bool {
            lhs.serialNumber == rhs.serialNumber
                && lhs.deviceID == rhs.deviceID
                && lhs.connectionType == rhs.connectionType
        }
    }

    static func listUsbDeviceUdids() throws -> [String] {
        try listUsbDevices().map(\.serialNumber)
    }

    static func listUsbDevices() throws -> [Device] {
        let fd = try openSocket()
        defer { Darwin.close(fd) }
        let list = try request(fd: fd, payload: [
            "MessageType": "ListDevices",
            "ProgName": "ios-use",
            "ClientVersionString": "1.0",
        ], tag: 0)
        guard let devices = list["DeviceList"] as? [[String: Any]] else {
            return []
        }
        return devices.compactMap { device in
            guard let props = device["Properties"] as? [String: Any],
                  let serial = props["SerialNumber"] as? String else { return nil }
            if let connectionType = props["ConnectionType"] as? String, connectionType != "USB" {
                return nil
            }
            let deviceID = (props["DeviceID"] as? Int) ?? (device["DeviceID"] as? Int) ?? 0
            return Device(
                serialNumber: serial,
                deviceID: deviceID,
                connectionType: props["ConnectionType"] as? String ?? "USB",
                properties: props
            )
        }
    }

    static func openSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIParseError.invalidValue("failed to open usbmux socket") }
        setSocketNoSigPipe(fd)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array("/var/run/usbmuxd".utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw CLIParseError.invalidValue("usbmux socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: path.count) { dst in
                for i in 0..<path.count { dst[i] = CChar(path[i]) }
            }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.count)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard result == 0 else {
            let err = errno
            Darwin.close(fd)
            throw CLIParseError.invalidValue("failed to connect usbmuxd: errno \(err)")
        }
        return fd
    }

    static func connect(udid: String, port: Int) throws -> Int32 {
        let fd = try openSocket()
        do {
            let list = try request(fd: fd, payload: [
                "MessageType": "ListDevices",
                "ProgName": "ios-use",
                "ClientVersionString": "1.0",
            ], tag: 0)
            guard let devices = list["DeviceList"] as? [[String: Any]] else {
                throw CLIParseError.invalidValue("usbmux ListDevices returned no devices")
            }
            let normalized = udid.replacingOccurrences(of: "-", with: "").lowercased()
            let match = devices.first { device in
                guard let props = device["Properties"] as? [String: Any],
                      let serial = props["SerialNumber"] as? String else { return false }
                return serial.replacingOccurrences(of: "-", with: "").lowercased() == normalized
            }
            guard let properties = match?["Properties"] as? [String: Any],
                  let deviceID = properties["DeviceID"] as? Int else {
                throw CLIParseError.invalidValue("Device \(udid) not found via usbmux. USB connection is required.")
            }
            let response = try request(fd: fd, payload: [
                "MessageType": "Connect",
                "ProgName": "ios-use",
                "ClientVersionString": "1.0",
                "DeviceID": deviceID,
                "PortNumber": swap16(port),
            ], tag: 1)
            guard (response["Number"] as? Int) == 0 else {
                throw CLIParseError.invalidValue("usbmux Connect failed with code \(response["Number"] ?? "unknown")")
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    static func request(fd: Int32, payload: [String: Any], tag: UInt32) throws -> [String: Any] {
        let body = try serializePlist(payload)
        var frame = Data()
        frame.append(uint32LE(UInt32(16 + body.count)))
        frame.append(uint32LE(1))
        frame.append(uint32LE(8))
        frame.append(uint32LE(tag))
        frame.append(body)
        try writeAll(fd: fd, data: frame)
        let header = try readExact(fd: fd, byteCount: 16, timeoutSeconds: 5)
        let size = Int(readUInt32LE(header, 0))
        guard size >= 16, size <= 10 * 1024 * 1024 else {
            throw CLIParseError.invalidValue("usbmux invalid response size: \(size)")
        }
        return try parsePlist(try readExact(fd: fd, byteCount: size - 16, timeoutSeconds: 5))
    }

    private static func swap16(_ value: Int) -> Int {
        ((value & 0xff) << 8) | ((value >> 8) & 0xff)
    }
}

func serializePlist(_ value: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}

func parsePlist(_ data: Data) throws -> [String: Any] {
    let raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    guard let dict = raw as? [String: Any] else {
        throw CLIParseError.invalidValue("plist response is not a dictionary")
    }
    return dict
}

func readExact(fd: Int32, byteCount: Int, timeoutSeconds: Double) throws -> Data {
    var out = Data()
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while out.count < byteCount {
        guard waitForReadable(fd: fd, timeoutSeconds: max(0, deadline.timeIntervalSinceNow)) else {
            throw CLIParseError.invalidValue("socket read timeout")
        }
        var buffer = [UInt8](repeating: 0, count: byteCount - out.count)
        let n = Darwin.read(fd, &buffer, buffer.count)
        if n > 0 {
            out.append(contentsOf: buffer.prefix(n))
        } else if n == 0 {
            throw CLIParseError.invalidValue("socket closed")
        } else if errno != EINTR && errno != EAGAIN {
            throw CLIParseError.invalidValue("socket read failed: errno \(errno)")
        }
    }
    return out
}

func writeAll(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let n = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
            if n > 0 {
                offset += n
            } else if n < 0, errno != EINTR && errno != EAGAIN {
                throw CLIParseError.invalidValue("socket write failed: errno \(errno)")
            }
        }
    }
}

func waitForReadable(fd: Int32, timeoutSeconds: Double) -> Bool {
    var set = fd_set()
    fdZero(&set)
    fdSet(fd, &set)
    var timeout = timeval(
        tv_sec: Int(timeoutSeconds),
        tv_usec: Int32((timeoutSeconds - floor(timeoutSeconds)) * 1_000_000)
    )
    return Darwin.select(fd + 1, &set, nil, nil, &timeout) > 0
}

func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL, 0)
    if flags >= 0 {
        let result = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        if ProcessInfo.processInfo.environment["IOS_USE_DEBUG_OSLOG"] == "1" {
            FileHandle.standardError.write(Data("[real-oslog] fcntl flags=\(flags) setNonBlocking=\(result) errno=\(errno)\n".utf8))
        }
    } else if ProcessInfo.processInfo.environment["IOS_USE_DEBUG_OSLOG"] == "1" {
        FileHandle.standardError.write(Data("[real-oslog] fcntl get failed errno=\(errno)\n".utf8))
    }
}

func setNoSigPipe(_ fd: Int32) {
    _ = fcntl(fd, F_SETNOSIGPIPE, 1)
}

func setSocketNoSigPipe(_ fd: Int32) {
    var noSigPipe: Int32 = 1
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
}

func fdZero(_ set: inout fd_set) {
    memset(&set, 0, MemoryLayout<fd_set>.size)
}

func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd / 32)
    let bitOffset = Int(fd % 32)
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            bits[intOffset] |= 1 << Int32(bitOffset)
        }
    }
}

func uint32LE(_ value: UInt32) -> Data {
    Data([
        UInt8(value & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 24) & 0xff),
    ])
}

func uint32BE(_ value: UInt32) -> Data {
    Data([
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ])
}

func uint64LE(_ value: UInt64) -> Data {
    Data([
        UInt8(value & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 32) & 0xff),
        UInt8((value >> 40) & 0xff),
        UInt8((value >> 48) & 0xff),
        UInt8((value >> 56) & 0xff),
    ])
}

func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
    let bytes = [UInt8](data)
    return UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32 {
    let bytes = [UInt8](data)
    return (UInt32(bytes[offset]) << 24)
        | (UInt32(bytes[offset + 1]) << 16)
        | (UInt32(bytes[offset + 2]) << 8)
        | UInt32(bytes[offset + 3])
}

func readUInt64LE(_ data: Data, _ offset: Int) -> UInt64 {
    let bytes = [UInt8](data)
    return UInt64(bytes[offset])
        | (UInt64(bytes[offset + 1]) << 8)
        | (UInt64(bytes[offset + 2]) << 16)
        | (UInt64(bytes[offset + 3]) << 24)
        | (UInt64(bytes[offset + 4]) << 32)
        | (UInt64(bytes[offset + 5]) << 40)
        | (UInt64(bytes[offset + 6]) << 48)
        | (UInt64(bytes[offset + 7]) << 56)
}
