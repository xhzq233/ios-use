import Foundation

enum AfcOpcode: UInt64 {
    case status = 0x01
    case data = 0x02
    case removePath = 0x08
    case makeDirectory = 0x09
    case fileOpen = 0x0d
    case fileOpenResult = 0x0e
    case write = 0x10
    case close = 0x14
}

enum AfcStatus: UInt64, CustomStringConvertible {
    case success = 0
    case unknownError = 1
    case opHeaderInvalid = 2
    case noResources = 3
    case readError = 4
    case writeError = 5
    case unknownPacketType = 6
    case invalidArgument = 7
    case objectNotFound = 8
    case objectIsDirectory = 9
    case permissionDenied = 10
    case serviceNotConnected = 11
    case operationTimeout = 12
    case tooMuchData = 13
    case endOfData = 14
    case operationNotSupported = 15
    case objectExists = 16
    case objectBusy = 17
    case noSpaceLeft = 18
    case operationWouldBlock = 19
    case ioError = 20
    case operationInterrupted = 21
    case operationInProgress = 22
    case internalError = 23
    case muxError = 30
    case noMemory = 31
    case notEnoughData = 32
    case directoryNotEmpty = 33

    var description: String {
        switch self {
        case .success: return "SUCCESS"
        case .unknownError: return "UNKNOWN_ERROR"
        case .opHeaderInvalid: return "OP_HEADER_INVALID"
        case .noResources: return "NO_RESOURCES"
        case .readError: return "READ_ERROR"
        case .writeError: return "WRITE_ERROR"
        case .unknownPacketType: return "UNKNOWN_PACKET_TYPE"
        case .invalidArgument: return "INVALID_ARG"
        case .objectNotFound: return "OBJECT_NOT_FOUND"
        case .objectIsDirectory: return "OBJECT_IS_DIR"
        case .permissionDenied: return "PERM_DENIED"
        case .serviceNotConnected: return "SERVICE_NOT_CONNECTED"
        case .operationTimeout: return "OP_TIMEOUT"
        case .tooMuchData: return "TOO_MUCH_DATA"
        case .endOfData: return "END_OF_DATA"
        case .operationNotSupported: return "OP_NOT_SUPPORTED"
        case .objectExists: return "OBJECT_EXISTS"
        case .objectBusy: return "OBJECT_BUSY"
        case .noSpaceLeft: return "NO_SPACE_LEFT"
        case .operationWouldBlock: return "OP_WOULD_BLOCK"
        case .ioError: return "IO_ERROR"
        case .operationInterrupted: return "OP_INTERRUPTED"
        case .operationInProgress: return "OP_IN_PROGRESS"
        case .internalError: return "INTERNAL_ERROR"
        case .muxError: return "MUX_ERROR"
        case .noMemory: return "NO_MEM"
        case .notEnoughData: return "NOT_ENOUGH_DATA"
        case .directoryNotEmpty: return "DIR_NOT_EMPTY"
        }
    }
}

enum AfcClientError: Error, CustomStringConvertible, Equatable {
    case invalidMagic
    case invalidLength(UInt64)
    case status(AfcStatus)
    case unknownStatus(UInt64)
    case unexpectedOpcode(UInt64)
    case missingFileHandle

    var description: String {
        switch self {
        case .invalidMagic: return "AFC invalid packet magic"
        case .invalidLength(let length): return "AFC invalid packet length: \(length)"
        case .status(let status): return "AFC operation failed: \(status)"
        case .unknownStatus(let value): return "AFC operation failed with unknown status: \(value)"
        case .unexpectedOpcode(let opcode): return "AFC unexpected response opcode: \(opcode)"
        case .missingFileHandle: return "AFC file open returned no handle"
        }
    }
}

final class AfcClient {
    private let stream: DeviceStream
    private var packetNumber: UInt64 = 1
    private var maxWriteChunkSize = 512 * 1024

    init(stream: DeviceStream) {
        self.stream = stream
    }

    static func withClient<T>(udid: String, _ body: (AfcClient) throws -> T) throws -> T {
        let stream = try LockdownSession.connectToService("com.apple.afc", udid: udid)
        defer { stream.close() }
        return try body(AfcClient(stream: stream))
    }

    func makeDirectories(_ path: String) throws {
        let normalized = normalizeDevicePath(path)
        let parts = normalized.split(separator: "/").map(String.init)
        var current = path.hasPrefix("/") ? "/" : ""
        for part in parts {
            if current.isEmpty || current == "/" {
                current += String(part)
            } else {
                current += "/\(part)"
            }
            do {
                try request(.makeDirectory, payload: cString(current))
            } catch AfcClientError.status(.objectExists) {
                continue
            } catch AfcClientError.status(.objectNotFound) {
                continue
            }
        }
    }

