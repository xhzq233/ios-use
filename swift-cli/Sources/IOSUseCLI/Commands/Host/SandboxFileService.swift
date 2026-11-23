#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation
import IOSUseProtocol

enum SandboxFileService {
    struct Result {
        let stdout: String
        let machineData: MachineValue
        var warnings: [String] = []
    }

    static var serviceConnectorForTesting: ((String, String) throws -> DeviceStream)?

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func run(_ command: SandboxFileCommand, paths: IOSUsePaths) throws -> Result {
        let scope: SandboxContainerScope = command.documents ? .documents : .container
        let udid = try AppManagementService.resolveRealDeviceTargetUdid(
            explicitUdid: command.udid,
            paths: paths,
            command: "file \(command.subcommand)",
            missingMessage: "file \(command.subcommand) requires --udid or an active driver. Run `ios-use start` or pass `--udid <UDID>`."
        )
        let connector = serviceConnectorForTesting ?? LockdownSession.connectToService

        return try HouseArrestClient.withClient(
            udid: udid,
            bundleID: command.bundleID,
            scope: scope,
            serviceConnector: connector
        ) { afc in
            switch command {
            case .ls(let bundleID, let rawRemotePath, _, _):
                return try runList(
                    afc: afc,
                    udid: udid,
                    bundleID: bundleID,
                    scope: scope,
                    rawRemotePath: rawRemotePath
                )
            case .pull(let bundleID, let rawRemotePath, let localPath, _, _):
                return try runPull(
                    afc: afc,
                    udid: udid,
                    bundleID: bundleID,
                    scope: scope,
                    rawRemotePath: rawRemotePath,
                    localPath: localPath
                )
            case .push(let bundleID, let localPath, let rawRemotePath, _, _):
                return try runPush(
                    afc: afc,
                    udid: udid,
                    bundleID: bundleID,
                    scope: scope,
                    localPath: localPath,
                    rawRemotePath: rawRemotePath
                )
            case .remove(let bundleID, let rawRemotePath, let recursive, _, _):
                return try runRemove(
                    afc: afc,
                    udid: udid,
                    bundleID: bundleID,
                    scope: scope,
                    rawRemotePath: rawRemotePath,
                    recursive: recursive
                )
            }
        }
    }

    private static func runList(
        afc: AfcClient,
        udid: String,
        bundleID: String,
        scope: SandboxContainerScope,
        rawRemotePath: String?
    ) throws -> Result {
        let resolvedPath = try HouseArrestClient.resolveRemotePath(rawRemotePath, scope: scope)
        let allowRootFallback = (scope == .container && resolvedPath == "/")
        var warnings: [String] = []
        let entries: [AfcEntryInfo]
        do {
            let targetInfo = try statRequired(afc: afc, path: resolvedPath)
            if targetInfo.kind == .directory {
                entries = try afc.listSandboxDirectory(
                    path: resolvedPath,
                    allowContainerRootFallback: allowRootFallback,
                    warnings: &warnings
                )
            } else {
                entries = [targetInfo]
            }
        } catch AfcClientError.status(.permissionDenied) {
            do {
                entries = try afc.listSandboxDirectory(
                    path: resolvedPath,
                    allowContainerRootFallback: allowRootFallback,
                    warnings: &warnings
                )
            } catch AfcClientError.status(.permissionDenied) {
                throw permissionDeniedError(path: resolvedPath, scope: scope, action: "listing")
            }
        }

        let stdout: String
        if entries.isEmpty {
            stdout = "Empty sandbox directory \(resolvedPath) for \(bundleID)\n"
        } else {
            stdout = entries.map { entry in
                let typeLabel = entryTypeLabel(entry.kind)
                let sizeLabel = entry.kind == .directory ? "-" : "\(entry.size)"
                let mtime = formattedTimestamp(entry.modifiedAtNanoseconds) ?? "-"
                return "\(typeLabel)\t\(sizeLabel)\t\(mtime)\t\(entry.name)"
            }.joined(separator: "\n") + "\n"
        }

        let machineEntries = entries.map { entry in
            MachineValue.object([
                "name": .string(entry.name),
                "path": .string(entry.path),
                "type": .string(entry.kind.rawValue),
                "size": .integer(Int(clamping: entry.size)),
                "modifiedAt": formattedTimestamp(entry.modifiedAtNanoseconds).map(MachineValue.string) ?? .null,
                "linkTarget": entry.linkTarget.map(MachineValue.string) ?? .null,
            ])
        }

        return Result(
            stdout: stdout,
            machineData: .object([
                "bundleId": .string(bundleID),
                "container": .string(scope.rawValue),
                "deviceUdid": .string(udid),
                "path": .string(resolvedPath),
                "entries": .array(machineEntries),
            ]),
            warnings: warnings
        )
    }

