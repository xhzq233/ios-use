import Foundation
import IOSUseProtocol
#if canImport(Darwin)
import Darwin
#endif

struct PlayCoverMediaImportProcessResult: Equatable, Sendable {
    let exitStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

enum PlayCoverMediaImportProcessRunnerError:
    Error, Equatable, CustomStringConvertible, Sendable {
    case unavailable(String)
    case timedOut(String)

    var description: String {
        switch self {
        case .unavailable(let detail):
            return detail
        case .timedOut(let detail):
            return detail
        }
    }
}

protocol PlayCoverMediaImportProcessRunning {
    func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) throws -> PlayCoverMediaImportProcessResult
}

struct PlayCoverMediaImportStagedFile: Equatable, Sendable {
    let path: String
    let directoryName: String
    let filename: String
    let directoryDevice: UInt64
    let directoryInode: UInt64
    let fileDevice: UInt64
    let fileInode: UInt64
}

protocol PlayCoverMediaImportFileSystem {
    func stage(
        data: Data,
        originalFilename: String,
        inRunDirectory runDirectory: String
    ) throws -> PlayCoverMediaImportStagedFile

    func verifyIdentity(
        of stagedFile: PlayCoverMediaImportStagedFile,
        inRunDirectory runDirectory: String
    ) throws

    func cleanup(
        _ stagedFile: PlayCoverMediaImportStagedFile,
        inRunDirectory runDirectory: String
    ) throws
}

enum PlayCoverMediaImportAdapterError:
    Error, Equatable, CustomStringConvertible, MachineErrorConvertible,
    Sendable {
    case invalidArguments(String)
    case stagingFailed(String)
    case identityMismatch(
        detail: String,
        mutationMayHaveApplied: Bool
    )
    case permissionDenied(String)
    case unavailable(String)
    case timedOut(String)
    case processFailed(String)
    case noImportedAssets
    case multipleImportedAssets(Int)
    case emptyAssetLocalIdentifier
    case cleanupFailed(
        detail: String,
        originalError: String?,
        mutationMayHaveApplied: Bool
    )

    var description: String {
        switch self {
        case .invalidArguments(let detail):
            return "invalid PlayCover media import arguments: \(detail)"
        case .stagingFailed(let detail):
            return "PlayCover media import staging failed: \(detail)"
        case .identityMismatch(let detail, _):
            return "PlayCover media import staging identity failed: \(detail)"
        case .permissionDenied(let detail):
            return "Photos automation permission was denied: \(detail)"
        case .unavailable(let detail):
            return "Photos automation is unavailable: \(detail)"
        case .timedOut(let detail):
            return "PlayCover media import timed out: \(detail)"
        case .processFailed(let detail):
            return "PlayCover media import failed: \(detail)"
        case .noImportedAssets:
            return "Photos returned no imported assets"
        case .multipleImportedAssets(let count):
            return "Photos returned \(count) imported assets for one input"
        case .emptyAssetLocalIdentifier:
            return "Photos returned an empty asset local identifier"
        case .cleanupFailed(
            let detail,
            let originalError,
            _
        ):
            if let originalError {
                return "PlayCover media import cleanup failed after "
                    + "\(originalError): \(detail)"
            }
            return "PlayCover media import cleanup failed: \(detail)"
        }
    }

    var mutationMayHaveApplied: Bool {
        switch self {
        case .identityMismatch(_, let value),
             .cleanupFailed(_, _, let value):
            return value
        case .timedOut, .processFailed, .noImportedAssets,
             .multipleImportedAssets, .emptyAssetLocalIdentifier:
            return true
        case .invalidArguments, .stagingFailed, .permissionDenied,
             .unavailable:
            return false
        }
    }

    var machineError: MachineError {
        let category: String
        let code: String
        let phase: String
        let retryable: Bool

        switch self {
        case .invalidArguments:
            category = IOSUseErrorCategory.validation
            code = IOSUseErrorCode.invalidArguments
            phase = IOSUseErrorPhase.validation
            retryable = false
        case .stagingFailed:
            category = IOSUseErrorCategory.internalFailure
            code = "playcover_media_import_staging_failed"
            phase = "playcover_media_import_staging"
            retryable = false
        case .identityMismatch:
            category = IOSUseErrorCategory.internalFailure
            code = "playcover_media_import_identity_failed"
            phase = "playcover_media_import_identity"
            retryable = false
        case .permissionDenied:
            category = IOSUseErrorCategory.authorization
            code = "playcover_photos_automation_denied"
            phase = IOSUseErrorPhase.authorization
            retryable = false
        case .unavailable:
            category = IOSUseErrorCategory.validation
            code = "playcover_photos_automation_unavailable"
            phase = "playcover_media_import_automation"
            retryable = false
        case .timedOut:
            category = IOSUseErrorCategory.timeout
            code = IOSUseErrorCode.mediaImportTimedOut
            phase = "playcover_media_import_automation"
            retryable = true
        case .processFailed:
            category = IOSUseErrorCategory.action
            code = IOSUseErrorCode.mediaImportFailed
            phase = "playcover_media_import_automation"
            retryable = false
        case .noImportedAssets:
            category = IOSUseErrorCategory.postcondition
            code = "playcover_media_import_zero_assets"
            phase = IOSUseErrorPhase.postcondition
            retryable = false
        case .multipleImportedAssets:
            category = IOSUseErrorCategory.postcondition
            code = "playcover_media_import_multiple_assets"
            phase = IOSUseErrorPhase.postcondition
            retryable = false
        case .emptyAssetLocalIdentifier:
            category = IOSUseErrorCategory.postcondition
            code = "playcover_media_import_empty_asset_identifier"
            phase = IOSUseErrorPhase.postcondition
            retryable = false
        case .cleanupFailed:
            category = IOSUseErrorCategory.internalFailure
            code = "playcover_media_import_cleanup_failed"
            phase = "playcover_media_import_cleanup"
            retryable = true
        }

        return MachineError(
            message: description,
            category: category,
            code: code,
            phase: phase,
            retryable: retryable,
            fatal: false,
            mutationMayHaveApplied: mutationMayHaveApplied
        )
    }
}