    func removePath(_ path: String) throws {
        do {
            try request(.removePath, payload: cString(normalizeDevicePath(path)))
        } catch AfcClientError.status(.objectNotFound) {
            return
        }
    }

    func uploadFile(localPath: String, remotePath: String) throws {
        let remotePath = normalizeDevicePath(remotePath)
        let parent = parentDevicePath(remotePath)
        if let parent, parent != "/" {
            try makeDirectories(parent)
        }
        let handle = try openFile(remotePath)
        defer { try? closeFile(handle) }

        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: localPath))
        defer { try? file.close() }
        while true {
            let data = try file.read(upToCount: maxWriteChunkSize) ?? Data()
            if data.isEmpty {
                return
            }
            do {
                try write(handle: handle, data: data)
            } catch let error as AfcClientError {
                switch error {
                case .status(.tooMuchData) where maxWriteChunkSize > 64 * 1024:
                    maxWriteChunkSize = 64 * 1024
                    try writeChunks(handle: handle, data: data, chunkSize: maxWriteChunkSize)
                default:
                    throw error
                }
            }
        }
    }

    func openFile(_ path: String) throws -> UInt64 {
        var payload = uint64LE(3)
        payload.append(cString(normalizeDevicePath(path)))
        let response = try request(.fileOpen, payload: payload)
        guard response.opcode == AfcOpcode.fileOpenResult.rawValue else {
            throw AfcClientError.unexpectedOpcode(response.opcode)
        }
        guard response.payload.count >= 8 else {
            throw AfcClientError.missingFileHandle
        }
        return readUInt64LE(response.payload, 0)
    }

    func write(handle: UInt64, data: Data) throws {
        var payload = uint64LE(handle)
        payload.append(data)
        try request(.write, payload: payload, thisLength: 48)
    }

    private func writeChunks(handle: UInt64, data: Data, chunkSize: Int) throws {
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            try write(handle: handle, data: data.subdata(in: offset..<end))
            offset = end
        }
    }

    func closeFile(_ handle: UInt64) throws {
        try request(.close, payload: uint64LE(handle))
    }

    @discardableResult
    private func request(_ opcode: AfcOpcode, payload: Data = Data(), thisLength: UInt64? = nil) throws -> (opcode: UInt64, payload: Data) {
        let packetNumber = self.packetNumber
        self.packetNumber += 1
        let requestEntireLength = 40 + UInt64(payload.count)

        var packet = Data("CFA6LPAA".utf8)
        packet.append(uint64LE(requestEntireLength))
        packet.append(uint64LE(thisLength ?? requestEntireLength))
        packet.append(uint64LE(packetNumber))
        packet.append(uint64LE(opcode.rawValue))
        packet.append(payload)
        try stream.write(packet)

        let header = try stream.readExact(byteCount: 40, timeoutSeconds: 30)
        guard Data(header.prefix(8)) == Data("CFA6LPAA".utf8) else {
            throw AfcClientError.invalidMagic
        }
        let entireLength = readUInt64LE(header, 8)
        let responseHeaderLength = readUInt64LE(header, 16)
        let responseOpcode = readUInt64LE(header, 32)
        guard entireLength >= responseHeaderLength, responseHeaderLength >= 40, entireLength <= 256 * 1024 * 1024 else {
            throw AfcClientError.invalidLength(entireLength)
        }

        let payloadCount = Int(entireLength - 40)
        let responsePayload = payloadCount == 0 ? Data() : try stream.readExact(byteCount: payloadCount, timeoutSeconds: 30)
        if responseOpcode == AfcOpcode.status.rawValue {
            let rawStatus = responsePayload.count >= 8 ? readUInt64LE(responsePayload, 0) : 0
            if rawStatus == AfcStatus.success.rawValue {
                return (responseOpcode, responsePayload)
            }
            guard let status = AfcStatus(rawValue: rawStatus) else {
                throw AfcClientError.unknownStatus(rawStatus)
            }
            throw AfcClientError.status(status)
        }
        return (responseOpcode, responsePayload)
    }

    private func cString(_ value: String) -> Data {
        var data = Data(value.utf8)
        data.append(0)
        return data
    }

    private func normalizeDevicePath(_ path: String) -> String {
        let normalized = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
        guard path.hasPrefix("/") else {
            return normalized
        }
        return "/" + normalized
    }

    private func parentDevicePath(_ path: String) -> String? {
        let normalized = normalizeDevicePath(path)
        guard let slash = normalized.lastIndex(of: "/") else {
            return nil
        }
        return String(normalized[..<slash])
    }
}
