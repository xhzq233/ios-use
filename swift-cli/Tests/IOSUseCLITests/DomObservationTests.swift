import Foundation
import XCTest
import IOSUseProtocol
@testable import IOSUseCLI

final class DomObservationTests: XCTestCase {
    private func payload(_ labels: [String], app: String = "Fixture", width: Double = 390) -> ForyDomPayload {
        ForyDomPayload(app: app, windowSize: ForyPoint(x: width, y: 844), elements:
            [ForyDomElement(traits: ["Application"], childCount: Int32(labels.count), label: app)]
            + labels.map { ForyDomElement(traits: ["Button"], label: $0, rect: ForyRect(x: 0, y: 40, w: 100, h: 20)) })
    }

    private func withPaths(_ body: (IOSUsePaths) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root.path]))
    }

    private func fields(_ output: DomObservation.Output) throws -> [String: MachineValue] {
        guard case .object(let value) = output.value else { throw NSError(domain: "test", code: 1) }
        return value
    }

    func testPositionDeltaReconstructsInsertedRemovedAndReorderedRepeatedLabels() throws {
        let initial = DomObservation.Snapshot(payload: payload(["A", "Same", "Same", "B"]), session: "one")
        for labels in [["New", "A", "Same", "Same", "B"], ["B", "Same", "A"], [], ["Same", "B", "Same", "A"]] {
            let current = DomObservation.Snapshot(payload: payload(labels), session: "one")
            let delta = DomObservation.Delta(before: initial, after: current)
            var reconstructed = Dictionary(uniqueKeysWithValues: initial.nodes.map { ($0.path, $0.element) })
            for node in delta.removed { reconstructed.removeValue(forKey: node.path) }
            for node in delta.added { reconstructed[node.path] = node.element }
            for change in delta.changed { reconstructed[change.after.path] = change.after.element }
            XCTAssertEqual(reconstructed, Dictionary(uniqueKeysWithValues: current.nodes.map { ($0.path, $0.element) }))
            XCTAssertFalse(delta.unchanged)
        }
    }

    func testPersistedObservationIgnoresGenerationButDetectsStateAndContextChanges() throws {
        try withPaths { paths in
            let original = payload((0..<20).map { "Button \($0)" })
            _ = try DomObservation(paths: paths).observe(original, diff: false)
            var regenerated = original
            regenerated.snapshotGeneration = 500
            regenerated.elements[1].snapshotGeneration = 500
            regenerated.elements[1].nodeID = "new-capture-id"
            let same = try fields(DomObservation(paths: paths).observe(regenerated, diff: true))
            XCTAssertEqual(same["unchanged"], .boolean(true))
            regenerated.elements[1].state.selected = true
            let changed = try fields(DomObservation(paths: paths).observe(regenerated, diff: true))
            guard case .array(let changes) = changed["changed"] else { return XCTFail("Expected state delta") }
            XCTAssertEqual(changes.count, 1)
            let resized = try fields(DomObservation(paths: paths).observe(payload(["Other"], width: 844), diff: true))
            XCTAssertNotNil(resized["nodes"])
            let appChanged = try fields(DomObservation(paths: paths).observe(payload(["Other"], app: "Another", width: 844), diff: true))
            XCTAssertNotNil(appChanged["nodes"])
        }
    }

    func testRestartDuringCaptureCannotSaveOldDOMAsNewSession() throws {
        try withPaths { paths in
            try DriverSessionStore.write(info: .init(udid: "fixture", deviceName: "Fixture", deviceVersion: "", deviceType: "real", sessionIdentifier: "old"), paths: paths)
            _ = try DomObservation(paths: paths).observe(payload(["Old"]), diff: false)
            let pending = try DomObservation(paths: paths)
            try DriverSessionStore.write(info: .init(udid: "fixture", deviceName: "Fixture", deviceVersion: "", deviceType: "real", sessionIdentifier: "new"), paths: paths)
            XCTAssertNotNil(try fields(pending.observe(payload(["Old"]), diff: true))["nodes"])
            XCTAssertNotNil(try fields(DomObservation(paths: paths).observe(payload(["New"]), diff: true))["nodes"])
            XCTAssertEqual(try fields(DomObservation(paths: paths).observe(payload(["New"]), diff: true))["unchanged"], .boolean(true))
        }
    }
}
