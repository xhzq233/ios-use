#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation
import CoreFoundation
import IOSUseProtocol

enum AfcOpcode: UInt64 {
    case status = 0x01
    case data = 0x02
    case readDirectory = 0x03
    case removePath = 0x08
    case makeDirectory = 0x09
    case getFileInfo = 0x0a
    case fileOpen = 0x0d
    case fileOpenResult = 0x0e
    case read = 0x0f
    case write = 0x10
    case close = 0x14
    case makeLink = 0x1c
}

enum AfcEntryKind: String, Equatable, Sendable {
    case file
    case directory
    case symlink
    case other

    init(ifmt: String?) {
        switch ifmt {
        case "S_IFREG": self = .file
        case "S_IFDIR": self = .directory
        case "S_IFLNK": self = .symlink
        default: self = .other
        }
    }
}

struct AfcEntryInfo: Equatable, Sendable {
    let name: String
    let path: String
    let kind: AfcEntryKind
    let size: Int64
    let modifiedAtNanoseconds: Int64?
    let linkTarget: String?
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
    private var maxWriteChunkSize = IOSUseProtocol.XCConstants.afcInitialWriteChunkSize

    init(stream: DeviceStream) {
        self.stream = stream
    }

    static func withClient<T>(udid: String, _ body: (AfcClient) throws -> T) throws -> T {
        let stream = try LockdownSession.connectToService(IOSUseProtocol.XCConstants.afcServiceName, udid: udid)
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

    func removePathRecursive(_ path: String) throws {
        let normalized = normalizeDevicePath(path)
        guard let info = try? fileInfo(normalized) else {
            try? removePath(normalized)
            return
        }
        if info["st_ifmt"] == "S_IFDIR" {
            let children = (try? readDirectory(normalized)) ?? []
            for child in children where child != "." && child != ".." {
                try removePathRecursive(joinDevicePath(normalized, child))
            }
        }
        try removePath(normalized)
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
                case .status(.tooMuchData) where maxWriteChunkSize > IOSUseProtocol.XCConstants.afcFallbackWriteChunkSize:
                    maxWriteChunkSize = IOSUseProtocol.XCConstants.afcFallbackWriteChunkSize
                    try writeChunks(handle: handle, data: data, chunkSize: maxWriteChunkSize)
                default:
                    throw error
                }
            }
        }
    }

    func uploadDirectory(localPath: String, remotePath: String) throws {
        let localURL = URL(fileURLWithPath: localPath, isDirectory: true)
        let remotePath = normalizeDevicePath(remotePath)
        try makeDirectories(remotePath)
        let children = try FileManager.default.contentsOfDirectory(
            at: localURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for child in children {
            let remoteChild = joinDevicePath(remotePath, child.lastPathComponent)
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: child.path)
                try makeSymlink(target: target, linkPath: remoteChild)
            } else if values.isDirectory == true {
                try uploadDirectory(localPath: child.path, remotePath: remoteChild)
            } else if values.isRegularFile == true {
                try uploadFile(localPath: child.path, remotePath: remoteChild)
            }
        }
    }

    func readDirectory(_ path: String) throws -> [String] {
        let response = try request(.readDirectory, payload: cString(normalizeDevicePath(path)))
        guard response.opcode == AfcOpcode.data.rawValue else {
            throw AfcClientError.unexpectedOpcode(response.opcode)
        }
        return nullSeparatedStrings(response.payload)
    }

    func fileInfo(_ path: String) throws -> [String: String] {
        let response = try request(.getFileInfo, payload: cString(normalizeDevicePath(path)))
        guard response.opcode == AfcOpcode.data.rawValue else {
            throw AfcClientError.unexpectedOpcode(response.opcode)
        }
        let fields = nullSeparatedStrings(response.payload)
        var result: [String: String] = [:]
        var index = 0
        while index + 1 < fields.count {
            result[fields[index]] = fields[index + 1]
            index += 2
        }
        return result
    }

    func makeSymlink(target: String, linkPath: String) throws {
        var payload = uint64LE(2)
        payload.append(cString(target))
        payload.append(cString(normalizeDevicePath(linkPath)))
        try request(.makeLink, payload: payload)
    }

    func openFile(_ path: String) throws -> UInt64 {
        try openFile(path, mode: IOSUseProtocol.XCConstants.afcFileOpenModeWriteOnly)
    }

    func openFileForReading(_ path: String) throws -> UInt64 {
        try openFile(path, mode: IOSUseProtocol.XCConstants.afcFileOpenModeReadOnly)
    }

    private func openFile(_ path: String, mode: UInt64) throws -> UInt64 {
        var payload = uint64LE(mode)
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

    func read(handle: UInt64, maxLength: UInt64 = IOSUseProtocol.XCConstants.afcReadChunkSize) throws -> Data {
        var payload = uint64LE(handle)
        payload.append(uint64LE(maxLength))
        do {
            let response = try request(.read, payload: payload)
            switch response.opcode {
            case AfcOpcode.data.rawValue:
                return response.payload
            case AfcOpcode.status.rawValue:
                return Data()
            default:
                throw AfcClientError.unexpectedOpcode(response.opcode)
            }
        } catch AfcClientError.status(.endOfData) {
            return Data()
        }
    }

    func statEntry(_ path: String) throws -> AfcEntryInfo {
        let normalized = normalizeDevicePath(path)
        let info = try fileInfo(normalized)
        let name: String
        if normalized == "/" {
            name = "/"
        } else {
            name = normalized.split(separator: "/").last.map(String.init) ?? normalized
        }
        return AfcEntryInfo(
            name: name,
            path: normalized,
            kind: AfcEntryKind(ifmt: info["st_ifmt"]),
            size: Int64(info["st_size"] ?? "") ?? 0,
            modifiedAtNanoseconds: info["st_mtime"].flatMap(Int64.init),
            linkTarget: info["LinkTarget"]
        )
    }

    func removeExistingPath(_ path: String) throws {
        try request(.removePath, payload: cString(normalizeDevicePath(path)))
    }

    func removeExistingPathRecursive(_ path: String) throws {
        let normalized = normalizeDevicePath(path)
        let entry = try statEntry(normalized)
        if entry.kind == .directory {
            let children = try readDirectory(normalized)
            for child in children where child != "." && child != ".." {
                try validateSafeChildName(child)
                try removeExistingPathRecursive(joinDevicePath(normalized, child))
            }
        }
        try removeExistingPath(normalized)
    }

    func downloadFile(remotePath: String, localPath: String) throws -> Int64 {
        let normalizedRemote = normalizeDevicePath(remotePath)
        let localURL = URL(fileURLWithPath: localPath).standardizedFileURL
        var destStat = stat()
        if lstat(localURL.path, &destStat) == 0 && (destStat.st_mode & S_IFMT) == S_IFLNK {
            throw CLIParseError.invalidValue("Refusing to overwrite symbolic link destination: \(localURL.path)")
        }

        let parentURL = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)

        let handle = try openFileForReading(normalizedRemote)
        defer { try? closeFile(handle) }

        let tempURL = parentURL.appendingPathComponent(".ios-use-pull-\(UUID().uuidString).tmp")
        let fd = open(
            tempURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        )
        guard fd >= 0 else {
            throw CLIParseError.invalidValue("Unable to create local file \(tempURL.path): errno \(errno)")
        }
        var shouldRemoveTemp = true
        var fdClosed = false
        defer {
            if !fdClosed {
                _ = posixClose(fd)
            }
            if shouldRemoveTemp {
                _ = unlink(tempURL.path)
            }
        }

        var totalBytes: Int64 = 0
        while true {
            let chunk = try read(handle: handle)
            if chunk.isEmpty {
                break
            }
            try writeAllToDescriptor(fd, data: chunk, destinationPath: localURL.path)
            totalBytes += Int64(chunk.count)
        }

        _ = posixClose(fd)
        fdClosed = true
        guard rename(tempURL.path, localURL.path) == 0 else {
            throw CLIParseError.invalidValue("Unable to move downloaded file to \(localURL.path): errno \(errno)")
        }
        shouldRemoveTemp = false
        return totalBytes
    }

    func downloadDirectory(
        remotePath: String,
        localPath: String,
        warnings: inout [String]
    ) throws -> (fileCount: Int, byteCount: Int64) {
        let normalizedRemote = normalizeDevicePath(remotePath)
        let localURL = URL(fileURLWithPath: localPath, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)

        let children = try readDirectory(normalizedRemote)
            .filter { $0 != "." && $0 != ".." }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var totalFiles = 0
        var totalBytes: Int64 = 0
        for child in children {
            try validateSafeChildName(child)
            let remoteChild = joinDevicePath(normalizedRemote, child)
            let localChild = localURL.appendingPathComponent(child).path
            let entry = try statEntry(remoteChild)
            switch entry.kind {
            case .directory:
                let sub = try downloadDirectory(remotePath: remoteChild, localPath: localChild, warnings: &warnings)
                totalFiles += sub.fileCount
                totalBytes += sub.byteCount
            case .file:
                totalBytes += try downloadFile(remotePath: remoteChild, localPath: localChild)
                totalFiles += 1
            case .symlink:
                warnings.append("Skipped symbolic link \(remoteChild)")
            case .other:
                warnings.append("Skipped non-regular entry \(remoteChild)")
            }
        }
        return (totalFiles, totalBytes)
    }

    func pushFileWithStats(localPath: String, remotePath: String) throws -> (fileCount: Int, byteCount: Int64) {
        let attrs = try FileManager.default.attributesOfItem(atPath: localPath)
        let byteCount = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        try uploadFile(localPath: localPath, remotePath: remotePath)
        return (1, byteCount)
    }

    func pushDirectoryWithStats(
        localPath: String,
        remotePath: String,
        warnings: inout [String]
    ) throws -> (fileCount: Int, byteCount: Int64) {
        let localURL = URL(fileURLWithPath: localPath, isDirectory: true).standardizedFileURL
        let normalizedRemote = normalizeDevicePath(remotePath)
        try makeDirectories(normalizedRemote)
        let children = try FileManager.default.contentsOfDirectory(
            at: localURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var totalFiles = 0
        var totalBytes: Int64 = 0
        for child in children {
            let remoteChild = joinDevicePath(normalizedRemote, child.lastPathComponent)
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                warnings.append("Skipped host symbolic link \(child.path)")
            } else if values.isDirectory == true {
                let sub = try pushDirectoryWithStats(localPath: child.path, remotePath: remoteChild, warnings: &warnings)
                totalFiles += sub.fileCount
                totalBytes += sub.byteCount
            } else if values.isRegularFile == true {
                let result = try pushFileWithStats(localPath: child.path, remotePath: remoteChild)
                totalFiles += result.fileCount
                totalBytes += result.byteCount
            }
        }
        return (totalFiles, totalBytes)
    }

    private func writeAllToDescriptor(_ fd: Int32, data: Data, destinationPath: String) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = posixWrite(fd, base.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw CLIParseError.invalidValue("Unable to write local file \(destinationPath): errno \(errno)")
                }
            }
        }
    }

    private func validateSafeChildName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0") else {
            throw CLIParseError.invalidValue("Unsafe remote entry name: \(name)")
        }
    }

    func write(handle: UInt64, data: Data) throws {
        var payload = uint64LE(handle)
        payload.append(data)
        try request(.write, payload: payload, thisLength: IOSUseProtocol.XCConstants.afcWriteRequestHeaderLength)
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
        let headerLength = UInt64(IOSUseProtocol.XCConstants.afcHeaderByteCount)
        let requestEntireLength = headerLength + UInt64(payload.count)

        var packet = Data(IOSUseProtocol.XCConstants.afcPacketMagic.utf8)
        packet.append(uint64LE(requestEntireLength))
        packet.append(uint64LE(thisLength ?? requestEntireLength))
        packet.append(uint64LE(packetNumber))
        packet.append(uint64LE(opcode.rawValue))
        packet.append(payload)
        try stream.write(packet)

        let header = try stream.readExact(
            byteCount: IOSUseProtocol.XCConstants.afcHeaderByteCount,
            timeoutSeconds: IOSUseProtocol.XCConstants.afcReadTimeoutSeconds
        )
        guard Data(header.prefix(8)) == Data(IOSUseProtocol.XCConstants.afcPacketMagic.utf8) else {
            throw AfcClientError.invalidMagic
        }
        let entireLength = readUInt64LE(header, 8)
        let responseHeaderLength = readUInt64LE(header, 16)
        let responseOpcode = readUInt64LE(header, 32)
        guard entireLength >= responseHeaderLength,
              responseHeaderLength >= headerLength,
              entireLength <= IOSUseProtocol.XCConstants.afcMaxResponseBytes else {
            throw AfcClientError.invalidLength(entireLength)
        }

        let payloadCount = Int(entireLength - headerLength)
        let responsePayload = payloadCount == 0 ? Data() : try stream.readExact(
            byteCount: payloadCount,
            timeoutSeconds: IOSUseProtocol.XCConstants.afcReadTimeoutSeconds
        )
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

    private func joinDevicePath(_ base: String, _ child: String) -> String {
        let normalized = normalizeDevicePath(base)
        return normalized.isEmpty ? child : "\(normalized)/\(child)"
    }

    private func parentDevicePath(_ path: String) -> String? {
        let normalized = normalizeDevicePath(path)
        guard let slash = normalized.lastIndex(of: "/") else {
            return nil
        }
        return String(normalized[..<slash])
    }

    private func nullSeparatedStrings(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: true).compactMap {
            String(data: Data($0), encoding: .utf8)
        }
    }
}
