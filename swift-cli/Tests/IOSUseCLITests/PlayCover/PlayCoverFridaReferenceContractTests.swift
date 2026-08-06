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
                "functions:ExampleApp!*Feature*"
            )
        )
        XCTAssertTrue(
            reference.contains(
                "functions:<module-glob>!<symbol-glob>"
            )
        )
        XCTAssertTrue(reference.contains("exports:<module-glob>!<name-glob>"))
        XCTAssertTrue(reference.contains("-[<class-glob> <selector-glob>]"))
        XCTAssertTrue(reference.contains("Append `/i` to a whole query"))
        XCTAssertTrue(reference.contains("reuse one resolver"))
        XCTAssertTrue(reference.contains("Own the restore path"))
        XCTAssertFalse(reference.contains("functions:*recordProbe*"))
        XCTAssertTrue(reference.contains("state.handle?.detach();"))
        XCTAssertTrue(reference.contains("Module.getExportByName(null, 'open')"))
        XCTAssertTrue(reference.contains("});\n({ attached: true"))
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
