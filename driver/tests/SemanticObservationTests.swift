import XCTest

final class SemanticObservationTests: XCTestCase {
    private func node(_ label: String, _ children: Int = 0) -> SemanticDOM.Element {
        SemanticDOM.Element(label: label, traits: [children > 0 ? "Cell" : "Button"], children: children, rect: [0, 0, 100, 30])
    }

    func testExactReconstructionAcrossInsertionsDuplicatesMovesAndStateChanges() throws {
        let store = SemanticDOM.Store()
        let initial = [node("Root", 40)] + (0..<40).map { node("Item \($0)") }
        var previous = store.observe(app: "Fixture", size: [390, 844], elements: initial, diff: false, since: "")
        var reconstructed = previous.lines
        var cases: [[SemanticDOM.Element]] = []
        var repeated = initial
        repeated[5].label = "Duplicate"; repeated[7].label = "Duplicate"
        cases.append(repeated)
        var inserted = repeated
        inserted[0].children += 1; inserted.insert(node("New"), at: 3)
        cases.append(inserted)
        var moved = inserted
        moved.swapAt(3, 12); moved[6].children = 1; moved[0].children -= 1
        cases.append(moved)
        var changed = moved
        changed[5].traits += ["disabled", "selected", "focused"]
        changed[5].value = "42"; changed[5].hint = "A hint"; changed[5].accessibilityLabel = "Native label"
        changed[9].label = "Repeated\ntext=5 [Button]:"
        cases.append(changed)
        cases += [[], initial]
        for elements in cases {
            let output = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: true, since: previous.revision)
            let wire = try JSONDecoder().decode(SemanticDOM.Observation.self, from: JSONEncoder().encode(output))
            reconstructed = try XCTUnwrap(wire.applying(to: reconstructed))
            XCTAssertEqual(reconstructed, SemanticDOM.lines(elements))
            previous = output
        }
    }

    func testCoalescesUniqueReplacementAndSharesParentContext() throws {
        let store = SemanticDOM.Store()
        var elements = [node("Root", 80)] + (0..<80).map { node("Item \($0)") }
        let before = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: false, since: "")
        elements[3].value = "new value"
        elements[4].traits += ["disabled"]
        elements.removeSubrange(20..<26)
        elements[0].children -= 6
        let after = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: true, since: before.revision)
        XCTAssertEqual(after.changes.count, 1)
        XCTAssertEqual(after.updated.count, 2)
        XCTAssertEqual(after.removed.count, 6)
        XCTAssertEqual(after.added.count, 0)
        let decoded = try JSONDecoder().decode(SemanticDOM.Observation.self, from: JSONEncoder().encode(after))
        XCTAssertEqual(decoded.applying(to: before.lines), SemanticDOM.lines(elements))
    }

    func testDuplicateSelectorsDoNotBecomeUpdates() throws {
        let store = SemanticDOM.Store()
        var elements = (0..<60).map { node("Item \($0)") }
        elements[2].label = "Duplicate"; elements[5].label = "Duplicate"
        let before = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: false, since: "")
        elements[2].value = "changed"
        let after = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: true, since: before.revision)
        XCTAssertTrue(after.updated.isEmpty)
        XCTAssertEqual(after.removed.count, 1)
        XCTAssertEqual(after.added.count, 1)
        XCTAssertEqual(after.applying(to: before.lines), SemanticDOM.lines(elements))
    }

    func testRepeatedStructuralEditsReconstructWithoutLosingRows() throws {
        let store = SemanticDOM.Store()
        var elements = [node("Root", 80)] + (0..<80).map { node("Item \($0)") }
        var previous = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: false, since: "")
        var reconstructed = previous.lines
        var deltaCount = 0
        for step in 0..<120 {
            let index = 1 + (step * 17) % (elements.count - 1)
            switch step % 4 {
            case 0: elements[index].value = "State \(step)"
            case 1: elements.swapAt(index, elements.count - 1)
            case 2: elements.insert(node("New \(step)"), at: index)
            default: elements.remove(at: index)
            }
            elements[0].children = elements.count - 1
            let current = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: true, since: previous.revision)
            if current.mode == "diff" { deltaCount += 1 }
            let wire = try JSONDecoder().decode(SemanticDOM.Observation.self, from: JSONEncoder().encode(current))
            reconstructed = try XCTUnwrap(wire.applying(to: reconstructed))
            XCTAssertEqual(reconstructed, SemanticDOM.lines(elements))
            previous = current
        }
        XCTAssertGreaterThan(deltaCount, 100)
    }

    func testResizedWindowSignalsGeometryEvenWhenSemanticTextIsIdentical() {
        let store = SemanticDOM.Store()
        let elements = [node("Rotate")]
        let before = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: false, since: "")
        let after = store.observe(app: "Fixture", size: [844, 390], elements: elements, diff: true, since: before.revision)
        XCTAssertTrue(after.layoutChanged)
        XCTAssertEqual(after.lines, before.lines)
        XCTAssertTrue(after.added.isEmpty && after.removed.isEmpty)
    }

    func testGeometryIsSeparateAndStaleContinuationOrChangedAppReturnsFull() throws {
        let store = SemanticDOM.Store()
        var elements = (0..<30).map { node("Item \($0)") }
        let first = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: false, since: "")
        elements[5].rect = [0, 50, 100, 30]
        let moved = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: true, since: first.revision)
        XCTAssertTrue(moved.layoutChanged)
        XCTAssertTrue(moved.added.isEmpty && moved.removed.isEmpty && moved.lines.isEmpty)
        for (app, size, since) in [("Fixture", [390.0, 844.0], first.revision),
                                   ("Other", [390.0, 844.0], moved.revision),
                                   ("Fixture", [844.0, 390.0], moved.revision)] {
            let output = store.observe(app: app, size: size, elements: elements, diff: true, since: since)
            XCTAssertEqual(output.lines.count, elements.count)
        }
        store.reset()
        let restarted = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: true, since: moved.revision)
        XCTAssertEqual(restarted.lines.count, elements.count)
    }
}
