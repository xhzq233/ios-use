import Foundation
import Photos
import UniformTypeIdentifiers

enum PhotosPermissionPromptOutcome: Equatable {
    case handled(text: String, button: String)
    case notHandled
    case interactionRequired(String)
}

protocol PhotosPermissionPromptHandling {
    func handle(
        deadline: Date,
        shouldStop: @escaping () -> Bool,
        completion: @escaping (PhotosPermissionPromptOutcome) -> Void
    )
}

private struct SystemPhotosPermissionPromptHandler: PhotosPermissionPromptHandling {
    func handle(
        deadline: Date,
        shouldStop: @escaping () -> Bool,
        completion: @escaping (PhotosPermissionPromptOutcome) -> Void
    ) {
        DispatchQueue.main.async {
            AlertCommands.handlePhotosAddPermissionPrompt(
                deadline: deadline,
                shouldStop: shouldStop,
                completion: completion
            )
        }
    }
}

enum MediaPhotoAuthorizationStatus: Equatable {
    case notDetermined
    case restricted
    case denied
    case allowed
    case unknown(Int)
}

protocol MediaPhotoLibrary {
    func authorizationStatus() -> MediaPhotoAuthorizationStatus
    func requestAuthorization(_ completion: @escaping (MediaPhotoAuthorizationStatus) -> Void)
    func supports(kind: String) -> Bool
    func createAsset(
        args: ForyMediaImportArgs,
        completion: @escaping (_ localIdentifier: String?, _ error: String?) -> Void
    )
}

private final class SystemMediaPhotoLibrary: MediaPhotoLibrary {
    func authorizationStatus() -> MediaPhotoAuthorizationStatus {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    func requestAuthorization(_ completion: @escaping (MediaPhotoAuthorizationStatus) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) {
            completion(Self.map($0))
        }
    }

    func supports(kind: String) -> Bool {
        guard let resourceType = Self.resourceType(kind: kind) else { return false }
        return PHAssetCreationRequest.supportsAssetResourceTypes([
            NSNumber(value: resourceType.rawValue)
        ])
    }

    func createAsset(
        args: ForyMediaImportArgs,
        completion: @escaping (String?, String?) -> Void
    ) {
        guard let resourceType = Self.resourceType(kind: args.kind) else {
            completion(nil, "unsupported media kind '\(args.kind)'")
            return
        }

        let stagedVideo: StagedVideoResource?
        let source: ResourceSource
        if args.kind == "video" {
            do {
                let staged = try Self.stageVideo(args)
                stagedVideo = staged
                source = .file(staged.fileURL)
            } catch {
                completion(
                    nil,
                    "failed to stage \(args.originalFilename) for PhotoKit: \(error.localizedDescription)"
                )
                return
            }
        } else {
            stagedVideo = nil
            source = .data(args.data)
        }

        Self.performCreation(args: args, resourceType: resourceType, source: source) {
            success,
            localIdentifier,
            error in
            stagedVideo?.remove()
            guard success else {
                completion(nil, Self.describe(error))
                return
            }
            Self.completeSuccess(
                localIdentifier: localIdentifier,
                completion: completion
            )
        }
    }

    private enum ResourceSource {
        case data(Data)
        case file(URL)
    }