struct PlayCoverMediaImportAdapter {
    static let osascriptPath = "/usr/bin/osascript"
    static let resultSentinel = "IOS_USE_MEDIA_IMPORT_V1"
    static let appleScript = """
        on run argv
            set mediaPath to item 1 of argv
            tell application "Photos"
                set importedItems to import {POSIX file mediaPath} skip check duplicates yes
                set output to "\(resultSentinel)" & linefeed & ((count of importedItems) as text)
                repeat with importedItem in importedItems
                    set output to output & linefeed & (id of importedItem as text)
                end repeat
                return output
            end tell
        end run
        """

    private let paths: IOSUsePaths
    private let processRunner: any PlayCoverMediaImportProcessRunning
    private let fileSystem: any PlayCoverMediaImportFileSystem
    private let timeoutSeconds: TimeInterval

    init(
        paths: IOSUsePaths,
        processRunner: any PlayCoverMediaImportProcessRunning =
            PlayCoverMediaImportFoundationProcessRunner(),
        fileSystem: any PlayCoverMediaImportFileSystem =
            PlayCoverMediaImportPOSIXFileSystem(),
        timeoutSeconds: TimeInterval =
            IOSUseProtocol.mediaImportTimeoutSeconds
    ) {
        self.paths = paths
        self.processRunner = processRunner
        self.fileSystem = fileSystem
        self.timeoutSeconds = timeoutSeconds
    }

