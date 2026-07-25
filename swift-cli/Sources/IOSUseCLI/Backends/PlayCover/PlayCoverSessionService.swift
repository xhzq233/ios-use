import Foundation

enum PlayCoverSessionService {
    static let deviceType = "playcover"

    struct PreparedReference: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let appPath: String
        let bundleIdentifier: String
        let profileHash: String
        let preparedGenerationID: String
    }

    struct LaunchResult: Equatable, Sendable {
        let appPath: String
        let bundleIdentifier: String
        let profileHash: String
        let productType: String
        let pid: Int32
        let runtimeSocketPath: String?
        let launchNonce: String?
        let preparedGenerationID: String?
        let runtimeInstanceID: String?

        init(
            appPath: String,
            bundleIdentifier: String,
            profileHash: String,
            productType: String,
            pid: Int32,
            runtimeSocketPath: String? = nil,
            launchNonce: String? = nil,
            preparedGenerationID: String? = nil,
            runtimeInstanceID: String? = nil
        ) {
            self.appPath = appPath
            self.bundleIdentifier = bundleIdentifier
            self.profileHash = profileHash
            self.productType = productType
            self.pid = pid
            self.runtimeSocketPath = runtimeSocketPath
            self.launchNonce = launchNonce
            self.preparedGenerationID = preparedGenerationID
            self.runtimeInstanceID = runtimeInstanceID
        }
    }

    static var launchOverrideForTesting: ((String, Double) throws -> LaunchResult)?
    static var terminateOverrideForTesting: ((String) throws -> Int32)?

    static func recordPrepared(
        _ manifest: PlayCoverPrepareManifest,
        paths: IOSUsePaths
    ) throws {
        try writeReference(
            PreparedReference(
                schemaVersion: 2,
                appPath: manifest.preparedAppPath,
                bundleIdentifier: manifest.bundleIdentifier,
                profileHash: manifest.profileHash,
                preparedGenerationID: manifest.preparedGenerationID
            ),
            paths: paths
        )
    }

    static func resolvePreparedAppPath(
        explicitAppPath: String?,
        paths: IOSUsePaths
    ) throws -> String {
        if let explicitAppPath, !explicitAppPath.isEmpty {
            return try PlayCoverManagedAppService.resolveExplicitApp(
                explicitAppPath,
                paths: paths
            )
        }
        guard let reference = try readPreparedReference(paths: paths) else {
            throw PlayCoverBackendError.launchFailed(
                "no prepared App is selected; pass `--app <source-or-prepared.app>`"
            )
        }
        return reference.appPath
    }

    static func launch(
        explicitAppPath: String?,
        timeout: Double,
        paths: IOSUsePaths
    ) throws -> LaunchResult {
        let appPath = try resolvePreparedAppPath(
            explicitAppPath: explicitAppPath,
            paths: paths
        )
        let result: LaunchResult
        if let launchOverrideForTesting {
            result = try launchOverrideForTesting(appPath, timeout)
        } else {
            let verification = try PlayCoverService.verify(appPath: appPath)
            let hello = try PlayCoverService.launch(appPath: appPath, timeout: timeout)
            result = LaunchResult(
                appPath: verification.manifest.preparedAppPath,
                bundleIdentifier: verification.manifest.bundleIdentifier,
                profileHash: verification.manifest.profileHash,
                productType: verification.profile.productType,
                pid: hello.pid,
                runtimeSocketPath: verification.manifest.runtimeSocketPath,
                launchNonce: hello.launchNonce,
                preparedGenerationID: hello.preparedGenerationID,
                runtimeInstanceID: hello.runtimeInstanceID
            )
        }
        guard result.pid > 0,
              let runtimeSocketPath = result.runtimeSocketPath,
              !runtimeSocketPath.isEmpty,
              let launchNonce = result.launchNonce,
              !launchNonce.isEmpty,
              let preparedGenerationID = result.preparedGenerationID,
              !preparedGenerationID.isEmpty,
              let runtimeInstanceID = result.runtimeInstanceID,
              !runtimeInstanceID.isEmpty else {
            throw PlayCoverBackendError.launchFailed(
                "runtime hello returned incomplete session identity"
            )
        }
        return result
    }

    @discardableResult
    static func terminate(result: LaunchResult) throws -> Int32 {
        if let terminateOverrideForTesting {
            return try terminateOverrideForTesting(result.appPath)
        }
        return try PlayCoverService.terminate(
            session: makeSessionInfo(from: result)
        )
    }

    static func terminate(session: SessionService.Info) throws -> Int32 {
        guard session.deviceType == deviceType,
              let appPath = session.playCoverAppPath,
              !appPath.isEmpty else {
            throw CLIParseError.invalidValue(
                "Invalid driver.lock: PlayCover App identity is incomplete."
            )
        }
        if let terminateOverrideForTesting {
            return try terminateOverrideForTesting(appPath)
        }
        guard session.playCoverRuntimeSocketPath?.isEmpty == false,
              session.playCoverLaunchNonce?.isEmpty == false,
              session.playCoverPreparedGenerationID?.isEmpty == false,
              session.playCoverRuntimeInstanceID?.isEmpty == false else {
            throw CLIParseError.invalidValue(
                "Invalid driver.lock: PlayCover runtime identity is incomplete."
            )
        }
        return try PlayCoverService.terminate(session: session)
    }

    static func makeSessionInfo(from result: LaunchResult) -> SessionService.Info {
        SessionService.Info(
            udid: "playcover:\(result.bundleIdentifier)",
            deviceName: result.productType,
            deviceVersion: "Mac Catalyst",
            deviceType: deviceType,
            runnerPid: Int(result.pid),
            startMode: deviceType,
            bundleId: result.bundleIdentifier,
            playCoverAppPath: result.appPath,
            profileHash: result.profileHash,
            playCoverRuntimeSocketPath: result.runtimeSocketPath,
            playCoverLaunchNonce: result.launchNonce,
            playCoverPreparedGenerationID: result.preparedGenerationID,
            playCoverRuntimeInstanceID: result.runtimeInstanceID
        )
    }

    static func readPreparedReference(paths: IOSUsePaths) throws -> PreparedReference? {
        guard FileManager.default.fileExists(atPath: paths.playcoverLastPrepared) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: paths.playcoverLastPrepared))
            let reference = try JSONDecoder().decode(PreparedReference.self, from: data)
            guard !reference.appPath.isEmpty,
                  !reference.bundleIdentifier.isEmpty,
                  !reference.profileHash.isEmpty,
                  !reference.preparedGenerationID.isEmpty else {
                throw PlayCoverBackendError.launchFailed(
                    "last prepared App record is incomplete"
                )
            }
            guard reference.schemaVersion == 2 else {
                throw PlayCoverBackendError.launchFailed(
                    "last prepared App record schema is unsupported"
                )
            }
            return reference
        } catch let error as PlayCoverBackendError {
            throw error
        } catch {
            throw PlayCoverBackendError.launchFailed(
                "cannot read \(paths.playcoverLastPrepared): \(error)"
            )
        }
    }

    private static func writeReference(
        _ reference: PreparedReference,
        paths: IOSUsePaths
    ) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: paths.playcover,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(reference)
            try data.write(
                to: URL(fileURLWithPath: paths.playcoverLastPrepared),
                options: .atomic
            )
        } catch {
            throw PlayCoverBackendError.prepareFailed(
                "cannot record the last prepared App: \(error)"
            )
        }
    }
}