    private static func performCreation(
        args: ForyMediaImportArgs,
        resourceType: PHAssetResourceType,
        source: ResourceSource,
        completion: @escaping (_ success: Bool, _ localIdentifier: String?, _ error: Error?) -> Void
    ) {
        let identifier = LockedMediaValue<String>()
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = args.originalFilename
            options.uniformTypeIdentifier = args.uniformTypeIdentifier
            switch source {
            case .data(let data):
                request.addResource(with: resourceType, data: data, options: options)
            case .file(let fileURL):
                request.addResource(with: resourceType, fileURL: fileURL, options: options)
            }
            if let localIdentifier = request.placeholderForCreatedAsset?.localIdentifier {
                identifier.set(localIdentifier)
            }
        }) { success, error in
            completion(success, identifier.get(), error)
        }
    }

    private static func completeSuccess(
        localIdentifier: String?,
        completion: @escaping (String?, String?) -> Void
    ) {
        guard let localIdentifier, !localIdentifier.isEmpty else {
            completion(nil, "PhotoKit did not return a local asset identifier")
            return
        }
        completion(localIdentifier, nil)
    }

    private struct StagedVideoResource {
        let directoryURL: URL
        let fileURL: URL

        func remove() {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    private static func stageVideo(_ args: ForyMediaImportArgs) throws -> StagedVideoResource {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        do {
            let fileURL = directoryURL.appendingPathComponent(
                args.originalFilename,
                isDirectory: false
            )
            try args.data.write(to: fileURL, options: .atomic)
            return StagedVideoResource(directoryURL: directoryURL, fileURL: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    private static func describe(_ error: Error?) -> String {
        guard let error else {
            return "PhotoKit performChanges returned false"
        }
        let nsError = error as NSError
        return "\(nsError.localizedDescription) [domain=\(nsError.domain) code=\(nsError.code)]"
    }

    private static func resourceType(kind: String) -> PHAssetResourceType? {
        switch kind {
        case "photo": return .photo
        case "video": return .video
        default: return nil
        }
    }

    private static func map(_ status: PHAuthorizationStatus) -> MediaPhotoAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized, .limited: return .allowed
        @unknown default: return .unknown(Int(status.rawValue))
        }
    }
}

private final class LockedMediaValue<Value> {
    private let condition = NSCondition()
    private var value: Value?

    func set(_ value: Value) {
        condition.lock()
        guard self.value == nil else {
            condition.unlock()
            return
        }
        self.value = value
        condition.broadcast()
        condition.unlock()
    }

    func get() -> Value? {
        condition.lock()
        defer { condition.unlock() }
        return value
    }

    func wait(until deadline: Date) -> Value? {
        condition.lock()
        defer { condition.unlock() }
        while value == nil, Date() < deadline {
            _ = condition.wait(until: deadline)
        }
        return value
    }
}

private final class MediaAuthorizationCoordinator {
    struct Snapshot {
        let authorization: MediaPhotoAuthorizationStatus?
        let prompt: PhotosPermissionPromptOutcome?
    }

    private let condition = NSCondition()
    private var authorization: MediaPhotoAuthorizationStatus?
    private var prompt: PhotosPermissionPromptOutcome?
    private var stopped = false

    func setAuthorization(_ value: MediaPhotoAuthorizationStatus) {
        condition.lock()
        if authorization == nil {
            authorization = value
            condition.broadcast()
        }
        condition.unlock()
    }

    func setPrompt(_ value: PhotosPermissionPromptOutcome) {
        condition.lock()
        if prompt == nil {
            prompt = value
            condition.broadcast()
        }
        condition.unlock()
    }

    func snapshot() -> Snapshot {
        condition.lock()
        defer { condition.unlock() }
        return Snapshot(authorization: authorization, prompt: prompt)
    }

    func waitForChange(until deadline: Date) {
        condition.lock()
        _ = condition.wait(until: deadline)
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    func shouldStop() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped || authorization != nil
    }
}

enum MediaCommands {
    static var photoLibraryFactoryForTesting: (() -> MediaPhotoLibrary)?
    static var promptHandlerForTesting: PhotosPermissionPromptHandling?

    static func resetTestingHooks() {
        photoLibraryFactoryForTesting = nil
        promptHandlerForTesting = nil
    }

    static func importMedia(_ args: ForyMediaImportArgs) throws -> ForyResponseFrame {
        precondition(!Thread.isMainThread)
        let commandDeadline = Date().addingTimeInterval(IOSUseProtocol.mediaImportTimeoutSeconds)

        if let validationFailure = validate(args) {
            return try validationFailure.response()
        }

        let library = photoLibraryFactoryForTesting?() ?? SystemMediaPhotoLibrary()
        guard library.supports(kind: args.kind) else {
            return try MediaFailure(
                message: "PhotoKit does not support \(args.kind) resources on this device",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.unsupportedMediaType,
                phase: IOSUseErrorPhase.validation
            ).response()
        }

        let permission: PermissionResolution
        switch library.authorizationStatus() {
        case .allowed:
            permission = PermissionResolution(promptHandled: false)
        case .denied:
            return try permissionFailure(
                message: "Photos add-only access is denied for the ios-use Runner",
                code: IOSUseErrorCode.photosAddPermissionDenied
            ).response()
        case .restricted:
            return try permissionFailure(
                message: "Photos add-only access is restricted for the ios-use Runner",
                code: IOSUseErrorCode.photosAddPermissionRestricted
            ).response()
        case .notDetermined:
            switch requestInitialPermission(
                library: library,
                promptHandler: promptHandlerForTesting ?? SystemPhotosPermissionPromptHandler(),
                commandDeadline: commandDeadline
            ) {
            case .success(let resolved):
                permission = resolved
            case .failure(let failure):
                return try failure.response()
            }
        case .unknown(let rawValue):
            return try permissionFailure(
                message: "Photos add-only authorization returned unknown status \(rawValue); no prompt was requested",
                code: IOSUseErrorCode.photosPermissionInteractionRequired
            ).response()
        }

        let creation = LockedMediaValue<AssetCreationResult>()
        library.createAsset(args: args) { identifier, error in
            creation.set(AssetCreationResult(localIdentifier: identifier, error: error))
        }
        guard let result = creation.wait(until: commandDeadline) else {
            return try MediaFailure(
                message: "Media import did not complete within \(formattedSeconds(IOSUseProtocol.mediaImportTimeoutSeconds))s; the PhotoKit change may still finish",
                category: IOSUseErrorCategory.action,
                code: IOSUseErrorCode.mediaImportTimedOut,
                phase: IOSUseErrorPhase.interaction
            ).response()
        }
        guard let localIdentifier = result.localIdentifier, result.error == nil else {
            return try MediaFailure(
                message: "PhotoKit failed to import \(args.originalFilename): \(result.error ?? "unknown error")",
                category: IOSUseErrorCategory.action,
                code: IOSUseErrorCode.mediaImportFailed,
                phase: IOSUseErrorPhase.interaction
            ).response()
        }

        return try Codec.foryOKFromAnyThread(ForyMediaImportPayload(
            kind: args.kind,
            originalFilename: args.originalFilename,
            byteCount: args.byteCount,
            assetLocalIdentifier: localIdentifier,
            permissionPromptHandled: permission.promptHandled
        ))
    }

    private struct AssetCreationResult {
        let localIdentifier: String?
        let error: String?
    }

    private struct PermissionResolution {
        let promptHandled: Bool
    }

    private struct MediaFailure: Error {
        let message: String
        let category: String
        let code: String
        let phase: String
        var retryable = false

        func response() throws -> ForyResponseFrame {
            try Codec.foryError(
                message,
                category: category,
                code: code,
                phase: phase,
                retryable: retryable
            )
        }
    }

    private static func validate(_ args: ForyMediaImportArgs) -> MediaFailure? {
        guard args.kind == "photo" || args.kind == "video" else {
            return MediaFailure(
                message: "Unsupported media kind '\(args.kind)'",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.unsupportedMediaType,
                phase: IOSUseErrorPhase.validation
            )
        }
        guard !args.data.isEmpty,
              args.byteCount == Int64(args.data.count) else {
            return MediaFailure(
                message: "Media byteCount \(args.byteCount) does not match payload size \(args.data.count)",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.invalidArguments,
                phase: IOSUseErrorPhase.validation
            )
        }
        let filename = args.originalFilename
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              (filename as NSString).lastPathComponent == filename else {
            return MediaFailure(
                message: "Media originalFilename must be a basename",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.invalidArguments,
                phase: IOSUseErrorPhase.validation
            )
        }
        guard let type = UTType(args.uniformTypeIdentifier) else {
            return MediaFailure(
                message: "Unknown media type identifier '\(args.uniformTypeIdentifier)'",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.unsupportedMediaType,
                phase: IOSUseErrorPhase.validation
            )
        }
        let typeMatches = args.kind == "photo"
            ? type.conforms(to: .image)
            : type.conforms(to: .movie)
        guard typeMatches else {
            return MediaFailure(
                message: "Media kind '\(args.kind)' does not match \(type.identifier)",
                category: IOSUseErrorCategory.validation,
                code: IOSUseErrorCode.unsupportedMediaType,
                phase: IOSUseErrorPhase.validation
            )
        }
        return nil
    }

    private static func requestInitialPermission(
        library: MediaPhotoLibrary,
        promptHandler: PhotosPermissionPromptHandling,
        commandDeadline: Date
    ) -> Result<PermissionResolution, MediaFailure> {
        let coordinator = MediaAuthorizationCoordinator()
        library.requestAuthorization {
            coordinator.setAuthorization($0)
        }
        let promptDeadline = min(
            commandDeadline,
            Date().addingTimeInterval(IOSUseProtocol.mediaPermissionPromptDiscoveryTimeoutSeconds)
        )
        promptHandler.handle(
            deadline: promptDeadline,
            shouldStop: { coordinator.shouldStop() }
        ) {
            coordinator.setPrompt($0)
        }

        while Date() < commandDeadline {
            var snapshot = coordinator.snapshot()
            if let authorization = snapshot.authorization {
                // `XCUIElement.tap()` can grant authorization before the tap call
                // itself returns. Wait for the prompt handler's terminal outcome
                // instead of guessing with a fixed post-authorization delay.
                while snapshot.prompt == nil, Date() < promptDeadline {
                    coordinator.waitForChange(
                        until: min(
                            promptDeadline,
                            Date().addingTimeInterval(IOSUseProtocol.mediaPermissionPromptPollIntervalSeconds)
                        )
                    )
                    snapshot = coordinator.snapshot()
                }
                coordinator.stop()
                let promptHandled: Bool
                if case .handled? = snapshot.prompt {
                    promptHandled = true
                } else {
                    promptHandled = false
                }
                switch authorization {
                case .allowed:
                    return .success(PermissionResolution(promptHandled: promptHandled))
                case .denied:
                    return .failure(permissionFailure(
                        message: "Photos add-only access was denied",
                        code: IOSUseErrorCode.photosAddPermissionDenied
                    ))
                case .restricted:
                    return .failure(permissionFailure(
                        message: "Photos add-only access is restricted",
                        code: IOSUseErrorCode.photosAddPermissionRestricted
                    ))
                case .notDetermined:
                    return .failure(permissionFailure(
                        message: "Photos authorization remained not determined after requesting access",
                        code: IOSUseErrorCode.photosPermissionInteractionRequired
                    ))
                case .unknown(let rawValue):
                    return .failure(permissionFailure(
                        message: "Photos authorization returned unknown status \(rawValue)",
                        code: IOSUseErrorCode.photosPermissionInteractionRequired
                    ))
                }
            }

            if case .interactionRequired(let diagnostic)? = snapshot.prompt {
                coordinator.stop()
                return .failure(permissionFailure(
                    message: "Photos permission requires manual interaction: \(diagnostic)",
                    code: IOSUseErrorCode.photosPermissionInteractionRequired
                ))
            }
            coordinator.waitForChange(
                until: min(commandDeadline, Date().addingTimeInterval(0.1))
            )
        }

        coordinator.stop()
        return .failure(permissionFailure(
            message: "Photos authorization did not complete within \(formattedSeconds(IOSUseProtocol.mediaImportTimeoutSeconds))s",
            code: IOSUseErrorCode.photosAuthorizationTimedOut
        ))
    }

    private static func permissionFailure(message: String, code: String) -> MediaFailure {
        MediaFailure(
            message: message,
            category: IOSUseErrorCategory.authorization,
            code: code,
            phase: IOSUseErrorPhase.authorization
        )
    }

    private static func formattedSeconds(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
