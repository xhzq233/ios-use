import Foundation
import PlayCoverUpstream
#if canImport(Darwin)
import Darwin
#endif

/// Account-global content-addressed final generations.
///
/// A completed generation is never repaired or overwritten in place. Any
/// marker/hash/signature failure is reported as tampering. Preparation happens
/// in a sibling staging directory and publishes with one atomic rename.
enum PlayCoverManagedAppService {
    static let preparationRevision =
        PlayCoverService.prepareImplementationRevision
    private static let preparationProcessLock = NSLock()

    static var inspectOverrideForTesting:
        ((String) throws -> PlayCoverPreparationSource)?
    static var readManifestOverrideForTesting:
        ((String) throws -> PlayCoverPrepareManifest)?
    static var prepareOverrideForTesting: ((
        PlayCoverPreparationPlan,
        String,
        IOSUsePaths,
        String
    ) throws -> PlayCoverPrepareManifest)?
    static var runtimePathOverrideForTesting:
        ((IOSUsePaths) throws -> String)?
    static var executablePathOverrideForTesting: (() throws -> String)?
    static var generationKeyOverrideForTesting: ((
        PlayCoverAppInspection,
        String,
        String
    ) throws -> String)?
    static var afterManagedDirectoryOpenForTesting: (() throws -> Void)?
    static var afterStagingPathResolvedForTesting:
        ((URL) throws -> Void)?
    static var afterPreparedSelectionPinnedForTesting:
        (() throws -> Void)?

    struct Resolution: Equatable, Sendable {
        let manifest: PlayCoverPrepareManifest
        let generationIdentity: PlayCoverGenerationIdentity
        let reused: Bool
        let selectionPreparationID: String?
    }

    struct ManagedDirectories: Equatable, Sendable {
        let playcover: URL
        let prepared: URL
        let homes: URL
        let locks: URL
    }

    struct ManagedDirectoryAccess {
        let playcover: URL
        let prepared: URL
        let homes: URL
        let locks: URL
        let playcoverDescriptor: Int32
        let preparedDescriptor: Int32
        let homesDescriptor: Int32
        let locksDescriptor: Int32
    }