    func importMedia(
        args: ForyMediaImportArgs
    ) throws -> ForyMediaImportPayload {
        try validate(args)

        let stagedFile: PlayCoverMediaImportStagedFile
        do {
            stagedFile = try fileSystem.stage(
                data: args.data,
                originalFilename: args.originalFilename,
                inRunDirectory: paths.playcoverRun
            )
        } catch {
            throw PlayCoverMediaImportAdapterError.stagingFailed(
                String(describing: error)
            )
        }

        var primaryError: PlayCoverMediaImportAdapterError?
        var payload: ForyMediaImportPayload?

        do {
            do {
                try fileSystem.verifyIdentity(
                    of: stagedFile,
                    inRunDirectory: paths.playcoverRun
                )
            } catch {
                throw PlayCoverMediaImportAdapterError.identityMismatch(
                    detail: String(describing: error),
                    mutationMayHaveApplied: false
                )
            }

            let result: PlayCoverMediaImportProcessResult
            do {
                result = try processRunner.run(
                    executablePath: Self.osascriptPath,
                    arguments: [
                        "-e",
                        Self.appleScript,
                        stagedFile.path,
                    ],
                    timeoutSeconds: timeoutSeconds
                )
            } catch let error
                    as PlayCoverMediaImportProcessRunnerError {
                switch error {
                case .unavailable(let detail):
                    throw PlayCoverMediaImportAdapterError.unavailable(
                        detail
                    )
                case .timedOut(let detail):
                    throw PlayCoverMediaImportAdapterError.timedOut(
                        detail
                    )
                }
            } catch {
                throw PlayCoverMediaImportAdapterError.processFailed(
                    String(describing: error)
                )
            }

            do {
                try fileSystem.verifyIdentity(
                    of: stagedFile,
                    inRunDirectory: paths.playcoverRun
                )
            } catch {
                throw PlayCoverMediaImportAdapterError.identityMismatch(
                    detail: String(describing: error),
                    mutationMayHaveApplied: true
                )
            }

            if result.exitStatus != 0 {
                throw classifyProcessFailure(result)
            }
            let identifier = try parseAssetIdentifier(
                standardOutput: result.standardOutput
            )
            payload = ForyMediaImportPayload(
                kind: args.kind,
                originalFilename: args.originalFilename,
                byteCount: args.byteCount,
                assetLocalIdentifier: identifier,
                permissionPromptHandled: false
            )
        } catch let error as PlayCoverMediaImportAdapterError {
            primaryError = error
        } catch {
            primaryError = .processFailed(String(describing: error))
        }

        do {
            try fileSystem.cleanup(
                stagedFile,
                inRunDirectory: paths.playcoverRun
            )
        } catch {
            throw PlayCoverMediaImportAdapterError.cleanupFailed(
                detail: String(describing: error),
                originalError: primaryError?.description,
                mutationMayHaveApplied:
                    primaryError?.mutationMayHaveApplied
                    ?? (payload != nil)
            )
        }

        if let primaryError {
            throw primaryError
        }
        guard let payload else {
            throw PlayCoverMediaImportAdapterError.processFailed(
                "Photos automation returned no result"
            )
        }
        return payload
    }

