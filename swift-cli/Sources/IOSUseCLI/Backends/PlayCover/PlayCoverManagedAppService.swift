import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Content-addressed managed generations under one IOS_USE_HOME.
///
/// A completed generation is never repaired or overwritten in place. Any
/// marker/hash/signature failure is reported as tampering. Preparation happens
/// in a sibling staging directory and publishes with one atomic rename.
enum PlayCoverManagedAppService {
    static let preparationRevision =
        PlayCoverService.prepareImplementationRevision

    static var inspectOverrideForTesting:
        ((String) throws -> PlayCoverAppInspection)?
    static var verifyOverrideForTesting:
        ((String) throws -> PlayCoverVerification)?
    static var fastVerifyOverrideForTesting:
        ((String) throws -> PlayCoverPrepareManifest)?
    static var prepareOverrideForTesting: ((
        String,
        String,
        String,
        IOSUsePaths,
        String,
        String
    ) throws -> PlayCoverPrepareManifest)?
    static var runtimePathOverrideForTesting:
        ((IOSUsePaths) throws -> String)?
    static var executablePathOverrideForTesting: (() throws -> String)?
    static var generationKeyOverrideForTesting: ((
        PlayCoverAppInspection,
        String
    ) throws -> String)?

    struct Resolution: Equatable, Sendable {
        let manifest: PlayCoverPrepareManifest
        let reused: Bool
    }

    static func resolveExplicitApp(
        _ appPath: String,
        paths: IOSUsePaths
    ) throws -> Resolution {
        let lexical = lexicalStandardizedPath(appPath)
        let isManagedCandidate = isLexicallyInsideManagedPrepared(
            lexical,
            paths: paths
        )
        if isManagedCandidate {
            _ = try validatedManagedPreparedAppPath(
                lexical,
                paths: paths
            )
        }
        let canonical = standardizedPath(appPath)
        if isManagedCandidate || hasAnyPreparedEvidence(at: canonical) {
            guard isManagedCandidate,
                  hasCompletePreparedSidecars(at: canonical) else {
                throw PlayCoverBackendError.cacheTampered(
                    "an App containing prepared evidence cannot be "
                        + "reinterpreted as a source App or reused from a "
                        + "different IOS_USE_HOME"
                )
            }
            let manifest = try fastVerifyApp(at: canonical)
            try PlayCoverSessionService.recordPrepared(
                manifest,
                paths: paths
            )
            return Resolution(
                manifest: manifest,
                reused: true
            )
        }

        let source = try inspectApp(at: canonical)
        for macho in source.machOs {
            if macho.encrypted {
                throw PlayCoverBackendError.encryptedMachO(macho.path)
            }
            guard macho.platform == PlayCoverMachO.platformIPhoneOS else {
                throw PlayCoverBackendError.unsupportedMachO(
                    "\(macho.path) must be an unmodified iPhoneOS Mach-O"
                )
            }
            let runtimeName = PlayCoverService.runtimeExecutableName
            if macho.dependencies.contains(where: {
                URL(fileURLWithPath: $0).lastPathComponent == runtimeName
            }) {
                throw PlayCoverBackendError.duplicateRuntimeLoad(macho.path)
            }
        }

        let runtime = try resolveDefaultRuntime(paths: paths)
        let generationKey: String
        if let generationKeyOverrideForTesting {
            generationKey = try generationKeyOverrideForTesting(
                source,
                runtime
            )
        } else {
            generationKey = PlayCoverService.makeGenerationKey(
                sourceContentHash: source.sourceContentHash,
                runtimeBuildHash: try PlayCoverService.runtimeBuildHash(
                    frameworkPath: runtime
                )
            )
        }
        guard generationKey.count == 64,
              generationKey.allSatisfy({ $0.isHexDigit }) else {
            throw PlayCoverBackendError.prepareFailed(
                "content generation key must be a 64-character SHA-256"
            )
        }

        let layout = generationLayout(
            source: source,
            generationKey: generationKey,
            paths: paths
        )
        if FileManager.default.fileExists(atPath: layout.directory.path) {
            guard hasCompletePreparedSidecars(at: layout.app.path) else {
                throw PlayCoverBackendError.cacheTampered(
                    "generation directory exists without immutable "
                        + "manifest/completed marker"
                )
            }
            let manifest = try fastVerifyApp(at: layout.app.path)
            try validateManagedManifest(
                manifest,
                source: source,
                generationKey: generationKey,
                outputPath: layout.app.path
            )
            try PlayCoverSessionService.recordPrepared(
                manifest,
                paths: paths
            )
            return Resolution(
                manifest: manifest,
                reused: true
            )
        }

        try ensureManagedPreparedRoot(paths: paths)
        let stagingDirectory = URL(
            fileURLWithPath: paths.playcoverPrepared,
            isDirectory: true
        ).appendingPathComponent(
            ".staging-\(generationKey)-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagingApp = stagingDirectory.appendingPathComponent(
            layout.app.lastPathComponent,
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

        let manifest: PlayCoverPrepareManifest
        if let prepareOverrideForTesting {
            manifest = try prepareOverrideForTesting(
                source.appPath,
                stagingApp.path,
                runtime,
                paths,
                generationKey,
                layout.app.path
            )
        } else {
            manifest = try PlayCoverService.prepare(
                sourceAppPath: source.appPath,
                outputAppPath: stagingApp.path,
                runtimeFrameworkPath: runtime,
                paths: paths,
                generationKey: generationKey,
                publishedAppPath: layout.app.path
            )
        }
        try validateManagedManifest(
            manifest,
            source: source,
            generationKey: generationKey,
            outputPath: layout.app.path
        )
        do {
            try FileManager.default.moveItem(
                at: stagingDirectory,
                to: layout.directory
            )
            removeStaging = false
            try syncDirectory(
                URL(
                    fileURLWithPath: paths.playcoverPrepared,
                    isDirectory: true
                )
            )
        } catch {
            if hasCompletePreparedSidecars(at: layout.app.path) {
                let winner = try fastVerifyApp(at: layout.app.path)
                try validateManagedManifest(
                    winner,
                    source: source,
                    generationKey: generationKey,
                    outputPath: layout.app.path
                )
                try PlayCoverSessionService.recordPrepared(
                    winner,
                    paths: paths
                )
                return Resolution(manifest: winner, reused: true)
            }
            throw PlayCoverBackendError.prepareFailed(
                "atomic generation publish failed: \(error)"
            )
        }

        let publishedManifest = try fastVerifyApp(at: layout.app.path)
        guard publishedManifest == manifest else {
            throw PlayCoverBackendError.cacheTampered(
                "published generation identity changed after atomic rename"
            )
        }
        try PlayCoverSessionService.recordPrepared(
            manifest,
            paths: paths
        )
        return Resolution(manifest: manifest, reused: false)
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
                .appendingPathComponent(
                    PlayCoverService.runtimeFrameworkName
                ).path,
            executableDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("share", isDirectory: true)
                .appendingPathComponent("ios-use", isDirectory: true)
                .appendingPathComponent("playcover", isDirectory: true)
                .appendingPathComponent(
                    PlayCoverService.runtimeFrameworkName
                ).path,
        ]
        var seen: Set<String> = []
        return candidates.compactMap {
            let value = standardizedPath($0)
            return seen.insert(value).inserted ? value : nil
        }
    }

