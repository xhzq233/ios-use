import Foundation

/// Transaction-safe subset of PlayCover's Mach-O conversion.
///
/// The conversion model is derived from PlayCover's `Macho.swift` at
/// 7190cc9ce57c8dee0e222918468f2579acc95e1b (GPL-3.0). This implementation
/// keeps the original file layout and only rewrites verified header padding.
public enum PlayCoverMachO {
    static let magic64: UInt32 = 0xfeedfacf
    static let cpuTypeArm64: Int32 = 0x0100_000c
    static let loadSegment64: UInt32 = 0x19
    static let loadVersionMinMacOS: UInt32 = 0x24
    static let loadVersionMinIPhoneOS: UInt32 = 0x25
    static let loadEncryptionInfo: UInt32 = 0x21
    static let loadEncryptionInfo64: UInt32 = 0x2c
    static let loadBuildVersion: UInt32 = 0x32
    static let loadDylib: UInt32 = 0x0c
    static let platformIPhoneOS: UInt32 = 2
    public static let platformMacCatalyst: UInt32 = 6

    public static let runtimeLoadPath =
        "@executable_path/Frameworks/IOSUsePlayRuntime.framework/IOSUsePlayRuntime"

    private static let headerSize = 32
    private static let segment64Size = 72
    private static let section64Size = 80
    private static let maximumLoadCommandBytes = 16 * 1024 * 1024
    private static let maximumHeaderPrefixBytes = 64 * 1024 * 1024

    public static func isThinArm64MachO(at url: URL) throws -> Bool {
        let header = try readPrefix(at: url, count: headerSize)
        guard header.count >= 8 else { return false }
        return try header.readUInt32(at: 0) == magic64
            && Int32(bitPattern: try header.readUInt32(at: 4)) == cpuTypeArm64
    }

    public static func inspect(
        at url: URL,
        injectedRuntimePath: String = runtimeLoadPath
    ) throws -> PlayCoverMachOInspection {
        let document = try readDocument(at: url)
        return inspection(document: document, path: url.path, injectedRuntimePath: injectedRuntimePath)
    }

    /// Converts one thin arm64 iPhoneOS Mach-O in place.
    ///
    /// Exactly one runtime dependency is appended when `injectRuntime` is true.
    /// The method validates every byte it needs to consume after the existing
    /// load commands before opening the file for writing.
    @discardableResult
    public static func convert(
        at url: URL,
        injectRuntime: Bool,
        injectedRuntimePath: String = runtimeLoadPath
    ) throws -> PlayCoverMachOInspection {
        let document = try readDocument(at: url)
        let before = inspection(document: document, path: url.path, injectedRuntimePath: injectedRuntimePath)
        if before.encrypted {
            throw PlayCoverBackendError.encryptedMachO(url.path)
        }

        let versionIndices = document.commands.indices.filter {
            isVersionCommand(document.commands[$0].command)
        }
        guard let versionIndex = versionIndices.last else {
            throw PlayCoverBackendError.unsupportedMachO("\(url.path) has no iPhoneOS build-version command")
        }

        if let platform = before.platform,
           platform != platformIPhoneOS,
           platform != platformMacCatalyst {
            throw PlayCoverBackendError.unsupportedMachO(
                "\(url.path) declares platform \(platform), expected iPhoneOS or Mac Catalyst"
            )
        }

        var commandData = document.commands.map(\.data)
        if before.platform != platformMacCatalyst {
            commandData[versionIndex] = makeMacCatalystBuildVersion()
        }

        if injectRuntime && !before.runtimeInjected {
            commandData.append(makeDylibCommand(path: injectedRuntimePath))
        }

        let rebuiltCommands = commandData.reduce(into: Data()) { partial, command in
            partial.append(command)
        }
        let commandCapacity = Int(document.firstSectionOffset) - headerSize
        guard rebuiltCommands.count <= commandCapacity else {
            throw PlayCoverBackendError.insufficientLoadCommandSpace(
                required: rebuiltCommands.count,
                available: commandCapacity
            )
        }

        let previousCommandsEnd = headerSize + Int(document.header.sizeOfCommands)
        let rebuiltCommandsEnd = headerSize + rebuiltCommands.count
        if rebuiltCommandsEnd > previousCommandsEnd {
            let consumedPadding = document.prefix[previousCommandsEnd..<rebuiltCommandsEnd]
            guard consumedPadding.allSatisfy({ $0 == 0 }) else {
                throw PlayCoverBackendError.nonZeroLoadCommandPadding(url.path)
            }
        }

        var rewrittenPrefix = document.prefix
        rewrittenPrefix.writeUInt32(
            UInt32(commandData.count),
            at: 16
        )
        rewrittenPrefix.writeUInt32(
            UInt32(rebuiltCommands.count),
            at: 20
        )
        rewrittenPrefix.replaceSubrange(
            headerSize..<rebuiltCommandsEnd,
            with: rebuiltCommands
        )
        if rebuiltCommandsEnd < previousCommandsEnd {
            rewrittenPrefix.replaceSubrange(
                rebuiltCommandsEnd..<previousCommandsEnd,
                with: Data(repeating: 0, count: previousCommandsEnd - rebuiltCommandsEnd)
            )
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw PlayCoverBackendError.prepareFailed("cannot open \(url.path) for writing: \(error)")
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: rewrittenPrefix)
            try handle.synchronize()
        } catch {
            throw PlayCoverBackendError.prepareFailed("cannot rewrite \(url.path): \(error)")
        }

