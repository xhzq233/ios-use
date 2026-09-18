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

    func testMatchedDeltaReconstructsInsertedRemovedAndReorderedRepeatedLabels() throws {
        let initial = DomObservation.Snapshot(payload: payload(["A", "Same", "Same", "B"]), session: "one")
        for labels in [["New", "A", "Same", "Same", "B"], ["B", "Same", "A"], [], ["Same", "B", "Same", "A"]] {
            let current = DomObservation.Snapshot(payload: payload(labels), session: "one", previous: initial)
            let delta = DomObservation.Delta(before: initial, after: current)
            var reconstructed = Dictionary(uniqueKeysWithValues: initial.nodes.map { ($0.id, $0.machineValue) })
            for node in delta.removed { reconstructed.removeValue(forKey: node.id) }
            for node in delta.added { reconstructed[node.id] = node.machineValue }
            for change in delta.changed { reconstructed[change.after.id] = change.after.machineValue }
            XCTAssertEqual(reconstructed, Dictionary(uniqueKeysWithValues: current.nodes.map { ($0.id, $0.machineValue) }))
            XCTAssertFalse(delta.unchanged)
        }
    }

    func testInsertionKeepsOtherIdentitiesAndGeometryUpdatesRemainObservable() throws {
        let original = payload(["A", "B", "C"])
        let before = DomObservation.Snapshot(payload: original, session: "one")
        var inserted = payload(["New", "A", "B", "C"])
        for index in 1..<inserted.elements.count {
            inserted.elements[index].rect = ForyRect(x: 0, y: Int32(index * 40), w: 100, h: 20)
        }
        let after = DomObservation.Snapshot(payload: inserted, session: "one", previous: before)
        let delta = DomObservation.Delta(before: before, after: after)
        XCTAssertEqual(delta.added.count, 1)
        XCTAssertEqual(delta.removed.count, 0)
        XCTAssertEqual(Array(before.nodes.dropFirst().map(\.id)), Array(after.nodes.dropFirst(2).map(\.id)))
        XCTAssertEqual(delta.changed.count, 4) // parent childCount + moved A/B/C
        var reconstructed = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.id, $0.machineValue) })
        for node in delta.added { reconstructed[node.id] = node.machineValue }
        for change in delta.changed { reconstructed[change.after.id] = change.after.machineValue }
        XCTAssertEqual(reconstructed, Dictionary(uniqueKeysWithValues: after.nodes.map { ($0.id, $0.machineValue) }))
    }

    func testMatchedIdentifierKeepsLabelValueStateAndReparentingChanges() throws {
        var original = payload(["Old", "Other"])
        original.elements[1].identifier = "control"
        let before = DomObservation.Snapshot(payload: original, session: "one")
        var updated = original
        updated.elements[1].label = "New"
        updated.elements[1].value = "42"
        updated.elements[1].hint = "Updated hint"
        updated.elements[1].state.enabled = false
        updated.elements[1].state.visible = false
        updated.elements[1].state.selected = true
        updated.elements[1].state.focused = true
        updated.elements[1].rect = nil
        let after = DomObservation.Snapshot(payload: updated, session: "one", previous: before)
        let delta = DomObservation.Delta(before: before, after: after)
        XCTAssertEqual(delta.changed.count, 1)
        XCTAssertEqual(delta.changed.first?.after.id, before.nodes[1].id)
        XCTAssertEqual(delta.changed.first?.after.element, after.nodes[1].element)

        // The same label under a different parent must not silently keep the old hierarchy.
        updated.elements[0].childCount = 1
        updated.elements[1].childCount = 1
        let moved = DomObservation.Snapshot(payload: updated, session: "one", previous: after)
        let reparented = DomObservation.Delta(before: after, after: moved)
        XCTAssertEqual(reparented.removed.count, 0)
        XCTAssertEqual(reparented.added.count, 0)
        XCTAssertEqual(reparented.changed.first { $0.after.id == after.nodes[2].id }?.after.parent, moved.nodes[1].id)
    }

    func testUniqueLabelsSurviveReplacedContainerWithoutLosingHierarchy() throws {
        var original = payload(["Container1", "A", "B"])
        original.elements[0].childCount = 1
        original.elements[1].childCount = 2
        let before = DomObservation.Snapshot(payload: original, session: "one")
        var updated = original
        updated.elements[1].label = "Container2"
        let after = DomObservation.Snapshot(payload: updated, session: "one", previous: before)
        let delta = DomObservation.Delta(before: before, after: after)
        XCTAssertEqual(delta.added.count, 1)
        XCTAssertEqual(delta.removed.count, 1)
        XCTAssertEqual(after.nodes[2].id, before.nodes[2].id)
        XCTAssertEqual(after.nodes[3].id, before.nodes[3].id)
        XCTAssertEqual(delta.changed.count, 2)
        XCTAssertTrue(delta.changed.allSatisfy { $0.after.parent == after.nodes[1].id })
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

    func testObservationIDsSurviveCLIProcessesAndDoNotReuseRemovedIDs() throws {
        try withPaths { paths in
            let labels = (0..<20).map { "Button \($0)" }
            let full = try fields(DomObservation(paths: paths).observe(payload(labels + ["C"]), diff: false))
            guard case .array(let elements) = full["elements"], case .object(let last) = elements.last,
                  case .integer(let removedID) = last["observationID"] else { return XCTFail("Missing observation ID") }
            _ = try DomObservation(paths: paths).observe(payload(labels), diff: true)
            let inserted = try fields(DomObservation(paths: paths).observe(payload(labels + ["New"]), diff: true))
            guard case .array(let added) = inserted["added"], case .object(let node) = added.first,
                  case .integer(let id) = node["id"] else { return XCTFail("Missing inserted node") }
            XCTAssertGreaterThan(id, removedID)
            XCTAssertEqual(try fields(DomObservation(paths: paths).observe(payload(labels + ["New"]), diff: true))["unchanged"], .boolean(true))
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
