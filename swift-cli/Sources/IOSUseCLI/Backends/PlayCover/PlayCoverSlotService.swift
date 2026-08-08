import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct PlayCoverSlotMetadata: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let appRelativePath: String
    let executableRelativePath: String
    let installRevision: String
}

struct PlayCoverInstalledSlot: Equatable, Sendable {
    let metadata: PlayCoverSlotMetadata
    let appPath: String
    let executablePath: String
}

/// The account-global, single-current-App store for the Mac backend.
enum PlayCoverSlotService {
    static let metadataFilename = "slot.json"
    static let installContractRevision = "mac-bundle-slot-v1"
    private static let maximumMetadataBytes = 64 * 1_024
    private static let processLock = NSLock()

    static var prepareOverrideForTesting: ((
        PlayCoverPreparationPlan,
        String,
        IOSUsePaths,
        String
    ) throws -> PlayCoverPreparedApp)?
    static var publishOverrideForTesting: ((URL, URL, Bool) throws -> Void)?
    static var runtimePathOverrideForTesting:
        ((IOSUsePaths) throws -> String)?
    static var executablePathOverrideForTesting: (() throws -> String)?
    static var currentInstallRevisionOverrideForTesting:
        ((IOSUsePaths) throws -> String)?

    static func install(
        sourceAppPath: String,
        paths: IOSUsePaths,
        signingIdentity: PlayCoverSigningIdentityEvidence
    ) throws -> PlayCoverInstalledSlot {
        let sourcePath = URL(
            fileURLWithPath: sourceAppPath,
            isDirectory: true
        ).standardizedFileURL.path
        guard !isInsideAppsRoot(sourcePath, paths: paths) else {
            throw PlayCoverBackendError.invalidApp(
                "--app expects a source App, not an installed Mac slot; "
                    + "use --reuse"
            )
        }
        let preparationSource = try PlayCoverService
            .inspectPreparationSource(appPath: sourcePath)
        try validateSource(preparationSource.inspection)
        let bundleIdentifier = preparationSource.inspection.bundleIdentifier
        try validateBundleIdentifier(bundleIdentifier)
        let displayName = try resolvedDisplayName(
            sourceAppPath: sourcePath,
            bundleIdentifier: bundleIdentifier
        )
        let appRelativePath = "\(displayName).app"
        try validateAppRelativePath(appRelativePath)

        let runtimePath = try resolveDefaultRuntime(paths: paths)
        let engine = try PlayCoverFridaEngineService.ensureAvailable()
        let plan = try PlayCoverService.makePreparationPlan(
            source: preparationSource,
            runtimeFrameworkPath: runtimePath,
            paths: paths,
            signingIdentity: signingIdentity,
            fridaEngine: engine
        )
        let installRevision = makeInstallRevision(
            runtimeBuildHash: plan.runtimeBuildHash,
            prepareRevision: plan.prepareRevision,
            accountNamespacePolicyHash:
                plan.accountNamespacePolicyHash
        )
        let executableRelativePath = preparationSource.inspection
            .mainExecutableRelativePath
        try validateExecutableRelativePath(executableRelativePath)
        let metadata = PlayCoverSlotMetadata(
            bundleIdentifier: bundleIdentifier,
            appRelativePath: appRelativePath,
            executableRelativePath: executableRelativePath,
            installRevision: installRevision
        )

        processLock.lock()
        defer { processLock.unlock() }
        let appsRoot = try ensureAppsRoot(paths: paths)
        try recoverResidues(
            bundleIdentifier: bundleIdentifier,
            appsRoot: appsRoot
        )
        let stagingName = stagingDirectoryName(
            bundleIdentifier: bundleIdentifier
        )
        let stagingDirectory = appsRoot.appendingPathComponent(
            stagingName,
            isDirectory: true
        )
        let stagingApp = stagingDirectory.appendingPathComponent(
            appRelativePath,
            isDirectory: true
        )
        let finalDirectory = appsRoot.appendingPathComponent(
            bundleIdentifier,
            isDirectory: true
        )
        let finalApp = finalDirectory.appendingPathComponent(
            appRelativePath,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var removeStaging = true
        defer {
            if removeStaging {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
        }
        let preparedApp: PlayCoverPreparedApp
        if let prepareOverrideForTesting {
            preparedApp = try prepareOverrideForTesting(
                plan,
                stagingApp.path,
                paths,
                finalApp.path
            )
        } else {
            preparedApp = try PlayCoverService.prepareArtifact(
                plan: plan,
                outputAppPath: stagingApp.path,
                paths: paths,
                publishedAppPath: finalApp.path
            ).preparedApp
        }
        guard preparedApp.bundleIdentifier == bundleIdentifier,
              preparedApp.executablePath
                == finalApp.appendingPathComponent(
                    executableRelativePath
                ).path,
              preparedApp.fridaEngineSHA256 == engine.sha256 else {
            throw PlayCoverBackendError.verificationFailed(
                "prepared App does not match the fixed slot identity"
            )
        }
        try writeMetadata(metadata, in: stagingDirectory)
        try syncTreeRoot(stagingDirectory)

        let replacing = FileManager.default.fileExists(
            atPath: finalDirectory.path
        )
        if let publishOverrideForTesting {
            try publishOverrideForTesting(
                stagingDirectory,
                finalDirectory,
                replacing
            )
        } else {
            try publish(
                staging: stagingDirectory,
                current: finalDirectory,
                replacing: replacing,
                appsRoot: appsRoot
            )
        }
        if replacing {
            // After RENAME_SWAP the old slot occupies the staging name.
            // Its removal is rebuildable cleanup, not a rollback generation.
            try? FileManager.default.removeItem(at: stagingDirectory)
        }
        removeStaging = false
        let installed = try read(
            bundleIdentifier: bundleIdentifier,
            paths: paths,
            expectedInstallRevision: installRevision
        )
        guard installed.metadata == metadata else {
            throw PlayCoverBackendError.cacheTampered(
                "published Mac slot metadata changed during installation"
            )
        }
        return installed
    }

    static func readCurrent(
        paths: IOSUsePaths
    ) throws -> PlayCoverInstalledSlot? {
        guard let bundleIdentifier = try PlayCoverHomeStore
            .readCurrentBundle(paths: paths) else {
            return nil
        }
        return try read(
            bundleIdentifier: bundleIdentifier,
            paths: paths,
            expectedInstallRevision: currentInstallRevision(paths: paths)
        )
    }

    static func read(
        bundleIdentifier: String,
        paths: IOSUsePaths,
        expectedInstallRevision: String? = nil
    ) throws -> PlayCoverInstalledSlot {
        try validateBundleIdentifier(bundleIdentifier)
        let slotDirectory = URL(
            fileURLWithPath: paths.playcoverApps,
            isDirectory: true
        ).appendingPathComponent(bundleIdentifier, isDirectory: true)
        let metadataURL = slotDirectory.appendingPathComponent(
            metadataFilename
        )
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw PlayCoverBackendError.launchFailed(
                "no current Mac App is installed for \(bundleIdentifier); "
                    + "run `ios-use start --mac --app <source.app>`"
            )
        }
        let data = try boundedMetadata(at: metadataURL)
        let metadata: PlayCoverSlotMetadata
        do {
            guard let object = try JSONSerialization
                    .jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set([
                    "bundleIdentifier",
                    "appRelativePath",
                    "executableRelativePath",
                    "installRevision",
                  ]) else {
                throw PlayCoverBackendError.cacheTampered(
                    "Mac slot metadata has unknown fields"
                )
            }
            metadata = try JSONDecoder().decode(
                PlayCoverSlotMetadata.self,
                from: data
            )
        } catch let error as PlayCoverBackendError {
            throw error
        } catch {
            throw PlayCoverBackendError.cacheTampered(
                "Mac slot metadata is not valid JSON"
            )
        }
        try validateMetadata(metadata)
        guard metadata.bundleIdentifier == bundleIdentifier else {
            throw PlayCoverBackendError.cacheTampered(
                "Mac slot Bundle ID does not match its directory"
            )
        }
        if let expectedInstallRevision,
           metadata.installRevision != expectedInstallRevision {
            throw PlayCoverBackendError.launchFailed(
                "the installed Mac App is from an incompatible ios-use "
                    + "prepare contract; reinstall it with `--app`"
            )
        }
        let app = slotDirectory.appendingPathComponent(
            metadata.appRelativePath,
            isDirectory: true
        )
        let executable = app.appendingPathComponent(
            metadata.executableRelativePath
        )
        var appIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
                atPath: app.path,
                isDirectory: &appIsDirectory
              ),
              appIsDirectory.boolValue,
              FileManager.default.isExecutableFile(
                atPath: executable.path
              ),
              FileManager.default.fileExists(
                atPath: app.appendingPathComponent(
                    "Frameworks/IOSUsePlayRuntime.framework/IOSUsePlayRuntime"
                ).path
              ),
              FileManager.default.fileExists(
                atPath: app.appendingPathComponent(
                    "Frameworks/IOSUseFridaEngine.framework/IOSUseFridaEngine"
                ).path
              ) else {
            throw PlayCoverBackendError.cacheTampered(
                "Mac slot is incomplete or missing Runtime/Frida Engine"
            )
        }
        let observedIdentity = try readAppIdentity(
            appURL: app
        )
        guard observedIdentity.bundleIdentifier == bundleIdentifier,
              observedIdentity.executableRelativePath
                == metadata.executableRelativePath else {
            throw PlayCoverBackendError.cacheTampered(
                "Mac slot Info.plist identity changed"
            )
        }
        let visibleEntries = try FileManager.default.contentsOfDirectory(
            atPath: slotDirectory.path
        ).filter { !$0.hasPrefix(".") }
        guard Set(visibleEntries) == Set([
            metadata.appRelativePath,
            metadataFilename,
        ]) else {
            throw PlayCoverBackendError.cacheTampered(
                "Mac slot must contain exactly one App and slot.json"
            )
        }
        return PlayCoverInstalledSlot(
            metadata: metadata,
            appPath: app.path,
            executablePath: executable.path
        )
    }