    static func resolveExplicitApp(
        _ appPath: String,
        paths: IOSUsePaths,
        signingIdentity:
            PlayCoverSigningIdentityEvidence? = nil
    ) throws -> Resolution {
        let lexical = lexicalStandardizedPath(appPath)
        let isManagedCandidate = isLexicallyInsideManagedPrepared(
            lexical,
            paths: paths
        )
        if isManagedCandidate {
            guard let generationKey =
                    managedGenerationKey(
                        lexicalAppPath: lexical,
                        paths: paths
                    ) else {
                throw PlayCoverBackendError.cacheTampered(
                    "managed prepared App path does not have the exact "
                        + "<generation>/App.app shape"
                )
            }
            let preparationID =
                try PlayCoverGlobalReferenceStore.beginPreparation(
                    generationKey: generationKey,
                    paths: paths
                )
            var selectionPinHandedOff = false
            defer {
                if !selectionPinHandedOff {
                    try? PlayCoverGlobalReferenceStore
                        .abandonPreparation(
                            generationKey: generationKey,
                            preparationID: preparationID,
                            paths: paths
                        )
                }
            }
            #if DEBUG && canImport(Darwin)
            PlayCoverLaunchCrashCut.hit(.afterPreparationPinned)
            #endif
            try afterPreparedSelectionPinnedForTesting?()
            let canonical = try validatedManagedPreparedAppPath(
                lexical,
                paths: paths
            )
            guard hasCompletePreparedSidecars(at: canonical) else {
                throw PlayCoverBackendError.cacheTampered(
                    "managed prepared App is missing immutable "
                        + "manifest/completed evidence"
                )
            }
            let validated = try readPreparedManifest(
                at: canonical
            )
            let manifest = validated.manifest
            guard manifest.generationKey == generationKey,
                  manifest.accountNamespacePolicyHash
                    == PlayCoverService
                        .accountNamespacePolicyHash(paths: paths) else {
                throw PlayCoverBackendError.cacheTampered(
                    "managed prepared App generation does not match its "
                        + "content-addressed path or current account "
                        + "Runtime namespace"
                )
            }
            if let signingIdentity,
               manifest.signingIdentity != signingIdentity {
                throw PlayCoverBackendError.cacheTampered(
                    "managed prepared App signer does not match the "
                        + "start preflight evidence"
                )
            }
            selectionPinHandedOff = true
            return Resolution(
                manifest: manifest,
                generationIdentity:
                    validated.generationIdentity,
                reused: true,
                selectionPreparationID: preparationID
            )
        }

        let canonical = standardizedPath(appPath)
        if hasAnyPreparedEvidence(at: canonical) {
            throw PlayCoverBackendError.cacheTampered(
                "an App containing prepared evidence cannot be "
                    + "reinterpreted as a source App outside the "
                    + "account-global prepared cache"
            )
        }

        let preparationSource = try inspectApp(at: canonical)
        let source = preparationSource.inspection
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
        let plan = try PlayCoverService.makePreparationPlan(
            source: preparationSource,
            runtimeFrameworkPath: runtime,
            paths: paths,
            signingIdentity: signingIdentity,
            generationKeyOverride: generationKeyOverrideForTesting
        )
        let generationKey = plan.generationKey
        guard isLowercaseSHA256(generationKey) else {
            throw PlayCoverBackendError.prepareFailed(
                "content generation key must be a 64-character SHA-256"
            )
        }
        preparationProcessLock.lock()
        defer { preparationProcessLock.unlock() }
        let preparationID =
            try PlayCoverGlobalReferenceStore.beginPreparation(
                generationKey: generationKey,
                paths: paths
            )
        #if DEBUG && canImport(Darwin)
        PlayCoverLaunchCrashCut.hit(.afterPreparationPinned)
        #endif
        var preparationPinCompleted = false
        defer {
            if !preparationPinCompleted {
                try? PlayCoverGlobalReferenceStore.abandonPreparation(
                    generationKey: generationKey,
                    preparationID: preparationID,
                    paths: paths
                )
            }
        }
        let resolution =
          try PlayCoverGlobalReferenceStore.withGenerationLock(
            generationKey: generationKey,
            paths: paths
        ) {
          try withSecureManagedDirectories(paths: paths) { access in
            let layout = generationLayout(
                generationKey: generationKey,
                paths: paths
            )
            #if canImport(Darwin)
            let generationExists = try ownedDirectoryExists(
                parentDescriptor: access.preparedDescriptor,
                name: generationKey,
                label: "managed generation \(generationKey)"
            )
            #else
            let generationExists = FileManager.default.fileExists(
                atPath: layout.directory.path
            )
            #endif
            if generationExists {
                _ = try validatedManagedPreparedAppPath(
                    layout.app.path,
                    paths: paths
                )
                guard hasCompletePreparedSidecars(at: layout.app.path) else {
                    throw PlayCoverBackendError.cacheTampered(
                        "generation directory exists without immutable "
                            + "manifest/completed marker"
                    )
                }
                let validated = try readPreparedManifest(
                    at: layout.app.path,
                    expectedGenerationIdentity:
                        plan.generationIdentity
                )
                let manifest = validated.manifest
                try validateManagedManifest(
                    manifest,
                    plan: plan,
                    outputPath: layout.app.path
                )
                return Resolution(
                    manifest: manifest,
                    generationIdentity: plan.generationIdentity,
                    reused: true,
                    selectionPreparationID: nil
                )
            }

            let stagingName =
                ".staging-\(generationKey)-\(UUID().uuidString)"
            let stagingIdentityDirectory =
                access.prepared.appendingPathComponent(
                    stagingName,
                    isDirectory: true
                )
            #if canImport(Darwin)
            guard Darwin.mkdirat(
                    access.preparedDescriptor,
                    stagingName,
                    0o700
                  ) == 0 else {
                throw PlayCoverBackendError.prepareFailed(
                    "cannot create anchored staging generation: errno "
                        + "\(errno)"
                )
            }
            let stagingDescriptor: Int32
            do {
                stagingDescriptor = try openOwnedDirectory(
                    parentDescriptor: access.preparedDescriptor,
                    name: stagingName,
                    label: "staging generation"
                )
            } catch {
                _ = Darwin.unlinkat(
                    access.preparedDescriptor,
                    stagingName,
                    AT_REMOVEDIR
                )
                throw error
            }
            #else
            try FileManager.default.createDirectory(
                at: stagingIdentityDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            #endif
            var removeStaging = true
            defer {
                if removeStaging {
                    #if canImport(Darwin)
                    try? removeAnchoredDirectoryTree(
                        parentDescriptor: access.preparedDescriptor,
                        name: stagingName,
                        label: "staging generation"
                    )
                    #else
                    try? FileManager.default.removeItem(
                        at: stagingIdentityDirectory
                    )
                    #endif
                }
            }
            #if canImport(Darwin)
            defer { Darwin.close(stagingDescriptor) }
            #endif

            let prepareAtPaths: (String, String) throws
                -> PlayCoverPreparedArtifact = {
                    stagingIdentityAppPath,
                    stagingIOAppPath in
                    if let prepareOverrideForTesting {
                        return PlayCoverPreparedArtifact(
                            manifest: try prepareOverrideForTesting(
                                plan,
                                stagingIOAppPath,
                                paths,
                                layout.app.path
                            ),
                            upstreamResult: nil
                        )
                    }
                    return try PlayCoverService.prepareArtifact(
                        plan: plan,
                        outputAppPath: stagingIdentityAppPath,
                        stagingIOAppPath: stagingIOAppPath,
                        paths: paths,
                        publishedAppPath: layout.app.path
                    )
                }
            let preparedArtifact: PlayCoverPreparedArtifact
            #if canImport(Darwin)
            let stagingIODirectory =
                try ownedDirectoryDescriptorPath(
                    stagingDescriptor,
                    label: "staging generation"
                )
            preparedArtifact =
                try PlayCoverPrepareNamespaceGuard.withProtection(
                    directories: [
                        .init(
                            descriptor: access.playcoverDescriptor,
                            label: "managed Mac cache directory"
                        ),
                        .init(
                            descriptor: access.preparedDescriptor,
                            label: "managed prepared root"
                        ),
                    ],
                    links: [
                        .init(
                            parentDescriptor: access.playcoverDescriptor,
                            childName: access.prepared.lastPathComponent,
                            childDescriptor: access.preparedDescriptor,
                            label: "managed prepared root"
                        ),
                        .init(
                            parentDescriptor: access.preparedDescriptor,
                            childName: stagingName,
                            childDescriptor: stagingDescriptor,
                            label: "staging generation"
                        ),
                    ]
                ) {
                    try afterStagingPathResolvedForTesting?(
                        stagingIODirectory
                    )
                    return try prepareAtPaths(
                        stagingIdentityDirectory.appendingPathComponent(
                            layout.app.lastPathComponent,
                            isDirectory: true
                        ).path,
                        stagingIODirectory.appendingPathComponent(
                            layout.app.lastPathComponent,
                            isDirectory: true
                        ).path
                    )
                }
            #else
            let stagingAppPath =
                stagingIdentityDirectory.appendingPathComponent(
                    layout.app.lastPathComponent,
                    isDirectory: true
                ).path
            preparedArtifact = try prepareAtPaths(
                stagingAppPath,
                stagingAppPath
            )
            #endif
            let manifest = preparedArtifact.manifest
            try validateManagedManifest(
                manifest,
                plan: plan,
                outputPath: layout.app.path
            )
            do {
                #if canImport(Darwin)
                guard Darwin.renameatx_np(
                        access.preparedDescriptor,
                        stagingName,
                        access.preparedDescriptor,
                        generationKey,
                        UInt32(RENAME_EXCL)
                      ) == 0 else {
                    throw PlayCoverBackendError.prepareFailed(
                        "anchored generation rename failed: errno \(errno)"
                    )
                }
                removeStaging = false
                try syncDirectoryDescriptor(
                    access.preparedDescriptor,
                    label: "managed prepared root"
                )
                #else
                try FileManager.default.moveItem(
                    at: stagingIdentityDirectory,
                    to: layout.directory
                )
                removeStaging = false
                try syncDirectory(access.prepared)
                #endif
            } catch {
                if hasCompletePreparedSidecars(at: layout.app.path) {
                    let validatedWinner = try readPreparedManifest(
                        at: layout.app.path,
                        expectedGenerationIdentity:
                            plan.generationIdentity
                    )
                    let winner = validatedWinner.manifest
                    try validateManagedManifest(
                        winner,
                        plan: plan,
                        outputPath: layout.app.path
                    )
                    return Resolution(
                        manifest: winner,
                        generationIdentity:
                            plan.generationIdentity,
                        reused: true,
                        selectionPreparationID: nil
                    )
                }
                throw PlayCoverBackendError.prepareFailed(
                    "atomic generation publish failed: \(error)"
                )
            }

            _ = try validatedManagedPreparedAppPath(
                layout.app.path,
                paths: paths
            )
            let publishedManifest = try readPreparedManifest(
                at: layout.app.path,
                expectedGenerationIdentity:
                    plan.generationIdentity
            ).manifest
            guard try publishedManifest.hasSamePersistedSeal(
                as: manifest
            ) else {
                throw PlayCoverBackendError.cacheTampered(
                    "published generation identity changed after atomic rename"
                )
            }
            return Resolution(
                manifest: publishedManifest,
                generationIdentity: plan.generationIdentity,
                reused: false,
                selectionPreparationID: nil
            )
          }
        }
        try PlayCoverGlobalReferenceStore.finishPreparation(
            generationKey: generationKey,
            preparationID: preparationID,
            paths: paths
        )
        preparationPinCompleted = true
        return resolution
    }

    static func runtimeCandidates(
        paths: IOSUsePaths,
        executablePath: String
    ) -> [String] {
        let executableDirectory = URL(fileURLWithPath: executablePath)
            .standardizedFileURL
            .deletingLastPathComponent()
        var candidates: [String] = []
        if paths.hasExplicitHome {
            candidates.append(paths.playcoverRuntime)
        }
        candidates.append(contentsOf: [
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
        ])
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
        generationKey: String,
        paths: IOSUsePaths
    ) -> GenerationLayout {
        let directory = URL(
            fileURLWithPath: paths.playcoverGlobalObjects,
            isDirectory: true
        ).appendingPathComponent(generationKey, isDirectory: true)
        return GenerationLayout(
            directory: directory,
            app: directory.appendingPathComponent(
                "App.app",
                isDirectory: true
            )
        )
    }

    private static func inspectApp(
        at path: String
    ) throws -> PlayCoverPreparationSource {
        if let inspectOverrideForTesting {
            return try inspectOverrideForTesting(path)
        }
        return try PlayCoverService.inspectPreparationSource(
            appPath: path
        )
    }

    private static func readPreparedManifest(
        at path: String,
        expectedGenerationIdentity:
            PlayCoverGenerationIdentity? = nil
    ) throws -> PlayCoverValidatedPreparedManifest {
        if let readManifestOverrideForTesting {
            return PlayCoverService
                .uncheckedValidatedPreparedManifestForTesting(
                    try readManifestOverrideForTesting(path),
                    expectedGenerationIdentity:
                        expectedGenerationIdentity
                )
        }
        return try PlayCoverService.readPreparedManifestEvidence(
            appPath: path,
            expectedGenerationIdentity:
                expectedGenerationIdentity
        )
    }

    private static func validateManagedManifest(
        _ manifest: PlayCoverPrepareManifest,
        plan: PlayCoverPreparationPlan,
        outputPath: String
    ) throws {
        let source = plan.source.inspection
        guard manifest.schemaVersion == 5,
              manifest.backend == "mac",
              standardizedPath(manifest.preparedAppPath)
                == standardizedPath(outputPath),
              manifest.bundleIdentifier == source.bundleIdentifier,
              manifest.sourceContentHash == source.sourceContentHash,
              manifest.sourceHashAfterPreparation
                == source.sourceContentHash,
              manifest.runtimeBuildHash == plan.runtimeBuildHash,
              manifest.accountNamespacePolicyHash
                == plan.accountNamespacePolicyHash,
              manifest.generationKey == plan.generationKey,
              manifest.signingIdentity == plan.signingIdentity,
              manifest.prepareRevision == plan.prepareRevision,
              plan.prepareRevision == preparationRevision else {
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
            paths.playcoverGlobalObjects
        )
        do {
            try rejectUserOwnedSymlinkComponents(lexicalRoot)
        } catch {
            throw PlayCoverBackendError.cacheTampered(
                "managed prepared root/App contains a "
                    + "symbolic-link escape: \(error)"
            )
        }
        let canonicalRoot = standardizedPath(
            paths.playcoverGlobalObjects
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

    static func secureManagedDirectories(
        paths: IOSUsePaths
    ) throws -> ManagedDirectories {
        try withSecureManagedDirectories(paths: paths) {
            ManagedDirectories(
                playcover: $0.playcover,
                prepared: $0.prepared,
                homes: $0.homes,
                locks: $0.locks
            )
        }
    }

    static func withSecureManagedDirectories<T>(
        paths: IOSUsePaths,
        _ operation: (ManagedDirectoryAccess) throws -> T
    ) throws -> T {
        #if canImport(Darwin)
        let access = try openSecureManagedDirectories(paths: paths)
        defer {
            Darwin.close(access.locksDescriptor)
            Darwin.close(access.homesDescriptor)
            Darwin.close(access.preparedDescriptor)
            Darwin.close(access.playcoverDescriptor)
        }
        try afterManagedDirectoryOpenForTesting?()
        return try operation(access)
        #else
        try FileManager.default.createDirectory(
            atPath: paths.playcoverGlobalObjects,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let prepared = URL(
            fileURLWithPath:
                lexicalStandardizedPath(paths.playcoverGlobalObjects),
            isDirectory: true
        )
        let root = prepared.deletingLastPathComponent()
        let homes = URL(
            fileURLWithPath: paths.playcoverGlobalHomes,
            isDirectory: true
        )
        let locks = URL(
            fileURLWithPath: paths.playcoverGlobalLocks,
            isDirectory: true
        )
        for directory in [prepared, homes, locks] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try afterManagedDirectoryOpenForTesting?()
        return try operation(
            ManagedDirectoryAccess(
                playcover: root,
                prepared: prepared,
                homes: homes,
                locks: locks,
                playcoverDescriptor: -1,
                preparedDescriptor: -1,
                homesDescriptor: -1,
                locksDescriptor: -1
            )
        )
        #endif
    }

    private static func isLexicallyInsideManagedPrepared(
        _ appPath: String,
        paths: IOSUsePaths
    ) -> Bool {
        appPath.hasPrefix(
            lexicalStandardizedPath(paths.playcoverGlobalObjects) + "/"
        )
    }

    private static func managedGenerationKey(
        lexicalAppPath: String,
        paths: IOSUsePaths
    ) -> String? {
        let root = lexicalStandardizedPath(
            paths.playcoverGlobalObjects
        )
        guard lexicalAppPath.hasPrefix(root + "/") else {
            return nil
        }
        let relative = String(
            lexicalAppPath.dropFirst(root.count + 1)
        )
        let components = relative.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              components[1] == "App.app" else {
            return nil
        }
        let generationKey = String(components[0])
        guard isLowercaseSHA256(generationKey) else {
            return nil
        }
        return generationKey
    }

    private static func isLowercaseSHA256(
        _ value: String
    ) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64
            && bytes.allSatisfy {
                ($0 >= 48 && $0 <= 57)
                    || ($0 >= 97 && $0 <= 102)
            }
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

    #if canImport(Darwin)
    static func ownedDirectoryDescriptorPath(
        _ descriptor: Int32,
        label: String
    ) throws -> URL {
        var expected = stat()
        guard fstat(descriptor, &expected) == 0,
              expected.st_mode & S_IFMT == S_IFDIR,
              expected.st_uid == geteuid() else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot inspect anchored \(label)"
            )
        }
        let stableURL = URL(
            fileURLWithPath:
                "/.vol/\(expected.st_dev)/\(expected.st_ino)",
            isDirectory: true
        )
        let verificationDescriptor = Darwin.open(
            stableURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard verificationDescriptor >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot resolve stable vnode path for anchored \(label): "
                    + "errno \(errno)"
            )
        }
        defer { Darwin.close(verificationDescriptor) }
        var actual = stat()
        guard fstat(verificationDescriptor, &actual) == 0,
              actual.st_dev == expected.st_dev,
              actual.st_ino == expected.st_ino else {
            throw PlayCoverBackendError.cacheTampered(
                "stable vnode path changed identity for anchored \(label)"
            )
        }
        return stableURL
    }

    static func openOwnedDirectory(
        parentDescriptor: Int32,
        name: String,
        label: String
    ) throws -> Int32 {
        try openAnchoredDirectory(
            parentDescriptor: parentDescriptor,
            name: name,
            label: label,
            requireOwnerOnlyMode: true
        )
    }

    private static func openAnchoredDirectory(
        parentDescriptor: Int32,
        name: String,
        label: String,
        requireOwnerOnlyMode: Bool
    ) throws -> Int32 {
        guard isSafeRelativeName(name) else {
            throw PlayCoverBackendError.cacheTampered(
                "\(label) has an unsafe directory name"
            )
        }
        let descriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot open anchored \(label): errno \(errno)"
            )
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              !requireOwnerOnlyMode
                || status.st_mode & 0o077 == 0 else {
            Darwin.close(descriptor)
            throw PlayCoverBackendError.cacheTampered(
                "\(label) is not an owner-only directory"
            )
        }
        return descriptor
    }