        let after = try inspect(at: url, injectedRuntimePath: injectedRuntimePath)
        guard after.isMacCatalyst else {
            throw PlayCoverBackendError.verificationFailed("\(url.path) was not converted to Mac Catalyst")
        }
        if injectRuntime && !after.runtimeInjected {
            throw PlayCoverBackendError.verificationFailed("\(url.path) does not load the ios-use runtime")
        }
        return after
    }

    private struct Header {
        let cpuType: Int32
        let fileType: UInt32
        let commandCount: UInt32
        let sizeOfCommands: UInt32
    }

    private struct Command {
        let command: UInt32
        let data: Data
        let path: String?
    }

    private struct Document {
        let fileSize: UInt64
        let header: Header
        let commands: [Command]
        let firstSectionOffset: UInt64
        let prefix: Data
        let platform: UInt32?
        let minimumOS: UInt32?
        let sdk: UInt32?
        let encrypted: Bool
    }

    private static func readDocument(at url: URL) throws -> Document {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw PlayCoverBackendError.invalidApp("cannot inspect \(url.path): \(error)")
        }
        guard values.isRegularFile == true, let rawFileSize = values.fileSize, rawFileSize >= headerSize else {
            throw PlayCoverBackendError.unsupportedMachO("\(url.path) is not a regular 64-bit Mach-O file")
        }
        let fileSize = UInt64(rawFileSize)
        let headerData = try readPrefix(at: url, count: headerSize)
        guard try headerData.readUInt32(at: 0) == magic64 else {
            throw PlayCoverBackendError.unsupportedMachO("\(url.path) is not a thin little-endian 64-bit Mach-O")
        }
        let cpuType = Int32(bitPattern: try headerData.readUInt32(at: 4))
        guard cpuType == cpuTypeArm64 else {
            throw PlayCoverBackendError.unsupportedMachO("\(url.path) is not arm64")
        }
        let header = Header(
            cpuType: cpuType,
            fileType: try headerData.readUInt32(at: 12),
            commandCount: try headerData.readUInt32(at: 16),
            sizeOfCommands: try headerData.readUInt32(at: 20)
        )
        guard header.commandCount > 0,
              header.sizeOfCommands >= 8,
              header.sizeOfCommands <= maximumLoadCommandBytes else {
            throw PlayCoverBackendError.malformedMachO("\(url.path) has invalid load-command counts")
        }
        let commandEnd = headerSize + Int(header.sizeOfCommands)
        guard UInt64(commandEnd) < fileSize else {
            throw PlayCoverBackendError.malformedMachO("\(url.path) load commands exceed the file")
        }

        let commandRegion = try readRange(
            at: url,
            offset: UInt64(headerSize),
            count: Int(header.sizeOfCommands)
        )
        var cursor = 0
        var commands: [Command] = []
        var firstSectionOffset = fileSize
        var platform: UInt32?
        var minimumOS: UInt32?
        var sdk: UInt32?
        var encrypted = false

        for index in 0..<Int(header.commandCount) {
            guard cursor + 8 <= commandRegion.count else {
                throw PlayCoverBackendError.malformedMachO(
                    "\(url.path) load command \(index) has no complete header"
                )
            }
            let command = try commandRegion.readUInt32(at: cursor)
            let commandSize = Int(try commandRegion.readUInt32(at: cursor + 4))
            guard commandSize >= 8,
                  commandSize % 4 == 0,
                  cursor + commandSize <= commandRegion.count else {
                throw PlayCoverBackendError.malformedMachO(
                    "\(url.path) load command \(index) has invalid size \(commandSize)"
                )
            }

            if command == loadSegment64 {
                guard commandSize >= segment64Size else {
                    throw PlayCoverBackendError.malformedMachO(
                        "\(url.path) contains a truncated LC_SEGMENT_64"
                    )
                }
                let sectionCount = Int(try commandRegion.readUInt32(at: cursor + 64))
                let requiredSize = segment64Size + sectionCount * section64Size
                guard requiredSize <= commandSize else {
                    throw PlayCoverBackendError.malformedMachO(
                        "\(url.path) contains truncated section records"
                    )
                }
                for sectionIndex in 0..<sectionCount {
                    let section = cursor + segment64Size + sectionIndex * section64Size
                    let fileOffset = UInt64(try commandRegion.readUInt32(at: section + 48))
                    if fileOffset > 0 {
                        firstSectionOffset = min(firstSectionOffset, fileOffset)
                    }
                }
            } else if command == loadBuildVersion {
                guard commandSize >= 24 else {
                    throw PlayCoverBackendError.malformedMachO(
                        "\(url.path) contains a truncated LC_BUILD_VERSION"
                    )
                }
                platform = try commandRegion.readUInt32(at: cursor + 8)
                minimumOS = try commandRegion.readUInt32(at: cursor + 12)
                sdk = try commandRegion.readUInt32(at: cursor + 16)
            } else if command == loadVersionMinIPhoneOS {
                guard commandSize >= 16 else {
                    throw PlayCoverBackendError.malformedMachO(
                        "\(url.path) contains a truncated LC_VERSION_MIN_IPHONEOS"
                    )
                }
                platform = platformIPhoneOS
                minimumOS = try commandRegion.readUInt32(at: cursor + 8)
                sdk = try commandRegion.readUInt32(at: cursor + 12)
            } else if command == loadVersionMinMacOS {
                guard commandSize >= 16 else {
                    throw PlayCoverBackendError.malformedMachO(
                        "\(url.path) contains a truncated LC_VERSION_MIN_MACOSX"
                    )
                }
                platform = 1
                minimumOS = try commandRegion.readUInt32(at: cursor + 8)
                sdk = try commandRegion.readUInt32(at: cursor + 12)
            } else if command == loadEncryptionInfo || command == loadEncryptionInfo64 {
                guard commandSize >= 20 else {
                    throw PlayCoverBackendError.malformedMachO(
                        "\(url.path) contains a truncated encryption command"
                    )
                }
                let cryptID = try commandRegion.readUInt32(at: cursor + 16)
                encrypted = encrypted || cryptID != 0
            }

            let bytes = Data(commandRegion[cursor..<(cursor + commandSize)])
            commands.append(
                Command(
                    command: command,
                    data: bytes,
                    path: dylibPath(command: command, data: bytes)
                )
            )
            cursor += commandSize
        }

        guard cursor == commandRegion.count else {
            throw PlayCoverBackendError.malformedMachO(
                "\(url.path) command count and sizeofcmds disagree"
            )
        }
        guard firstSectionOffset > UInt64(commandEnd),
              firstSectionOffset <= fileSize,
              firstSectionOffset <= UInt64(maximumHeaderPrefixBytes) else {
            throw PlayCoverBackendError.malformedMachO(
                "\(url.path) has no safe bounded header padding"
            )
        }

        let prefix = try readPrefix(at: url, count: Int(firstSectionOffset))
        return Document(
            fileSize: fileSize,
            header: header,
            commands: commands,
            firstSectionOffset: firstSectionOffset,
            prefix: prefix,
            platform: platform,
            minimumOS: minimumOS,
            sdk: sdk,
            encrypted: encrypted
        )
    }

    private static func inspection(
        document: Document,
        path: String,
        injectedRuntimePath: String
    ) -> PlayCoverMachOInspection {
        let commandEnd = UInt64(headerSize) + UInt64(document.header.sizeOfCommands)
        return PlayCoverMachOInspection(
            path: path,
            cpuType: document.header.cpuType,
            fileType: document.header.fileType,
            commandCount: document.header.commandCount,
            commandBytes: document.header.sizeOfCommands,
            firstSectionOffset: document.firstSectionOffset,
            availableCommandPadding: document.firstSectionOffset - commandEnd,
            platform: document.platform,
            minimumOS: document.minimumOS,
            sdk: document.sdk,
            encrypted: document.encrypted,
            runtimeInjected: document.commands.contains { $0.path == injectedRuntimePath }
        )
    }

    private static func isVersionCommand(_ command: UInt32) -> Bool {
        command == loadBuildVersion
            || command == loadVersionMinIPhoneOS
            || command == loadVersionMinMacOS
    }

    private static func makeMacCatalystBuildVersion() -> Data {
        var data = Data(repeating: 0, count: 24)
        data.writeUInt32(loadBuildVersion, at: 0)
        data.writeUInt32(24, at: 4)
        data.writeUInt32(platformMacCatalyst, at: 8)
        data.writeUInt32(0x000b_0000, at: 12)
        data.writeUInt32(0x000e_0000, at: 16)
        data.writeUInt32(0, at: 20)
        return data
    }

    private static func makeDylibCommand(path: String) -> Data {
        let string = Data(path.utf8) + Data([0])
        let unalignedSize = 24 + string.count
        let commandSize = (unalignedSize + 7) & ~7
        var data = Data(repeating: 0, count: commandSize)
        data.writeUInt32(loadDylib, at: 0)
        data.writeUInt32(UInt32(commandSize), at: 4)
        data.writeUInt32(24, at: 8)
        data.replaceSubrange(24..<(24 + string.count), with: string)
        return data
    }

    private static func dylibPath(command: UInt32, data: Data) -> String? {
        let dylibCommands: Set<UInt32> = [
            loadDylib,
            0x18 | 0x8000_0000, // LC_LOAD_WEAK_DYLIB
            0x1f | 0x8000_0000, // LC_REEXPORT_DYLIB
            0x20,               // LC_LAZY_LOAD_DYLIB
            0x23 | 0x8000_0000, // LC_LOAD_UPWARD_DYLIB
        ]
        guard dylibCommands.contains(command), data.count >= 24,
              let nameOffset = try? data.readUInt32(at: 8),
              nameOffset >= 24,
              Int(nameOffset) < data.count else {
            return nil
        }
        let bytes = data[Int(nameOffset)...].prefix { $0 != 0 }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func readPrefix(at url: URL, count: Int) throws -> Data {
        try readRange(at: url, offset: 0, count: count)
    }

    private static func readRange(at url: URL, offset: UInt64, count: Int) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PlayCoverBackendError.invalidApp("cannot open \(url.path): \(error)")
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else {
                throw PlayCoverBackendError.malformedMachO(
                    "\(url.path) ended while reading \(count) bytes at offset \(offset)"
                )
            }
            return data
        } catch let error as PlayCoverBackendError {
            throw error
        } catch {
            throw PlayCoverBackendError.invalidApp("cannot read \(url.path): \(error)")
        }
    }
}

private extension Data {
    func readUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw PlayCoverBackendError.malformedMachO("integer read is outside the available data")
        }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        precondition(offset >= 0 && offset + 4 <= count)
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