    static func currentInstallRevision(
        paths: IOSUsePaths
    ) throws -> String {
        if let currentInstallRevisionOverrideForTesting {
            return try currentInstallRevisionOverrideForTesting(paths)
        }
        let runtime = try resolveDefaultRuntime(paths: paths)
        let engine = try PlayCoverFridaEngineService.ensureAvailable()
        return makeInstallRevision(
            runtimeBuildHash: try PlayCoverService.runtimeBuildHash(
                frameworkPath: runtime
            ),
            prepareRevision: PlayCoverService.fridaPrepareRevision(
                engineSHA256: engine.sha256
            ),
            accountNamespacePolicyHash:
                PlayCoverService.accountNamespacePolicyHash(paths: paths)
        )
    }

    static func resolveDefaultRuntime(paths: IOSUsePaths) throws -> String {
        if let runtimePathOverrideForTesting {
            let value = URL(
                fileURLWithPath: try runtimePathOverrideForTesting(paths),
                isDirectory: true
            ).standardizedFileURL.path
            guard isRuntimeFrameworkPresent(at: value) else {
                throw PlayCoverBackendError.missingRuntime(value)
            }
            return value
        }
        let executablePath: String
        if let executablePathOverrideForTesting {
            executablePath = try executablePathOverrideForTesting()
        } else if let value = Bundle.main.executableURL?.path {
            executablePath = value
        } else if let value = ProcessInfo.processInfo.arguments.first {
            executablePath = value.hasPrefix("/")
                ? value
                : URL(
                    fileURLWithPath:
                        FileManager.default.currentDirectoryPath,
                    isDirectory: true
                ).appendingPathComponent(value).path
        } else {
            throw PlayCoverBackendError.missingRuntime(
                "cannot resolve the ios-use executable"
            )
        }
        let executableDirectory = URL(fileURLWithPath: executablePath)
            .standardizedFileURL.deletingLastPathComponent()
        let candidates = [
            executableDirectory
                .appendingPathComponent(".ios-use", isDirectory: true)
                .appendingPathComponent("playcover", isDirectory: true)
                .appendingPathComponent(
                    PlayCoverService.runtimeFrameworkName,
                    isDirectory: true
                ).path,
            executableDirectory.deletingLastPathComponent()
                .appendingPathComponent("share", isDirectory: true)
                .appendingPathComponent("ios-use", isDirectory: true)
                .appendingPathComponent("mac", isDirectory: true)
                .appendingPathComponent(
                    PlayCoverService.runtimeFrameworkName,
                    isDirectory: true
                ).path,
        ]
        var seen = Set<String>()
        let unique = candidates.compactMap { candidate -> String? in
            let value = URL(
                fileURLWithPath: candidate,
                isDirectory: true
            ).standardizedFileURL.path
            return seen.insert(value).inserted ? value : nil
        }
        if let value = unique.first(where: isRuntimeFrameworkPresent) {
            return value
        }
        throw PlayCoverBackendError.missingRuntime(
            "no default \(PlayCoverService.runtimeFrameworkName) found; "
                + "searched: \(unique.joined(separator: ", "))"
        )
    }

