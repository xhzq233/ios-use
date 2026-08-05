import Foundation
import IOSUseProtocol
import XCTest
@testable import IOSUseCLI
#if canImport(Darwin)
import Darwin
#endif

final class PlayCoverMediaImportAdapterTests: XCTestCase {
    func testSuccessUsesFixedOsaScriptAndPathOnlyArgument() throws {
        let fileSystem = FakeMediaImportFileSystem()
        let runner = FakeMediaImportProcessRunner(
            result: .init(
                exitStatus: 0,
                standardOutput: Data(
                    "IOS_USE_MEDIA_IMPORT_RESULT\n1\nasset/local/id\n".utf8
                ),
                standardError: Data()
            )
        )
        let adapter = makeAdapter(
            processRunner: runner,
            fileSystem: fileSystem,
            timeoutSeconds: 17
        )

        let payload = try adapter.importMedia(args: makeArgs())

        XCTAssertEqual(payload.kind, "photo")
        XCTAssertEqual(payload.originalFilename, "fixture.heic")
        XCTAssertEqual(payload.byteCount, 4)
        XCTAssertEqual(payload.assetLocalIdentifier, "asset/local/id")
        XCTAssertFalse(payload.permissionPromptHandled)
        XCTAssertEqual(fileSystem.stageCount, 1)
        XCTAssertEqual(fileSystem.verifyCount, 2)
        XCTAssertEqual(fileSystem.cleanupCount, 1)
        XCTAssertFalse(fileSystem.hasStagedMaterial)

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.executablePath, "/usr/bin/osascript")
        XCTAssertEqual(invocation.timeoutSeconds, 17)
        XCTAssertEqual(invocation.arguments.count, 3)
        XCTAssertEqual(invocation.arguments[0], "-e")
        XCTAssertEqual(invocation.arguments[2], fileSystem.staged.path)
        XCTAssertFalse(
            invocation.arguments[1].contains(fileSystem.staged.path)
        )
        XCTAssertTrue(
            invocation.arguments[1].contains(
                #"tell application "Photos""#
            )
        )
        XCTAssertTrue(
            invocation.arguments[1].contains(
                "import {POSIX file mediaPath}"
            )
        )
        XCTAssertFalse(
            invocation.arguments[1].contains("System Events")
        )
        XCTAssertFalse(
            invocation.arguments[1].contains("do shell script")
        )
        XCTAssertTrue(
            invocation.arguments[1].contains(
                PlayCoverMediaImportAdapter.resultSentinel
            )
        )
    }

    func testPermissionDeniedHasAuthorizationTaxonomyAndCleansUp()
        throws
    {
        let fileSystem = FakeMediaImportFileSystem()
        let runner = FakeMediaImportProcessRunner(
            result: .init(
                exitStatus: 1,
                standardOutput: Data(),
                standardError: Data(
                    "execution error: Not authorized to send Apple "
                        .appending("events to Photos. (-1743)")
                        .utf8
                )
            )
        )

        let error = try captureAdapterError {
            try makeAdapter(
                processRunner: runner,
                fileSystem: fileSystem
            ).importMedia(args: makeArgs())
        }

        guard case .permissionDenied = error else {
            return XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(
            error.machineError.code,
            "mac_photos_automation_denied"
        )
        XCTAssertEqual(
            error.machineError.category,
            IOSUseErrorCategory.authorization
        )
        XCTAssertFalse(error.machineError.mutationMayHaveApplied)
        XCTAssertEqual(fileSystem.cleanupCount, 1)
        XCTAssertFalse(fileSystem.hasStagedMaterial)
    }

    func testUnavailableIsDistinctForLaunchAndAppleEventFailures()
        throws
    {
        let launchFileSystem = FakeMediaImportFileSystem()
        let launchError = try captureAdapterError {
            try makeAdapter(
                processRunner: FakeMediaImportProcessRunner(
                    error: PlayCoverMediaImportProcessRunnerError
                        .unavailable("missing osascript")
                ),
                fileSystem: launchFileSystem
            ).importMedia(args: makeArgs())
        }
        guard case .unavailable = launchError else {
            return XCTFail("unexpected error: \(launchError)")
        }
        XCTAssertEqual(
            launchError.machineError.code,
            "mac_photos_automation_unavailable"
        )
        XCTAssertFalse(
            launchError.machineError.mutationMayHaveApplied
        )
        XCTAssertEqual(launchFileSystem.cleanupCount, 1)

        let eventFileSystem = FakeMediaImportFileSystem()
        let eventError = try captureAdapterError {
            try makeAdapter(
                processRunner: FakeMediaImportProcessRunner(
                    result: .init(
                        exitStatus: 1,
                        standardOutput: Data(),
                        standardError: Data(
                            "Photos is unavailable. (-10827)".utf8
                        )
                    )
                ),
                fileSystem: eventFileSystem
            ).importMedia(args: makeArgs())
        }
        guard case .unavailable = eventError else {
            return XCTFail("unexpected error: \(eventError)")
        }
        XCTAssertEqual(eventFileSystem.cleanupCount, 1)
    }

    func testTimeoutsAreRetryableAndMayHaveMutated() throws {
        let cases: [FakeMediaImportProcessRunner] = [
            FakeMediaImportProcessRunner(
                error: PlayCoverMediaImportProcessRunnerError
                    .timedOut("deadline")
            ),
            FakeMediaImportProcessRunner(
                result: .init(
                    exitStatus: 1,
                    standardOutput: Data(),
                    standardError: Data(
                        "Photos got an error: AppleEvent timed out. "
                            .appending("(-1712)")
                            .utf8
                    )
                )
            ),
        ]

        for runner in cases {
            let fileSystem = FakeMediaImportFileSystem()
            let error = try captureAdapterError {
                try makeAdapter(
                    processRunner: runner,
                    fileSystem: fileSystem
                ).importMedia(args: makeArgs())
            }
            guard case .timedOut = error else {
                XCTFail("unexpected error: \(error)")
                continue
            }
            XCTAssertEqual(
                error.machineError.code,
                IOSUseErrorCode.mediaImportTimedOut
            )
            XCTAssertEqual(
                error.machineError.category,
                IOSUseErrorCategory.timeout
            )
            XCTAssertTrue(error.machineError.retryable)
            XCTAssertTrue(
                error.machineError.mutationMayHaveApplied
            )
            XCTAssertEqual(fileSystem.cleanupCount, 1)
            XCTAssertFalse(fileSystem.hasStagedMaterial)
        }
    }

    func testResultCardinalityAndIdentifierAreStrictlyClassified()
        throws
    {
        let cases: [
            (
                output: String,
                code: String,
                assertion: (PlayCoverMediaImportAdapterError) -> Bool
            )
        ] = [
            (
                "IOS_USE_MEDIA_IMPORT_RESULT\n0\n",
                "mac_media_import_zero_assets",
                {
                    if case .noImportedAssets = $0 { return true }
                    return false
                }
            ),
            (
                "IOS_USE_MEDIA_IMPORT_RESULT\n2\nasset-1\nasset-2\n",
                "mac_media_import_multiple_assets",
                {
                    if case .multipleImportedAssets(2) = $0 {
                        return true
                    }
                    return false
                }
            ),
            (
                "IOS_USE_MEDIA_IMPORT_RESULT\n1\n\n",
                "mac_media_import_empty_asset_identifier",
                {
                    if case .emptyAssetLocalIdentifier = $0 {
                        return true
                    }
                    return false
                }
            ),
        ]

        for testCase in cases {
            let fileSystem = FakeMediaImportFileSystem()
            let error = try captureAdapterError {
                try makeAdapter(
                    processRunner: FakeMediaImportProcessRunner(
                        result: .init(
                            exitStatus: 0,
                            standardOutput: Data(
                                testCase.output.utf8
                            ),
                            standardError: Data()
                        )
                    ),
                    fileSystem: fileSystem
                ).importMedia(args: makeArgs())
            }
            XCTAssertTrue(testCase.assertion(error), "\(error)")
            XCTAssertEqual(error.machineError.code, testCase.code)
            XCTAssertEqual(
                error.machineError.category,
                IOSUseErrorCategory.postcondition
            )
            XCTAssertTrue(
                error.machineError.mutationMayHaveApplied
            )
            XCTAssertEqual(fileSystem.cleanupCount, 1)
            XCTAssertFalse(fileSystem.hasStagedMaterial)
        }
    }

    func testResultEnvelopeRequiresVersionSentinel() throws {
        let fileSystem = FakeMediaImportFileSystem()
        let error = try captureAdapterError {
            try makeAdapter(
                processRunner: FakeMediaImportProcessRunner(
                    result: .init(
                        exitStatus: 0,
                        standardOutput: Data("1\nasset-id\n".utf8),
                        standardError: Data()
                    )
                ),
                fileSystem: fileSystem
            ).importMedia(args: makeArgs())
        }

        guard case .processFailed = error else {
            return XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(
            error.machineError.code,
            IOSUseErrorCode.mediaImportFailed
        )
        XCTAssertTrue(error.machineError.mutationMayHaveApplied)
        XCTAssertEqual(fileSystem.cleanupCount, 1)
    }

    func testIdentityFailureBeforeAndAfterAutomationTracksMutation()
        throws
    {
        let beforeFileSystem = FakeMediaImportFileSystem()
        beforeFileSystem.verifyErrors[1] = FakeError("before")
        let beforeRunner = FakeMediaImportProcessRunner(
            result: successfulProcessResult()
        )
        let beforeError = try captureAdapterError {
            try makeAdapter(
                processRunner: beforeRunner,
                fileSystem: beforeFileSystem
            ).importMedia(args: makeArgs())
        }
        guard case .identityMismatch(_, false) = beforeError else {
            return XCTFail("unexpected error: \(beforeError)")
        }
        XCTAssertTrue(beforeRunner.invocations.isEmpty)
        XCTAssertEqual(beforeFileSystem.cleanupCount, 1)

        let afterFileSystem = FakeMediaImportFileSystem()
        afterFileSystem.verifyErrors[2] = FakeError("after")
        let afterRunner = FakeMediaImportProcessRunner(
            result: successfulProcessResult()
        )
        let afterError = try captureAdapterError {
            try makeAdapter(
                processRunner: afterRunner,
                fileSystem: afterFileSystem
            ).importMedia(args: makeArgs())
        }
        guard case .identityMismatch(_, true) = afterError else {
            return XCTFail("unexpected error: \(afterError)")
        }
        XCTAssertEqual(afterRunner.invocations.count, 1)
        XCTAssertTrue(
            afterError.machineError.mutationMayHaveApplied
        )
        XCTAssertEqual(afterFileSystem.cleanupCount, 1)
    }

    func testCleanupFailureIsDistinctAndPreservesMutationEvidence()
        throws
    {
        let successFileSystem = FakeMediaImportFileSystem()
        successFileSystem.cleanupError = FakeError("unlink failed")
        let successError = try captureAdapterError {
            try makeAdapter(
                processRunner: FakeMediaImportProcessRunner(
                    result: successfulProcessResult()
                ),
                fileSystem: successFileSystem
            ).importMedia(args: makeArgs())
        }
        guard case .cleanupFailed(_, nil, true) = successError else {
            return XCTFail("unexpected error: \(successError)")
        }
        XCTAssertEqual(
            successError.machineError.code,
            "mac_media_import_cleanup_failed"
        )
        XCTAssertTrue(
            successError.machineError.mutationMayHaveApplied
        )

        let deniedFileSystem = FakeMediaImportFileSystem()
        deniedFileSystem.cleanupError = FakeError("unlink failed")
        let deniedError = try captureAdapterError {
            try makeAdapter(
                processRunner: FakeMediaImportProcessRunner(
                    result: .init(
                        exitStatus: 1,
                        standardOutput: Data(),
                        standardError: Data(
                            "Not authorized. (-1743)".utf8
                        )
                    )
                ),
                fileSystem: deniedFileSystem
            ).importMedia(args: makeArgs())
        }
        guard case .cleanupFailed(_, let original?, false) =
                deniedError else {
            return XCTFail("unexpected error: \(deniedError)")
        }
        XCTAssertTrue(original.contains("permission was denied"))
        XCTAssertFalse(
            deniedError.machineError.mutationMayHaveApplied
        )
    }

    func testDefaultFileSystemUsesOwnerOnlyObjectsAndRemovesThem()
        throws
    {
        #if canImport(Darwin)
        let fixture = try RealFileSystemFixture()
        defer { fixture.remove() }
        let fileSystem = PlayCoverMediaImportPOSIXFileSystem()
        let staged = try fileSystem.stage(
            data: Data([1, 2, 3, 4]),
            originalFilename: "../../fixture.HEIC",
            inRunDirectory: fixture.paths.playcoverRun
        )

        var directoryStatus = stat()
        var fileStatus = stat()
        XCTAssertEqual(
            Darwin.lstat(
                URL(fileURLWithPath: staged.path)
                    .deletingLastPathComponent().path,
                &directoryStatus
            ),
            0
        )
        XCTAssertEqual(Darwin.lstat(staged.path, &fileStatus), 0)
        XCTAssertEqual(directoryStatus.st_mode & 0o7777, 0o700)
        XCTAssertEqual(fileStatus.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(fileStatus.st_mode & 0o7777, 0o600)
        XCTAssertEqual(
            URL(fileURLWithPath: staged.path).lastPathComponent,
            "payload.HEIC"
        )

        try fileSystem.verifyIdentity(
            of: staged,
            inRunDirectory: fixture.paths.playcoverRun
        )
        try fileSystem.cleanup(
            staged,
            inRunDirectory: fixture.paths.playcoverRun
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staged.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: staged.path)
                    .deletingLastPathComponent().path
            )
        )
        #endif
    }

    func testDefaultFileSystemRejectsSymlinkReplacementWithoutFollowing()
        throws
    {
        #if canImport(Darwin)
        let fixture = try RealFileSystemFixture()
        defer { fixture.remove() }
        let fileSystem = PlayCoverMediaImportPOSIXFileSystem()
        let staged = try fileSystem.stage(
            data: Data([1, 2, 3, 4]),
            originalFilename: "fixture.heic",
            inRunDirectory: fixture.paths.playcoverRun
        )
        let outside = fixture.root.appendingPathComponent("outside")
        try Data("preserve".utf8).write(to: outside)
        XCTAssertEqual(Darwin.unlink(staged.path), 0)
        XCTAssertEqual(
            Darwin.symlink(outside.path, staged.path),
            0
        )

        XCTAssertThrowsError(
            try fileSystem.verifyIdentity(
                of: staged,
                inRunDirectory: fixture.paths.playcoverRun
            )
        )
        XCTAssertEqual(
            try String(contentsOf: outside, encoding: .utf8),
            "preserve"
        )
        XCTAssertEqual(Darwin.unlink(staged.path), 0)
        XCTAssertEqual(
            Darwin.rmdir(
                URL(fileURLWithPath: staged.path)
                    .deletingLastPathComponent().path
            ),
            0
        )
        #endif
    }

    func testDefaultCleanupRemovesExactFileAfterModeIdentityFailure()
        throws
    {
        #if canImport(Darwin)
        let fixture = try RealFileSystemFixture()
        defer { fixture.remove() }
        let fileSystem = PlayCoverMediaImportPOSIXFileSystem()
        let staged = try fileSystem.stage(
            data: Data([1, 2, 3, 4]),
            originalFilename: "fixture.heic",
            inRunDirectory: fixture.paths.playcoverRun
        )
        XCTAssertEqual(Darwin.chmod(staged.path, 0o640), 0)

        XCTAssertThrowsError(
            try fileSystem.verifyIdentity(
                of: staged,
                inRunDirectory: fixture.paths.playcoverRun
            )
        )
        try fileSystem.cleanup(
            staged,
            inRunDirectory: fixture.paths.playcoverRun
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.paths.playcoverRun
            ),
            []
        )
        #endif
    }

    func testRealStagingLeavesNoMaterialAfterProcessFailure() throws {
        #if canImport(Darwin)
        let fixture = try RealFileSystemFixture()
        defer { fixture.remove() }
        let error = try captureAdapterError {
            try PlayCoverMediaImportAdapter(
                paths: fixture.paths,
                processRunner: FakeMediaImportProcessRunner(
                    result: .init(
                        exitStatus: 1,
                        standardOutput: Data(),
                        standardError: Data(
                            "Not authorized. (-1743)".utf8
                        )
                    )
                ),
                fileSystem: PlayCoverMediaImportPOSIXFileSystem()
            ).importMedia(args: makeArgs())
        }
        guard case .permissionDenied = error else {
            return XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.paths.playcoverRun
            ),
            []
        )
        #endif
    }

    private func makeAdapter(
        processRunner: any PlayCoverMediaImportProcessRunning,
        fileSystem: any PlayCoverMediaImportFileSystem,
        timeoutSeconds: TimeInterval = 10
    ) -> PlayCoverMediaImportAdapter {
        PlayCoverMediaImportAdapter(
            paths: resolvePlayCoverTestPaths(
                environment: ["IOS_USE_HOME": "/state/ios-use"]
            ),
            processRunner: processRunner,
            fileSystem: fileSystem,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func makeArgs() -> ForyMediaImportArgs {
        ForyMediaImportArgs(
            kind: "photo",
            originalFilename: "fixture.heic",
            uniformTypeIdentifier: "public.heic",
            byteCount: 4,
            data: Data([1, 2, 3, 4])
        )
    }

    private func successfulProcessResult()
        -> PlayCoverMediaImportProcessResult {
        .init(
            exitStatus: 0,
            standardOutput: Data(
                "IOS_USE_MEDIA_IMPORT_RESULT\n1\nasset-id\n".utf8
            ),
            standardError: Data()
        )
    }

    private func captureAdapterError(
        _ body: () throws -> ForyMediaImportPayload
    ) throws -> PlayCoverMediaImportAdapterError {
        do {
            _ = try body()
            throw FakeError("expected adapter error")
        } catch let error as PlayCoverMediaImportAdapterError {
            return error
        }
    }
}

private final class FakeMediaImportProcessRunner:
    PlayCoverMediaImportProcessRunning {
    struct Invocation {
        let executablePath: String
        let arguments: [String]
        let timeoutSeconds: TimeInterval
    }

    private let result: PlayCoverMediaImportProcessResult?
    private let error: Error?
    private(set) var invocations: [Invocation] = []

    init(
        result: PlayCoverMediaImportProcessResult? = nil,
        error: Error? = nil
    ) {
        self.result = result
        self.error = error
    }

    func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) throws -> PlayCoverMediaImportProcessResult {
        invocations.append(
            .init(
                executablePath: executablePath,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds
            )
        )
        if let error {
            throw error
        }
        return try XCTUnwrap(result)
    }
}