    private func validate(
        _ args: ForyMediaImportArgs
    ) throws {
        guard args.kind == "photo" || args.kind == "video" else {
            throw PlayCoverMediaImportAdapterError.invalidArguments(
                "kind must be `photo` or `video`"
            )
        }
        guard !args.originalFilename.isEmpty else {
            throw PlayCoverMediaImportAdapterError.invalidArguments(
                "originalFilename is empty"
            )
        }
        guard !args.data.isEmpty else {
            throw PlayCoverMediaImportAdapterError.invalidArguments(
                "data is empty"
            )
        }
        guard args.byteCount == Int64(args.data.count) else {
            throw PlayCoverMediaImportAdapterError.invalidArguments(
                "byteCount does not match data"
            )
        }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw PlayCoverMediaImportAdapterError.invalidArguments(
                "timeout must be positive and finite"
            )
        }
    }

    private func classifyProcessFailure(
        _ result: PlayCoverMediaImportProcessResult
    ) -> PlayCoverMediaImportAdapterError {
        let stderr = String(
            decoding: result.standardError,
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = stderr.isEmpty
            ? "osascript exited with status \(result.exitStatus)"
            : stderr
        if Self.containsAppleEventError(
            stderr,
            numbers: [-1743, -10004]
        ) {
            return .permissionDenied(detail)
        }
        if Self.containsAppleEventError(stderr, numbers: [-1712]) {
            return .timedOut(detail)
        }
        if Self.containsAppleEventError(
            stderr,
            numbers: [-600, -609, -10827]
        ) {
            return .unavailable(detail)
        }
        return .processFailed(detail)
    }

    private func parseAssetIdentifier(
        standardOutput: Data
    ) throws -> String {
        var output = String(decoding: standardOutput, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if output.hasSuffix("\n") {
            output.removeLast()
        }
        let lines = output.components(separatedBy: "\n")
        guard lines.first == Self.resultSentinel,
              lines.count >= 2,
              let countLine = lines.dropFirst().first,
              let count = Int(
                countLine.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
              ),
              count >= 0 else {
            throw PlayCoverMediaImportAdapterError.processFailed(
                "Photos returned an invalid result envelope"
            )
        }
        if count == 0 {
            throw PlayCoverMediaImportAdapterError.noImportedAssets
        }
        if count != 1 {
            throw PlayCoverMediaImportAdapterError
                .multipleImportedAssets(count)
        }
        guard lines.count == 3 else {
            throw PlayCoverMediaImportAdapterError.processFailed(
                "Photos returned an inconsistent result envelope"
            )
        }
        let identifier = lines[2].trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !identifier.isEmpty else {
            throw PlayCoverMediaImportAdapterError
                .emptyAssetLocalIdentifier
        }
        return identifier
    }

    private static func containsAppleEventError(
        _ message: String,
        numbers: [Int]
    ) -> Bool {
        numbers.contains { number in
            message.contains("(\(number))")
                || message.contains("error number \(number)")
        }
    }
}

struct PlayCoverMediaImportFoundationProcessRunner:
    PlayCoverMediaImportProcessRunning {
    func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) throws -> PlayCoverMediaImportProcessResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }

        do {
            try process.run()
        } catch {
            throw PlayCoverMediaImportProcessRunnerError.unavailable(
                "\(executablePath): \(error.localizedDescription)"
            )
        }

        let outputGroup = DispatchGroup()
        var outputData = Data()
        var errorData = Data()
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData =
                standardOutput.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData =
                standardError.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }

        let deadline = DispatchTime.now() + timeoutSeconds
        guard termination.wait(timeout: deadline) == .success else {
            process.terminate()
            if termination.wait(
                timeout: .now() + 1.0
            ) != .success {
                #if canImport(Darwin)
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                #endif
                _ = termination.wait(timeout: .now() + 1.0)
            }
            try? standardOutput.fileHandleForReading.close()
            try? standardError.fileHandleForReading.close()
            outputGroup.wait()
            throw PlayCoverMediaImportProcessRunnerError.timedOut(
                "osascript exceeded \(timeoutSeconds) seconds"
            )
        }
        outputGroup.wait()
        return PlayCoverMediaImportProcessResult(
            exitStatus: process.terminationStatus,
            standardOutput: outputData,
            standardError: errorData
        )
    }
}