    static func ownedDirectoryExists(
        parentDescriptor: Int32,
        name: String,
        label: String
    ) throws -> Bool {
        guard isSafeRelativeName(name) else {
            throw PlayCoverBackendError.cacheTampered(
                "\(label) has an unsafe directory name"
            )
        }
        var status = stat()
        if fstatat(
            parentDescriptor,
            name,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) != 0 {
            if errno == ENOENT {
                return false
            }
            throw PlayCoverBackendError.cacheTampered(
                "cannot inspect anchored \(label): errno \(errno)"
            )
        }
        guard status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "\(label) is not an owner-only directory"
            )
        }
        return true
    }

    static func readOwnedRegularFile(
        parentDescriptor: Int32,
        name: String,
        maximumBytes: Int = 1_048_576,
        afterOpen: (() throws -> Void)? = nil
    ) throws -> Data {
        guard isSafeRelativeName(name) else {
            throw PlayCoverBackendError.cacheTampered(
                "generation metadata has an unsafe name"
            )
        }
        let descriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot open anchored generation metadata: errno \(errno)"
            )
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= Int64(maximumBytes) else {
            throw PlayCoverBackendError.cacheTampered(
                "generation metadata is not a bounded owned regular file"
            )
        }
        try afterOpen?()
        var data = Data(count: Int(status.st_size))
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                throw PlayCoverBackendError.cacheTampered(
                    "generation metadata could not be read completely"
                )
            }
        }
        var finalDescriptorStatus = stat()
        var finalPathStatus = stat()
        guard fstat(descriptor, &finalDescriptorStatus) == 0,
              fstatat(
                  parentDescriptor,
                  name,
                  &finalPathStatus,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              finalDescriptorStatus.st_dev == status.st_dev,
              finalDescriptorStatus.st_ino == status.st_ino,
              finalDescriptorStatus.st_mode == status.st_mode,
              finalDescriptorStatus.st_uid == status.st_uid,
              finalDescriptorStatus.st_size == status.st_size,
              finalPathStatus.st_dev == status.st_dev,
              finalPathStatus.st_ino == status.st_ino,
              finalPathStatus.st_mode == status.st_mode,
              finalPathStatus.st_uid == status.st_uid,
              finalPathStatus.st_size == status.st_size else {
            throw PlayCoverBackendError.cacheTampered(
                "generation metadata changed while it was read"
            )
        }
        return data
    }

    static func anchoredDirectoryNames(
        descriptor: Int32,
        label: String
    ) throws -> [String] {
        let path = try ownedDirectoryDescriptorPath(
            descriptor,
            label: label
        )
        return try FileManager.default.contentsOfDirectory(
            atPath: path.path
        )
    }

    static func removeAnchoredDirectoryTree(
        parentDescriptor: Int32,
        name: String,
        label: String
    ) throws {
        var parentStatus = stat()
        guard fstat(parentDescriptor, &parentStatus) == 0,
              parentStatus.st_mode & S_IFMT == S_IFDIR else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot inspect anchored \(label) parent"
            )
        }
        try removeAnchoredDirectoryTree(
            parentDescriptor: parentDescriptor,
            name: name,
            label: label,
            requireOwnerOnlyMode: true,
            allowedDevice: parentStatus.st_dev
        )
    }

    private static func removeAnchoredDirectoryTree(
        parentDescriptor: Int32,
        name: String,
        label: String,
        requireOwnerOnlyMode: Bool,
        allowedDevice: dev_t
    ) throws {
        let descriptor = try openAnchoredDirectory(
            parentDescriptor: parentDescriptor,
            name: name,
            label: label,
            requireOwnerOnlyMode: requireOwnerOnlyMode
        )
        defer { Darwin.close(descriptor) }
        var directoryStatus = stat()
        guard fstat(descriptor, &directoryStatus) == 0,
              directoryStatus.st_dev == allowedDevice else {
            throw PlayCoverBackendError.cacheTampered(
                "\(label) crosses a mounted filesystem boundary"
            )
        }
        let children = try anchoredDirectoryNames(
            descriptor: descriptor,
            label: label
        )
        for child in children {
            guard isSafeRelativeName(child) else {
                throw PlayCoverBackendError.cacheTampered(
                    "\(label) contains an unsafe entry name"
                )
            }
            var status = stat()
            guard fstatat(
                    descriptor,
                    child,
                    &status,
                    AT_SYMLINK_NOFOLLOW
                  ) == 0 else {
                throw PlayCoverBackendError.cacheTampered(
                    "cannot inspect anchored \(label) entry \(child)"
                )
            }
            guard status.st_dev == allowedDevice else {
                throw PlayCoverBackendError.cacheTampered(
                    "\(label)/\(child) crosses a mounted filesystem boundary"
                )
            }
            if status.st_mode & S_IFMT == S_IFDIR {
                try removeAnchoredDirectoryTree(
                    parentDescriptor: descriptor,
                    name: child,
                    label: "\(label)/\(child)",
                    requireOwnerOnlyMode: false,
                    allowedDevice: allowedDevice
                )
            } else {
                guard Darwin.unlinkat(descriptor, child, 0) == 0 else {
                    throw PlayCoverBackendError.cacheTampered(
                        "cannot unlink anchored \(label) entry \(child): "
                            + "errno \(errno)"
                    )
                }
            }
        }
        guard Darwin.unlinkat(
                parentDescriptor,
                name,
                AT_REMOVEDIR
              ) == 0 else {
            throw PlayCoverBackendError.cacheTampered(
                "cannot remove anchored \(label): errno \(errno)"
            )
        }
    }

    static func syncDirectoryDescriptor(
        _ descriptor: Int32,
        label: String
    ) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot fsync \(label): errno \(errno)"
            )
        }
    }

    private static func isSafeRelativeName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.utf8.contains(0)
    }
    #endif

    #if canImport(Darwin)
    private static func openSecureManagedDirectories(
        paths: IOSUsePaths
    ) throws -> ManagedDirectoryAccess {
        let lexicalPath = lexicalStandardizedPath(paths.playcoverGlobalObjects)
        let lexicalOwnedRoot = lexicalStandardizedPath(
            paths.playcoverGlobalCache
        )
        try rejectUserOwnedSymlinkComponents(
            lexicalOwnedRoot
        )
        for value in [
            lexicalOwnedRoot,
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
            components.count - 4
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
        var playcoverDescriptor: Int32 = -1
        var succeeded = false
        defer {
            if !succeeded {
                Darwin.close(descriptor)
                if playcoverDescriptor >= 0 {
                    Darwin.close(playcoverDescriptor)
                }
            }
        }
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
                      status.st_uid == geteuid() else {
                    Darwin.close(child)
                    throw PlayCoverBackendError.prepareFailed(
                        "managed directory is not owner-controlled: "
                            + component
                    )
                }
                if status.st_mode & 0o777 != 0o700,
                   fchmod(child, 0o700) != 0 {
                    Darwin.close(child)
                    throw PlayCoverBackendError.prepareFailed(
                        "managed directory permissions cannot be repaired: "
                            + component
                    )
                }
            }
            if index == components.count - 2 {
                try validateOrBootstrapGlobalLayout(
                    parentDescriptor: child,
                    parentWasCreated: created
                )
                playcoverDescriptor = Darwin.dup(child)
                guard playcoverDescriptor >= 0,
                      Darwin.fcntl(
                        playcoverDescriptor,
                        F_SETFD,
                        FD_CLOEXEC
                      ) == 0 else {
                    if playcoverDescriptor >= 0 {
                        Darwin.close(playcoverDescriptor)
                        playcoverDescriptor = -1
                    }
                    Darwin.close(child)
                    throw PlayCoverBackendError.prepareFailed(
                        "cannot retain managed Mac cache directory"
                    )
                }
            }
            Darwin.close(descriptor)
            descriptor = child
        }
        guard playcoverDescriptor >= 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "managed Mac cache directory was not opened"
            )
        }
        let prepared = URL(
            fileURLWithPath: lexicalPath,
            isDirectory: true
        )
        let homesDescriptor = try openOrCreateOwnedDirectory(
            parentDescriptor: playcoverDescriptor,
            name: "homes",
            label: "global home references"
        )
        let locksDescriptor: Int32
        do {
            locksDescriptor = try openOrCreateOwnedDirectory(
                parentDescriptor: playcoverDescriptor,
                name: "locks",
                label: "global cache locks"
            )
        } catch {
            Darwin.close(homesDescriptor)
            throw error
        }
        succeeded = true
        return ManagedDirectoryAccess(
            playcover: prepared.deletingLastPathComponent(),
            prepared: prepared,
            homes: URL(
                fileURLWithPath: paths.playcoverGlobalHomes,
                isDirectory: true
            ),
            locks: URL(
                fileURLWithPath: paths.playcoverGlobalLocks,
                isDirectory: true
            ),
            playcoverDescriptor: playcoverDescriptor,
            preparedDescriptor: descriptor,
            homesDescriptor: homesDescriptor,
            locksDescriptor: locksDescriptor
        )
    }

    /// `objects`, `homes`, and `locks` form one durable cache layout. Never
    /// recreate a missing sibling under an existing root: doing so could hide
    /// lost references or replace the inode held by another process's lock.
    /// Only a root created by this invocation may bootstrap the empty layout.
    private static func validateOrBootstrapGlobalLayout(
        parentDescriptor: Int32,
        parentWasCreated: Bool
    ) throws {
        let requiredNames = ["objects", "homes", "locks"]
        var present = Set<String>()
        for name in requiredNames {
            var status = stat()
            if fstatat(
                parentDescriptor,
                name,
                &status,
                AT_SYMLINK_NOFOLLOW
            ) == 0 {
                present.insert(name)
                continue
            }
            guard errno == ENOENT else {
                throw PlayCoverBackendError.cacheTampered(
                    "cannot inspect global cache layout entry \(name): "
                        + "errno \(errno)"
                )
            }
        }

        if parentWasCreated {
            let entries = try anchoredDirectoryNames(
                descriptor: parentDescriptor,
                label: "global cache root"
            )
            guard present.isEmpty, entries.isEmpty else {
                throw PlayCoverBackendError.cacheTampered(
                    "new global cache root is not empty"
                )
            }
            for name in requiredNames {
                guard Darwin.mkdirat(
                    parentDescriptor,
                    name,
                    0o700
                ) == 0 else {
                    throw PlayCoverBackendError.prepareFailed(
                        "cannot bootstrap global cache layout entry "
                            + "\(name): errno \(errno)"
                    )
                }
            }
            try syncDirectoryDescriptor(
                parentDescriptor,
                label: "global cache root"
            )
            return
        }

        guard present == Set(requiredNames) else {
            let missing = requiredNames.filter {
                !present.contains($0)
            }.joined(separator: ", ")
            throw PlayCoverBackendError.cacheTampered(
                "existing global cache layout is incomplete; missing: "
                    + missing
            )
        }
    }

    private static func openOrCreateOwnedDirectory(
        parentDescriptor: Int32,
        name: String,
        label: String
    ) throws -> Int32 {
        var descriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT {
            guard Darwin.mkdirat(parentDescriptor, name, 0o700) == 0
                    || errno == EEXIST else {
                throw PlayCoverBackendError.prepareFailed(
                    "cannot create \(label): errno \(errno)"
                )
            }
            descriptor = Darwin.openat(
                parentDescriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw PlayCoverBackendError.prepareFailed(
                "cannot open \(label): errno \(errno)"
            )
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0 else {
            Darwin.close(descriptor)
            throw PlayCoverBackendError.cacheTampered(
                "\(label) is not an owner-only directory"
            )
        }
        return descriptor
    }
    #endif

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
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." {
                continue
            }
            if component == ".." {
                if !components.isEmpty {
                    components.removeLast()
                }
                continue
            }
            components.append(component)
        }
        return "/" + components.joined(separator: "/")
    }
}