    static func validateBundleIdentifier(_ value: String) throws {
        guard isSafeComponent(value, maximumUTF8Bytes: 200) else {
            throw PlayCoverBackendError.invalidApp(
                "Mac App Bundle ID is not a safe path component"
            )
        }
    }

    #if DEBUG
    static func publishForTesting(
        staging: URL,
        current: URL,
        replacing: Bool,
        appsRoot: URL
    ) throws {
        try publish(
            staging: staging,
            current: current,
            replacing: replacing,
            appsRoot: appsRoot
        )
    }

    static func recoverResiduesForTesting(
        bundleIdentifier: String,
        appsRoot: URL
    ) throws {
        try recoverResidues(
            bundleIdentifier: bundleIdentifier,
            appsRoot: appsRoot
        )
    }

    static func stagingPrefixForTesting(
        bundleIdentifier: String
    ) -> String {
        stagingPrefix(bundleIdentifier: bundleIdentifier)
    }
    #endif

    private static func validateMetadata(
        _ metadata: PlayCoverSlotMetadata
    ) throws {
        try validateBundleIdentifier(metadata.bundleIdentifier)
        try validateAppRelativePath(metadata.appRelativePath)
        try validateExecutableRelativePath(
            metadata.executableRelativePath
        )
        guard isLowercaseSHA256(metadata.installRevision) else {
            throw PlayCoverBackendError.cacheTampered(
                "Mac slot installRevision is invalid"
            )
        }
    }

