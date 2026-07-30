import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import IOSUseCLI

final class PlayCoverSharedSubstrateCacheTests: XCTestCase {
    func testSameKeyIsReusedAcrossTwoIOSUseHomes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let builds = CacheTestCounter()

        let first = try Self.resolve(fixture, builds: builds)
        let second = try Self.resolve(fixture, builds: builds)
        XCTAssertEqual(builds.value, 1)
        XCTAssertEqual(first, second)

        let homeA = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": "\(fixture.root.path)/home-a"]
        )
        let homeB = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": "\(fixture.root.path)/home-b"]
        )
        for home in [homeA, homeB] {
            let parent = URL(
                fileURLWithPath: home.root, isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true
            )
            let target = parent.appendingPathComponent(
                "Demo.app", isDirectory: true
            )
            try PlayCoverSharedSubstrateCache.withLockedKey(
                paths: fixture.paths,
                generationKey: fixture.manifest.binding.generationKey
            ) {
                try $0.materialize(
                    first,
                    toFreshTarget: target,
                    validator: Self.validateSubstrate
                )
            }
            XCTAssertEqual(
                try Data(
                    contentsOf: target.appendingPathComponent("payload.txt")
                ),
                Self.payload
            )
        }

        let manifestJSON = try String(
            contentsOf: fixture.objectURL
                .appendingPathComponent("manifest.json"),
            encoding: .utf8
        )
        XCTAssertFalse(manifestJSON.contains(homeA.root))
        XCTAssertFalse(manifestJSON.contains(homeB.root))
    }

    func testConcurrentResolutionRunsBuilderOnce() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let builds = CacheTestCounter()
        let results = CacheTestBox<Result<
            PlayCoverSharedSubstrateCache.Entry, Error
        >>()
        let group = DispatchGroup()

        for _ in 0..<6 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    results.append(
                        .success(try Self.resolve(fixture, builds: builds))
                    )
                } catch {
                    results.append(.failure(error))
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(builds.value, 1)
        XCTAssertEqual(results.values.count, 6)
        for result in results.values {
            _ = try result.get()
        }
    }

    func testDifferentGenerationKeysDoNotShareProcessLock() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let errors = CacheTestBox<Error>()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                try PlayCoverSharedSubstrateCache.withLockedKey(
                    paths: fixture.paths,
                    generationKey: String(repeating: "1", count: 64)
                ) { _ in
                    firstEntered.signal()
                    _ = releaseFirst.wait(timeout: .now() + 5)
                }
            } catch {
                errors.append(error)
            }
        }
        guard firstEntered.wait(timeout: .now() + 5) == .success else {
            releaseFirst.signal()
            XCTFail("first key did not acquire its lock")
            return
        }

        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                _ = try PlayCoverSharedSubstrateCache.withLockedKey(
                    paths: fixture.paths,
                    generationKey: String(repeating: "2", count: 64)
                ) { _ in secondEntered.signal() }
            } catch {
                errors.append(error)
            }
        }
        let secondStatus = secondEntered.wait(timeout: .now() + 2)
        releaseFirst.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(secondStatus, .success)
        XCTAssertTrue(errors.values.isEmpty)
    }

    func testExistingRootSymlinkIsRejectedBeforeChmod() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-shared-cache-symlink-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent(
            "target", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: true
        )
        XCTAssertEqual(chmod(target.path, 0o755), 0)
        let link = root.appendingPathComponent("cache")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: target
        )
        let paths = try PlayCoverSharedCachePaths.resolve(
            preparedSubstrateRoot: link.path
        )

        XCTAssertThrowsError(
            try PlayCoverSharedSubstrateCache.withLockedKey(
                paths: paths,
                generationKey: String(repeating: "3", count: 64)
            ) { _ in () }
        )
        XCTAssertEqual(try Self.permissions(target.path), 0o755)
    }

    func testDuplicateConvertedPathsAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.manifest.binding
        let duplicate = PlayCoverSharedSubstrateCache.Binding(
            generationKey: source.generationKey,
            sourceContentSHA256: source.sourceContentSHA256,
            runtimeBuildSHA256: source.runtimeBuildSHA256,
            preparationRevision: source.preparationRevision,
            signerPublicKeySPKISHA256:
                source.signerPublicKeySPKISHA256,
            signerCertificateSHA256:
                source.signerCertificateSHA256,
            signingPolicyRevision: source.signingPolicyRevision,
            bundleIdentifier: source.bundleIdentifier,
            appBundleName: source.appBundleName,
            mainExecutableRelativePath:
                source.mainExecutableRelativePath,
            convertedMachORelativePaths: [
                "Contents/MacOS/Demo", "Contents/MacOS/Demo",
            ]
        )

        XCTAssertThrowsError(
            try PlayCoverSharedSubstrateCache.withLockedKey(
                paths: fixture.paths,
                generationKey: source.generationKey
            ) {
                try $0.lookup(
                    expected: duplicate,
                    validator: Self.validateSubstrate
                )
            }
        )
    }

    func testContentTamperIsDiscardedAndBecomesMiss() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try Self.resolve(fixture, builds: CacheTestCounter())
        try Data("tampered".utf8).write(
            to: fixture.objectURL
                .appendingPathComponent("Demo.app")
                .appendingPathComponent("payload.txt")
        )

        let lookup = try PlayCoverSharedSubstrateCache.withLockedKey(
            paths: fixture.paths,
            generationKey: fixture.manifest.binding.generationKey
        ) {
            try $0.lookup(
                expected: fixture.manifest.binding,
                validator: Self.validateSubstrate
            )
        }
        XCTAssertEqual(lookup, .miss)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.objectURL.path
            )
        )
    }

    func testDefaultPathIgnoresIOSUseHomeAndHome() throws {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/dev.ios-use")
            .appendingPathComponent("mac")
            .appendingPathComponent("prepared-substrate-v1")
            .standardizedFileURL.path
        let oldIOSUseHome = Self.environmentValue("IOS_USE_HOME")
        let oldHome = Self.environmentValue("HOME")
        defer {
            Self.restoreEnvironment("IOS_USE_HOME", oldIOSUseHome)
            Self.restoreEnvironment("HOME", oldHome)
        }
        setenv("IOS_USE_HOME", "/tmp/wrong-ios-use-home", 1)
        setenv("HOME", "/tmp/wrong-home", 1)

        let paths = try PlayCoverSharedCachePaths.resolve()
        XCTAssertEqual(paths.preparedSubstrateRoot, expected)
        XCTAssertFalse(paths.preparedSubstrateRoot.contains("wrong-home"))
    }

    func testTargetMutationCannotChangeCachedSubstrate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let entry = try Self.resolve(
            fixture, builds: CacheTestCounter()
        )
        let target = fixture.root.appendingPathComponent(
            "materialized/Demo.app", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try PlayCoverSharedSubstrateCache.withLockedKey(
            paths: fixture.paths,
            generationKey: fixture.manifest.binding.generationKey
        ) {
            try $0.materialize(
                entry,
                toFreshTarget: target,
                validator: Self.validateSubstrate
            )
        }
        let cachedPayload = entry.appURL.appendingPathComponent(
            "payload.txt"
        )
        let targetPayload = target.appendingPathComponent("payload.txt")
        var cachedStatus = stat()
        var targetStatus = stat()
        XCTAssertEqual(stat(cachedPayload.path, &cachedStatus), 0)
        XCTAssertEqual(stat(targetPayload.path, &targetStatus), 0)
        XCTAssertNotEqual(cachedStatus.st_ino, targetStatus.st_ino)

        try Data("target-only".utf8).write(to: targetPayload)
        XCTAssertEqual(
            try Data(contentsOf: cachedPayload),
            Self.payload
        )
        XCTAssertNoThrow(
            try Self.validateSubstrate(entry.appURL, entry.manifest)
        )
    }

    func testCacheDirectoriesAndPermanentLockAreOwnerOnly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try Self.resolve(fixture, builds: CacheTestCounter())
        for path in [
            fixture.paths.preparedSubstrateRoot,
            fixture.paths.preparedSubstrateObjects,
            fixture.paths.preparedSubstrateLocks,
            fixture.objectURL.path,
        ] {
            XCTAssertEqual(try Self.permissions(path), 0o700)
        }
        let key = fixture.manifest.binding.generationKey
        XCTAssertEqual(
            try Self.permissions(
                "\(fixture.paths.preparedSubstrateLocks)/\(key).lock"
            ),
            0o600
        )
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.preparedSubstrateObjects
        )
        XCTAssertFalse(
            siblings.contains { $0.hasPrefix(".staging-") }
        )
    }

    private static let executable = Data("executable-v1".utf8)
    private static let payload = Data("payload-v1".utf8)

    private static func resolve(
        _ fixture: Fixture,
        builds: CacheTestCounter
    ) throws -> PlayCoverSharedSubstrateCache.Entry {
        try PlayCoverSharedSubstrateCache.withLockedKey(
            paths: fixture.paths,
            generationKey: fixture.manifest.binding.generationKey
        ) { locked in
            switch try locked.lookup(
                expected: fixture.manifest.binding,
                validator: validateSubstrate
            ) {
            case .hit(let entry):
                return entry
            case .miss:
                builds.increment()
                return try locked.publish(
                    manifest: fixture.manifest,
                    populate: createSubstrate,
                    validator: validateSubstrate
                )
            }
        }
    }

    private static func createSubstrate(at app: URL) throws {
        let executableURL = app.appendingPathComponent(
            "Contents/MacOS/Demo"
        )
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try executable.write(to: executableURL)
        guard chmod(executableURL.path, 0o755) == 0 else {
            throw TestFailure.invalidSubstrate("chmod")
        }
        try payload.write(
            to: app.appendingPathComponent("payload.txt")
        )
    }

    private static func validateSubstrate(
        _ app: URL,
        _ manifest: PlayCoverSharedSubstrateCache.Manifest
    ) throws {
        guard app.lastPathComponent
                == manifest.binding.appBundleName else {
            throw TestFailure.invalidSubstrate("bundle name")
        }
        guard manifest.binding.convertedMachORelativePaths
                == ["Contents/MacOS/Demo"] else {
            throw TestFailure.invalidSubstrate("converted list")
        }
        guard FileManager.default.isExecutableFile(
            atPath: app.appendingPathComponent(
                manifest.binding.mainExecutableRelativePath
            ).path
        ) else {
            throw TestFailure.invalidSubstrate("main executable")
        }
        let actual = try treeHash(app)
        guard actual == manifest.substrateTreeSHA256 else {
            throw TestFailure.invalidSubstrate(
                "tree \(actual) != \(manifest.substrateTreeSHA256)"
            )
        }
    }

    private static func treeHash(_ app: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: app,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey,
            ]
        ) else {
            throw TestFailure.invalidSubstrate("enumerator")
        }
        let baseComponents = app.resolvingSymlinksInPath().pathComponents
        var records: [String] = []
        for case let url as URL in enumerator {
            let relative = url.resolvingSymlinksInPath().pathComponents
                .dropFirst(baseComponents.count)
                .joined(separator: "/")
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey]
            )
            if values.isDirectory == true {
                records.append("d \(relative)")
            } else if values.isRegularFile == true {
                records.append(
                    "f \(relative) \(testSHA256(try Data(contentsOf: url)))"
                )
            } else {
                throw TestFailure.invalidSubstrate("entry type")
            }
        }
        return testSHA256(Data(records.sorted().joined(separator: "\n").utf8))
    }

    private static func permissions(_ path: String) throws -> Int {
        let value = try FileManager.default.attributesOfItem(
            atPath: path
        )[.posixPermissions] as? NSNumber
        return try XCTUnwrap(value).intValue
    }

    private static func environmentValue(_ name: String) -> String? {
        getenv(name).map { String(cString: $0) }
    }

    private static func restoreEnvironment(
        _ name: String, _ value: String?
    ) {
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
    }

    private enum TestFailure: Error {
        case invalidSubstrate(String)
    }

    private struct Fixture: Sendable {
        let root: URL
        let paths: PlayCoverSharedCachePaths
        let manifest: PlayCoverSharedSubstrateCache.Manifest

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ios-use-shared-cache-\(UUID().uuidString)",
                    isDirectory: true
                )
            paths = try PlayCoverSharedCachePaths.resolve(
                preparedSubstrateRoot: root
                    .appendingPathComponent("cache").path
            )
            let binding = PlayCoverSharedSubstrateCache.Binding(
                generationKey: String(repeating: "a", count: 64),
                sourceContentSHA256:
                    String(repeating: "b", count: 64),
                runtimeBuildSHA256:
                    String(repeating: "c", count: 64),
                preparationRevision: "portable-substrate-v1",
                signerPublicKeySPKISHA256:
                    String(repeating: "d", count: 64),
                signerCertificateSHA256:
                    String(repeating: "e", count: 64),
                signingPolicyRevision: "policy-v1",
                bundleIdentifier: "dev.ios-use.fixture",
                appBundleName: "Demo.app",
                mainExecutableRelativePath: "Contents/MacOS/Demo",
                convertedMachORelativePaths: ["Contents/MacOS/Demo"]
            )
            let records = [
                "d Contents",
                "d Contents/MacOS",
                "f Contents/MacOS/Demo "
                    + testSHA256(
                        PlayCoverSharedSubstrateCacheTests.executable
                    ),
                "f payload.txt "
                    + testSHA256(
                        PlayCoverSharedSubstrateCacheTests.payload
                    ),
            ]
            manifest = PlayCoverSharedSubstrateCache.Manifest(
                binding: binding,
                substrateTreeSHA256: testSHA256(
                    Data(records.sorted().joined(separator: "\n").utf8)
                )
            )
        }

        var objectURL: URL {
            URL(
                fileURLWithPath: paths.preparedSubstrateObjects,
                isDirectory: true
            ).appendingPathComponent(
                manifest.binding.generationKey,
                isDirectory: true
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class CacheTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class CacheTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private func testSHA256(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}