    static func resolveDefaultRuntime(paths: IOSUsePaths) throws -> String {
        if let runtimePathOverrideForTesting {
            let value = standardizedPath(
                try runtimePathOverrideForTesting(paths)
            )
            guard isRuntimeFrameworkPresent(at: value) else {
                throw PlayCoverBackendError.missingRuntime(value)
            }
            return value
        }
        let candidates = runtimeCandidates(
            paths: paths,
            executablePath: try currentExecutablePath()
        )
        if let value = candidates.first(where: isRuntimeFrameworkPresent) {
            return value
        }
        throw PlayCoverBackendError.missingRuntime(
            "no default \(PlayCoverService.runtimeFrameworkName) found; "
                + "searched: \(candidates.joined(separator: ", "))"
        )
    }

    private struct GenerationLayout {
        let directory: URL
        let app: URL
    }

    private static func generationLayout(
        source: PlayCoverAppInspection,
        generationKey: String,
        paths: IOSUsePaths
    ) -> GenerationLayout {
        let directory = URL(
            fileURLWithPath: paths.playcoverPrepared,
            isDirectory: true
        ).appendingPathComponent(generationKey, isDirectory: true)
        let safeBundle = source.bundleIdentifier.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "-",
            options: .regularExpression
        )
        return GenerationLayout(
            directory: directory,
            app: directory.appendingPathComponent(
                "\(safeBundle.isEmpty ? "App" : safeBundle).app",
                isDirectory: true
            )
        )
    }

    private static func inspectApp(
        at path: String
    ) throws -> PlayCoverAppInspection {
        if let inspectOverrideForTesting {
            return try inspectOverrideForTesting(path)
        }
        return try PlayCoverService.inspect(appPath: path)
    }

    private static func verifyApp(
        at path: String
    ) throws -> PlayCoverVerification {
        if let verifyOverrideForTesting {
            return try verifyOverrideForTesting(path)
        }
        return try PlayCoverService.verify(appPath: path)
    }

    private static func fastVerifyApp(
        at path: String
    ) throws -> PlayCoverPrepareManifest {
        if let fastVerifyOverrideForTesting {
            return try fastVerifyOverrideForTesting(path)
        }
        return try PlayCoverService.fastVerify(appPath: path)
    }

    private static func validateManagedManifest(
        _ manifest: PlayCoverPrepareManifest,
        source: PlayCoverAppInspection,
        generationKey: String,
        outputPath: String
    ) throws {
        guard manifest.schemaVersion == 3,
              manifest.backend == "playcover-headless",
              standardizedPath(manifest.preparedAppPath)
                == standardizedPath(outputPath),
              manifest.bundleIdentifier == source.bundleIdentifier,
              manifest.sourceContentHash == source.sourceContentHash,
              manifest.sourceHashAfterPreparation
                == source.sourceContentHash,
              manifest.generationKey == generationKey,
              manifest.prepareRevision == preparationRevision else {
            throw PlayCoverBackendError.verificationFailed(
                "managed generation does not match source/content/runtime"
            )
        }
    }

    private static func hasAnyPreparedEvidence(at appPath: String) -> Bool {
        let app = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        )
        let parent = app.deletingLastPathComponent()
        let candidates = [
            parent.appendingPathComponent(
                PlayCoverService.manifestFilename
            ).path,
            parent.appendingPathComponent(
                PlayCoverService.completedFilename
            ).path,
            app.appendingPathComponent("Frameworks", isDirectory: true)
                .appendingPathComponent(
                    PlayCoverService.runtimeFrameworkName,
                    isDirectory: true
                ).path,
        ]
        return candidates.contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    private static func hasCompletePreparedSidecars(
        at appPath: String
    ) -> Bool {
        let parent = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        ).deletingLastPathComponent()
        return FileManager.default.fileExists(
            atPath: parent.appendingPathComponent(
                PlayCoverService.manifestFilename
            ).path
        ) && FileManager.default.fileExists(
            atPath: parent.appendingPathComponent(
                PlayCoverService.completedFilename
            ).path
        )
    }

    static func validatedManagedPreparedAppPath(
        _ appPath: String,
        paths: IOSUsePaths
    ) throws -> String {
        let lexicalRoot = lexicalStandardizedPath(
            paths.playcoverPrepared
        )
        let canonicalRoot = standardizedPath(
            paths.playcoverPrepared
        )
        let lexicalApp = lexicalStandardizedPath(appPath)
        let canonicalApp = standardizedPath(appPath)
        guard !isSymbolicLinkExact(lexicalRoot),
              !isSymbolicLinkExact(lexicalApp),
              lexicalApp.hasPrefix(lexicalRoot + "/"),
              canonicalApp.hasPrefix(canonicalRoot + "/") else {
            throw PlayCoverBackendError.cacheTampered(
                "managed prepared root/App must not contain a "
                    + "symbolic-link escape"
            )
        }
        try validateNoFollowDescendant(
            root: canonicalRoot,
            descendant: canonicalApp
        )
        return canonicalApp
    }

    private static func isLexicallyInsideManagedPrepared(
        _ appPath: String,
        paths: IOSUsePaths
    ) -> Bool {
        appPath.hasPrefix(
            lexicalStandardizedPath(paths.playcoverPrepared) + "/"
        )
    }

    private static func isRuntimeFrameworkPresent(at path: String) -> Bool {
        let runtime = URL(
            fileURLWithPath: path,
            isDirectory: true
        )
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

    private static func currentExecutablePath() throws -> String {
        if let executablePathOverrideForTesting {
            return try executablePathOverrideForTesting()
        }
        if let value = Bundle.main.executableURL?.path,
           FileManager.default.isExecutableFile(atPath: value) {
            return value
        }
        guard let argument = ProcessInfo.processInfo.arguments.first,
              !argument.isEmpty else {
            throw PlayCoverBackendError.missingRuntime(
                "cannot resolve current ios-use executable"
            )
        }
        if argument.hasPrefix("/") {
            return standardizedPath(argument)
        }
        return standardizedPath(
            URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            ).appendingPathComponent(argument).path
        )
    }

    private static func syncDirectory(_ url: URL) throws {
        #if canImport(Darwin)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot open generation parent for fsync: errno \(errno)"
            )
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot fsync generation parent: errno \(errno)"
            )
        }
        #endif
    }

    private static func ensureManagedPreparedRoot(
        paths: IOSUsePaths
    ) throws {
        #if canImport(Darwin)
        let lexicalPath = lexicalStandardizedPath(paths.playcoverPrepared)
        let lexicalOwnedRoot = lexicalStandardizedPath(paths.root)
        try rejectUserOwnedSymlinkComponents(
            lexicalOwnedRoot
        )
        for value in [
            lexicalOwnedRoot,
            URL(fileURLWithPath: lexicalOwnedRoot)
                .appendingPathComponent("playcover").path,
            lexicalPath,
        ] where isSymbolicLinkExact(value) {
            throw PlayCoverBackendError.prepareFailed(
                "managed directory contains symbolic link: \(value)"
            )
        }
        let path = canonicalizingExistingPrefix(lexicalPath)
        let components = Array(
            URL(fileURLWithPath: path).pathComponents.dropFirst()
        )
        let ownedStartIndex = max(
            0,
            components.count - 3
        )
        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot open filesystem root for managed containment"
            )
        }
        defer { Darwin.close(descriptor) }
        for (index, component) in components.enumerated() {
            var created = false
            var child = Darwin.openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            if child < 0, errno == ENOENT {
                guard Darwin.mkdirat(descriptor, component, 0o700) == 0
                        || errno == EEXIST else {
                    throw PlayCoverBackendError.prepareFailed(
                        "cannot create managed directory component "
                            + "\(component): errno \(errno)"
                    )
                }
                child = Darwin.openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                created = true
            }
            guard child >= 0 else {
                throw PlayCoverBackendError.prepareFailed(
                    "managed directory contains missing/symlink/non-directory "
                        + "component \(component): errno \(errno)"
                )
            }
            if created || index >= ownedStartIndex {
                var status = stat()
                guard fstat(child, &status) == 0,
                      status.st_uid == geteuid(),
                      fchmod(child, 0o700) == 0 else {
                    Darwin.close(child)
                    throw PlayCoverBackendError.prepareFailed(
                        "managed directory is not owner-controlled: "
                            + component
                    )
                }
            }
            Darwin.close(descriptor)
            descriptor = child
        }
        #else
        try FileManager.default.createDirectory(
            atPath: paths.playcoverPrepared,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #endif
    }

    private static func rejectUserOwnedSymlinkComponents(
        _ path: String
    ) throws {
        #if canImport(Darwin)
        var current = URL(fileURLWithPath: "/")
        for component in URL(
            fileURLWithPath: path
        ).standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var status = stat()
            if lstat(current.path, &status) != 0 {
                if errno == ENOENT {
                    return
                }
                throw PlayCoverBackendError.prepareFailed(
                    "cannot inspect managed path component "
                        + "\(current.path): errno \(errno)"
                )
            }
            if status.st_mode & S_IFMT == S_IFLNK,
               status.st_uid == geteuid() {
                throw PlayCoverBackendError.prepareFailed(
                    "managed path contains user-owned symbolic link: "
                        + current.path
                )
            }
        }
        #endif
    }

    private static func validateNoFollowDescendant(
        root: String,
        descendant: String
    ) throws {
        #if canImport(Darwin)
        guard descendant.hasPrefix(root + "/") else {
            throw PlayCoverBackendError.cacheTampered(
                "managed App is outside prepared root"
            )
        }
        var descriptor = Darwin.open(
            root,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "managed prepared root is missing, a symlink, or not a directory"
            )
        }
        defer { Darwin.close(descriptor) }
        let suffix = String(descendant.dropFirst(root.count + 1))
        for component in suffix.split(separator: "/") {
            let child = Darwin.openat(
                descriptor,
                String(component),
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard child >= 0 else {
                throw PlayCoverBackendError.cacheTampered(
                    "managed App contains symlink/missing component: "
                        + String(component)
                )
            }
            Darwin.close(descriptor)
            descriptor = child
        }
        #endif
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func isSymbolicLinkExact(_ path: String) -> Bool {
        #if canImport(Darwin)
        var status = stat()
        return lstat(path, &status) == 0
            && status.st_mode & S_IFMT == S_IFLNK
        #else
        return false
        #endif
    }

    private static func canonicalizingExistingPrefix(
        _ path: String
    ) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path),
              existing.path != "/" {
            suffix.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = existing.path.withCString {
            Darwin.realpath($0, &buffer)
        }
        var result = resolved == nil
            ? existing.path
            : String(cString: buffer)
        for component in suffix {
            result = (result as NSString)
                .appendingPathComponent(component)
        }
        return result
    }

    private static func lexicalStandardizedPath(
        _ path: String
    ) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .path
    }
}
