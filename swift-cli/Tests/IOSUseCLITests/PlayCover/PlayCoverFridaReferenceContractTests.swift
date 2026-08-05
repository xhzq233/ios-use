import Foundation
import XCTest

final class PlayCoverFridaReferenceContractTests: XCTestCase {
    func testReferenceUsesRunnableSwiftResolverAndSafeProbeWorkflow() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repositoryRoot.deleteLastPathComponent()
        }
        let reference = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "ios-use-skill/references/frida-debug.md"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            reference.contains(
                "functions:*IOSUsePlayFixture*!*FixtureHostingController.overrides*"
            )
        )
        XCTAssertFalse(reference.contains("functions:*recordProbe*"))
        XCTAssertTrue(reference.contains("state.handle?.detach();"))
        XCTAssertTrue(reference.contains("Module.getExportByName(null, 'open')"))
        XCTAssertTrue(reference.contains("});\n({ attached: true"))
        XCTAssertTrue(reference.contains("handle.detach();"))
        XCTAssertTrue(
            reference.contains(
                "functions:<module>!<symbol>"
            )
        )
        XCTAssertTrue(
            reference.contains(
                "ios-use debug --stream - < probe.js"
            )
        )
        XCTAssertTrue(
            reference.contains(
                "run `ios-use debug --reset` before attaching again"
            )
        )
        XCTAssertTrue(
            reference.contains(
                "one-module enumeration can exceed the 10-second"
            )
        )
    }
}
