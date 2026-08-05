import Foundation
import XCTest
@testable import IOSUseCLI

final class PlayCoverRulesResourceTests: XCTestCase {
    override func tearDown() {
        PlayCoverRulesService.rulesPathOverrideForTesting = nil
        super.tearDown()
    }

    func testCandidatesContainOnlySourceAndInstalledResources() {
        let paths = PlayCoverRulesService.rulesCandidates(
            executablePath: "/opt/ios-use/bin/ios-use",
            currentDirectory: "/workspace/ios-use"
        ).map(\.path)

        XCTAssertEqual(paths, [
            "/opt/ios-use/bin/ThirdParty/PlayCover/PlayCover/Rules/default.yaml",
            "/workspace/ios-use/ThirdParty/PlayCover/PlayCover/Rules/default.yaml",
            "/workspace/ThirdParty/PlayCover/PlayCover/Rules/default.yaml",
            "/opt/ios-use/share/ios-use/mac/default-sandbox-rules.yaml",
        ])
    }

    func testPinnedRulesAreAcceptedByteForByte() throws {
        let source = try pinnedRulesURL()
        PlayCoverRulesService.rulesPathOverrideForTesting = { source.path }

        XCTAssertEqual(
            try PlayCoverRulesService.ensureAvailable(),
            try Data(contentsOf: source)
        )
    }

    func testModifiedRulesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let rules = root.appendingPathComponent("default-sandbox-rules.yaml")
        try Data("allow: []\n".utf8).write(to: rules)
        PlayCoverRulesService.rulesPathOverrideForTesting = { rules.path }

        XCTAssertThrowsError(try PlayCoverRulesService.ensureAvailable()) {
            guard case .capabilityUnavailable(let detail) =
                    $0 as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertTrue(detail.contains("digest"), detail)
        }
    }

    private func pinnedRulesURL() throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            root.deleteLastPathComponent()
        }
        let url = root.appendingPathComponent(
            "ThirdParty/PlayCover/PlayCover/Rules/default.yaml"
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("pinned rules source is unavailable")
        }
        return url
    }
}