    private static func isRuntimeFrameworkPresent(at path: String) -> Bool {
        let runtime = URL(fileURLWithPath: path, isDirectory: true)
        var directory: ObjCBool = false
        return runtime.lastPathComponent
                == PlayCoverService.runtimeFrameworkName
            && FileManager.default.fileExists(
                atPath: runtime.path,
                isDirectory: &directory
            )
            && directory.boolValue
            && FileManager.default.isExecutableFile(
                atPath: runtime.appendingPathComponent(
                    PlayCoverService.runtimeExecutableName
                ).path
            )
    }

    private static func validateSource(
        _ source: PlayCoverAppInspection
    ) throws {
        for macho in source.machOs {
            if macho.encrypted {
                throw PlayCoverBackendError.encryptedMachO(macho.path)
            }
            guard macho.platform == PlayCoverMachO.platformIPhoneOS else {
                throw PlayCoverBackendError.unsupportedMachO(
                    "\(macho.path) must be an unmodified iPhoneOS Mach-O"
                )
            }
            if macho.dependencies.contains(where: {
                URL(fileURLWithPath: $0).lastPathComponent
                    == PlayCoverService.runtimeExecutableName
            }) {
                throw PlayCoverBackendError.duplicateRuntimeLoad(macho.path)
            }
        }
    }

