import Foundation
import IOSUseProtocol
import UniformTypeIdentifiers

enum MediaImportError: Error, CustomStringConvertible, MachineErrorConvertible {
    case sourceUnreadable(String)
    case unsupportedMediaType(String)
    case frameTooLarge(byteCount: Int, maximum: Int)

    var description: String {
        switch self {
        case .sourceUnreadable(let detail):
            return "media source is unreadable: \(detail)"
        case .unsupportedMediaType(let detail):
            return "unsupported media type: \(detail)"
        case .frameTooLarge(let byteCount, let maximum):
            return "driver frame is too large: source has \(byteCount) bytes; maximum framed request is \(maximum) bytes"
        }
    }

    var machineError: MachineError {
        let code: String
        switch self {
        case .sourceUnreadable:
            code = IOSUseErrorCode.mediaSourceUnreadable
        case .unsupportedMediaType:
            code = IOSUseErrorCode.unsupportedMediaType
        case .frameTooLarge:
            code = IOSUseErrorCode.driverFrameTooLarge
        }
        return MachineError(
            message: description,
            category: IOSUseErrorCategory.validation,
            code: code,
            phase: IOSUseErrorPhase.validation,
            retryable: false,
            fatal: false,
            mutationMayHaveApplied: false
        )
    }
}

enum MediaImportService {
    struct Result {
        let sourcePath: String
        let payload: ForyMediaImportPayload
    }

    private struct Source {
        let path: String
        let kind: String
        let filename: String
        let uniformTypeIdentifier: String
        let data: Data
    }

    static func run(options: MediaImportOptions, paths: IOSUsePaths) throws -> Result {
        let source = try loadSource(path: options.path)
        let args = ForyMediaImportArgs(
            kind: source.kind,
            originalFilename: source.filename,
            uniformTypeIdentifier: source.uniformTypeIdentifier,
            byteCount: Int64(source.data.count),
            data: source.data
        )
        do {
            let payload = try DriverCommandExecution.withLockedClient(paths: paths) {
                try $0.mediaImport(args: args)
            }
            return Result(sourcePath: source.path, payload: payload)
        } catch DriverClientError.maxFrameSizeExceeded {
            throw MediaImportError.frameTooLarge(
                byteCount: source.data.count,
                maximum: IOSUseProtocol.maxFrameSizeBytes
            )
        }
    }

    static func format(_ result: Result) -> String {
        let payload = result.payload
        return "Imported \(payload.kind) \(payload.originalFilename) (\(payload.byteCount) bytes, asset \(payload.assetLocalIdentifier))\n"
    }

    static func machineData(_ result: Result) -> MachineValue {
        let payload = result.payload
        return .object([
            "sourcePath": .string(result.sourcePath),
            "kind": .string(payload.kind),
            "originalFilename": .string(payload.originalFilename),
            "byteCount": .integer(Int(payload.byteCount)),
            "assetLocalIdentifier": .string(payload.assetLocalIdentifier),
            "permissionPromptHandled": .boolean(payload.permissionPromptHandled),
        ])
    }

    private static func loadSource(path: String) throws -> Source {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .nameKey])
        } catch {
            throw MediaImportError.sourceUnreadable("\(url.path): \(error.localizedDescription)")
        }
        guard values.isRegularFile == true,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw MediaImportError.sourceUnreadable(url.path)
        }

        let filename = values.name ?? url.lastPathComponent
        guard !filename.isEmpty,
              filename == url.lastPathComponent else {
            throw MediaImportError.sourceUnreadable("invalid filename for \(url.path)")
        }
        guard let type = UTType(filenameExtension: url.pathExtension), type.isDeclared else {
            throw MediaImportError.unsupportedMediaType(filename)
        }

        let kind: String
        if type.conforms(to: .image) {
            kind = "photo"
        } else if type.conforms(to: .movie) {
            kind = "video"
        } else {
            throw MediaImportError.unsupportedMediaType("\(filename) (\(type.identifier))")
        }

        if let size = values.fileSize, size >= IOSUseProtocol.maxFrameSizeBytes {
            throw MediaImportError.frameTooLarge(
                byteCount: size,
                maximum: IOSUseProtocol.maxFrameSizeBytes
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw MediaImportError.sourceUnreadable("\(url.path): \(error.localizedDescription)")
        }
        guard !data.isEmpty else {
            throw MediaImportError.sourceUnreadable("\(url.path) is empty")
        }
        return Source(
            path: url.path,
            kind: kind,
            filename: filename,
            uniformTypeIdentifier: type.identifier,
            data: data
        )
    }
}
