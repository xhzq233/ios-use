import Foundation
@testable import IOSUseCLI
import XCTest

final class PlayCoverCoreTests: XCTestCase {
    override func tearDown() {
        #if canImport(AppKit)
        PlayCoverBundleStartLock.runningBundlePIDsOverrideForTesting = nil
        #endif
        super.tearDown()
    }

    func testPathsKeepSessionStateHomeLocalAndSlotsAccountGlobal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("account")
        let first = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": root.appendingPathComponent("one").path,
            ],
            accountHomeDirectoryOverrideForTesting: account.path,
            socketRootOverrideForTesting:
                root.appendingPathComponent("sockets").path
        )
        let second = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": root.appendingPathComponent("two").path,
            ],
            accountHomeDirectoryOverrideForTesting: account.path,
            socketRootOverrideForTesting:
                root.appendingPathComponent("sockets").path
        )

        XCTAssertNotEqual(first.playcoverCurrentBundle,
                          second.playcoverCurrentBundle)
        XCTAssertNotEqual(first.playcoverLaunching, second.playcoverLaunching)
        XCTAssertEqual(first.playcoverApps, second.playcoverApps)
        XCTAssertEqual(first.playcoverLocks, second.playcoverLocks)
        XCTAssertEqual(first.playcoverPlayChain, second.playcoverPlayChain)
        XCTAssertEqual(
            first.playcoverSigningBinding,
            second.playcoverSigningBinding
        )
    }

    func testProductionAccountRootsIgnorePoisonedHOME() throws {
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": "/tmp/ios-use-logical-home",
            "HOME": "/tmp/attacker-home",
        ])

        XCTAssertFalse(paths.playcoverApps.hasPrefix("/tmp/attacker-home/"))
        XCTAssertFalse(
            paths.playcoverPlayChain.hasPrefix("/tmp/attacker-home/")
        )
    }

    func testSessionSocketIsBoundedIndependentlyOfLogicalHome() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": "/" + String(repeating: "long/", count: 80),
            ],
            accountHomeDirectoryOverrideForTesting:
                root.appendingPathComponent("account").path,
            socketRootOverrideForTesting:
                root.appendingPathComponent("sockets").path
        )
        let socket = try paths.macRuntimeSocketPath(
            sessionID: UUID().uuidString
        )

        XCTAssertLessThanOrEqual(socket.utf8.count, 103)
        XCTAssertTrue(socket.hasSuffix(".sock"))
    }

    func testBundleStartLockRejectsAnAlreadyRunningBundle() throws {
        #if canImport(AppKit)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        PlayCoverBundleStartLock.runningBundlePIDsOverrideForTesting = { _ in
            [4242]
        }

        XCTAssertThrowsError(
            try PlayCoverBundleStartLock.acquire(
                bundleIdentifier: "com.example.demo",
                paths: paths
            )
        ) { error in
            XCTAssertEqual(
                error as? PlayCoverBackendError,
                .bundleAlreadyRunning(
                    bundleIdentifier: "com.example.demo",
                    pid: 4242
                )
            )
        }
        #endif
    }

    func testRecoveryAcquisitionReturnsCensusWithoutRejecting() throws {
        #if canImport(AppKit)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        PlayCoverBundleStartLock.runningBundlePIDsOverrideForTesting = { _ in
            [111, 222]
        }

        let acquisition = try PlayCoverBundleStartLock.acquireForRecovery(
            bundleIdentifier: "com.example.demo",
            paths: paths
        )

        XCTAssertEqual(acquisition.runningPIDs, [111, 222])
        _ = acquisition.lock
        #endif
    }

    func testFreshRuntimeSocketRejectsAnyExistingObject() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        let socket = root.appendingPathComponent("s-demo.sock")

        XCTAssertNoThrow(
            try PlayCoverService.validateFreshRuntimeSocketPath(socket.path)
        )
        try Data("occupied".utf8).write(to: socket)
        XCTAssertThrowsError(
            try PlayCoverService.validateFreshRuntimeSocketPath(socket.path)
        )
    }

    func testStdioValidationRequiresExactRequestedIdentity() throws {
        let expected = PlayCoverStdioLogIdentity(
            path: "/tmp/mac.log",
            device: 7,
            inode: 9
        )
        let matching = PlayCoverRuntimeStdioState(
            status: "redirected",
            path: "/tmp/mac.log",
            device: 7,
            inode: 9,
            failureStage: nil,
            errorNumber: nil
        )
        let mismatched = PlayCoverRuntimeStdioState(
            status: "redirected",
            path: "/tmp/other.log",
            device: 7,
            inode: 9,
            failureStage: nil,
            errorNumber: nil
        )

        XCTAssertNoThrow(
            try PlayCoverService.validateStdio(matching, expected: expected)
        )
        XCTAssertThrowsError(
            try PlayCoverService.validateStdio(mismatched, expected: expected)
        )
    }

    func testPrepareContractIsSingleSlotAndAlwaysFrida() {
        XCTAssertTrue(
            PlayCoverService.prepareImplementationRevision.contains(
                "single-bundle-slot"
            )
        )
        XCTAssertTrue(
            PlayCoverService.prepareImplementationRevision.contains(
                "always-frida"
            )
        )
    }

    func testMacBackendCompatibilityWarningStartsAtMacOS26() {
        XCTAssertNil(
            IOSUseCLI.macBackendCompatibilityWarning(
                for: OperatingSystemVersion(
                    majorVersion: 25,
                    minorVersion: 9,
                    patchVersion: 0
                )
            )
        )
        XCTAssertNotNil(
            IOSUseCLI.macBackendCompatibilityWarning(
                for: OperatingSystemVersion(
                    majorVersion: 26,
                    minorVersion: 0,
                    patchVersion: 0
                )
            )
        )
    }

    func testDirectLaunchEnvironmentCarriesSanitizedRuntimeConfiguration() {
        let environment = PlayCoverSlotLauncher.launchEnvironmentForTesting(
            source: [
                "HOME": "/Users/example",
                "LANG": "en_US.UTF-8",
                "SECRET_TOKEN": "must-not-leak",
                "IOS_USE_PLAY_GENERATION_KEY": "obsolete",
                "IOS_USE_PLAY_FRIDA": "obsolete",
                "IOS_USE_PLAY_ENABLE_3X_BACKING": "1",
            ],
            sessionID: "session-id",
            runtimeSocketPath: "/private/tmp/runtime.sock",
            installRevision: String(repeating: "a", count: 64),
            playChainPath: "/Users/example/Library/PlayChain"
        )

        XCTAssertEqual(environment["HOME"], "/Users/example")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(environment["SECRET_TOKEN"], "")
        XCTAssertEqual(environment["IOS_USE_PLAY_GENERATION_KEY"], "")
        XCTAssertEqual(environment["IOS_USE_PLAY_FRIDA"], "")
        XCTAssertEqual(environment["IOS_USE_PLAY_SESSION_ID"], "session-id")
        XCTAssertEqual(
            environment["IOS_USE_PLAY_INSTALL_REVISION"],
            String(repeating: "a", count: 64)
        )
        XCTAssertEqual(
            environment["IOS_USE_PLAY_RUNTIME_SOCKET"],
            "/private/tmp/runtime.sock"
        )
        XCTAssertEqual(
            environment["IOS_USE_PLAYCHAIN_ROOT"],
            "/Users/example/Library/PlayChain"
        )
        XCTAssertEqual(
            environment["IOS_USE_PLAY_ENABLE_3X_BACKING"],
            "1"
        )
    }

    private func makePaths(root: URL) -> IOSUsePaths {
        IOSUsePaths.resolve(
            environment: [
                "IOS_USE_HOME": root.appendingPathComponent("home").path,
            ],
            accountHomeDirectoryOverrideForTesting:
                root.appendingPathComponent("account").path,
            socketRootOverrideForTesting:
                root.appendingPathComponent("sockets").path
        )
    }

    private func temporaryDirectory() throws -> URL {
        let root = URL(
            fileURLWithPath: "/tmp/iu-core-"
                + String(UUID().uuidString.prefix(8)),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }
}
