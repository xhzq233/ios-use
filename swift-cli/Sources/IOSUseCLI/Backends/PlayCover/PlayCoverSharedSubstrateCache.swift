import CryptoKit
import Darwin
import Foundation

enum PlayCoverSharedSubstrateCacheError: Error, Sendable {
    case invalidManifest(String)
    case unavailable(String)
}
enum PlayCoverSharedSubstrateCache {
    static let schemaVersion = 1
    /// This identity is portable across `IOS_USE_HOME` values by design.
    struct Binding: Codable, Equatable, Sendable {
        let generationKey: String
        let sourceContentSHA256: String
        let runtimeBuildSHA256: String
        let preparationRevision: String
        let signerPublicKeySPKISHA256: String
        let signerCertificateSHA256: String
        let signingPolicyRevision: String
        let bundleIdentifier: String
        let appBundleName: String
        let mainExecutableRelativePath: String
        let convertedMachORelativePaths: [String]
    }
    struct Manifest: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let binding: Binding
        /// Supplied by the caller's authoritative substrate inspection.
        let substrateTreeSHA256: String
        init(binding: Binding, substrateTreeSHA256: String) {
            schemaVersion = PlayCoverSharedSubstrateCache.schemaVersion
            self.binding = binding
            self.substrateTreeSHA256 = substrateTreeSHA256
        }
    }
    struct Entry: Equatable, Sendable {
        let appURL: URL
        let manifest: Manifest
    }
    enum LookupResult: Equatable, Sendable {
        case hit(Entry)
        case miss
    }
    struct LockedKey {
        let paths: PlayCoverSharedCachePaths
        let generationKey: String
        func lookup(
            expected binding: Binding,
            validator: (URL, Manifest) throws -> Void
        ) throws -> LookupResult {
            try validate(binding)
            guard binding.generationKey == generationKey else {
                throw PlayCoverSharedSubstrateCacheError.invalidManifest(
                    "generation key does not match the held lock"
                )
            }
            let object = objectURL
            guard lstatExists(object.path) else {
                return .miss
            }
            do {
                try requireOwnedDirectory(object, mode: 0o700)
                let manifestData = try readMetadata(
                    object.appendingPathComponent("manifest.json")
                )
                let manifest = try JSONDecoder().decode(
                    Manifest.self, from: manifestData
                )
                try validate(manifest)
                guard manifest.binding == binding else {
                    throw CacheDamage.invalid
                }
                let completed = try JSONDecoder().decode(
                    Completed.self,
                    from: readMetadata(
                        object.appendingPathComponent("completed.json")
                    )
                )
                guard completed.schemaVersion == schemaVersion,
                    completed.generationKey == generationKey,
                    completed.manifestSHA256 == sha256(manifestData),
                    completed.substrateTreeSHA256
                        == manifest.substrateTreeSHA256
                else {
                    throw CacheDamage.invalid
                }
                let app = object.appendingPathComponent(
                    binding.appBundleName, isDirectory: true
                )
                try requireOwnedDirectory(app)
                try validator(app, manifest)
                return .hit(Entry(appURL: app, manifest: manifest))
            } catch {
                try discardCorruptObject(object)
                return .miss
            }
        }
        /// Publish does not repeat the caller's substrate content-hash pass.
        func publish(
            manifest: Manifest,
            populate: (URL) throws -> Void,
            validator: (URL, Manifest) throws -> Void
        ) throws -> Entry {
            try validate(manifest)
            guard manifest.binding.generationKey == generationKey else {
                throw PlayCoverSharedSubstrateCacheError.invalidManifest(
                    "generation key does not match the held lock"
                )
            }
            let stage = URL(
                fileURLWithPath: paths.preparedSubstrateObjects,
                isDirectory: true
            ).appendingPathComponent(
                ".staging-\(generationKey)-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try FileManager.default.createDirectory(
                    at: stage,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                try requireOwnedDirectory(stage, mode: 0o700)
            } catch {
                throw unavailable("cannot create sibling staging", error)
            }
            var stageExists = true
            defer {
                if stageExists {
                    try? FileManager.default.removeItem(at: stage)
                }
            }
            let app = stage.appendingPathComponent(
                manifest.binding.appBundleName, isDirectory: true
            )
            do {
                try populate(app)
                try requireOwnedDirectory(app)
                let manifestData = try encoded(manifest)
                try writeMetadata(
                    manifestData,
                    to: stage.appendingPathComponent("manifest.json")
                )
                try writeMetadata(
                    encoded(
                        Completed(
                            schemaVersion: schemaVersion,
                            generationKey: generationKey,
                            manifestSHA256: sha256(manifestData),
                            substrateTreeSHA256:
                                manifest.substrateTreeSHA256
                        )
                    ),
                    to: stage.appendingPathComponent("completed.json")
                )
            } catch {
                throw unavailable("cannot populate sibling staging", error)
            }
            for _ in 0..<2 {
                if Darwin.renameatx_np(
                    AT_FDCWD, stage.path, AT_FDCWD, objectURL.path,
                    UInt32(RENAME_EXCL)
                ) == 0 {
                    stageExists = false
                    return Entry(
                        appURL: objectURL.appendingPathComponent(
                            manifest.binding.appBundleName,
                            isDirectory: true
                        ),
                        manifest: manifest
                    )
                }
                guard errno == EEXIST else {
                    throw errnoUnavailable("atomic publish failed")
                }
                switch try lookup(
                    expected: manifest.binding,
                    validator: validator
                ) {
                case .hit(let winner):
                    return winner
                case .miss:
                    continue
                }
            }
            throw PlayCoverSharedSubstrateCacheError.unavailable(
                "atomic publish winner could not be resolved"
            )
        }
        /// `COPYFILE_CLONE` falls back to a byte copy and never hard-links.
        func materialize(
            _ entry: Entry,
            toFreshTarget target: URL,
            validator: (URL, Manifest) throws -> Void
        ) throws {
            guard entry.manifest.binding.generationKey == generationKey else {
                throw PlayCoverSharedSubstrateCacheError.unavailable(
                    "materialization entry does not match held lock")
            }
            try cloneOrCopy(from: entry.appURL, toFreshTarget: target)
            do {
                try validator(target, entry.manifest)
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw unavailable("materialized substrate is invalid", error)
            }
        }
        private var objectURL: URL {
            URL(fileURLWithPath: paths.preparedSubstrateObjects)
                .appendingPathComponent(generationKey, isDirectory: true)
        }
    }
    private static let processLocksGuard = NSLock()
    private static var processLocks: [String: NSLock] = [:]
    static func cloneOrCopy(from source: URL, toFreshTarget target: URL) throws
    {
        guard !lstatExists(target.path) else {
            throw PlayCoverSharedSubstrateCacheError.unavailable(
                "clone/copy target is not fresh")
        }
        let flags = UInt32(
            COPYFILE_CLONE | COPYFILE_RECURSIVE
                | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
        guard Darwin.copyfile(source.path, target.path, nil, flags) == 0 else {
            let failure = errno
            try? FileManager.default.removeItem(at: target)
            throw PlayCoverSharedSubstrateCacheError.unavailable(
                "clone/copy failed: errno \(failure)")
        }
    }
    static func withLockedKey<T>(
        paths: PlayCoverSharedCachePaths,
        generationKey: String,
        _ operation: (LockedKey) throws -> T
    ) throws -> T {
        try validateDigest(generationKey, "generation key")
        let processLockKey =
            "\(paths.preparedSubstrateRoot)\0\(generationKey)"
        processLocksGuard.lock()
        let processLock: NSLock
        if let existing = processLocks[processLockKey] {
            processLock = existing
        } else {
            processLock = NSLock()
            processLocks[processLockKey] = processLock
        }
        processLocksGuard.unlock()
        processLock.lock()
        defer { processLock.unlock() }
        try prepareDirectories(paths)
        let lockPath = "\(paths.preparedSubstrateLocks)/\(generationKey).lock"
        let descriptor = Darwin.open(
            lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600
        )
        guard descriptor >= 0 else {
            throw errnoUnavailable("cannot open per-key lock")
        }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw errnoUnavailable("cannot secure per-key lock")
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1,
            status.st_mode & 0o7777 == 0o600
        else {
            throw PlayCoverSharedSubstrateCacheError.unavailable(
                "per-key lock is not an owned 0600 regular file"
            )
        }
        while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
            guard errno == EINTR else {
                throw errnoUnavailable("cannot acquire per-key lock")
            }
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try operation(
            LockedKey(paths: paths, generationKey: generationKey)
        )
    }
    /// No automatic GC: every cached substrate is disposable cold-build data.
}
extension PlayCoverSharedSubstrateCache {
    fileprivate struct Completed: Codable {
        let schemaVersion: Int
        let generationKey: String
        let manifestSHA256: String
        let substrateTreeSHA256: String
    }
    fileprivate enum CacheDamage: Error { case invalid }
    fileprivate static func prepareDirectories(
        _ paths: PlayCoverSharedCachePaths
    ) throws {
        for path in [
            paths.preparedSubstrateRoot,
            paths.preparedSubstrateObjects,
            paths.preparedSubstrateLocks,
        ] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var status = stat()
            if lstat(path, &status) == 0 {
                guard status.st_mode & S_IFMT == S_IFDIR,
                    status.st_uid == geteuid()
                else {
                    throw PlayCoverSharedSubstrateCacheError.unavailable(
                        "cache path is not an owned directory"
                    )
                }
            } else if errno == ENOENT {
                do {
                    try FileManager.default.createDirectory(
                        at: url,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                } catch {
                    throw unavailable("cannot create cache directory", error)
                }
            } else {
                throw errnoUnavailable("cannot inspect cache directory")
            }
            guard chmod(path, 0o700) == 0 else {
                throw errnoUnavailable("cannot secure cache directory")
            }
            do {
                try requireOwnedDirectory(url, mode: 0o700)
            } catch {
                throw unavailable("cache directory remains unsafe", error)
            }
        }
    }
    fileprivate static func requireOwnedDirectory(
        _ url: URL,
        mode: mode_t? = nil
    ) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_uid == geteuid(),
            mode == nil || status.st_mode & 0o7777 == mode
        else {
            throw CacheDamage.invalid
        }
    }
    fileprivate static func readMetadata(_ url: URL) throws -> Data {
        var status = stat()
        guard lstat(url.path, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(),
            status.st_nlink == 1,
            status.st_size <= 1_048_576
        else {
            throw CacheDamage.invalid
        }
        return try Data(contentsOf: url)
    }
    fileprivate static func writeMetadata(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        guard chmod(url.path, 0o600) == 0 else {
            throw errnoUnavailable("cannot secure cache metadata")
        }
    }
    fileprivate static func discardCorruptObject(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw unavailable("cannot discard corrupt cache object", error)
        }
    }
    fileprivate static func validate(_ manifest: Manifest) throws {
        guard manifest.schemaVersion == schemaVersion else {
            throw PlayCoverSharedSubstrateCacheError.invalidManifest(
                "unsupported schema"
            )
        }
        try validate(manifest.binding)
        try validateDigest(
            manifest.substrateTreeSHA256, "substrate tree hash"
        )
    }
    fileprivate static func validate(_ binding: Binding) throws {
        for (value, label) in [
            (binding.generationKey, "generation key"),
            (binding.sourceContentSHA256, "source hash"),
            (binding.runtimeBuildSHA256, "runtime hash"),
            (binding.signerPublicKeySPKISHA256, "signer key hash"),
            (binding.signerCertificateSHA256, "certificate hash"),
        ] {
            try validateDigest(value, label)
        }
        guard !binding.preparationRevision.isEmpty,
            !binding.signingPolicyRevision.isEmpty,
            !binding.bundleIdentifier.isEmpty,
            safeName(binding.appBundleName),
            binding.appBundleName.hasSuffix(".app"),
            safeRelativePath(binding.mainExecutableRelativePath),
            binding.convertedMachORelativePaths
                == binding.convertedMachORelativePaths.sorted(),
            Set(binding.convertedMachORelativePaths).count
                == binding.convertedMachORelativePaths.count,
            binding.convertedMachORelativePaths.allSatisfy(
                safeRelativePath
            )
        else {
            throw PlayCoverSharedSubstrateCacheError.invalidManifest(
                "binding contains an empty or unsafe value"
            )
        }
    }
    fileprivate static func validateDigest(
        _ value: String, _ label: String
    ) throws {
        guard value.count == 64,
            value.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else {
            throw PlayCoverSharedSubstrateCacheError.invalidManifest(
                "\(label) is not lowercase SHA-256"
            )
        }
    }
    fileprivate static func safeName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }
    fileprivate static func safeRelativePath(_ value: String) -> Bool {
        !value.hasPrefix("/")
            && value.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    fileprivate static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    fileprivate static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
    }
    fileprivate static func lstatExists(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
    }
    fileprivate static func unavailable(_ message: String, _ error: Error)
        -> PlayCoverSharedSubstrateCacheError
    {
        .unavailable("\(message): \(error)")
    }
    fileprivate static func errnoUnavailable(_ message: String)
        -> PlayCoverSharedSubstrateCacheError
    {
        .unavailable("\(message): errno \(errno)")
    }
}