struct PlayCoverMediaImportPOSIXFileSystem:
    PlayCoverMediaImportFileSystem {
    private enum FileSystemError:
        Error, CustomStringConvertible {
        case operation(String)

        var description: String {
            switch self {
            case .operation(let detail):
                return detail
            }
        }
    }

    func stage(
        data: Data,
        originalFilename: String,
        inRunDirectory runDirectory: String
    ) throws -> PlayCoverMediaImportStagedFile {
        #if canImport(Darwin)
        let runDescriptor = try openOwnedDirectory(
            runDirectory,
            mode: 0o700,
            label: "PlayCover run directory"
        )
        defer { Darwin.close(runDescriptor) }

        let directoryName =
            "media-import-\(UUID().uuidString.lowercased())"
        guard Darwin.mkdirat(
            runDescriptor,
            directoryName,
            0o700
        ) == 0 else {
            throw operationError(
                "cannot create unique media staging directory"
            )
        }
        var removeDirectory = true
        defer {
            if removeDirectory {
                _ = Darwin.unlinkat(
                    runDescriptor,
                    directoryName,
                    AT_REMOVEDIR
                )
            }
        }

        let directoryDescriptor = Darwin.openat(
            runDescriptor,
            directoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw operationError(
                "cannot open unique media staging directory"
            )
        }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fchmod(directoryDescriptor, 0o700) == 0 else {
            throw operationError(
                "cannot secure unique media staging directory"
            )
        }
        let directoryStatus = try ownedStatus(
            descriptor: directoryDescriptor,
            type: S_IFDIR,
            mode: 0o700,
            label: "unique media staging directory"
        )

        let filename = stagedFilename(
            originalFilename: originalFilename
        )
        let fileDescriptor = Darwin.openat(
            directoryDescriptor,
            filename,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard fileDescriptor >= 0 else {
            throw operationError("cannot create staged media file")
        }
        var removeFile = true
        defer {
            Darwin.close(fileDescriptor)
            if removeFile {
                _ = Darwin.unlinkat(
                    directoryDescriptor,
                    filename,
                    0
                )
            }
        }
        guard Darwin.fchmod(fileDescriptor, 0o600) == 0 else {
            throw operationError("cannot secure staged media file")
        }
        try writeAll(data, to: fileDescriptor)
        guard Darwin.fsync(fileDescriptor) == 0 else {
            throw operationError("cannot sync staged media file")
        }
        let fileStatus = try ownedStatus(
            descriptor: fileDescriptor,
            type: S_IFREG,
            mode: 0o600,
            label: "staged media file"
        )
        var namedStatus = stat()
        guard Darwin.fstatat(
            directoryDescriptor,
            filename,
            &namedStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              sameIdentity(fileStatus, namedStatus),
              namedStatus.st_mode & S_IFMT == S_IFREG else {
            throw FileSystemError.operation(
                "staged media file lost its exact no-follow identity"
            )
        }

        removeFile = false
        removeDirectory = false
        let directoryPath =
            URL(
                fileURLWithPath: runDirectory,
                isDirectory: true
            )
            .appendingPathComponent(
                directoryName,
                isDirectory: true
            ).path
        return PlayCoverMediaImportStagedFile(
            path: URL(
                fileURLWithPath: directoryPath,
                isDirectory: true
            ).appendingPathComponent(filename).path,
            directoryName: directoryName,
            filename: filename,
            directoryDevice: UInt64(directoryStatus.st_dev),
            directoryInode: UInt64(directoryStatus.st_ino),
            fileDevice: UInt64(fileStatus.st_dev),
            fileInode: UInt64(fileStatus.st_ino)
        )
        #else
        throw FileSystemError.operation(
            "secure PlayCover media staging requires Darwin"
        )
        #endif
    }

    func verifyIdentity(
        of stagedFile: PlayCoverMediaImportStagedFile,
        inRunDirectory runDirectory: String
    ) throws {
        #if canImport(Darwin)
        let runDescriptor = try openOwnedDirectory(
            runDirectory,
            mode: 0o700,
            label: "PlayCover run directory"
        )
        defer { Darwin.close(runDescriptor) }
        let directoryDescriptor = try openStagedDirectory(
            stagedFile,
            runDescriptor: runDescriptor
        )
        defer { Darwin.close(directoryDescriptor) }
        let fileDescriptor = Darwin.openat(
            directoryDescriptor,
            stagedFile.filename,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard fileDescriptor >= 0 else {
            throw operationError(
                "cannot open the exact staged media file"
            )
        }
        defer { Darwin.close(fileDescriptor) }
        let fileStatus = try ownedStatus(
            descriptor: fileDescriptor,
            type: S_IFREG,
            mode: 0o600,
            label: "staged media file"
        )
        guard UInt64(fileStatus.st_dev) == stagedFile.fileDevice,
              UInt64(fileStatus.st_ino) == stagedFile.fileInode else {
            throw FileSystemError.operation(
                "staged media file identity changed"
            )
        }
        var namedStatus = stat()
        guard Darwin.fstatat(
            directoryDescriptor,
            stagedFile.filename,
            &namedStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              sameIdentity(fileStatus, namedStatus),
              namedStatus.st_mode & S_IFMT == S_IFREG else {
            throw FileSystemError.operation(
                "staged media file path no longer names the exact file"
            )
        }
        #else
        throw FileSystemError.operation(
            "secure PlayCover media staging requires Darwin"
        )
        #endif
    }

    func cleanup(
        _ stagedFile: PlayCoverMediaImportStagedFile,
        inRunDirectory runDirectory: String
    ) throws {
        #if canImport(Darwin)
        let runDescriptor = try openOwnedDirectory(
            runDirectory,
            mode: 0o700,
            label: "PlayCover run directory"
        )
        defer { Darwin.close(runDescriptor) }
        let directoryDescriptor =
            try openStagedDirectoryForCleanup(
                stagedFile,
                runDescriptor: runDescriptor
            )
        defer { Darwin.close(directoryDescriptor) }
        let fileDescriptor = Darwin.openat(
            directoryDescriptor,
            stagedFile.filename,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard fileDescriptor >= 0 else {
            throw operationError(
                "cannot open exact staged media file for cleanup"
            )
        }
        defer { Darwin.close(fileDescriptor) }
        var fileStatus = stat()
        var namedStatus = stat()
        guard Darwin.fstat(fileDescriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG,
              fileStatus.st_uid == geteuid(),
              UInt64(fileStatus.st_dev) == stagedFile.fileDevice,
              UInt64(fileStatus.st_ino) == stagedFile.fileInode,
              Darwin.fstatat(
                directoryDescriptor,
                stagedFile.filename,
                &namedStatus,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              sameIdentity(fileStatus, namedStatus),
              namedStatus.st_mode & S_IFMT == S_IFREG else {
            throw FileSystemError.operation(
                "refusing to clean up a changed staged media identity"
            )
        }
        guard Darwin.unlinkat(
            directoryDescriptor,
            stagedFile.filename,
            0
        ) == 0 else {
            throw operationError("cannot remove staged media file")
        }
        guard Darwin.unlinkat(
            runDescriptor,
            stagedFile.directoryName,
            AT_REMOVEDIR
        ) == 0 else {
            throw operationError(
                "cannot remove media staging directory"
            )
        }
        #else
        throw FileSystemError.operation(
            "secure PlayCover media staging requires Darwin"
        )
        #endif
    }

    #if canImport(Darwin)
    private func openOwnedDirectory(
        _ path: String,
        mode: mode_t,
        label: String
    ) throws -> Int32 {
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw operationError("cannot open \(label)")
        }
        do {
            _ = try ownedStatus(
                descriptor: descriptor,
                type: S_IFDIR,
                mode: mode,
                label: label
            )
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openStagedDirectoryForCleanup(
        _ stagedFile: PlayCoverMediaImportStagedFile,
        runDescriptor: Int32
    ) throws -> Int32 {
        let descriptor = Darwin.openat(
            runDescriptor,
            stagedFile.directoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw operationError(
                "cannot open exact media staging directory for cleanup"
            )
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              UInt64(status.st_dev) == stagedFile.directoryDevice,
              UInt64(status.st_ino) == stagedFile.directoryInode else {
            Darwin.close(descriptor)
            throw FileSystemError.operation(
                "refusing to clean up a changed media staging directory"
            )
        }
        return descriptor
    }

    private func openStagedDirectory(
        _ stagedFile: PlayCoverMediaImportStagedFile,
        runDescriptor: Int32
    ) throws -> Int32 {
        let descriptor = Darwin.openat(
            runDescriptor,
            stagedFile.directoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw operationError(
                "cannot open exact media staging directory"
            )
        }
        do {
            let status = try ownedStatus(
                descriptor: descriptor,
                type: S_IFDIR,
                mode: 0o700,
                label: "media staging directory"
            )
            guard UInt64(status.st_dev)
                    == stagedFile.directoryDevice,
                  UInt64(status.st_ino)
                    == stagedFile.directoryInode else {
                throw FileSystemError.operation(
                    "media staging directory identity changed"
                )
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func ownedStatus(
        descriptor: Int32,
        type: mode_t,
        mode: mode_t,
        label: String
    ) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == type,
              status.st_uid == geteuid(),
              status.st_mode & 0o7777 == mode else {
            throw FileSystemError.operation(
                "\(label) is not an exact owner-only "
                    + "\(String(mode, radix: 8)) object"
            )
        }
        return status
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw operationError(
                        "cannot write staged media file"
                    )
                }
            }
        }
    }

    private func sameIdentity(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private func operationError(
        _ detail: String
    ) -> FileSystemError {
        FileSystemError.operation(
            "\(detail): errno \(errno)"
        )
    }
    #endif

    private func stagedFilename(
        originalFilename: String
    ) -> String {
        let pathExtension = URL(
            fileURLWithPath: originalFilename
        ).pathExtension
        let allowed = CharacterSet.alphanumerics
        let safeExtension = pathExtension.unicodeScalars
            .filter { allowed.contains($0) }
            .prefix(16)
            .map(String.init)
            .joined()
        return safeExtension.isEmpty
            ? "payload"
            : "payload.\(safeExtension)"
    }
}
