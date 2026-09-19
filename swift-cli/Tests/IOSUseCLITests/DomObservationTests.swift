import Foundation
import XCTest
import IOSUseProtocol
@testable import IOSUseCLI

final class DomObservationTests: XCTestCase {
    func testSeparateCLIInvocationsContinueDriverObservationAndDetailedReadResets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root.path])
        let store = SemanticDOM.Store()
        let elements = (0..<30).map { SemanticDOM.Element(label: "Item \($0)", traits: ["Button"], children: 0) }
        let observer = try DomObservation(paths: paths)
        let initial = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: false, since: "")
        let payload = ForyDomPayload(app: "Fixture", observation: String(decoding: try JSONEncoder().encode(initial), as: UTF8.self))
        _ = try observer.observe(payload, diff: false)
        let next = try DomObservation(paths: paths)
        let args = next.arguments(fresh: true, waitQuiescence: false, diff: true)
        let codec = ForyRegistry.create()
        let received = try codec.deserialize(codec.serialize(args), as: ForyDomArgs.self)
        XCTAssertTrue(received.semantic)
        XCTAssertTrue(received.diff)
        let delta = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: received.diff, since: received.since)
        XCTAssertTrue(delta.lines.isEmpty)
        XCTAssertEqual(delta.applying(to: initial.lines), initial.lines)
        let detailed = try DomObservation(paths: paths, detailed: true)
        XCTAssertFalse(detailed.arguments(fresh: true, waitQuiescence: false, diff: false).semantic)
        _ = try detailed.observe(ForyDomPayload(), diff: false)
        let reset = try DomObservation(paths: paths).arguments(fresh: true, waitQuiescence: false, diff: true)
        let full = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: true, since: reset.since)
        XCTAssertFalse(full.lines.isEmpty)
        XCTAssertTrue(full.added.isEmpty)
        XCTAssertTrue(full.removed.isEmpty)
    }
}
