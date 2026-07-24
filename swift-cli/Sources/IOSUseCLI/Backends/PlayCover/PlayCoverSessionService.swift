import Foundation

enum PlayCoverSessionService {
    static let deviceType = "playcover"

    struct PreparedReference: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let appPath: String
        let bundleIdentifier: String
        let profileHash: String
    }

    struct LaunchResult: Equatable, Sendable {
        let appPath: String
        let bundleIdentifier: String
        let profileHash: String
        let productType: String
        let pid: Int32
    }

    static var launchOverrideForTesting: ((String, Double) throws -> LaunchResult)?
    static var terminateOverrideForTesting: ((String) throws -> Int32)?

    static func recordPrepared(
        _ manifest: PlayCoverPrepareManifest,
        paths: IOSUsePaths
    ) throws {
        try writeReference(
            PreparedReference(
                schemaVersion: 1,
                appPath: manifest.preparedAppPath,
                bundleIdentifier: manifest.bundleIdentifier,
                profileHash: manifest.profileHash
            ),
            paths: paths
        )
    }

    static func resolvePreparedAppPath(
        explicitAppPath: String?,
        paths: IOSUsePaths
    ) throws -> String {
        if let explicitAppPath, !explicitAppPath.isEmpty {
            return URL(fileURLWithPath: explicitAppPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
        guard let reference = try readPreparedReference(paths: paths) else {
            throw PlayCoverBackendError.launchFailed(
                "no prepared App is selected; run `ios-use playcover prepare ...` or pass `--app <prepared.app>`"
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
                pid: hello.pid
            )
        }
        guard result.pid > 0 else {
            throw PlayCoverBackendError.launchFailed(
                "runtime hello returned an invalid pid"
            )
        }
        return result
    }

    @discardableResult
    static func terminate(appPath: String) throws -> Int32 {
        if let terminateOverrideForTesting {
            return try terminateOverrideForTesting(appPath)
        }
        return try PlayCoverService.terminate(appPath: appPath)
    }

    static func terminate(session: SessionService.Info) throws -> Int32 {
        guard session.deviceType == deviceType,
              let appPath = session.playCoverAppPath,
              !appPath.isEmpty else {
            throw CLIParseError.invalidValue(
                "Invalid driver.lock: PlayCover session is missing playcoverAppPath."
            )
        }
        return try terminate(appPath: appPath)
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
            profileHash: result.profileHash
        )
    }

    static func readPreparedReference(paths: IOSUsePaths) throws -> PreparedReference? {
        guard FileManager.default.fileExists(atPath: paths.playcoverLastPrepared) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: paths.playcoverLastPrepared))
            let reference = try JSONDecoder().decode(PreparedReference.self, from: data)
            guard reference.schemaVersion == 1,
                  !reference.appPath.isEmpty,
                  !reference.bundleIdentifier.isEmpty,
                  !reference.profileHash.isEmpty else {
                throw PlayCoverBackendError.launchFailed(
                    "last prepared App record is incomplete"
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
