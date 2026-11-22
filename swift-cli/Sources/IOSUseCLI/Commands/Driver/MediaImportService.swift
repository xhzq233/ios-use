import Foundation
import IOSUseProtocol
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

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
        let resolvedType = try resolveMediaType(
            filename: filename,
            pathExtension: url.pathExtension
        )

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
            kind: resolvedType.kind,
            filename: filename,
            uniformTypeIdentifier: resolvedType.uniformTypeIdentifier,
            data: data
        )
    }

    private static func resolveMediaType(
        filename: String,
        pathExtension: String
    ) throws -> (kind: String, uniformTypeIdentifier: String) {
        #if canImport(UniformTypeIdentifiers)
        guard let type = UTType(filenameExtension: pathExtension), type.isDeclared else {
            throw MediaImportError.unsupportedMediaType(filename)
        }
        if type.conforms(to: .image) {
            return ("photo", type.identifier)
        } else if type.conforms(to: .movie) {
            return ("video", type.identifier)
        } else {
            throw MediaImportError.unsupportedMediaType("\(filename) (\(type.identifier))")
        }
        #else
        return try resolveFallbackMediaType(filename: filename, pathExtension: pathExtension)
        #endif
    }

    static func resolveFallbackMediaType(
        filename: String,
        pathExtension: String
    ) throws -> (kind: String, uniformTypeIdentifier: String) {
        switch pathExtension.lowercased() {
        case "png":
            return ("photo", "public.png")
        case "jpg", "jpeg":
            return ("photo", "public.jpeg")
        case "heic":
            return ("photo", "public.heic")
        case "heif":
            return ("photo", "public.heif")
        case "gif":
            return ("photo", "com.compuserve.gif")
        case "tif", "tiff":
            return ("photo", "public.tiff")
        case "bmp":
            return ("photo", "com.microsoft.bmp")
        case "webp":
            return ("photo", "org.webmproject.webp")
        case "dng":
            return ("photo", "com.adobe.raw-image")
        case "mov", "qt":
            return ("video", "com.apple.quicktime-movie")
        case "mp4":
            return ("video", "public.mpeg-4")
        case "m4v":
            return ("video", "com.apple.m4v-video")
        case "3gp":
            return ("video", "public.3gpp")
        case "avi":
            return ("video", "public.avi")
        default:
            throw MediaImportError.unsupportedMediaType(filename)
        }
    }
}
