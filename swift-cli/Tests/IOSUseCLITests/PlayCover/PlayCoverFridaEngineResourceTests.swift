import Foundation
import XCTest
@testable import IOSUseCLI

final class PlayCoverFridaEngineResourceTests: XCTestCase {
    override func tearDown() {
        PlayCoverFridaEngineService.frameworkPathOverrideForTesting = nil
        super.tearDown()
    }

    func testCandidatesAreOnlyWorkspaceAndInstalledResources() {
        let paths = PlayCoverFridaEngineService.frameworkCandidates(
            executablePath: "/opt/ios-use/bin/ios-use"
        ).map(\.path)

        XCTAssertEqual(paths, [
            "/opt/ios-use/bin/.ios-use/playcover/IOSUseFridaEngine.framework",
            "/opt/ios-use/share/ios-use/mac/IOSUseFridaEngine.framework",
        ])
    }

    func testMissingInstalledResourceDoesNotCreateAccountCache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logicalHome = root.appendingPathComponent(
            "logical-home",
            isDirectory: true
        )
        let accountHome = root.appendingPathComponent(
            "account-home",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: logicalHome,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": logicalHome.path],
            accountHomeDirectoryOverrideForTesting: accountHome.path
        )
        PlayCoverFridaEngineService.frameworkPathOverrideForTesting = {
            root.appendingPathComponent(
                "missing/IOSUseFridaEngine.framework",
                isDirectory: true
            ).path
        }

        XCTAssertThrowsError(
            try PlayCoverFridaEngineService.ensureAvailable()
        ) { error in
            guard case .capabilityUnavailable(let detail) =
                    error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("frida-engine"), detail)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.accountCacheRoot)
        )
    }

    func testMetadataBindsThePinnedSourceAndWrapper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let framework = root.appendingPathComponent(
            PlayCoverFridaEngineService.frameworkName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: framework,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let info = framework.appendingPathComponent("Info.plist")
        let metadata: [String: Any] = [
            "CFBundleShortVersionString":
                PlayCoverFridaEngineService.descriptorVersion,
            "IOSUseFridaEngineABI":
                PlayCoverFridaEngineService.descriptorEngineABI,
            "IOSUseFridaSourceCommit":
                PlayCoverFridaEngineService.descriptorSourceCommit,
            "IOSUseFridaAgentSHA256":
                PlayCoverFridaEngineService.descriptorAgentSHA256,
            "IOSUseFridaSourceClosureSHA256":
                PlayCoverFridaEngineService.descriptorSourceClosureSHA256,
        ]
        try PropertyListSerialization.data(
            fromPropertyList: metadata,
            format: .xml,
            options: 0
        ).write(to: info)

        XCTAssertNoThrow(
            try PlayCoverFridaEngineService.validateFrameworkMetadata(
                framework
            )
        )

        var mismatched = metadata
        mismatched["IOSUseFridaSourceCommit"] = String(
            repeating: "0",
            count: 40
        )
        try PropertyListSerialization.data(
            fromPropertyList: mismatched,
            format: .xml,
            options: 0
        ).write(to: info)
        XCTAssertThrowsError(
            try PlayCoverFridaEngineService.validateFrameworkMetadata(
                framework
            )
        )
    }

    func testActualEngineDigestDefinesTheFridaPreparationIdentity() {
        let first = PlayCoverService.fridaPrepareRevision(
            engineSHA256: String(repeating: "a", count: 64)
        )
        let second = PlayCoverService.fridaPrepareRevision(
            engineSHA256: String(repeating: "b", count: 64)
        )

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(
            first.contains(
                PlayCoverFridaEngineService
                    .descriptorSourceClosureSHA256
            )
        )
    }
}