private final class FakeMediaImportFileSystem:
    PlayCoverMediaImportFileSystem {
    let staged = PlayCoverMediaImportStagedFile(
        path: "/state/ios-use/mac/run/media-import-test/payload.heic",
        directoryName: "media-import-test",
        filename: "payload.heic",
        directoryDevice: 1,
        directoryInode: 2,
        fileDevice: 1,
        fileInode: 3
    )
    var verifyErrors: [Int: Error] = [:]
    var cleanupError: Error?
    private(set) var stageCount = 0
    private(set) var verifyCount = 0
    private(set) var cleanupCount = 0
    private(set) var hasStagedMaterial = false

    func stage(
        data: Data,
        originalFilename: String,
        inRunDirectory runDirectory: String
    ) throws -> PlayCoverMediaImportStagedFile {
        stageCount += 1
        hasStagedMaterial = true
        return staged
    }

    func verifyIdentity(
        of stagedFile: PlayCoverMediaImportStagedFile,
        inRunDirectory runDirectory: String
    ) throws {
        verifyCount += 1
        if let error = verifyErrors[verifyCount] {
            throw error
        }
    }

    func cleanup(
        _ stagedFile: PlayCoverMediaImportStagedFile,
        inRunDirectory runDirectory: String
    ) throws {
        cleanupCount += 1
        if let cleanupError {
            throw cleanupError
        }
        hasStagedMaterial = false
    }
}

private struct FakeError:
    Error, CustomStringConvertible {
    let detail: String

    init(_ detail: String) {
        self.detail = detail
    }

    var description: String {
        detail
    }
}

#if canImport(Darwin)
private struct RealFileSystemFixture {
    let root: URL
    let paths: IOSUsePaths

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-use-media-import-\(UUID().uuidString)",
                isDirectory: true
            )
        paths = resolvePlayCoverTestPaths(
            environment: ["IOS_USE_HOME": root.path]
        )
        try FileManager.default.createDirectory(
            atPath: paths.playcoverRun,
            withIntermediateDirectories: true
        )
        guard Darwin.chmod(paths.playcoverRun, 0o700) == 0 else {
            throw FakeError("cannot chmod fixture run directory")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