    private static func resolvedDisplayName(
        sourceAppPath: String,
        bundleIdentifier: String
    ) throws -> String {
        let plistURL = URL(
            fileURLWithPath: sourceAppPath,
            isDirectory: true
        ).appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL, options: .mappedIfSafe)
        guard let plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            throw PlayCoverBackendError.invalidApp(
                "Mac source App Info.plist is invalid"
            )
        }
        let candidates = [
            plist["CFBundleDisplayName"] as? String,
            plist["CFBundleName"] as? String,
            bundleIdentifier,
        ]
        for raw in candidates.compactMap({ $0 }) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if isSafeComponent(value, maximumUTF8Bytes: 200),
               !value.lowercased().hasSuffix(".app") {
                return value
            }
        }
        return bundleIdentifier
    }

    private static func validateAppRelativePath(_ value: String) throws {
        let basename = String(value.dropLast(4))
        guard value.hasSuffix(".app"),
              isSafeComponent(basename, maximumUTF8Bytes: 200) else {
            throw PlayCoverBackendError.cacheTampered(
                "Mac slot App path is invalid"
            )
        }
    }

    private static func validateExecutableRelativePath(
        _ value: String
    ) throws {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              value.utf8.count <= 1_024,
              value.split(separator: "/").allSatisfy({
                isSafeComponent(String($0), maximumUTF8Bytes: 255)
              }) else {
            throw PlayCoverBackendError.cacheTampered(
                "Mac slot executable path is invalid"
            )
        }
    }

    private static func ensureAppsRoot(paths: IOSUsePaths) throws -> URL {
        let root = URL(
            fileURLWithPath: paths.playcoverApps,
            isDirectory: true
        ).standardizedFileURL
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #if canImport(Darwin)
        var status = stat()
        guard lstat(root.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              chmod(root.path, 0o700) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "Mac apps root must be an owner-only directory"
            )
        }
        #endif
        return root
    }

    private static func recoverResidues(
        bundleIdentifier: String,
        appsRoot: URL
    ) throws {
        let prefix = stagingPrefix(bundleIdentifier: bundleIdentifier)
        for name in try FileManager.default.contentsOfDirectory(
            atPath: appsRoot.path
        ) where name.hasPrefix(prefix) {
            try FileManager.default.removeItem(
                at: appsRoot.appendingPathComponent(name, isDirectory: true)
            )
        }
    }

    private static func publish(
        staging: URL,
        current: URL,
        replacing: Bool,
        appsRoot: URL
    ) throws {
        #if canImport(Darwin)
        let descriptor = Darwin.open(
            appsRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot open Mac apps root for atomic publish: errno \(errno)"
            )
        }
        defer { Darwin.close(descriptor) }
        let flags = replacing
            ? UInt32(RENAME_SWAP)
            : UInt32(RENAME_EXCL)
        guard Darwin.renameatx_np(
                descriptor,
                staging.lastPathComponent,
                descriptor,
                current.lastPathComponent,
                flags
              ) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "atomic Mac slot \(replacing ? "swap" : "install") failed: "
                    + "errno \(errno)"
            )
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot fsync Mac apps root after publish: errno \(errno)"
            )
        }
        #else
        guard !replacing else {
            throw PlayCoverBackendError.prepareFailed(
                "atomic Mac slot swap is supported only on macOS"
            )
        }
        try FileManager.default.moveItem(at: staging, to: current)
        #endif
    }

    private static func writeMetadata(
        _ metadata: PlayCoverSlotMetadata,
        in directory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(metadata)
        guard data.count <= maximumMetadataBytes else {
            throw PlayCoverBackendError.prepareFailed(
                "Mac slot metadata exceeds its size limit"
            )
        }
        let url = directory.appendingPathComponent(metadataFilename)
        try data.write(to: url, options: .atomic)
        #if canImport(Darwin)
        guard chmod(url.path, 0o600) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot secure Mac slot metadata: errno \(errno)"
            )
        }
        #endif
    }

    private static func boundedMetadata(at url: URL) throws -> Data {
        #if canImport(Darwin)
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= maximumMetadataBytes else {
            throw PlayCoverBackendError.cacheTampered(
                "Mac slot metadata is not a bounded owner-only file"
            )
        }
        #endif
        let data = try Data(contentsOf: url)
        guard data.count <= maximumMetadataBytes else {
            throw PlayCoverBackendError.cacheTampered(
                "Mac slot metadata exceeds its size limit"
            )
        }
        return data
    }

    private static func readAppIdentity(
        appURL: URL
    ) throws -> (
        bundleIdentifier: String,
        executableRelativePath: String
    ) {
        let data = try Data(
            contentsOf: appURL.appendingPathComponent("Info.plist"),
            options: .mappedIfSafe
        )
        guard let plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let bundleIdentifier = plist["CFBundleIdentifier"] as? String,
              let executable = plist["CFBundleExecutable"] as? String else {
            throw PlayCoverBackendError.cacheTampered(
                "Mac slot App has no Bundle ID or executable"
            )
        }
        return (bundleIdentifier, executable)
    }

    private static func syncTreeRoot(_ directory: URL) throws {
        #if canImport(Darwin)
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot open staged Mac slot for fsync: errno \(errno)"
            )
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot fsync staged Mac slot: errno \(errno)"
            )
        }
        #endif
    }

    private static func makeInstallRevision(
        runtimeBuildHash: String,
        prepareRevision: String,
        accountNamespacePolicyHash: String
    ) -> String {
        var hasher = SHA256()
        for value in [
            installContractRevision,
            runtimeBuildHash,
            prepareRevision,
            accountNamespacePolicyHash,
            PlayCoverSigningIdentityService.policyRevision,
        ] {
            var length = UInt64(value.utf8.count).bigEndian
            withUnsafeBytes(of: &length) {
                hasher.update(data: Data($0))
            }
            hasher.update(data: Data(value.utf8))
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func stagingDirectoryName(
        bundleIdentifier: String
    ) -> String {
        stagingPrefix(bundleIdentifier: bundleIdentifier)
            + UUID().uuidString
    }

    private static func stagingPrefix(
        bundleIdentifier: String
    ) -> String {
        let digest = SHA256.hash(data: Data(bundleIdentifier.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return ".staging-\(digest.prefix(16))-"
    }

    private static func isInsideAppsRoot(
        _ path: String,
        paths: IOSUsePaths
    ) -> Bool {
        let root = URL(
            fileURLWithPath: paths.playcoverApps,
            isDirectory: true
        ).standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    private static func isSafeComponent(
        _ value: String,
        maximumUTF8Bytes: Int
    ) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && value.utf8.count <= maximumUTF8Bytes
            && !value.contains("/")
            && !value.utf8.contains(0)
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}