    private static func runPull(
        afc: AfcClient,
        udid: String,
        bundleID: String,
        scope: SandboxContainerScope,
        rawRemotePath: String,
        localPath: String?
    ) throws -> Result {
        let resolvedRemote = try HouseArrestClient.resolveRemotePath(rawRemotePath, scope: scope)
        let targetKind: AfcEntryKind
        do {
            targetKind = try statRequired(afc: afc, path: resolvedRemote).kind
        } catch AfcClientError.status(.permissionDenied) {
            if HouseArrestClient.isProtectedRoot(resolvedRemote, scope: scope) || afc.directoryExists(resolvedRemote) {
                targetKind = .directory
            } else {
                throw permissionDeniedError(path: resolvedRemote, scope: scope, action: "pulling")
            }
        }
        let destinationPath = try resolveLocalPullDestination(
            remotePath: resolvedRemote,
            remoteKind: targetKind,
            explicitLocalPath: localPath,
            scope: scope
        )

        var warnings: [String] = []
        let transferKind: String
        let fileCount: Int
        let byteCount: Int64

        do {
            switch targetKind {
            case .file:
                transferKind = "file"
                fileCount = 1
                byteCount = try afc.downloadFile(remotePath: resolvedRemote, localPath: destinationPath)
            case .directory:
                transferKind = "directory"
                var isExistingDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: destinationPath, isDirectory: &isExistingDir),
                   !isExistingDir.boolValue {
                    throw CLIParseError.invalidValue("Local destination exists and is not a directory: \(destinationPath)")
                }
                let counts = try afc.downloadDirectory(
                    remotePath: resolvedRemote,
                    localPath: destinationPath,
                    warnings: &warnings
                )
                fileCount = counts.fileCount
                byteCount = counts.byteCount
            case .symlink:
                throw CLIParseError.invalidValue("Refusing to pull symbolic link at \(resolvedRemote)")
            case .other:
                throw CLIParseError.invalidValue("Unsupported sandbox entry type at \(resolvedRemote)")
            }
        } catch AfcClientError.status(.permissionDenied) {
            throw permissionDeniedError(path: resolvedRemote, scope: scope, action: "pulling")
        }

