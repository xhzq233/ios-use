import CryptoKit
import Foundation

/// Resolves a caller-supplied App into one verified, launchable PlayCover
/// generation without exposing runtime or output-path plumbing in `start`.
enum PlayCoverManagedAppService {
    static let preparationRevision = 1

    static var inspectOverrideForTesting: ((String) throws -> PlayCoverAppInspection)?
    static var verifyOverrideForTesting: ((String) throws -> PlayCoverVerification)?
    static var prepareOverrideForTesting: ((
        String,
        String,
        String,
        IOSUsePaths
    ) throws -> PlayCoverPrepareManifest)?
    static var runtimePathOverrideForTesting: ((IOSUsePaths) throws -> String)?
    static var executablePathOverrideForTesting: (() throws -> String)?
    static var generationKeyOverrideForTesting: ((
        PlayCoverAppInspection,
        String
    ) throws -> String)?

    static func resolveExplicitApp(
        _ appPath: String,
        paths: IOSUsePaths
    ) throws -> String {
        let canonicalAppPath = standardizedPath(appPath)
        if hasPreparedMarkers(at: canonicalAppPath) {
            return try verifyApp(at: canonicalAppPath).manifest.preparedAppPath
        }

        let inspection = try inspectApp(at: canonicalAppPath)
        if inspection.mainExecutable.encrypted {
            throw PlayCoverBackendError.encryptedMachO(
                inspection.mainExecutable.path
            )
        }
        guard inspection.mainExecutable.platform == PlayCoverMachO.platformIPhoneOS,
              !inspection.mainExecutable.runtimeInjected else {
            if inspection.mainExecutable.isMacCatalyst
                || inspection.mainExecutable.runtimeInjected {
                throw PlayCoverBackendError.verificationFailed(
                    "the App looks converted but is missing a complete ios-use "
                        + "PlayCover manifest/profile; pass an unmodified iPhoneOS "
                        + "source App or a complete prepared App"
                )
            }
            throw PlayCoverBackendError.unsupportedMachO(
                "\(inspection.executablePath) is platform "
                    + "\(inspection.mainExecutable.platform.map(String.init) ?? "unknown")"
            )
        }

        let runtimePath = try resolveDefaultRuntime(paths: paths)
        let generationKey: String
        if let generationKeyOverrideForTesting {
            generationKey = try generationKeyOverrideForTesting(
                inspection,
                runtimePath
            )
        } else {
            generationKey = try makeGenerationKey(
                inspection: inspection,
                runtimeFrameworkPath: runtimePath
            )
        }
        guard generationKey.count >= 16 else {
            throw PlayCoverBackendError.prepareFailed(
                "managed generation key is invalid"
            )
        }

        let outputPath = managedOutputPath(
            inspection: inspection,
            generationKey: generationKey,
            paths: paths
        )
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputPath) {
            let verification = try verifyApp(at: outputPath)
            try validateManagedGeneration(
                verification,
                source: inspection,
                outputPath: outputPath
            )
            try PlayCoverSessionService.recordPrepared(
                verification.manifest,
                paths: paths
            )
            return verification.manifest.preparedAppPath
        }

