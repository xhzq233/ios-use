import XCTest
import Fory

private final class FakeRawSnapshot: NSObject {
    @objc let label: String?
    @objc let identifier: String?
    @objc let value: String?
    @objc let placeholderValue: String?
    @objc let elementType: NSNumber
    @objc let frame: NSValue
    @objc let visibleFrame: NSValue
    @objc let isVisible: NSNumber
    @objc let isEnabled: NSNumber
    @objc let isSelected: NSNumber
    @objc let hasFocus: NSNumber
    @objc let hasKeyboardFocus: NSNumber
    @objc let children: [Any]
    @objc var parent: Any?

    init(
        label: String? = nil,
        identifier: String? = nil,
        value: String? = nil,
        placeholderValue: String? = nil,
        elementType: XCUIElement.ElementType = .staticText,
        frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 40),
        visibleFrame: CGRect? = nil,
        isVisible: Bool = true,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        hasFocus: Bool = false,
        hasKeyboardFocus: Bool = false,
        children: [FakeRawSnapshot] = []
    ) {
        self.label = label
        self.identifier = identifier
        self.value = value
        self.placeholderValue = placeholderValue
        self.elementType = NSNumber(value: elementType.rawValue)
        self.frame = NSValue(cgRect: frame)
        self.visibleFrame = NSValue(cgRect: visibleFrame ?? frame)
        self.isVisible = NSNumber(value: isVisible)
        self.isEnabled = NSNumber(value: isEnabled)
        self.isSelected = NSNumber(value: isSelected)
        self.hasFocus = NSNumber(value: hasFocus)
        self.hasKeyboardFocus = NSNumber(value: hasKeyboardFocus)
        self.children = children
        super.init()
        for child in children {
            child.parent = self
        }
    }
}

// MARK: - TypesTests

final class TypesTests: XCTestCase {