        let summary = targetKind == .directory
            ? "Pulled directory \(resolvedRemote) (\(fileCount) files, \(byteCount) bytes) -> \(destinationPath)\n"
            : "Pulled \(resolvedRemote) (\(byteCount) bytes) -> \(destinationPath)\n"
        return Result(
            stdout: summary,
            machineData: .object([
                "bundleId": .string(bundleID),
                "container": .string(scope.rawValue),
                "deviceUdid": .string(udid),
                "remotePath": .string(resolvedRemote),
                "localPath": .string(destinationPath),
                "type": .string(transferKind),
                "fileCount": .integer(fileCount),
                "byteCount": .integer(Int(clamping: byteCount)),
            ]),
            warnings: warnings
        )
    }

    private static func runPush(
        afc: AfcClient,
        udid: String,
        bundleID: String,
        scope: SandboxContainerScope,
        localPath: String,
        rawRemotePath: String
    ) throws -> Result {
        let localURL = URL(fileURLWithPath: localPath).standardizedFileURL
        var st = stat()
        guard lstat(localURL.path, &st) == 0 else {
            throw CLIParseError.invalidValue("Local source not found: \(localPath)")
        }
        let mode = st.st_mode & S_IFMT
        guard mode != S_IFLNK else {
            throw CLIParseError.invalidValue("Refusing to push symbolic link source: \(localPath)")
        }

        let baseRemote = try HouseArrestClient.resolveRemotePath(rawRemotePath, scope: scope)
        var warnings: [String] = []
        let finalRemotePath: String
        let transferKind: String
        let fileCount: Int
        let byteCount: Int64

        if mode == S_IFDIR {
            transferKind = "directory"
            let trailingSlash = rawRemotePath.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
            if trailingSlash || HouseArrestClient.isProtectedRoot(baseRemote, scope: scope) {
                let name = localURL.lastPathComponent
                finalRemotePath = baseRemote == "/" ? "/\(name)" : "\(baseRemote)/\(name)"
            } else {
                finalRemotePath = baseRemote
            }
            if let existing = try? afc.statEntry(finalRemotePath), existing.kind != .directory {
                throw CLIParseError.invalidValue("Remote destination exists and is not a directory: \(finalRemotePath)")
            }
            do {
                let counts = try afc.pushDirectoryWithStats(
                    localPath: localURL.path,
                    remotePath: finalRemotePath,
                    warnings: &warnings
                )
                fileCount = counts.fileCount
                byteCount = counts.byteCount
            } catch AfcClientError.status(.permissionDenied) {
                throw permissionDeniedError(path: finalRemotePath, scope: scope, action: "pushing")
            }
        } else if mode == S_IFREG {
            transferKind = "file"
            let trailingSlash = rawRemotePath.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
            if trailingSlash
                || HouseArrestClient.isProtectedRoot(baseRemote, scope: scope)
                || afc.directoryExists(baseRemote) {
                let name = localURL.lastPathComponent
                finalRemotePath = baseRemote == "/" ? "/\(name)" : "\(baseRemote)/\(name)"
            } else {
                finalRemotePath = baseRemote
            }
            do {
                let counts = try afc.pushFileWithStats(localPath: localURL.path, remotePath: finalRemotePath)
                fileCount = counts.fileCount
                byteCount = counts.byteCount
            } catch AfcClientError.status(.permissionDenied) {
                throw permissionDeniedError(path: finalRemotePath, scope: scope, action: "pushing")
            }
        } else {
            throw CLIParseError.invalidValue("Local source must be a regular file or directory: \(localPath)")
        }

        let summary = transferKind == "directory"
            ? "Pushed directory \(localURL.path) (\(fileCount) files, \(byteCount) bytes) -> \(finalRemotePath)\n"
            : "Pushed \(localURL.path) (\(byteCount) bytes) -> \(finalRemotePath)\n"
        return Result(
            stdout: summary,
            machineData: .object([
                "bundleId": .string(bundleID),
                "container": .string(scope.rawValue),
                "deviceUdid": .string(udid),
                "localPath": .string(localURL.path),
                "remotePath": .string(finalRemotePath),
                "type": .string(transferKind),
                "fileCount": .integer(fileCount),
                "byteCount": .integer(Int(clamping: byteCount)),
            ]),
            warnings: warnings
        )
    }

    private static func runRemove(
        afc: AfcClient,
        udid: String,
        bundleID: String,
        scope: SandboxContainerScope,
        rawRemotePath: String,
        recursive: Bool
    ) throws -> Result {
        let resolvedRemote = try HouseArrestClient.resolveRemotePath(rawRemotePath, scope: scope)
        guard !HouseArrestClient.isProtectedRoot(resolvedRemote, scope: scope) else {
            throw CLIParseError.invalidValue("Refusing to remove the sandbox container root \(resolvedRemote).")
        }
        do {
            let targetInfo = try statRequired(afc: afc, path: resolvedRemote)
            if targetInfo.kind == .directory {
                guard recursive else {
                    throw CLIParseError.invalidValue("Remote path \(resolvedRemote) is a directory; pass --recursive (-r) to remove it.")
                }
                try afc.removeExistingPathRecursive(resolvedRemote)
            } else {
                try afc.removeExistingPath(resolvedRemote)
            }
        } catch AfcClientError.status(.permissionDenied) {
            throw permissionDeniedError(path: resolvedRemote, scope: scope, action: "removing")
        }
        return Result(
            stdout: "Removed \(resolvedRemote) from \(bundleID)\n",
            machineData: .object([
                "bundleId": .string(bundleID),
                "container": .string(scope.rawValue),
                "deviceUdid": .string(udid),
                "remotePath": .string(resolvedRemote),
                "recursive": .boolean(recursive),
            ])
        )
    }

    private static func statRequired(afc: AfcClient, path: String) throws -> AfcEntryInfo {
        do {
            return try afc.statEntry(path)
        } catch AfcClientError.status(.objectNotFound) {
            throw CLIParseError.invalidValue("Remote path not found: \(path)")
        }
    }

    private static func permissionDeniedError(
        path: String,
        scope: SandboxContainerScope,
        action: String
    ) -> CLIParseError {
        CLIParseError.invalidValue(
            "Permission denied \(action) sandbox path \(path) (\(scope.vendCommand)). "
                + "Container root / is read-only under iOS Seatbelt (use /Documents, /Library, or /tmp); "
                + "full container access also requires get-task-allow (or pass --documents for UIFileSharingEnabled apps)."
        )
    }

    private static func resolveLocalPullDestination(
        remotePath: String,
        remoteKind: AfcEntryKind,
        explicitLocalPath: String?,
        scope: SandboxContainerScope
    ) throws -> String {
        if let explicitLocalPath {
            let trimmed = explicitLocalPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw CLIParseError.invalidValue("Local destination path must not be empty.")
            }
            let localURL = URL(fileURLWithPath: trimmed).standardizedFileURL
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir)
            if remoteKind == .file && (exists && isDir.boolValue || trimmed.hasSuffix("/")) {
                let name = remotePath.split(separator: "/").last.map(String.init) ?? "file"
                return localURL.appendingPathComponent(name).path
            }
            return localURL.path
        }
        if HouseArrestClient.isProtectedRoot(remotePath, scope: scope) {
            throw CLIParseError.invalidValue("Specify a local directory when pulling container root \(remotePath).")
        }
        let basename = remotePath.split(separator: "/").last.map(String.init) ?? "pulled"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(basename)
            .standardizedFileURL
            .path
    }

    private static func entryTypeLabel(_ kind: AfcEntryKind) -> String {
        switch kind {
        case .file: return "file"
        case .directory: return "dir"
        case .symlink: return "link"
        case .other: return "other"
        }
    }

    private static func formattedTimestamp(_ nanoseconds: Int64?) -> String? {
        guard let nanoseconds, nanoseconds > 0 else { return nil }
        return isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(nanoseconds) / 1_000_000_000))
    }
}