        let manifest: PlayCoverPrepareManifest
        if let prepareOverrideForTesting {
            manifest = try prepareOverrideForTesting(
                inspection.appPath,
                outputPath,
                runtimePath,
                paths
            )
        } else {
            manifest = try PlayCoverService.prepare(
                sourceAppPath: inspection.appPath,
                outputAppPath: outputPath,
                runtimeFrameworkPath: runtimePath,
                paths: paths,
                profile: inspection.profile
            )
        }
        try validateManagedManifest(
            manifest,
            source: inspection,
            outputPath: outputPath
        )
        try PlayCoverSessionService.recordPrepared(manifest, paths: paths)
        return manifest.preparedAppPath
    }

    static func runtimeCandidates(
        paths: IOSUsePaths,
        executablePath: String
    ) -> [String] {
        let executableDirectory = URL(fileURLWithPath: executablePath)
            .standardizedFileURL
            .deletingLastPathComponent()
        let candidates = [
            paths.playcoverRuntime,
            executableDirectory
                .appendingPathComponent(".ios-use", isDirectory: true)
                .appendingPathComponent("playcover", isDirectory: true)
                .appendingPathComponent(PlayCoverService.runtimeFrameworkName)
                .path,
            executableDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("share", isDirectory: true)
                .appendingPathComponent("ios-use", isDirectory: true)
                .appendingPathComponent("playcover", isDirectory: true)
                .appendingPathComponent(PlayCoverService.runtimeFrameworkName)
                .path,
        ]
        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            let canonical = standardizedPath(candidate)
            return seen.insert(canonical).inserted ? canonical : nil
        }
    }

    static func resolveDefaultRuntime(paths: IOSUsePaths) throws -> String {
        if let runtimePathOverrideForTesting {
            let path = standardizedPath(try runtimePathOverrideForTesting(paths))
            guard isRuntimeFrameworkPresent(at: path) else {
                throw PlayCoverBackendError.missingRuntime(path)
            }
            return path
        }

        let executablePath = try currentExecutablePath()
        let candidates = runtimeCandidates(
            paths: paths,
            executablePath: executablePath
        )
        if let runtime = candidates.first(where: {
            isRuntimeFrameworkPresent(at: $0)
        }) {
            return runtime
        }
        throw PlayCoverBackendError.missingRuntime(
            "no default runtime was found; build the source CLI with "
                + "`bash scripts/build_swift_cli.sh --debug` or install "
                + "\(PlayCoverService.runtimeFrameworkName) under "
                + "\(paths.playcover). Searched: \(candidates.joined(separator: ", "))"
        )
    }

    private static func inspectApp(at appPath: String) throws -> PlayCoverAppInspection {
        if let inspectOverrideForTesting {
            return try inspectOverrideForTesting(appPath)
        }
        return try PlayCoverService.inspect(appPath: appPath)
    }

    private static func verifyApp(at appPath: String) throws -> PlayCoverVerification {
        if let verifyOverrideForTesting {
            return try verifyOverrideForTesting(appPath)
        }
        return try PlayCoverService.verify(appPath: appPath)
    }

    private static func hasPreparedMarkers(at appPath: String) -> Bool {
        let app = URL(fileURLWithPath: appPath, isDirectory: true)
        let candidates = [
            app.appendingPathComponent(PlayCoverService.manifestFilename).path,
            app.appendingPathComponent(PlayCoverService.profileFilename).path,
            app
                .appendingPathComponent("Frameworks", isDirectory: true)
                .appendingPathComponent(
                    PlayCoverService.runtimeFrameworkName,
                    isDirectory: true
                )
                .path,
        ]
        return candidates.contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    private static func managedOutputPath(
        inspection: PlayCoverAppInspection,
        generationKey: String,
        paths: IOSUsePaths
    ) -> String {
        let safeBundleIdentifier = inspection.bundleIdentifier.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "-",
            options: .regularExpression
        )
        let stem = safeBundleIdentifier.isEmpty ? "App" : safeBundleIdentifier
        let name = "\(stem)-\(generationKey.prefix(16)).app"
        return URL(fileURLWithPath: paths.playcoverPrepared, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .standardizedFileURL
            .path
    }

    private static func validateManagedGeneration(
        _ verification: PlayCoverVerification,
        source: PlayCoverAppInspection,
        outputPath: String
    ) throws {
        try validateManagedManifest(
            verification.manifest,
            source: source,
            outputPath: outputPath
        )
        guard verification.profile == source.profile else {
            throw PlayCoverBackendError.verificationFailed(
                "managed generation uses a different device profile"
            )
        }
    }

    private static func validateManagedManifest(
        _ manifest: PlayCoverPrepareManifest,
        source: PlayCoverAppInspection,
        outputPath: String
    ) throws {
        guard standardizedPath(manifest.sourceAppPath) == source.appPath,
              standardizedPath(manifest.preparedAppPath)
                == standardizedPath(outputPath),
              manifest.bundleIdentifier == source.bundleIdentifier,
              manifest.profileHash == source.profileHash,
              manifest.backend == "playcover-headless" else {
            throw PlayCoverBackendError.verificationFailed(
                "managed generation does not match the selected source App"
            )
        }
    }

    private static func makeGenerationKey(
        inspection: PlayCoverAppInspection,
        runtimeFrameworkPath: String
    ) throws -> String {
        do {
            var hasher = SHA256()
            update(
                &hasher,
                with: "ios-use-playcover-managed-v\(preparationRevision)"
            )
            update(&hasher, with: inspection.appPath)
            update(&hasher, with: inspection.profileHash)

            let sourceURL = URL(
                fileURLWithPath: inspection.appPath,
                isDirectory: true
            )
            try appendTreeMetadata(
                sourceURL,
                relativePath: ".",
                to: &hasher
            )
            try appendFileContents(
                URL(fileURLWithPath: inspection.executablePath),
                label: "source-main",
                to: &hasher
            )
            try appendFileContents(
                sourceURL.appendingPathComponent("Info.plist"),
                label: "source-info",
                to: &hasher
            )

            let runtimeURL = URL(
                fileURLWithPath: runtimeFrameworkPath,
                isDirectory: true
            )
            try appendTreeMetadata(
                runtimeURL,
                relativePath: ".",
                to: &hasher
            )
            try appendFileContents(
                runtimeURL.appendingPathComponent(
                    PlayCoverService.runtimeExecutableName
                ),
                label: "runtime-main",
                to: &hasher
            )
            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch let error as PlayCoverBackendError {
            throw error
        } catch {
            throw PlayCoverBackendError.prepareFailed(
                "cannot fingerprint the source App and runtime: \(error)"
            )
        }
    }

    private static func appendTreeMetadata(
        _ url: URL,
        relativePath: String,
        to hasher: inout SHA256
    ) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        let values = try url.resourceValues(forKeys: keys)
        let type: String
        if values.isSymbolicLink == true {
            type = "symlink"
        } else if values.isDirectory == true {
            type = "directory"
        } else if values.isRegularFile == true {
            type = "file"
        } else {
            type = "other"
        }
        let modified = values.contentModificationDate?
            .timeIntervalSinceReferenceDate.bitPattern ?? 0
        update(
            &hasher,
            with: "\(relativePath)|\(type)|\(values.fileSize ?? 0)|\(modified)"
        )

        if values.isSymbolicLink == true {
            let destination = try FileManager.default.destinationOfSymbolicLink(
                atPath: url.path
            )
            update(&hasher, with: "destination|\(destination)")
            return
        }
        guard values.isDirectory == true else {
            return
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ).sorted { lhs, rhs in
            lhs.lastPathComponent < rhs.lastPathComponent
        }
        for child in children {
            let childRelative = relativePath == "."
                ? child.lastPathComponent
                : "\(relativePath)/\(child.lastPathComponent)"
            try appendTreeMetadata(
                child,
                relativePath: childRelative,
                to: &hasher
            )
        }
    }

    private static func appendFileContents(
        _ url: URL,
        label: String,
        to hasher: inout SHA256
    ) throws {
        update(&hasher, with: label)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
    }

    private static func update(_ hasher: inout SHA256, with string: String) {
        hasher.update(data: Data(string.utf8))
        hasher.update(data: Data([0]))
    }

    private static func isRuntimeFrameworkPresent(at path: String) -> Bool {
        let runtime = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        return runtime.lastPathComponent == PlayCoverService.runtimeFrameworkName
            && FileManager.default.fileExists(
                atPath: runtime.path,
                isDirectory: &isDirectory
            )
            && isDirectory.boolValue
            && FileManager.default.isExecutableFile(
                atPath: runtime
                    .appendingPathComponent(
                        PlayCoverService.runtimeExecutableName
                    )
                    .path
            )
    }

    private static func currentExecutablePath() throws -> String {
        if let executablePathOverrideForTesting {
            return try executablePathOverrideForTesting()
        }
        if let path = Bundle.main.executableURL?.path,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        guard let arg0 = ProcessInfo.processInfo.arguments.first,
              !arg0.isEmpty else {
            throw PlayCoverBackendError.missingRuntime(
                "cannot resolve the current ios-use executable"
            )
        }
        let candidate: URL
        if arg0.hasPrefix("/") {
            candidate = URL(fileURLWithPath: arg0)
        } else {
            candidate = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            ).appendingPathComponent(arg0)
        }
        return candidate.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