    private func makeElement(
        label: String? = nil,
        identifier: String? = nil,
        value: String? = nil,
        placeholderValue: String? = nil,
        type: XCUIElement.ElementType = .staticText
    ) -> SnapshotElement {
        let raw = FakeRawSnapshot(
            label: label,
            identifier: identifier,
            value: value,
            placeholderValue: placeholderValue,
            elementType: type
        )
        let snapshot = SafeSnapshot(raw: raw, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))
        return SnapshotElement(
            node: snapshot,
            traits: snapshotTraits(for: snapshot, disabled: false, invisible: !snapshot.isVisible),
            disabled: false,
            invisible: !snapshot.isVisible,
            childCount: 0
        )
    }

    private func makeCleanedSnapshot(_ elements: [SnapshotElement]) -> CleanedSnapshot {
        let root = elements.first!.node
        let searchEntries = elements.map { element in
            let rawTexts = searchableTexts(for: element.node)
            return SearchEntry(
                element: element,
                rawTexts: rawTexts,
                normalizedTexts: normalizedSearchableTexts(from: rawTexts)
            )
        }
        let searchCandidates = searchEntries.flatMap { entry in
            entry.rawTexts.compactMap { text -> SearchCandidate? in
                let normalized = normalizeSearchText(text)
                guard !normalized.isEmpty else { return nil }
                return SearchCandidate(displayText: text, normalizedText: normalized)
            }
        }
        return CleanedSnapshot(
            root: root,
            appFrame: CGRect(x: 0, y: 0, width: 375, height: 812),
            rawRoot: root,
            elements: elements,
            searchEntries: searchEntries,
            searchCandidates: searchCandidates
        )
    }

    private func makeSnapshotElement(_ snapshot: SafeSnapshot) -> SnapshotElement {
        SnapshotElement(
            node: snapshot,
            traits: snapshotTraits(for: snapshot, disabled: false, invisible: !snapshot.isVisible),
            disabled: false,
            invisible: !snapshot.isVisible,
            childCount: 0
        )
    }

    // MARK: - Command enum

    func testCommandRawValues() {
        let cmds: [Command] = [
            .createSession, .deleteSession,
            .activateApp, .terminateApp, .screenshot,
            .dom, .find, .tap, .longPress, .input, .swipe, .waitFor,
        ]
        for cmd in cmds {
            XCTAssertFalse(cmd.rawValue.isEmpty, "\(cmd) should have non-empty rawValue")
        }
        XCTAssertEqual(cmds.count, 12)
    }

    // MARK: - resolveTapPoint

    func testResolveTapPoint_DefaultsToCenter() {
        let point = resolveTapPoint(frame: CGRect(x: 10, y: 20, width: 100, height: 40), offset: nil, ratio: ForyPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(point.x, 60)
        XCTAssertEqual(point.y, 40)
    }

    func testResolveTapPoint_UsesAbsoluteOffset() {
        let point = resolveTapPoint(
            frame: CGRect(x: 10, y: 20, width: 100, height: 40),
            offset: ForyPoint(x: 12, y: 5),
            ratio: ForyPoint(x: 0.5, y: 0.5)
        )
        XCTAssertEqual(point.x, 22)
        XCTAssertEqual(point.y, 25)
    }

    func testResolveTapPoint_UsesRatio() {
        let point = resolveTapPoint(
            frame: CGRect(x: 10, y: 20, width: 100, height: 40),
            offset: nil,
            ratio: ForyPoint(x: 0.8, y: 0.5)
        )
        XCTAssertEqual(point.x, 90)
        XCTAssertEqual(point.y, 40)
    }

    // MARK: - canProceedWithTyping

    func testCanProceedWithTyping_InitialLookupRequiresTargetFocus() {
        XCTAssertFalse(canProceedWithTyping(
            targetHasKeyboardFocus: false,
            keyboardVisible: true,
            phase: .initialLookup
        ))
    }

    func testCanProceedWithTyping_AfterTapAllowsKeyboardVisibleFallback() {
        XCTAssertTrue(canProceedWithTyping(
            targetHasKeyboardFocus: false,
            keyboardVisible: true,
            phase: .afterTapAttempt
        ))
    }

    // MARK: - Double.sanitized

    func testDoubleSanitized_Finite() {
        XCTAssertEqual(Double(73.83333333333333).sanitized, 73.8)
    }

    func testDoubleSanitized_NaN() {
        XCTAssertEqual(Double.nan.sanitized, 0)
    }

    func testDoubleSanitized_Infinity() {
        XCTAssertEqual(Double.infinity.sanitized, 0)
    }

    func testDoubleSanitized_Negative() {
        XCTAssertEqual(Double(-42.6).sanitized, -42.6)
    }

    // MARK: - DriverError

    func testDriverError_Descriptions() {
        XCTAssertEqual(DriverError.noSession.description, "no active session")
        XCTAssertEqual(DriverError.elementNotFound("foo").description, "element not found: foo")
        XCTAssertEqual(DriverError.invalidArgs("bad").description, "invalid arguments: bad")
        XCTAssertEqual(DriverError.appNotFound("com.test").description, "app not found: com.test")
        XCTAssertEqual(DriverError.ambiguous("x").description, "ambiguous: x")
        XCTAssertEqual(DriverError.timeout("x").description, "timeout: x")
        XCTAssertEqual(DriverError.atBoundary("x").description, "at boundary: x")
        XCTAssertEqual(DriverError.serverError("x").description, "server error: x")
    }

    // MARK: - Levenshtein (doc 8)

    func testLevenshtein_Equal() {
        XCTAssertEqual(levenshtein("hello", "hello"), 0)
    }

    func testLevenshtein_Insert() {
        XCTAssertEqual(levenshtein("cat", "cats"), 1)
    }

    func testLevenshtein_Substitute() {
        XCTAssertEqual(levenshtein("cat", "bat"), 1)
    }

    func testLevenshtein_Empty() {
        XCTAssertEqual(levenshtein("", "abc"), 3)
        XCTAssertEqual(levenshtein("abc", ""), 3)
    }

    func testLevenshtein_Unicode_ChineseEqualsOneCharEach() {
        XCTAssertEqual(levenshtein("蓝牙", "蓝牙"), 0)
        XCTAssertEqual(levenshtein("蓝牙", "蓝牙设置"), 2)
    }

    func testFuzzySuggestions_ThresholdApplied() {
        let candidates = [
            SearchCandidate(displayText: "Dark Mode", normalizedText: normalizeSearchText("Dark Mode")),
            SearchCandidate(displayText: "Auto-Lock", normalizedText: normalizeSearchText("Auto-Lock")),
            SearchCandidate(displayText: "Display", normalizedText: normalizeSearchText("Display")),
            SearchCandidate(displayText: "Completely Different", normalizedText: normalizeSearchText("Completely Different")),
        ]
        let suggestions = fuzzySuggestions(forNormalizedQuery: normalizeSearchText("DarkMode"), from: candidates)
        XCTAssertTrue(suggestions.contains("Dark Mode"))
    }

    func testNormalizeSearchText_IgnoresWhitespaceCaseAndPunctuation() {
        XCTAssertEqual(normalizeSearchText(" 编 辑 "), "编辑")
        XCTAssertEqual(normalizeSearchText("FAcetime通话"), "facetime通话")
        XCTAssertEqual(normalizeSearchText("FaceTime 通话"), "facetime通话")
        XCTAssertEqual(normalizeSearchText("Wi-Fi"), "wifi")
    }

    // MARK: - serializeDomFlat (ForyDomElement)

    func testSerializeDomFlat_ReconstructsNestedTreeFromChildCount() {
        let root = makeElement(label: "Root", type: .other)
        let child1 = makeElement(label: "Child 1", type: .button)
        let parent = makeElement(label: "Parent", type: .cell)
        let grandchild = makeElement(label: "Grandchild", type: .staticText)
        let child2 = makeElement(label: "Child 2", type: .button)

        let elements = [
            SnapshotElement(node: root.node, traits: root.traits, disabled: root.disabled, invisible: root.invisible, childCount: 3),
            child1,
            SnapshotElement(node: parent.node, traits: parent.traits, disabled: parent.disabled, invisible: parent.invisible, childCount: 1),
            grandchild,
            child2,
        ]

        let dom = serializeDomFlat(from: elements)

        XCTAssertEqual(dom.count, 5)
        XCTAssertEqual(dom[0].label, "Root")
        XCTAssertEqual(dom[0].childCount, 3)
        XCTAssertEqual(dom[1].label, "Child 1")
        XCTAssertEqual(dom[1].childCount, 0)
        XCTAssertEqual(dom[2].label, "Parent")
        XCTAssertEqual(dom[2].childCount, 1)
        XCTAssertEqual(dom[3].label, "Grandchild")
        XCTAssertEqual(dom[3].childCount, 0)
        XCTAssertEqual(dom[4].label, "Child 2")
        XCTAssertEqual(dom[4].childCount, 0)
    }

    func testSerializeDomFlat_EmptyElementsReturnsEmptyArray() {
        XCTAssertTrue(serializeDomFlat(from: []).isEmpty)
    }

    func testSerializeDomFlat_ChildCountZeroSerializesLeafRect() {
        let leaf = makeElement(label: "Leaf", type: .button)
        let dom = serializeDomFlat(from: [leaf])

        XCTAssertEqual(dom.count, 1)
        XCTAssertEqual(dom[0].label, "Leaf")
        XCTAssertNotNil(dom[0].rect)
        XCTAssertEqual(dom[0].childCount, 0)
    }

    // MARK: - elementTypeName

    func testElementTypeName_OtherReturnsDash() {
        XCTAssertEqual(elementTypeName(.other), "-")
    }

    // MARK: - resolveButtonIndex logic

    func testResolveButtonIndex_EmptyButtons_ReturnsNil() {
        XCTAssertNil(AlertCommands.resolveButtonIndex(buttonCount: 0, requestedIndex: nil))
        XCTAssertNil(AlertCommands.resolveButtonIndex(buttonCount: 0, requestedIndex: 0))
    }

    func testResolveButtonIndex_NoIndex_ReturnsLast() {
        XCTAssertEqual(AlertCommands.resolveButtonIndex(buttonCount: 1, requestedIndex: nil), 0)
        XCTAssertEqual(AlertCommands.resolveButtonIndex(buttonCount: 2, requestedIndex: nil), 1)
        XCTAssertEqual(AlertCommands.resolveButtonIndex(buttonCount: 3, requestedIndex: nil), 2)
    }

    func testResolveButtonIndex_ValidIndex_ReturnsThat() {
        XCTAssertEqual(AlertCommands.resolveButtonIndex(buttonCount: 3, requestedIndex: 0), 0)
        XCTAssertEqual(AlertCommands.resolveButtonIndex(buttonCount: 3, requestedIndex: 1), 1)
        XCTAssertEqual(AlertCommands.resolveButtonIndex(buttonCount: 3, requestedIndex: 2), 2)
    }

    func testResolveButtonIndex_OutOfBounds_FallsBackToLast() {
        XCTAssertEqual(AlertCommands.resolveButtonIndex(buttonCount: 2, requestedIndex: 5), 1)
        XCTAssertEqual(AlertCommands.resolveButtonIndex(buttonCount: 2, requestedIndex: -1), 1)
    }

    // MARK: - rawFindInSnapshot

    func testRawFindInSnapshot_FindsByValueContains() {
        let element = makeElement(
            label: "TabBarItemTitle",
            value: "搜索或输入网站名称",
            type: .textField
        )
        let cs = makeCleanedSnapshot([element])

        switch rawFindInSnapshot("搜索", cs: cs) {
        case .found(let found):
            XCTAssertEqual(found.node.value, "搜索或输入网站名称")
            XCTAssertEqual(displayValue(for: found.node), "搜索或输入网站名称")
        default:
            XCTFail("expected rawFindInSnapshot to find value contains match")
        }
    }

    func testRawFindInSnapshot_FallsBackToFuzzyWhenContainsMisses() {
        let element = makeElement(label: "天气", type: .staticText)
        let cs = makeCleanedSnapshot([element])

        switch rawFindInSnapshot("天琪", cs: cs) {
        case .fuzzy(let suggestions):
            XCTAssertTrue(suggestions.contains("天气"))
        default:
            XCTFail("expected rawFindInSnapshot to fall back to fuzzy suggestions")
        }
    }

    func testRawFindInSnapshot_FindsByNormalizedContains() {
        let element = makeElement(label: "FaceTime 通话", type: .button)
        let cs = makeCleanedSnapshot([element])

        switch rawFindInSnapshot("facetime通话", cs: cs) {
        case .found(let found):
            XCTAssertEqual(found.node.label, "FaceTime 通话")
        default:
            XCTFail("expected rawFindInSnapshot to find normalized contains match")
        }
    }

    // MARK: - Trait filtering

    func testRawFindInSnapshot_TraitFilter_MatchesType() {
        let button = makeElement(label: "开关", type: .switch)
        let text = makeElement(label: "开关文字", type: .staticText)
        let cs = makeCleanedSnapshot([button, text])

        switch rawFindInSnapshot("开关", traits: "switch", cs: cs) {
        case .found(let found):
            XCTAssertEqual(found.node.elementType, XCUIElement.ElementType.switch.rawValue)
        default:
            XCTFail("expected trait filter to match Switch type")
        }
    }

    func testRawFindInSnapshot_MultiTraitAnd_MatchesAll() {
        let elem = makeElement(label: "设置", type: .button)
        let cs = makeCleanedSnapshot([elem])

        switch rawFindInSnapshot("设置", traits: "button,statictext", cs: cs) {
        case .notFound:
            break // expected: Button does not have StaticText trait
        default:
            XCTFail("expected notFound when traits don't all match")
        }
    }

    func testRawFindInSnapshot_PrefersElementWithEffectiveGeometry() {
        let offscreenLabel = FakeRawSnapshot(
            label: "配置代理",
            elementType: .staticText,
            frame: CGRect(x: 0, y: 900, width: 80, height: 20),
            isVisible: true
        )
        let visibleLabel = FakeRawSnapshot(
            label: "配置代理",
            elementType: .staticText,
            frame: CGRect(x: 32, y: 600, width: 80, height: 20),
            isVisible: true
        )
        let visibleCell = FakeRawSnapshot(
            elementType: .cell,
            frame: CGRect(x: 0, y: 580, width: 375, height: 64),
            isVisible: true,
            children: [visibleLabel]
        )
        let table = FakeRawSnapshot(elementType: .table, children: [offscreenLabel, visibleCell])
        let root = SafeSnapshot(raw: table, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))
        let offscreen = makeSnapshotElement(root.children[0])
        let visible = makeSnapshotElement(root.children[1].children[0])
        let cs = makeCleanedSnapshot([offscreen, visible])

        switch rawFindInSnapshot("配置代理", cs: cs) {
        case .found(let found):
            XCTAssertEqual(found.node.frame.origin.y, 600)
        default:
            XCTFail("expected rawFindInSnapshot to prefer the element with effective geometry")
        }
    }

    // MARK: - collectCellSnapshots / collectVisibleCellFrames

    func testCollectCellSnapshots_TopToBottomOrder() {
        let top = FakeRawSnapshot(label: "蓝牙", elementType: .cell, frame: CGRect(x: 0, y: 100, width: 375, height: 44))
        let mid = FakeRawSnapshot(label: "通用", elementType: .cell, frame: CGRect(x: 0, y: 200, width: 375, height: 44))
        let bottom = FakeRawSnapshot(label: "开发者", elementType: .cell, frame: CGRect(x: 0, y: 500, width: 375, height: 44))
        let scrollView = FakeRawSnapshot(elementType: .scrollView, children: [top, mid, bottom])
        let root = SafeSnapshot(raw: scrollView, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))

        let cells = collectCellSnapshots(root)
        XCTAssertEqual(cells.map { $0.label }, ["蓝牙", "通用", "开发者"])
    }

    func testCollectVisibleCellFrames_ReturnsVisibleCellFrames() {
        let c1 = FakeRawSnapshot(label: "A", elementType: .cell, frame: CGRect(x: 0, y: 0, width: 375, height: 44))
        let c2 = FakeRawSnapshot(label: "B", elementType: .cell, frame: CGRect(x: 0, y: 50, width: 375, height: 44))
        let c3 = FakeRawSnapshot(label: "C", elementType: .cell, frame: CGRect(x: 0, y: 100, width: 375, height: 44))
        let scrollView = FakeRawSnapshot(elementType: .scrollView, children: [c1, c2, c3])
        let root = SafeSnapshot(raw: scrollView, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))

        let frames = collectVisibleCellFrames(root)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[0].origin.y, 0)
        XCTAssertEqual(frames[1].origin.y, 50)
        XCTAssertEqual(frames[2].origin.y, 100)
    }

    // MARK: - ForyRect / makeForyRect

    func testMakeForyRect_RoundsToIntegers() {
        let rect = makeForyRect(CGRect(x: 10.7, y: 20.3, width: 100.8, height: 40.1))
        XCTAssertEqual(rect.x, 11)
        XCTAssertEqual(rect.y, 20)
        XCTAssertEqual(rect.w, 101)
        XCTAssertEqual(rect.h, 40)
    }

    // MARK: - makeForyFindMatch

    func testMakeForyFindMatch_BasicFields() {
        let elem = makeElement(label: "Test", value: "val", type: .button)
        let match = makeForyFindMatch(elem, includeAncestors: false)
        XCTAssertEqual(match.elemType, Int32(XCUIElement.ElementType.button.rawValue))
        XCTAssertEqual(match.label, "Test")
        XCTAssertEqual(match.value, "val")
        XCTAssertFalse(match.traits.isEmpty)
    }
}
