import CryptoKit
import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import IOSUseCLI

final class PlayCoverFastVerifyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PlayCoverService.signingIdentityResolverOverrideForTesting = {
            _ in makePlayCoverTestSigningIdentity()
        }
        PlayCoverService.rootCodeSignatureInspectorOverrideForTesting = {
            _ in makePlayCoverTestRootCodeSignature(
                bundleIdentifier: "com.example.fastverify"
            )
        }
    }

    override func tearDown() {
        Shell.runResultOverrideForTesting = nil
        PlayCoverService.fastVerifyEventOverrideForTesting = nil
        PlayCoverService.launchIntegrityEventOverrideForTesting = nil
        PlayCoverService.launchAliasRootOverrideForTesting = nil
        #if canImport(AppKit)
        PlayCoverService.workspaceOpenOverrideForTesting = nil
        #endif
        PlayCoverService
            .generationKeyComputationObserverForTesting = nil
        PlayCoverService.manifestValidationObserverForTesting = nil
        PlayCoverService.signingIdentityResolverOverrideForTesting = nil
        PlayCoverService.rootCodeSignatureInspectorOverrideForTesting = nil
        PlayCoverService.signingIdentityNowOverrideForTesting = nil
        super.tearDown()
    }

    func testFastVerifyCarriesOneValidatedGenerationIdentity()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        Shell.runResultOverrideForTesting = {
            _, _, _ in
            Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }
        var computationCount = 0
        PlayCoverService.generationKeyComputationObserverForTesting = {
            computationCount += 1
        }

        let bare = try PlayCoverService.fastVerifyEvidence(
            appPath: fixture.app.path,
            expectedGenerationIdentity: nil
        )
        XCTAssertEqual(
            computationCount,
            1,
            "a bare selection must independently derive the untrusted "
                + "disk manifest generation exactly once"
        )
        let trusted = bare.generationIdentity
        computationCount = 0

        let explicit = try PlayCoverService.fastVerifyEvidence(
            appPath: fixture.app.path,
            expectedGenerationIdentity: trusted
        )
        XCTAssertEqual(explicit.generationIdentity, trusted)
        XCTAssertEqual(computationCount, 0)

        let differentPlan = try PlayCoverService.makePreparationPlan(
            source: PlayCoverService.inspectPreparationSource(
                appPath: fixture.app.path
            ),
            runtimeFrameworkPath: fixture.app
                .appendingPathComponent(
                    "Frameworks",
                    isDirectory: true
                )
                .appendingPathComponent(
                    PlayCoverService.runtimeFrameworkName,
                    isDirectory: true
                ).path,
            paths: fixture.paths
        )
        XCTAssertNotEqual(
            differentPlan.generationIdentity,
            trusted
        )
        computationCount = 0
        XCTAssertThrowsError(
            try PlayCoverService.fastVerifyEvidence(
                appPath: fixture.app.path,
                expectedGenerationIdentity:
                    differentPlan.generationIdentity
            )
        )
        XCTAssertEqual(
            computationCount,
            0,
            "mismatched trusted evidence must fail by field comparison "
                + "without silently deriving a replacement key"
        )
    }

    func testFastVerifyResolvesSignerOnlyForBareReuse() throws {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        Shell.runResultOverrideForTesting = {
            _, _, _ in
            Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }
        var resolverCalls = 0
        PlayCoverService.signingIdentityResolverOverrideForTesting = {
            _ in
            resolverCalls += 1
            return fixture.manifest.signingIdentity
        }

        _ = try PlayCoverService.fastVerifyEvidence(
            appPath: fixture.app.path,
            expectedGenerationIdentity: nil
        )
        XCTAssertEqual(resolverCalls, 1)

        resolverCalls = 0
        _ = try PlayCoverService.fastVerifyEvidence(
            appPath: fixture.app.path,
            expectedGenerationIdentity: nil,
            expectedSigningIdentity:
                fixture.manifest.signingIdentity
        )
        XCTAssertEqual(
            resolverCalls,
            0,
            "explicit start must carry its one preflight signer through "
                + "fast verification"
        )
    }

    func testFastVerifyRejectsReplacedSignerAfterRootSeal() throws {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        var verifiedPaths: [String] = []
        let verifiedPathsLock = NSLock()
        Shell.runResultOverrideForTesting = {
            _, arguments, _ in
            if arguments.first == "--verify" {
                verifiedPathsLock.lock()
                verifiedPaths.append(arguments.last ?? "")
                verifiedPathsLock.unlock()
            }
            return Shell.RunResult(
                stdout: "",
                stderr: "",
                exitCode: 0
            )
        }
        PlayCoverService.signingIdentityResolverOverrideForTesting = {
            _ in makePlayCoverTestSigningIdentity(seed: "C")
        }

        assertFastVerifyTampered(fixture.app.path)

        XCTAssertEqual(
            verifiedPaths.last,
            ".",
            "the current signer must be checked only after the root seal"
        )
    }

    func testFastVerifyPropagatesSignerResolverErrorAfterRootSeal()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        var verifiedPaths: [String] = []
        let verifiedPathsLock = NSLock()
        Shell.runResultOverrideForTesting = {
            _, arguments, _ in
            if arguments.first == "--verify" {
                verifiedPathsLock.lock()
                verifiedPaths.append(arguments.last ?? "")
                verifiedPathsLock.unlock()
            }
            return Shell.RunResult(
                stdout: "",
                stderr: "",
                exitCode: 0
            )
        }
        let expected =
            PlayCoverSigningIdentityServiceError.unhealthy(.missing)
        PlayCoverService.signingIdentityResolverOverrideForTesting = {
            _ in throw expected
        }

        XCTAssertThrowsError(
            try PlayCoverService.fastVerifyEvidence(
                appPath: fixture.app.path,
                expectedGenerationIdentity: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? PlayCoverSigningIdentityServiceError,
                expected,
                "resolver failures must not be reclassified as cache "
                    + "tampering"
            )
        }
        XCTAssertEqual(
            verifiedPaths.last,
            ".",
            "resolver health must be observed only after the root seal"
        )
    }

    func testFastVerifyRejectsRootEvidenceMismatchAtAnchoredAppVnode()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        Shell.runResultOverrideForTesting = {
            _, _, _ in
            Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }
        var inspectedPath: String?
        PlayCoverService.rootCodeSignatureInspectorOverrideForTesting = {
            appURL in
            inspectedPath = appURL.path
            return makePlayCoverTestRootCodeSignature(
                bundleIdentifier: "com.example.fastverify",
                cdHashSeed: "C"
            )
        }

        assertFastVerifyTampered(fixture.app.path)

        XCTAssertTrue(
            inspectedPath?.hasPrefix("/.vol/") == true,
            "\(inspectedPath ?? "nil")"
        )
    }

    func testFastVerifiedGenerationTokenBindsMarkerAndVnode()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        Shell.runResultOverrideForTesting = {
            _, _, _ in
            Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }

        let acquired =
            try PlayCoverService.acquireFastVerifiedLaunchCapability(
                appPath: fixture.app.path,
                expectedGenerationIdentity: nil
            )
        defer { acquired.capability.close() }
        let completed = try JSONDecoder().decode(
            PlayCoverCompletedGeneration.self,
            from: Data(contentsOf: fixture.completedURL)
        )
        var status = stat()
        XCTAssertEqual(lstat(fixture.root.path, &status), 0)

        XCTAssertEqual(
            acquired.currentGenerationToken.generationKey,
            fixture.manifest.generationKey
        )
        XCTAssertEqual(
            acquired.currentGenerationToken.completedAt,
            fixture.manifest.completedAt
        )
        XCTAssertEqual(
            acquired.currentGenerationToken.completed,
            completed
        )
        XCTAssertEqual(
            acquired.currentGenerationToken.directoryIdentity.device,
            UInt64(status.st_dev)
        )
        XCTAssertEqual(
            acquired.currentGenerationToken.directoryIdentity.inode,
            UInt64(status.st_ino)
        )
    }

    func testLaunchVerifiedConsumesValidatedManifestWithoutRevalidation()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        Shell.runResultOverrideForTesting = {
            _, _, _ in
            Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }
        var validationCount = 0
        PlayCoverService.manifestValidationObserverForTesting = {
            validationCount += 1
        }
        PlayCoverService.launchAliasRootOverrideForTesting =
            fixture.launchAliasRoot
        #if canImport(AppKit)
        PlayCoverService.workspaceOpenOverrideForTesting = {
            _, _, completion in
            completion(
                nil,
                NSError(
                    domain: "PlayCoverFastVerifyTests",
                    code: 1
                )
            )
        }
        #endif
        let acquired =
            try PlayCoverService.acquireFastVerifiedLaunchCapability(
                appPath: fixture.app.path,
                expectedGenerationIdentity: nil
            )
        defer { acquired.capability.close() }
        XCTAssertEqual(validationCount, 1)
        let homeID = String(repeating: "a", count: 64)
        let socketRootURL = URL(
            fileURLWithPath:
                "/private/tmp/iu-fv-"
                + String(UUID().uuidString.prefix(8)),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: socketRootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: socketRootURL) }
        let socketRoot = socketRootURL.path
        let runtimeHomeURL = socketRootURL.appendingPathComponent(
            "runtime-home",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: runtimeHomeURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: runtimeHomeURL.appendingPathComponent(
                "playchain",
                isDirectory: true
            ),
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sessionID = "validated-manifest-single-pass"
        XCTAssertThrowsError(
            try PlayCoverService.launchVerified(
                validatedManifest: acquired.evidence,
                launchCapability: acquired.capability,
                sessionID: sessionID,
                runtimeSocketPath:
                    try IOSUsePaths.macRuntimeSocketPath(
                        sessionID: sessionID,
                        homeID: homeID,
                        socketRoot: socketRoot
                    ),
                runtimeHomePath: runtimeHomeURL.path,
                homeID: homeID,
                socketRootPath: socketRoot,
                timeout: 0.1
            )
        ) { error in
            guard case .launchFailed =
                    error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            validationCount,
            1,
            "launch must consume the fast-validated token without "
                + "revalidating its manifest"
        )
    }

    func testFastVerifyHashesRequiredExecutablesAndCodesignsSigningOrderOnce()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        var calls: [String: Int] = [:]
        var beforeHashes: [String: Int] = [:]
        var afterHashes: [String: Int] = [:]
        var beforeSignatures: [String: Int] = [:]
        var afterSignatures: [String: Int] = [:]
        let eventLock = NSLock()
        PlayCoverService.fastVerifyEventOverrideForTesting = { event in
            eventLock.lock()
            defer { eventLock.unlock() }
            switch event {
            case .beforeFileHash(let path):
                beforeHashes[path, default: 0] += 1
            case .afterFileHash(let path):
                afterHashes[path, default: 0] += 1
            case .beforeCodeSignature(let path):
                beforeSignatures[path, default: 0] += 1
            case .afterCodeSignature(let path):
                afterSignatures[path, default: 0] += 1
            case .afterGenerationOpen,
                 .afterPreparedAppOpen,
                 .beforeMetadataOpen,
                 .afterMetadataOpen,
                 .afterMetadataRead:
                break
            }
        }
        Shell.runResultOverrideForTesting = {
            executable,
            arguments,
            cwd in
            XCTAssertEqual(executable, "/usr/bin/codesign")
            XCTAssertEqual(Array(arguments.prefix(2)), ["--verify", "--strict"])
            XCTAssertTrue(cwd?.hasPrefix("/.vol/") == true)
            let path = try XCTUnwrap(arguments.last)
            XCTAssertFalse(path.hasPrefix("/"))
            eventLock.lock()
            calls[path, default: 0] += 1
            eventLock.unlock()
            return Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }

        try PlayCoverService.fastVerifyGeneration(
            appPath: fixture.app.path,
            manifest: fixture.manifest
        )

        let expectedHashes: Set<String> = [
            fixture.manifest.executableName,
            "Frameworks/\(PlayCoverService.runtimeFrameworkName)"
                + "/\(PlayCoverService.runtimeExecutableName)",
        ]
        let expectedCodeRelativePaths = Set(fixture.manifest.signingOrder)
        let expectedPaths = expectedCodeRelativePaths

        XCTAssertEqual(Set(beforeHashes.keys), expectedHashes)
        XCTAssertEqual(beforeHashes, afterHashes)
        XCTAssertTrue(
            beforeHashes.values.allSatisfy { $0 == 1 },
            "required files were re-hashed: \(beforeHashes)"
        )
        XCTAssertEqual(Set(calls.keys), expectedPaths)
        XCTAssertTrue(
            calls.values.allSatisfy { $0 == 1 },
            "codesign calls were not unique: \(calls)"
        )
        XCTAssertEqual(Set(beforeSignatures.keys), expectedCodeRelativePaths)
        XCTAssertEqual(beforeSignatures, afterSignatures)
        XCTAssertTrue(
            beforeSignatures.values.allSatisfy { $0 == 1 },
            "code objects were re-verified: \(beforeSignatures)"
        )
        XCTAssertFalse(
            expectedCodeRelativePaths.contains(
                fixture.manifest.executableName
            ),
            "the root bundle already verifies its main executable"
        )
        XCTAssertFalse(
            expectedCodeRelativePaths.contains(
                "Frameworks/\(PlayCoverService.runtimeFrameworkName)"
                    + "/\(PlayCoverService.runtimeExecutableName)"
            ),
            "the Runtime bundle already verifies its executable"
        )
    }

    func testFastVerifyOverlapsHashesWithNestedSignaturesAndKeepsRootLast()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let hashStarted = DispatchSemaphore(value: 0)
        let releaseHash = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var blockedFirstHash = false
        var hashIsBlocked = false
        var hashReleaseSucceeded = false
        var completedHashEvents = 0
        var attemptedNestedOverlap = false
        var nestedObservedBlockedHash = false
        var rootObservedCompletedHashes = false
        PlayCoverService.fastVerifyEventOverrideForTesting = { event in
            switch event {
            case .beforeFileHash:
                stateLock.lock()
                let shouldBlock = !blockedFirstHash
                blockedFirstHash = true
                if shouldBlock {
                    hashIsBlocked = true
                }
                stateLock.unlock()
                guard shouldBlock else {
                    return
                }
                hashStarted.signal()
                let released =
                    releaseHash.wait(timeout: .now() + 5) == .success
                stateLock.lock()
                hashIsBlocked = false
                hashReleaseSucceeded = released
                stateLock.unlock()
            case .afterFileHash:
                stateLock.lock()
                completedHashEvents += 1
                stateLock.unlock()
            case .afterGenerationOpen,
                 .afterPreparedAppOpen,
                 .beforeMetadataOpen,
                 .afterMetadataOpen,
                 .afterMetadataRead,
                 .beforeCodeSignature,
                 .afterCodeSignature:
                return
            }
        }
        Shell.runResultOverrideForTesting = {
            _, arguments, _ in
            if arguments.last == "." {
                stateLock.lock()
                rootObservedCompletedHashes =
                    !hashIsBlocked
                    && hashReleaseSucceeded
                    && completedHashEvents == 2
                stateLock.unlock()
            } else {
                stateLock.lock()
                let shouldCoordinate = !attemptedNestedOverlap
                attemptedNestedOverlap = true
                stateLock.unlock()
                guard shouldCoordinate else {
                    return Shell.RunResult(
                        stdout: "",
                        stderr: "",
                        exitCode: 0
                    )
                }
                let overlapped =
                    hashStarted.wait(timeout: .now() + 5) == .success
                stateLock.lock()
                let blocked = hashIsBlocked
                if !nestedObservedBlockedHash {
                    nestedObservedBlockedHash = overlapped && blocked
                }
                stateLock.unlock()
                releaseHash.signal()
            }
            return Shell.RunResult(
                stdout: "",
                stderr: "",
                exitCode: 0
            )
        }

        try PlayCoverService.fastVerifyGeneration(
            appPath: fixture.app.path,
            manifest: fixture.manifest
        )

        stateLock.lock()
        let nestedObserved = nestedObservedBlockedHash
        let releaseSucceeded = hashReleaseSucceeded
        let rootObserved = rootObservedCompletedHashes
        stateLock.unlock()
        XCTAssertTrue(
            nestedObserved,
            "a nested codesign must run while the hash lane is blocked"
        )
        XCTAssertTrue(
            releaseSucceeded,
            "the hash lane must be released by the concurrent nested lane"
        )
        XCTAssertTrue(
            rootObserved,
            "root codesign must remain after every required hash as the "
                + "final App seal"
        )
    }

    func testConcurrentNestedSignatureFailureDoesNotMaskHashFailure()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let hashMutated = DispatchSemaphore(value: 0)
        let releaseHash = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var mutatedFirstHash = false
        var hashReleaseSucceeded = false
        var nestedFailureInjected = false
        var coordinatedNestedCall = false
        PlayCoverService.fastVerifyEventOverrideForTesting = { event in
            guard case .beforeFileHash(let relative) = event else {
                return
            }
            stateLock.lock()
            let shouldMutate = !mutatedFirstHash
            mutatedFirstHash = true
            stateLock.unlock()
            guard shouldMutate else {
                return
            }
            let target = fixture.app.appendingPathComponent(relative)
            var bytes = try Data(contentsOf: target)
            bytes[0] ^= 0xff
            try bytes.write(to: target)
            hashMutated.signal()
            let released =
                releaseHash.wait(timeout: .now() + 5) == .success
            stateLock.lock()
            hashReleaseSucceeded = released
            stateLock.unlock()
        }
        Shell.runResultOverrideForTesting = {
            _, arguments, _ in
            guard arguments.last != "." else {
                XCTFail(
                    "root signature must not run after a nested "
                        + "signature failure"
                )
                return Shell.RunResult(
                    stdout: "",
                    stderr: "",
                    exitCode: 0
                )
            }
            stateLock.lock()
            let shouldCoordinate = !coordinatedNestedCall
            coordinatedNestedCall = true
            stateLock.unlock()
            guard shouldCoordinate else {
                return Shell.RunResult(
                    stdout: "",
                    stderr: "",
                    exitCode: 0
                )
            }
            let overlapped =
                hashMutated.wait(timeout: .now() + 5) == .success
            stateLock.lock()
            nestedFailureInjected = overlapped
            stateLock.unlock()
            releaseHash.signal()
            return Shell.RunResult(
                stdout: "",
                stderr: "nested signature failed",
                exitCode: 1
            )
        }

        XCTAssertThrowsError(
            try PlayCoverService.fastVerifyGeneration(
                appPath: fixture.app.path,
                manifest: fixture.manifest
            )
        ) { error in
            guard case .cacheTampered(let detail) =
                    error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(
                detail.contains("recorded file changed:"),
                "hash failure must retain its former precedence: \(detail)"
            )
            XCTAssertFalse(detail.contains("nested signature failed"))
        }
        stateLock.lock()
        let injected = nestedFailureInjected
        let released = hashReleaseSucceeded
        stateLock.unlock()
        XCTAssertTrue(injected)
        XCTAssertTrue(released)
    }

    func testFastVerifyBoundsNestedSignatureWorkersAndKeepsRootLast()
        throws
    {
        let fixture = try FastVerifyFixture(
            additionalStandaloneDylibCount: 5
        )
        defer { fixture.remove() }
        let nestedCount = fixture.manifest.signingOrder.count - 1
        XCTAssertGreaterThan(nestedCount, 4)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        let result = LockedResult()
        let completed = expectation(
            description: "bounded nested signature verification"
        )
        var active = 0
        var maximumActive = 0
        var nestedStarted = 0
        var nestedTimedOut = false
        var rootObservedJoinedNested = false
        Shell.runResultOverrideForTesting = {
            _, arguments, _ in
            let relative = try XCTUnwrap(arguments.last)
            if relative == "." {
                stateLock.lock()
                rootObservedJoinedNested =
                    active == 0 && nestedStarted == nestedCount
                stateLock.unlock()
                return Shell.RunResult(
                    stdout: "",
                    stderr: "",
                    exitCode: 0
                )
            }
            stateLock.lock()
            active += 1
            nestedStarted += 1
            maximumActive = max(maximumActive, active)
            stateLock.unlock()
            entered.signal()
            let released =
                release.wait(timeout: .now() + 5) == .success
            stateLock.lock()
            active -= 1
            nestedTimedOut = nestedTimedOut || !released
            stateLock.unlock()
            return Shell.RunResult(
                stdout: "",
                stderr: released ? "" : "test release timed out",
                exitCode: released ? 0 : 1
            )
        }

        DispatchQueue.global(qos: .userInitiated).async {
            result.set(
                Result {
                    try PlayCoverService.fastVerifyGeneration(
                        appPath: fixture.app.path,
                        manifest: fixture.manifest
                    )
                }
            )
            completed.fulfill()
        }

        var initialWorkers = 0
        for _ in 0..<4 {
            guard entered.wait(timeout: .now() + 5) == .success else {
                break
            }
            initialWorkers += 1
        }
        if initialWorkers == 4 {
            XCTAssertEqual(
                entered.wait(timeout: .now() + 0.2),
                .timedOut,
                "a fifth nested worker escaped the configured bound"
            )
        }
        for _ in 0..<nestedCount {
            release.signal()
        }
        wait(for: [completed], timeout: 10)

        guard let verification = result.value else {
            return XCTFail("fast verification did not finish")
        }
        if case .failure(let error) = verification {
            XCTFail("unexpected fast verification failure: \(error)")
        }
        stateLock.lock()
        let observedMaximum = maximumActive
        let observedStarted = nestedStarted
        let observedTimeout = nestedTimedOut
        let observedRoot = rootObservedJoinedNested
        stateLock.unlock()
        XCTAssertEqual(initialWorkers, 4)
        XCTAssertEqual(observedMaximum, 4)
        XCTAssertEqual(observedStarted, nestedCount)
        XCTAssertFalse(observedTimeout)
        XCTAssertTrue(observedRoot)
    }

    func testConcurrentNestedSignatureFailureUsesSigningOrder()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let nested = Array(fixture.manifest.signingOrder.dropLast())
        let first = try XCTUnwrap(nested.first)
        let second = nested[1]
        let secondFinished = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var firstObservedSecond = false
        var rootRan = false
        Shell.runResultOverrideForTesting = {
            _, arguments, _ in
            let relative = try XCTUnwrap(arguments.last)
            if relative == "." {
                stateLock.lock()
                rootRan = true
                stateLock.unlock()
                return Shell.RunResult(
                    stdout: "",
                    stderr: "",
                    exitCode: 0
                )
            }
            if relative == first {
                let observed =
                    secondFinished.wait(timeout: .now() + 5)
                        == .success
                stateLock.lock()
                firstObservedSecond = observed
                stateLock.unlock()
                return Shell.RunResult(
                    stdout: "",
                    stderr: "first signing-order failure",
                    exitCode: 1
                )
            }
            if relative == second {
                secondFinished.signal()
                return Shell.RunResult(
                    stdout: "",
                    stderr: "second signing-order failure",
                    exitCode: 1
                )
            }
            return Shell.RunResult(
                stdout: "",
                stderr: "",
                exitCode: 0
            )
        }

        XCTAssertThrowsError(
            try PlayCoverService.fastVerifyGeneration(
                appPath: fixture.app.path,
                manifest: fixture.manifest
            )
        ) { error in
            guard case .cacheTampered(let detail) =
                    error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("(\(first))"))
            XCTAssertTrue(
                detail.contains("first signing-order failure")
            )
            XCTAssertFalse(
                detail.contains("second signing-order failure")
            )
        }
        stateLock.lock()
        let observedSecond = firstObservedSecond
        let observedRoot = rootRan
        stateLock.unlock()
        XCTAssertTrue(
            observedSecond,
            "a later signing-order failure must be allowed to finish first"
        )
        XCTAssertFalse(observedRoot)
    }

    func testGenerationSidecarsUseFinalInspectionHashesWithoutPreparedFiles()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let manifest = fixture.manifest
        let executable = try XCTUnwrap(
            manifest.machOs.first {
                $0.relativePath == manifest.executableName
            }
        )
        let runtimePrefix =
            "Frameworks/\(manifest.runtimeFrameworkName)/"
        let runtime = try XCTUnwrap(
            manifest.machOs.first {
                $0.relativePath.hasPrefix(runtimePrefix)
                    && $0.relativePath.split(separator: "/").last
                        == Substring(
                            PlayCoverService.runtimeExecutableName
                        )
            }
        )

        fixture.remove()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.app.path)
        )

        let sidecars = try PlayCoverService.generationSidecars(
            manifest: manifest
        )

        XCTAssertEqual(
            sidecars.completed.executableSHA256,
            executable.fileSHA256
        )
        XCTAssertEqual(
            sidecars.completed.runtimeSHA256,
            runtime.fileSHA256
        )
        let persistedManifest = try JSONDecoder().decode(
            PlayCoverPrepareManifest.self,
            from: sidecars.manifestData
        )
        XCTAssertTrue(
            try persistedManifest.hasSamePersistedSeal(as: manifest)
        )
    }

    func testGenerationSidecarsSealVersionedRuntimeExecutable()
        throws
    {
        let fixture = try FastVerifyFixture(
            versionedRuntime: true
        )
        defer { fixture.remove() }

        XCTAssertEqual(
            fixture.manifest.runtimeExecutableRelativePath,
            "Frameworks/IOSUsePlayRuntime.framework/"
                + "Versions/A/IOSUsePlayRuntime"
        )
        let runtime = try XCTUnwrap(
            fixture.manifest.machOs.first {
                $0.relativePath
                    == fixture.manifest
                        .runtimeExecutableRelativePath
            }
        )
        XCTAssertEqual(
            fixture.manifest.runtimeExecutableSHA256,
            runtime.fileSHA256
        )
        XCTAssertTrue(
            fixture.manifest.codeObjects.contains {
                $0.relativePath
                    == fixture.manifest
                        .runtimeExecutableRelativePath
            }
        )
    }

    func testRuntimeExecutableSealRejectsDuplicatedMachO()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let framework = fixture.app
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent(
                PlayCoverService.runtimeFrameworkName,
                isDirectory: true
            )
        let duplicateDirectory = framework
            .appendingPathComponent("Versions", isDirectory: true)
            .appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(
            at: duplicateDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: framework.appendingPathComponent(
                PlayCoverService.runtimeExecutableName
            ),
            to: duplicateDirectory.appendingPathComponent(
                PlayCoverService.runtimeExecutableName
            )
        )
        let inspection = try PlayCoverService.inspect(
            appPath: fixture.app.path
        )

        XCTAssertThrowsError(
            try PlayCoverService.runtimeExecutableMachO(
                in: inspection
            )
        ) { error in
            guard case .verificationFailed(let message) =
                    error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("missing or duplicated"))
        }
    }

    func testMutationAfterFinalInspectionCannotBeSealedIntoCompletedMarker()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let executable = fixture.app.appendingPathComponent(
            fixture.manifest.executableName
        )
        var bytes = try Data(contentsOf: executable)
        bytes[bytes.index(before: bytes.endIndex)] ^= 0xff
        try bytes.write(to: executable)

        let sidecars = try PlayCoverService.generationSidecars(
            manifest: fixture.manifest
        )
        let recordedExecutable = try XCTUnwrap(
            fixture.manifest.machOs.first {
                $0.relativePath == fixture.manifest.executableName
            }
        )
        XCTAssertEqual(
            sidecars.completed.executableSHA256,
            recordedExecutable.fileSHA256
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(sidecars.completed).write(
            to: fixture.completedURL
        )
        Shell.runResultOverrideForTesting = { _, _, _ in
            Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }

        assertFastVerifyTampered(fixture.app.path)
    }

    func testDescriptorSHA256MatchesOneShotAcrossBufferBoundaries()
        throws
    {
        #if canImport(Darwin)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "IOSUsePlayCoverDescriptorHash-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let sizes = [
            0,
            1,
            1_048_575,
            1_048_576,
            1_048_577,
            2_097_275,
        ]
        for size in sizes {
            var data = Data(count: size)
            data.withUnsafeMutableBytes {
                (bytes: UnsafeMutableRawBufferPointer) in
                for index in 0..<size {
                    bytes[index] = UInt8(
                        truncatingIfNeeded: index &* 31 &+ size
                    )
                }
            }
            let url = root.appendingPathComponent("bytes-\(size)")
            try data.write(to: url)
            let expected = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
            let descriptor = Darwin.open(
                url.path,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { continue }
            defer { Darwin.close(descriptor) }

            XCTAssertEqual(
                try PlayCoverService.fileSHA256(
                    descriptor: descriptor
                ),
                expected,
                "descriptor hash mismatch for \(size) bytes"
            )
        }
        #else
        throw XCTSkip("descriptor hashing is Darwin-only")
        #endif
    }

    func testFastVerifyUsesOneGenerationDescriptorAndAccepts0755AppRoot()
        throws
    {
        #if canImport(Darwin)
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        var appStatus = stat()
        XCTAssertEqual(lstat(fixture.app.path, &appStatus), 0)
        XCTAssertEqual(Int(appStatus.st_mode & 0o777), 0o755)
        var generationOpenCount = 0
        var appOpenCount = 0
        PlayCoverService.fastVerifyEventOverrideForTesting = { event in
            switch event {
            case .afterGenerationOpen:
                generationOpenCount += 1
            case .afterPreparedAppOpen:
                appOpenCount += 1
            default:
                break
            }
        }
        Shell.runResultOverrideForTesting = { _, _, _ in
            Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }

        XCTAssertNoThrow(
            try PlayCoverService.fastVerify(appPath: fixture.app.path)
        )

        XCTAssertEqual(generationOpenCount, 1)
        XCTAssertEqual(appOpenCount, 1)
        #else
        throw XCTSkip("descriptor verification is Darwin-only")
        #endif
    }

    func testFastVerifyRejectsInvalidSigningOrderBeforeCodeSign()
        throws
    {
        let fixture = try FastVerifyFixture(
            signingOrderOverride: [".", "."]
        )
        defer { fixture.remove() }
        var codeSignCalls = 0
        Shell.runResultOverrideForTesting = { _, _, _ in
            codeSignCalls += 1
            return Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }

        assertFastVerifyTampered(fixture.app.path)

        XCTAssertEqual(codeSignCalls, 0)
    }

    func testFastVerifyRejectsSigningOrderMissingStandaloneCodeObject()
        throws
    {
        let fixture = try FastVerifyFixture(
            signingOrderOverride: [
                "Frameworks/FixtureKit.framework",
                "Frameworks/\(PlayCoverService.runtimeFrameworkName)",
                ".",
            ]
        )
        defer { fixture.remove() }
        var codeSignCalls = 0
        Shell.runResultOverrideForTesting = { _, _, _ in
            codeSignCalls += 1
            return Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }

        assertFastVerifyTampered(fixture.app.path)

        XCTAssertEqual(codeSignCalls, 0)
    }

    func testGenerationReplacementAfterCompletedReadFailsFinalIdentity()
        throws
    {
        #if canImport(Darwin)
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let parent = fixture.root.deletingLastPathComponent()
        let replacement = parent.appendingPathComponent(
            "IOSUsePlayCoverReplacement-\(UUID().uuidString)",
            isDirectory: true
        )
        let displaced = parent.appendingPathComponent(
            "IOSUsePlayCoverDisplaced-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: replacement)
            try? FileManager.default.removeItem(at: displaced)
        }
        try FileManager.default.copyItem(
            at: fixture.root,
            to: replacement
        )
        let replacementExecutable = replacement
            .appendingPathComponent(fixture.app.lastPathComponent)
            .appendingPathComponent(fixture.manifest.executableName)
        try Data("damaged replacement".utf8).write(
            to: replacementExecutable
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: replacementExecutable.path
        )
        var replaced = false
        var reachedAnchoredHash = false
        PlayCoverService.fastVerifyEventOverrideForTesting = { event in
            if case .beforeFileHash = event {
                reachedAnchoredHash = true
            }
            guard event
                    == .afterMetadataRead(
                        PlayCoverService.completedFilename
                    ),
                  !replaced else {
                return
            }
            replaced = true
            guard Darwin.rename(
                    fixture.root.path,
                    displaced.path
                  ) == 0,
                  Darwin.rename(
                    replacement.path,
                    fixture.root.path
                  ) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno)
                )
            }
        }
        Shell.runResultOverrideForTesting = { _, _, _ in
            Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }

        assertFastVerifyTampered(fixture.app.path)

        XCTAssertTrue(replaced)
        XCTAssertTrue(
            reachedAnchoredHash,
            "replacement should be rejected by the final generation check"
        )
        #else
        throw XCTSkip("descriptor verification is Darwin-only")
        #endif
    }

    func testPreparedAppReplacementAfterOpenFailsFinalIdentity()
        throws
    {
        #if canImport(Darwin)
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let replacement = fixture.root.appendingPathComponent(
            "Replacement.app",
            isDirectory: true
        )
        let displaced = fixture.root.appendingPathComponent(
            "Displaced.app",
            isDirectory: true
        )
        try FileManager.default.copyItem(
            at: fixture.app,
            to: replacement
        )
        var replaced = false
        var reachedAnchoredHash = false
        PlayCoverService.fastVerifyEventOverrideForTesting = { event in
            if case .beforeFileHash = event {
                reachedAnchoredHash = true
            }
            guard event == .afterPreparedAppOpen,
                  !replaced else {
                return
            }
            replaced = true
            guard Darwin.rename(
                    fixture.app.path,
                    displaced.path
                  ) == 0,
                  Darwin.rename(
                    replacement.path,
                    fixture.app.path
                  ) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno)
                )
            }
        }
        Shell.runResultOverrideForTesting = { _, _, _ in
            Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }

        assertFastVerifyTampered(fixture.app.path)

        XCTAssertTrue(replaced)
        XCTAssertTrue(
            reachedAnchoredHash,
            "replacement should be rejected after anchored verification"
        )
        #else
        throw XCTSkip("descriptor verification is Darwin-only")
        #endif
    }

    func testCodeSignUsesStableAppVnodeAcrossReplaceAndRestore()
        throws
    {
        #if canImport(Darwin)
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let replacement = fixture.root.appendingPathComponent(
            "Replacement.app",
            isDirectory: true
        )
        let displaced = fixture.root.appendingPathComponent(
            "Displaced.app",
            isDirectory: true
        )
        try FileManager.default.copyItem(
            at: fixture.app,
            to: replacement
        )
        var originalStatus = stat()
        XCTAssertEqual(lstat(fixture.app.path, &originalStatus), 0)
        var exercisedABA = false
        Shell.runResultOverrideForTesting = {
            executable,
            arguments,
            cwd in
            XCTAssertEqual(executable, "/usr/bin/codesign")
            XCTAssertEqual(Array(arguments.prefix(2)), ["--verify", "--strict"])
            let stableRoot = try XCTUnwrap(cwd)
            XCTAssertTrue(stableRoot.hasPrefix("/.vol/"))
            let relative = try XCTUnwrap(arguments.last)
            XCTAssertFalse(relative.hasPrefix("/"))
            if relative == ".", !exercisedABA {
                exercisedABA = true
                guard Darwin.rename(
                        fixture.app.path,
                        displaced.path
                      ) == 0,
                      Darwin.rename(
                        replacement.path,
                        fixture.app.path
                      ) == 0 else {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(errno)
                    )
                }
                var stableStatus = stat()
                var lexicalStatus = stat()
                XCTAssertEqual(lstat(stableRoot, &stableStatus), 0)
                XCTAssertEqual(lstat(fixture.app.path, &lexicalStatus), 0)
                XCTAssertEqual(stableStatus.st_dev, originalStatus.st_dev)
                XCTAssertEqual(stableStatus.st_ino, originalStatus.st_ino)
                XCTAssertNotEqual(lexicalStatus.st_ino, originalStatus.st_ino)
                guard Darwin.rename(
                        fixture.app.path,
                        replacement.path
                      ) == 0,
                      Darwin.rename(
                        displaced.path,
                        fixture.app.path
                      ) == 0 else {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(errno)
                    )
                }
            }
            return Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }

        XCTAssertNoThrow(
            try PlayCoverService.fastVerify(appPath: fixture.app.path)
        )
        XCTAssertTrue(exercisedABA)
        #else
        throw XCTSkip("descriptor verification is Darwin-only")
        #endif
    }

    func testBundledExecutableIdentityRemainsCoveredWithoutOwnCodeSign()
        throws
    {
        #if canImport(Darwin)
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let frameworkRelative = "Frameworks/FixtureKit.framework"
        let executableRelative = "\(frameworkRelative)/FixtureKit"
        let framework = fixture.app.appendingPathComponent(
            frameworkRelative,
            isDirectory: true
        )
        let executable = fixture.app.appendingPathComponent(
            executableRelative
        )
        let replacement = framework.appendingPathComponent(
            "ReplacementExecutable"
        )
        let displaced = framework.appendingPathComponent(
            "DisplacedExecutable"
        )
        try FileManager.default.copyItem(
            at: executable,
            to: replacement
        )
        var signaturePaths = Set<String>()
        var replaced = false
        let signatureLock = NSLock()
        PlayCoverService.fastVerifyEventOverrideForTesting = { event in
            signatureLock.lock()
            defer { signatureLock.unlock() }
            if case .beforeCodeSignature(let relative) = event {
                signaturePaths.insert(relative)
            }
            guard event == .afterCodeSignature(frameworkRelative),
                  !replaced else {
                return
            }
            replaced = true
            guard Darwin.rename(
                    executable.path,
                    displaced.path
                  ) == 0,
                  Darwin.rename(
                    replacement.path,
                    executable.path
                  ) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno)
                )
            }
        }
        Shell.runResultOverrideForTesting = { _, _, _ in
            Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }

        assertFastVerifyTampered(fixture.app.path)

        signatureLock.lock()
        let didReplace = replaced
        let observedSignaturePaths = signaturePaths
        signatureLock.unlock()
        XCTAssertTrue(didReplace)
        XCTAssertTrue(
            observedSignaturePaths.contains(frameworkRelative)
        )
        XCTAssertFalse(
            observedSignaturePaths.contains(executableRelative)
        )
        #else
        throw XCTSkip("descriptor verification is Darwin-only")
        #endif
    }

    func testPreparedAppRootSymlinkFailsClosed() throws {
        #if canImport(Darwin)
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let saved = fixture.root.appendingPathComponent(
            "Saved.app",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: fixture.app, to: saved)
        try FileManager.default.createSymbolicLink(
            at: fixture.app,
            withDestinationURL: saved
        )

        assertFastVerifyTampered(fixture.app.path)
        #else
        throw XCTSkip("descriptor verification is Darwin-only")
        #endif
    }

    func testManifestByteSealRejectsSemanticallyEquivalentRewrite()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        var codeSignCalls = 0
        let codeSignLock = NSLock()
        Shell.runResultOverrideForTesting = { _, _, _ in
            codeSignLock.lock()
            codeSignCalls += 1
            codeSignLock.unlock()
            return Shell.RunResult(
                stdout: "",
                stderr: "",
                exitCode: 0
            )
        }

        XCTAssertNoThrow(
            try PlayCoverService.fastVerify(appPath: fixture.app.path)
        )
        codeSignLock.lock()
        let initialCodeSignCalls = codeSignCalls
        codeSignLock.unlock()
        XCTAssertGreaterThan(initialCodeSignCalls, 0)

        let canonical = try Data(contentsOf: fixture.manifestURL)
        let object = try JSONSerialization.jsonObject(with: canonical)
        let rewritten = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        XCTAssertNotEqual(rewritten, canonical)
        let decoded = try JSONDecoder().decode(
            PlayCoverPrepareManifest.self,
            from: rewritten
        )
        XCTAssertEqual(
            decoded.generationKey,
            fixture.manifest.generationKey
        )
        try rewritten.write(to: fixture.manifestURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.manifestURL.path
        )
        codeSignLock.lock()
        codeSignCalls = 0
        codeSignLock.unlock()

        assertFastVerifyTampered(fixture.app.path)

        codeSignLock.lock()
        let rewrittenCodeSignCalls = codeSignCalls
        codeSignLock.unlock()
        XCTAssertEqual(
            rewrittenCodeSignCalls,
            0,
            "rewritten manifest reached code signature verification"
        )
    }

    func testCompletedMarkerSchemaFiveOmitsLegacyArraySeals()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let data = try Data(contentsOf: fixture.completedURL)
        let completed = try JSONDecoder().decode(
            PlayCoverCompletedGeneration.self,
            from: data
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )

        XCTAssertEqual(completed.schemaVersion, 5)
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "schemaVersion",
                "generationKey",
                "manifestSHA256",
                "executableSHA256",
                "runtimeSHA256",
            ])
        )
        XCTAssertNil(object["inventorySHA256"])
        XCTAssertNil(object["machoSealSHA256"])
    }

    func testFastVerifyRejectsLegacyCompletedSchemaTwoBeforeCodeSign()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.completedURL)
            ) as? [String: Any]
        )
        object["schemaVersion"] = 2
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: fixture.completedURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.completedURL.path
        )
        var codeSignCalls = 0
        Shell.runResultOverrideForTesting = { _, _, _ in
            codeSignCalls += 1
            return Shell.RunResult(
                stdout: "",
                stderr: "",
                exitCode: 0
            )
        }

        assertFastVerifyTampered(fixture.app.path)
        XCTAssertEqual(codeSignCalls, 0)
    }

    func testManifestSymlinkFailsClosed() throws {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let saved = fixture.root.appendingPathComponent("saved-manifest")
        try FileManager.default.moveItem(
            at: fixture.manifestURL,
            to: saved
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.manifestURL,
            withDestinationURL: saved
        )

        assertFastVerifyTampered(fixture.app.path)
    }

    func testManifestFIFOIsRejectedWithoutBlocking() throws {
        #if canImport(Darwin)
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.manifestURL)
        XCTAssertEqual(mkfifo(fixture.manifestURL.path, 0o600), 0)
        let finished = DispatchSemaphore(value: 0)
        let result = LockedResult()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try PlayCoverService.fastVerify(
                    appPath: fixture.app.path
                )
                result.set(.success(()))
            } catch {
                result.set(.failure(error))
            }
            finished.signal()
        }

        let completedWithoutWriter =
            finished.wait(timeout: .now() + 1) == .success
        if !completedWithoutWriter {
            let writer = Darwin.open(
                fixture.manifestURL.path,
                O_WRONLY | O_NONBLOCK | O_CLOEXEC
            )
            if writer >= 0 {
                Darwin.close(writer)
            }
            _ = finished.wait(timeout: .now() + 1)
        }

        XCTAssertTrue(
            completedWithoutWriter,
            "opening hostile metadata FIFO blocked fast verification"
        )
        assertTampered(result.value)
        #else
        throw XCTSkip("FIFO verification is Darwin-only")
        #endif
    }

    func testOversizedManifestIsRejectedWithoutReadingPayload()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.manifestURL)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: fixture.manifestURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        )
        let handle = try FileHandle(forWritingTo: fixture.manifestURL)
        try handle.truncate(
            atOffset: UInt64(
                PlayCoverService.generationManifestMaximumBytes + 1
            )
        )
        try handle.close()
        let started = ProcessInfo.processInfo.systemUptime

        assertFastVerifyTampered(fixture.app.path)

        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - started,
            1,
            "oversized sparse metadata should be rejected by fstat"
        )
    }

    func testOversizedCompletedMarkerUsesItsSmallerLimit()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let handle = try FileHandle(
            forWritingTo: fixture.completedURL
        )
        try handle.truncate(
            atOffset: UInt64(
                PlayCoverService.completedMarkerMaximumBytes + 1
            )
        )
        try handle.close()
        var events: [PlayCoverService.FastVerifyEvent] = []
        PlayCoverService.fastVerifyEventOverrideForTesting = {
            events.append($0)
        }

        assertFastVerifyTampered(fixture.app.path)

        XCTAssertTrue(
            events.contains(
                .beforeMetadataOpen(
                    PlayCoverService.completedFilename
                )
            )
        )
        XCTAssertFalse(
            events.contains(
                .afterMetadataOpen(
                    PlayCoverService.completedFilename
                )
            ),
            "oversized completed marker should fail its fstat bound"
        )
    }

    func testManifestAtomicReplacementDuringReadFailsClosed()
        throws
    {
        #if canImport(Darwin)
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let replacement = fixture.root.appendingPathComponent(
            "replacement-manifest"
        )
        try Data(contentsOf: fixture.manifestURL).write(to: replacement)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: replacement.path
        )
        var replaced = false
        PlayCoverService.fastVerifyEventOverrideForTesting = { event in
            guard event
                    == .afterMetadataOpen(
                        PlayCoverService.manifestFilename
                    ),
                  !replaced else {
                return
            }
            replaced = true
            guard Darwin.rename(
                    replacement.path,
                    fixture.manifestURL.path
                  ) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno)
                )
            }
        }

        assertFastVerifyTampered(fixture.app.path)

        XCTAssertTrue(replaced)
        #else
        throw XCTSkip("metadata replacement verification is Darwin-only")
        #endif
    }

    func testLaunchCapabilityRejectsTopLevelReplacementAfterFastVerify()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        Shell.runResultOverrideForTesting = {
            _, _, _ in
            Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }
        let info = fixture.app.appendingPathComponent("Info.plist")
        let displaced = fixture.app.appendingPathComponent(
            "Verified-Info.plist"
        )
        let originalSize = try Data(contentsOf: info).count
        var replaced = false
        PlayCoverService.fastVerifyEventOverrideForTesting = { event in
            guard event == .afterCodeSignature("."),
                  !replaced else {
                return
            }
            replaced = true
            try FileManager.default.moveItem(
                at: info,
                to: displaced
            )
            try Data(repeating: 0x20, count: originalSize).write(to: info)
        }
        var launchBodyCalled = false

        XCTAssertThrowsError(
            try PlayCoverService.withFastVerifiedLaunchCapability(
                appPath: fixture.app.path,
                expectedGenerationIdentity: nil
            ) { _, _ in
                launchBodyCalled = true
            }
        ) { error in
            self.assertCacheTampered(error)
        }

        XCTAssertTrue(replaced)
        XCTAssertFalse(
            launchBodyCalled,
            "replacement between verification and capability capture "
                + "must not become the trusted launch baseline"
        )
    }

    #if canImport(AppKit)
    func testLaunchCapabilityRejectsAppReplacementBeforeSubmission()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let replacement = fixture.root.appendingPathComponent(
            "Replacement.app",
            isDirectory: true
        )
        let result = try launchIntegrityFailure(
            fixture: fixture,
            sessionID: "replace-app-before-submit",
            event: .afterFastVerificationBeforeLaunchBody
        ) {
            try FileManager.default.moveItem(
                at: fixture.app,
                to: replacement
            )
            try FileManager.default.createDirectory(
                at: fixture.app,
                withIntermediateDirectories: false
            )
        }

        assertCacheTampered(result.error)
        XCTAssertTrue(result.mutationFired)
        XCTAssertEqual(result.workspaceOpenCount, 0)
        XCTAssertFalse(result.workspaceOpenSubmitted)
        XCTAssertFalse(result.enteredOwnershipLoop)
        XCTAssertNil(result.alias)
    }

    func testLaunchCapabilityRejectsAliasReplacementBeforeSubmission()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let sessionID = "replace-alias-before-submit"
        PlayCoverService.launchAliasRootOverrideForTesting =
            fixture.launchAliasRoot
        let alias = PlayCoverService.sessionLaunchAlias(
            sessionID: sessionID
        )
        let displaced = alias.rootURL.appendingPathComponent(
            "Displaced.app",
            isDirectory: true
        )
        let result = try launchIntegrityFailure(
            fixture: fixture,
            sessionID: sessionID,
            event: .afterAliasBuiltBeforePreSubmitValidation
        ) {
            try FileManager.default.moveItem(
                at: alias.bundleURL,
                to: displaced
            )
            try FileManager.default.createDirectory(
                at: alias.bundleURL,
                withIntermediateDirectories: false
            )
        }

        assertCacheTampered(result.error)
        XCTAssertTrue(result.mutationFired)
        XCTAssertEqual(result.workspaceOpenCount, 0)
        XCTAssertFalse(result.workspaceOpenSubmitted)
        XCTAssertFalse(result.enteredOwnershipLoop)
        XCTAssertEqual(result.alias, alias)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: displaced.path)
        )
    }

    func testLaunchCapabilityRejectsAliasReplacementAfterSubmission()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let sessionID = "replace-alias-after-submit"
        PlayCoverService.launchAliasRootOverrideForTesting =
            fixture.launchAliasRoot
        let alias = PlayCoverService.sessionLaunchAlias(
            sessionID: sessionID
        )
        let displaced = alias.rootURL.appendingPathComponent(
            "Submitted.app",
            isDirectory: true
        )
        let result = try launchIntegrityFailure(
            fixture: fixture,
            sessionID: sessionID,
            event:
                .afterWorkspaceOpenReturnedBeforePostSubmitValidation
        ) {
            try FileManager.default.moveItem(
                at: alias.bundleURL,
                to: displaced
            )
            try FileManager.default.createDirectory(
                at: alias.bundleURL,
                withIntermediateDirectories: false
            )
        }

        assertCacheTampered(result.error)
        XCTAssertTrue(result.mutationFired)
        XCTAssertEqual(result.workspaceOpenCount, 1)
        XCTAssertTrue(result.workspaceOpenSubmitted)
        XCTAssertTrue(
            result.enteredOwnershipLoop,
            "a submitted request must remain under ownership observation "
                + "after post-submit integrity failure"
        )
        XCTAssertEqual(result.alias, alias)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: displaced.path)
        )
    }

    func testLaunchCapabilityAllowsSiblingInSharedAliasRoot()
        throws
    {
        let fixture = try FastVerifyFixture()
        defer { fixture.remove() }
        let sibling = fixture.launchAliasRoot.appendingPathComponent(
            "other-session.app",
            isDirectory: true
        )
        let result = try launchIntegrityFailure(
            fixture: fixture,
            sessionID: "shared-root-sibling",
            event: .afterAliasBuiltBeforePreSubmitValidation
        ) {
            try FileManager.default.createDirectory(
                at: sibling,
                withIntermediateDirectories: false
            )
        }

        guard case .launchFailed =
                result.error as? PlayCoverBackendError else {
            return XCTFail("unexpected error: \(result.error)")
        }
        XCTAssertTrue(result.mutationFired)
        XCTAssertEqual(result.workspaceOpenCount, 1)
        XCTAssertTrue(result.workspaceOpenSubmitted)
        XCTAssertTrue(result.enteredOwnershipLoop)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sibling.path)
        )
    }

    private func launchIntegrityFailure(
        fixture: FastVerifyFixture,
        sessionID: String,
        event: PlayCoverService.LaunchIntegrityEvent,
        mutation: @escaping () throws -> Void
    ) throws -> (
        error: Error,
        mutationFired: Bool,
        workspaceOpenCount: Int,
        workspaceOpenSubmitted: Bool,
        enteredOwnershipLoop: Bool,
        alias: PlayCoverService.SessionLaunchAlias?
    ) {
        Shell.runResultOverrideForTesting = { _, _, _ in
            Shell.RunResult(stdout: "", stderr: "", exitCode: 0)
        }
        PlayCoverService.launchAliasRootOverrideForTesting =
            fixture.launchAliasRoot
        var mutationFired = false
        var enteredOwnershipLoop = false
        PlayCoverService.launchIntegrityEventOverrideForTesting = {
            actual in
            if actual == .enteredExactOwnershipLoop {
                enteredOwnershipLoop = true
            }
            guard actual == event, !mutationFired else { return }
            mutationFired = true
            try mutation()
        }
        var workspaceOpenCount = 0
        PlayCoverService.workspaceOpenOverrideForTesting = {
            _, _, _ in
            workspaceOpenCount += 1
        }
        var alias: PlayCoverService.SessionLaunchAlias?
        var workspaceOpenSubmitted = false
        var postSubmissionIntegrityError: Error?
        do {
            try PlayCoverService.withFastVerifiedLaunchCapability(
                appPath: fixture.app.path,
                expectedGenerationIdentity: nil
            ) { evidence, capability in
                _ = try PlayCoverService.launchPreparedApplication(
                    manifest: evidence.manifest,
                    launchCapability: capability,
                    sessionID: sessionID,
                    runtimeSocketPath:
                        fixture.root.appendingPathComponent(
                            "runtime.sock"
                        ).path,
                    runtimeHomePath: fixture.root
                        .appendingPathComponent("runtime-home").path,
                    homeID: String(repeating: "a", count: 64),
                    deadline:
                        ProcessInfo.processInfo.systemUptime + 0.1,
                    launchAlias: &alias,
                    workspaceOpenSubmitted:
                        &workspaceOpenSubmitted,
                    postSubmissionIntegrityError:
                        &postSubmissionIntegrityError
                )
            }
            throw NSError(
                domain: "PlayCoverFastVerifyTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "launch integrity mutation was accepted",
                ]
            )
        } catch {
            return (
                error,
                mutationFired,
                workspaceOpenCount,
                workspaceOpenSubmitted,
                enteredOwnershipLoop,
                alias
            )
        }
    }
    #endif

    private func assertFastVerifyTampered(
        _ appPath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try PlayCoverService.fastVerify(appPath: appPath),
            file: file,
            line: line
        ) { error in
            guard case .cacheTampered =
                    error as? PlayCoverBackendError else {
                return XCTFail(
                    "unexpected error: \(error)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertCacheTampered(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .cacheTampered =
                error as? PlayCoverBackendError else {
            return XCTFail(
                "unexpected error: \(error)",
                file: file,
                line: line
            )
        }
    }

    private func assertTampered(
        _ result: Result<Void, Error>?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let result else {
            return XCTFail(
                "fast verification did not complete",
                file: file,
                line: line
            )
        }
        switch result {
        case .success:
            XCTFail(
                "hostile generation metadata was accepted",
                file: file,
                line: line
            )
        case .failure(let error):
            guard case .cacheTampered =
                    error as? PlayCoverBackendError else {
                return XCTFail(
                    "unexpected error: \(error)",
                    file: file,
                    line: line
                )
            }
        }
    }
}

private final class LockedResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Void, Error>?

    var value: Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Result<Void, Error>) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private struct FastVerifyFixture {
    let root: URL
    let paths: IOSUsePaths
    let app: URL
    let manifest: PlayCoverPrepareManifest
    let manifestURL: URL
    let completedURL: URL
    var launchAliasRoot: URL {
        root.deletingLastPathComponent().appendingPathComponent(
            "\(root.lastPathComponent)-launch-aliases",
            isDirectory: true
        )
    }

    init(
        signingOrderOverride: [String]? = nil,
        additionalStandaloneDylibCount: Int = 0,
        versionedRuntime: Bool = false
    ) throws {
        precondition(additionalStandaloneDylibCount >= 0)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "IOSUsePlayCoverFastVerify-\(UUID().uuidString)",
            isDirectory: true
        )
        paths = resolvePlayCoverTestPaths(
            environment: ["IOS_USE_HOME": root.path]
        )
        app = root.appendingPathComponent(
            "App.app",
            isDirectory: true
        )
        manifestURL = root.appendingPathComponent(
            PlayCoverService.manifestFilename
        )
        completedURL = root.appendingPathComponent(
            PlayCoverService.completedFilename
        )
        try FileManager.default.createDirectory(
            at: app,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: app.path
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.fastverify",
            "CFBundleExecutable": "Fixture",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Info.plist"))
        let executable = app.appendingPathComponent("Fixture")
        try Self.makeThinMachO().write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let source = try PlayCoverService.inspect(appPath: app.path)

        let runtimeFramework = app
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent(
                PlayCoverService.runtimeFrameworkName,
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: runtimeFramework,
            withIntermediateDirectories: true
        )
        let runtime: URL
        if versionedRuntime {
            let versions = runtimeFramework.appendingPathComponent(
                "Versions",
                isDirectory: true
            )
            let version = versions.appendingPathComponent(
                "A",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: version,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                atPath: versions.appendingPathComponent("Current").path,
                withDestinationPath: "A"
            )
            try FileManager.default.createSymbolicLink(
                atPath: runtimeFramework.appendingPathComponent(
                    PlayCoverService.runtimeExecutableName
                ).path,
                withDestinationPath:
                    "Versions/Current/"
                        + PlayCoverService.runtimeExecutableName
            )
            runtime = version.appendingPathComponent(
                PlayCoverService.runtimeExecutableName
            )
        } else {
            runtime = runtimeFramework.appendingPathComponent(
                PlayCoverService.runtimeExecutableName
            )
        }
        try Self.makeThinMachO().write(to: runtime)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtime.path
        )
        let fixtureFramework = app
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent(
                "FixtureKit.framework",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fixtureFramework,
            withIntermediateDirectories: false
        )
        let fixtureFrameworkInfo: [String: Any] = [
            "CFBundleIdentifier": "com.example.fixturekit",
            "CFBundleExecutable": "FixtureKit",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: fixtureFrameworkInfo,
            format: .xml,
            options: 0
        ).write(to: fixtureFramework.appendingPathComponent("Info.plist"))
        let fixtureFrameworkExecutable = fixtureFramework
            .appendingPathComponent("FixtureKit")
        try Self.makeThinMachO().write(to: fixtureFrameworkExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixtureFrameworkExecutable.path
        )
        let standaloneDylib = app
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("Standalone.dylib")
        try Self.makeThinMachO().write(to: standaloneDylib)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: standaloneDylib.path
        )
        for index in 0..<additionalStandaloneDylibCount {
            let extraDylib = app
                .appendingPathComponent(
                    "Frameworks",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "Extra-\(index).dylib"
                )
            try Self.makeThinMachO().write(to: extraDylib)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: extraDylib.path
            )
        }
        let prepared = try PlayCoverService.inspect(appPath: app.path)
        let runtimeExecutable =
            try PlayCoverService.runtimeExecutableMachO(
                in: prepared
            )
        let runtimeHash = try Self.fileSHA256(runtime)
        let signingIdentity = makePlayCoverTestSigningIdentity()
        let generationKey = PlayCoverService.makeGenerationKey(
            sourceContentHash: source.sourceContentHash,
            runtimeBuildHash: runtimeHash,
            prepareRevision: PlayCoverService.prepareImplementationRevision,
            accountNamespacePolicyHash:
                PlayCoverService.accountNamespacePolicyHash(
                    paths: paths
                ),
            signerPublicKeySPKISHA256:
                signingIdentity.publicKeySPKISHA256,
            signerCertificateSHA256:
                signingIdentity.certificateSHA256,
            signingPolicyRevision:
                signingIdentity.policy.revision
        )
        let signingOrder = signingOrderOverride
            ?? prepared.inventory.compactMap { entry -> String? in
                guard let codeObjectKind = entry.codeObjectKind,
                      entry.relativePath
                        != prepared.mainExecutableRelativePath,
                      !codeObjectKind.hasSuffix("Executable") else {
                    return nil
                }
                return entry.relativePath
            }.sorted() + ["."]
        manifest = PlayCoverPrepareManifest(
            sourceAppPath: source.appPath,
            preparedAppPath: app.path,
            bundleIdentifier: prepared.bundleIdentifier,
            executableName: prepared.executableName,
            executablePath: prepared.executablePath,
            sourceContentHash: source.sourceContentHash,
            sourceHashAfterPreparation: source.sourceContentHash,
            runtimeBuildHash: runtimeHash,
            prepareRevision: PlayCoverService.prepareImplementationRevision,
            accountNamespacePolicyHash:
                PlayCoverService.accountNamespacePolicyHash(
                    paths: paths
                ),
            generationKey: generationKey,
            signingIdentity: signingIdentity,
            rootCodeSignature: makePlayCoverTestRootCodeSignature(
                bundleIdentifier: prepared.bundleIdentifier,
                identity: signingIdentity
            ),
            runtimeLoadPath: PlayCoverMachO.runtimeLoadPath,
            runtimeFrameworkName:
                PlayCoverService.runtimeFrameworkName,
            convertedMachOs: prepared.machOs.map(\.relativePath),
            signingOrder: signingOrder,
            sourceInventory: source.inventory,
            sourceMachOs: source.machOs,
            inventory: prepared.inventory,
            machOs: prepared.machOs,
            entitlementDiff: try Self.emptyEntitlementDiff(),
            completedAt: "2026-07-27T00:00:00Z",
            runtimeExecutableRelativePath:
                runtimeExecutable.relativePath,
            runtimeExecutableSHA256:
                runtimeExecutable.fileSHA256,
            rootEntitlementsSHA256:
                String(repeating: "E", count: 64)
        )
        let sidecars = try PlayCoverService.generationSidecars(
            manifest: manifest
        )
        try sidecars.manifestData.write(to: manifestURL, options: .atomic)
        try Self.canonicalJSON(sidecars.completed).write(
            to: completedURL,
            options: .atomic
        )
        for sidecar in [manifestURL, completedURL] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: sidecar.path
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: launchAliasRoot)
    }

    private static func emptyEntitlementDiff()
        throws -> PlayCoverEntitlementDiff
    {
        try JSONDecoder().decode(
            PlayCoverEntitlementDiff.self,
            from: Data(
                """
                {
                  "original": {},
                  "playCoverBaseline": {},
                  "final": {},
                  "addedByPlayCover": [],
                  "addedByIOSUse": [],
                  "changedFromOriginal": [],
                  "removedFromOriginal": []
                }
                """.utf8
            )
        )
    }

    private static func canonicalJSON<T: Encodable>(
        _ value: T
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func fileSHA256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return sha256(data)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func makeThinMachO() -> Data {
        var commands: [Data] = []
        var segment = Data()
        appendU32(0x19, to: &segment)
        appendU32(152, to: &segment)
        segment.append(Data(repeating: 0, count: 56))
        appendU32(1, to: &segment)
        appendU32(0, to: &segment)
        segment.append(Data(repeating: 0, count: 48))
        appendU32(512, to: &segment)
        segment.append(Data(repeating: 0, count: 28))
        commands.append(segment)

        var build = Data()
        appendU32(0x32, to: &build)
        appendU32(24, to: &build)
        appendU32(2, to: &build)
        appendU32(0x0011_0000, to: &build)
        appendU32(0x0011_0400, to: &build)
        appendU32(0, to: &build)
        commands.append(build)

        var result = Data([0xcf, 0xfa, 0xed, 0xfe])
        appendU32(0x0100_000c, to: &result)
        appendU32(0, to: &result)
        appendU32(2, to: &result)
        appendU32(UInt32(commands.count), to: &result)
        appendU32(
            UInt32(commands.reduce(0) { $0 + $1.count }),
            to: &result
        )
        appendU32(0, to: &result)
        appendU32(0, to: &result)
        for command in commands {
            result.append(command)
        }
        result.append(
            Data(repeating: 0, count: max(0, 512 - result.count))
        )
        result.append(Data(repeating: 0xab, count: 64))
        return result
    }

    private static func appendU32(
        _ value: UInt32,
        to data: inout Data
    ) {
        data.append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }
}
