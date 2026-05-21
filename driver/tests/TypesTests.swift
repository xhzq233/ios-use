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
            .activateApp, .terminateApp, .screenshot,
            .home, .dom, .find, .tap, .longPress, .input, .swipe, .waitFor,
            .openURL, .proxyCAPush, .dismissAlert,
        ]
        for cmd in cmds {
            XCTAssertFalse(cmd.rawValue.isEmpty, "\(cmd) should have non-empty rawValue")
        }
        XCTAssertEqual(cmds.count, DriverCommand.allCases.count)
        XCTAssertEqual(Command.find.metadata.argsTypeName, "ForyFindArgs")
        XCTAssertEqual(Command.swipe.metadata.payloadTypeName, "ForySwipePayload")
    }

    func testSwipePayload_UsesElementSummaryAndScrollDirection() throws {
        let fory = ForyRegistry.create()
        let payload = ForySwipePayload(
            element: ForyElementSummary(
                elemType: Int32(XCUIElement.ElementType.cell.rawValue),
                label: "General",
                rect: ForyRect(x: 1, y: 2, w: 3, h: 4),
                ancestors: ["Application", "Table"]
            ),
            scrolls: 2,
            scrollDirection: "down"
        )

        let decoded = try fory.deserialize(try fory.serialize(payload), as: ForySwipePayload.self)

        XCTAssertEqual(decoded.element.elemType, Int32(XCUIElement.ElementType.cell.rawValue))
        XCTAssertEqual(decoded.element.label, "General")
        XCTAssertEqual(decoded.element.rect?.x, 1)
        XCTAssertEqual(decoded.element.ancestors, ["Application", "Table"])
        XCTAssertEqual(decoded.scrolls, 2)
        XCTAssertEqual(decoded.scrollDirection, "down")
    }

    func testAmbiguityResponseUsesErrorStringWithoutPayload() {
        let first = makeElement(label: "关闭", type: .button)
        let second = makeElement(label: "关闭", type: .button)

        let response = ambiguityResponse("关闭", matches: [first, second])

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.payload.isEmpty)
        XCTAssertTrue(response.error.contains("label '关闭' is ambiguous (2 matches)"))
        XCTAssertTrue(response.error.contains("matches:"))
        XCTAssertTrue(response.error.contains("Button \"关闭\""))
        XCTAssertTrue(response.error.contains("hint: Try adding --traits to disambiguate"))
    }

    func testNotFoundResponseUsesErrorStringWithoutPayload() {
        let response = notFoundResponse(
            "Bluetoth",
            suggestions: ["Bluetooth"],
            hint: "Try adding --traits, or verify the active app"
        )

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.payload.isEmpty)
        XCTAssertTrue(response.error.contains("label 'Bluetoth' not found"))
        XCTAssertTrue(response.error.contains("suggestions: Bluetooth"))
        XCTAssertTrue(response.error.contains("hint: Try adding --traits, or verify the active app"))
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

    func testRawFindInSnapshot_DisableFuzzyReturnsNotFoundWithoutSuggestions() {
        let element = makeElement(label: "Bluetooth")
        let cs = makeCleanedSnapshot([element])

        switch rawFindInSnapshot(ForyTarget(label: "Bluetoth"), cs: cs, enableFuzzy: false) {
        case .notFound(let suggestions):
            XCTAssertTrue(suggestions.isEmpty)
        default:
            XCTFail("Expected notFound when fuzzy is disabled")
        }
    }

    func testRawFindInSnapshot_DefaultFuzzyReturnsSuggestions() {
        let element = makeElement(label: "Bluetooth")
        let cs = makeCleanedSnapshot([element])

        switch rawFindInSnapshot(ForyTarget(label: "Bluetoth"), cs: cs) {
        case .fuzzy(let suggestions):
            XCTAssertEqual(suggestions, ["Bluetooth"])
        default:
            XCTFail("Expected fuzzy suggestions by default")
        }
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

    func testFuzzySuggestions_ReturnsTopThreeByDistanceThenDisplayText() {
        let candidates = [
            SearchCandidate(displayText: "GeneralC", normalizedText: normalizeSearchText("GeneralC")),
            SearchCandidate(displayText: "GeneralA", normalizedText: normalizeSearchText("GeneralA")),
            SearchCandidate(displayText: "General", normalizedText: normalizeSearchText("General")),
            SearchCandidate(displayText: "GeneralB", normalizedText: normalizeSearchText("GeneralB")),
            SearchCandidate(displayText: "Genral", normalizedText: normalizeSearchText("Genral")),
        ]

        let suggestions = fuzzySuggestions(forNormalizedQuery: normalizeSearchText("General"), from: candidates)

        XCTAssertEqual(suggestions, ["General", "GeneralA", "GeneralB"])
    }

    func testFuzzySuggestions_LengthPruningSkipsImpossibleCandidates() {
        let candidates = [
            SearchCandidate(displayText: "Extremely Long General Settings Label", normalizedText: normalizeSearchText("Extremely Long General Settings Label")),
            SearchCandidate(displayText: "Genral", normalizedText: normalizeSearchText("Genral")),
        ]

        let suggestions = fuzzySuggestions(forNormalizedQuery: normalizeSearchText("General"), from: candidates)

        XCTAssertEqual(suggestions, ["Genral"])
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

    func testCleanTree_Rule4SameTypeMergePreservesDescendants() {
        let content = FakeRawSnapshot(
            label: "content",
            elementType: .staticText,
            frame: CGRect(x: 20, y: 20, width: 100, height: 20),
            isVisible: true
        )
        let childWebView = FakeRawSnapshot(
            label: "NestedWeb",
            elementType: .webView,
            frame: CGRect(x: 10, y: 10, width: 300, height: 300),
            isVisible: true,
            children: [content]
        )
        let parentWebView = FakeRawSnapshot(
            label: "NestedWeb",
            elementType: .webView,
            frame: CGRect(x: 10, y: 10, width: 300, height: 300),
            isVisible: true,
            children: [childWebView]
        )

        let elements = buildCleanElements(from: SafeSnapshot(raw: parentWebView, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812)))

        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements[0].node.label, "NestedWeb")
        XCTAssertEqual(elements[0].childCount, 1)
        XCTAssertEqual(elements[1].node.label, "content")
    }

    func testAutoLabelsUnnamedCleanedContainerAndRawFindCanLocateIt() {
        let firstCell = FakeRawSnapshot(label: "Wi-Fi", elementType: .cell)
        let secondCell = FakeRawSnapshot(label: "Bluetooth", elementType: .cell)
        let table = FakeRawSnapshot(elementType: .table, children: [firstCell, secondCell])
        let footer = FakeRawSnapshot(label: "Footer", elementType: .staticText)
        let app = FakeRawSnapshot(label: "Settings", elementType: .application, children: [table, footer])
        let elements = buildCleanElements(from: SafeSnapshot(raw: app, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812)))
        assignAutoLabels(elements)
        let cs = makeCleanedSnapshot(elements)

        XCTAssertEqual(displayName(for: elements[1].node), "SettingsApplicationc1")
        XCTAssertEqual(serializeDomFlat(from: elements)[1].label, "SettingsApplicationc1")

        switch rawFindInSnapshot(ForyTarget(label: "SettingsApplicationc1", traits: "Table"), cs: cs, visibility: .any) {
        case .found(let found):
            XCTAssertEqual(found.node.elementType, XCUIElement.ElementType.table.rawValue)
        default:
            XCTFail("expected auto-labeled table to be searchable")
        }
    }

    func testAutoLabelCanBeUsedAsCindexParentAndAncestorLabel() {
        let title = FakeRawSnapshot(label: "Title", elementType: .staticText)
        let button = FakeRawSnapshot(label: "Open", elementType: .button)
        let cell = FakeRawSnapshot(elementType: .cell, children: [title, button])
        let app = FakeRawSnapshot(label: "App", elementType: .application, children: [cell])
        let elements = buildCleanElements(from: SafeSnapshot(raw: app, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812)))
        assignAutoLabels(elements)
        let cs = makeCleanedSnapshot(elements)

        XCTAssertEqual(displayName(for: elements[1].node), "AppApplication")

        switch rawFindInSnapshot(ForyTarget(label: "AppApplication", traits: "Cell", cindex: -1), cs: cs, visibility: .any) {
        case .found(let found):
            XCTAssertEqual(displayName(for: found.node), "Open")
            XCTAssertEqual(ancestorChainNames(found.node), ["Application[App]", "Cell[AppApplication]"])
        default:
            XCTFail("expected auto-labeled cell to support cindex lookup")
        }
    }

    func testAutoLabelDedupesDuplicateSiblingDisplayLabels() {
        let first = FakeRawSnapshot(label: "Duplicate", elementType: .button)
        let second = FakeRawSnapshot(label: "Duplicate", elementType: .button)
        let third = FakeRawSnapshot(label: "Duplicate", elementType: .button)
        let app = FakeRawSnapshot(label: "App", elementType: .application, children: [first, second, third])
        let elements = buildCleanElements(from: SafeSnapshot(raw: app, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812)))
        assignAutoLabels(elements)
        let cs = makeCleanedSnapshot(elements)

        XCTAssertEqual(displayName(for: elements[1].node), "Duplicate")
        XCTAssertEqual(displayName(for: elements[2].node), "Duplicate-1")
        XCTAssertEqual(displayName(for: elements[3].node), "Duplicate-2")

        switch rawFindInSnapshot(ForyTarget(label: "Duplicate-1", traits: "Button"), cs: cs, visibility: .any) {
        case .found(let found):
            XCTAssertEqual(displayName(for: found.node), "Duplicate-1")
        default:
            XCTFail("expected deduped sibling alias to be searchable")
        }
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

        switch rawFindInSnapshot(ForyTarget(label: "搜索"), cs: cs) {
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

        switch rawFindInSnapshot(ForyTarget(label: "天琪"), cs: cs) {
        case .fuzzy(let suggestions):
            XCTAssertTrue(suggestions.contains("天气"))
        default:
            XCTFail("expected rawFindInSnapshot to fall back to fuzzy suggestions")
        }
    }

    func testRawFindInSnapshot_FindsByNormalizedContains() {
        let element = makeElement(label: "FaceTime 通话", type: .button)
        let cs = makeCleanedSnapshot([element])

        switch rawFindInSnapshot(ForyTarget(label: "facetime通话"), cs: cs) {
        case .found(let found):
            XCTAssertEqual(found.node.label, "FaceTime 通话")
        default:
            XCTFail("expected rawFindInSnapshot to find normalized contains match")
        }
    }

    func testRawFindInSnapshot_ExactMatchWinsOverLongerContainsMatches() {
        let exact = makeElement(label: "ic album zoom simple-1", type: .button)
        let longer = makeElement(label: "ic album zoom simple-10", type: .button)
        let cs = makeCleanedSnapshot([exact, longer])

        switch rawFindInSnapshot(ForyTarget(label: "ic album zoom simple-1"), cs: cs) {
        case .found(let found):
            XCTAssertEqual(found.node.label, "ic album zoom simple-1")
        case .ambiguous(let matches):
            XCTFail("expected exact match to avoid ambiguity, got \(matches.count) matches")
        default:
            XCTFail("expected rawFindInSnapshot to return the exact label")
        }
    }

    func testRawFindInSnapshot_ContainsStillWorksWhenExactMisses() {
        let first = makeElement(label: "ic album zoom simple-1", type: .button)
        let second = makeElement(label: "ic album zoom simple-10", type: .button)
        let cs = makeCleanedSnapshot([first, second])

        switch rawFindInSnapshot(ForyTarget(label: "album zoom"), cs: cs) {
        case .ambiguous(let matches):
            XCTAssertEqual(matches.map { $0.node.label }, ["ic album zoom simple-1", "ic album zoom simple-10"])
        default:
            XCTFail("expected contains fallback to preserve multiple partial matches")
        }
    }

    func testRawFindInSnapshot_DoesNotFallbackToContainsWhenExactFilteredByTraits() {
        let exactStaticText = makeElement(label: "Settings", type: .staticText)
        let containingButton = makeElement(label: "Settings Button", type: .button)
        let cs = makeCleanedSnapshot([exactStaticText, containingButton])

        switch rawFindInSnapshot(ForyTarget(label: "Settings", traits: "Button"), cs: cs) {
        case .notFound:
            break
        default:
            XCTFail("expected exact match filtered by traits to stay notFound without contains fallback")
        }
    }

    // MARK: - Trait filtering

    func testRawFindInSnapshot_TraitFilter_MatchesType() {
        let button = makeElement(label: "开关", type: .switch)
        let text = makeElement(label: "开关文字", type: .staticText)
        let cs = makeCleanedSnapshot([button, text])

        switch rawFindInSnapshot(ForyTarget(label: "开关", traits: "switch"), cs: cs) {
        case .found(let found):
            XCTAssertEqual(found.node.elementType, XCUIElement.ElementType.switch.rawValue)
        default:
            XCTFail("expected trait filter to match Switch type")
        }
    }

    func testRawFindInSnapshot_MultiTraitAnd_MatchesAll() {
        let elem = makeElement(label: "设置", type: .button)
        let cs = makeCleanedSnapshot([elem])

        switch rawFindInSnapshot(ForyTarget(label: "设置", traits: "button,statictext"), cs: cs) {
        case .notFound:
            break // expected: Button does not have StaticText trait
        default:
            XCTFail("expected notFound when traits don't all match")
        }
    }

    func testRawFindInSnapshot_CindexSelectsPositiveAndNegativeCleanedChildren() {
        let title = FakeRawSnapshot(label: "标题", elementType: .staticText)
        let value = FakeRawSnapshot(label: "值", elementType: .staticText)
        let chevron = FakeRawSnapshot(label: "详情", elementType: .button)
        let cell = FakeRawSnapshot(label: "蓝牙", elementType: .cell, children: [title, value, chevron])
        let root = SafeSnapshot(raw: cell, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))
        let cs = makeCleanedSnapshot(buildCleanElements(from: root))

        switch rawFindInSnapshot(ForyTarget(label: "蓝牙", traits: "Cell", cindex: 0), cs: cs) {
        case .found(let found):
            XCTAssertEqual(found.node.label, "标题")
        default:
            XCTFail("expected cindex=0 to select first child")
        }

        switch rawFindInSnapshot(ForyTarget(label: "蓝牙", traits: "Cell", cindex: -1), cs: cs) {
        case .found(let found):
            XCTAssertEqual(found.node.label, "详情")
        default:
            XCTFail("expected cindex=-1 to select last child")
        }

        switch rawFindInSnapshot(ForyTarget(label: "蓝牙", traits: "Cell", cindex: -2), cs: cs) {
        case .found(let found):
            XCTAssertEqual(found.node.label, "值")
        default:
            XCTFail("expected cindex=-2 to select second-to-last child")
        }
    }

    func testRawFindInSnapshot_CindexOutOfBoundsReturnsNotFound() {
        let child = FakeRawSnapshot(label: "子项", elementType: .staticText)
        let cell = FakeRawSnapshot(label: "蓝牙", elementType: .cell, children: [child])
        let root = SafeSnapshot(raw: cell, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))
        let cs = makeCleanedSnapshot(buildCleanElements(from: root))

        switch rawFindInSnapshot(ForyTarget(label: "蓝牙", traits: "Cell", cindex: 2), cs: cs) {
        case .notFound:
            break
        default:
            XCTFail("expected positive out-of-bounds cindex to return notFound")
        }

        switch rawFindInSnapshot(ForyTarget(label: "蓝牙", traits: "Cell", cindex: -2), cs: cs) {
        case .notFound:
            break
        default:
            XCTFail("expected negative out-of-bounds cindex to return notFound")
        }
    }

    func testRawFindInSnapshot_CindexShrinksAmbiguousMatches() {
        let child = FakeRawSnapshot(label: "可点", elementType: .button)
        let withChild = FakeRawSnapshot(label: "设置", elementType: .cell, children: [child])
        let withoutChild = FakeRawSnapshot(label: "设置", elementType: .cell)
        let table = FakeRawSnapshot(elementType: .table, children: [withChild, withoutChild])
        let root = SafeSnapshot(raw: table, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))
        let cs = makeCleanedSnapshot(buildCleanElements(from: root))

        switch rawFindInSnapshot(ForyTarget(label: "设置", traits: "Cell", cindex: 0), cs: cs) {
        case .found(let found):
            XCTAssertEqual(found.node.label, "可点")
        default:
            XCTFail("expected cindex to drop ambiguous parents without selected child")
        }
    }

    func testRawFindInSnapshot_CindexAppliesVisibilityToSelectedChild() {
        let hiddenChild = FakeRawSnapshot(
            label: "关闭",
            elementType: .staticText,
            frame: CGRect(x: 0, y: 116, width: 34, height: 20),
            visibleFrame: .zero,
            isVisible: true
        )
        let cell = FakeRawSnapshot(label: "配置代理", elementType: .cell, children: [hiddenChild])
        let root = SafeSnapshot(raw: cell, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))
        let cs = makeCleanedSnapshot(buildCleanElements(from: root))

        switch rawFindInSnapshot(ForyTarget(label: "配置代理", traits: "Cell", cindex: 0), cs: cs, visibility: .only) {
        case .notFound:
            break
        default:
            XCTFail("expected .only cindex result to filter invisible selected child")
        }

        switch rawFindInSnapshot(ForyTarget(label: "配置代理", traits: "Cell", cindex: 0), cs: cs, visibility: .any) {
        case .found(let found):
            XCTAssertEqual(found.node.label, "关闭")
        default:
            XCTFail("expected .any cindex result to keep invisible selected child")
        }
    }

    func testRawFindInSnapshot_CindexDoesNotAffectFuzzySuggestions() {
        let element = makeElement(label: "天气", type: .staticText)
        let cs = makeCleanedSnapshot([element])

        switch rawFindInSnapshot(ForyTarget(label: "天琪", cindex: 0), cs: cs) {
        case .fuzzy(let suggestions):
            XCTAssertEqual(suggestions, ["天气"])
        default:
            XCTFail("expected cindex to be ignored for fuzzy suggestions")
        }
    }

    func testRawFindInSnapshot_OnlyReturnsElementWithEffectiveGeometry() {
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

        switch rawFindInSnapshot(ForyTarget(label: "配置代理"), cs: cs) {
        case .found(let found):
            XCTAssertEqual(found.node.frame.origin.y, 600)
        default:
            XCTFail("expected rawFindInSnapshot to return the element with effective geometry")
        }
    }

    func testRawFindInSnapshot_OnlyReturnsNotFoundWhenMatchesAreNotEffectivelyVisible() {
        let offscreenLabel = FakeRawSnapshot(
            label: "配置代理",
            elementType: .staticText,
            frame: CGRect(x: 0, y: 900, width: 80, height: 20),
            isVisible: true
        )
        let cs = makeCleanedSnapshot([makeSnapshotElement(SafeSnapshot(raw: offscreenLabel, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812)))])

        switch rawFindInSnapshot(ForyTarget(label: "配置代理"), cs: cs, visibility: .only) {
        case .notFound:
            break
        default:
            XCTFail("expected rawFindInSnapshot to return notFound when visibility is .only and matches are not effectively visible")
        }
    }

    func testRawFindInSnapshot_OnlyDoesNotFallbackToFrameForNonIconElements() {
        let proxyLabel = FakeRawSnapshot(
            label: "配置代理",
            elementType: .staticText,
            frame: CGRect(x: 0, y: 116, width: 80, height: 20),
            visibleFrame: .zero,
            isVisible: true
        )
        let cs = makeCleanedSnapshot([makeSnapshotElement(SafeSnapshot(raw: proxyLabel, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812)))])

        switch rawFindInSnapshot(ForyTarget(label: "配置代理"), cs: cs, visibility: .only) {
        case .notFound:
            break
        default:
            XCTFail("expected non-icon elements with empty visibleFrame to remain not effectively visible even when frame is in bounds")
        }
    }

    func testRawFindInSnapshot_OnlyFallsBackToFrameForIconElements() {
        let icon = FakeRawSnapshot(
            label: "醒图开发版",
            elementType: .icon,
            frame: CGRect(x: 22, y: 489, width: 80, height: 90),
            visibleFrame: .zero,
            isVisible: true
        )
        let cs = makeCleanedSnapshot([makeSnapshotElement(SafeSnapshot(raw: icon, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812)))])

        switch rawFindInSnapshot(ForyTarget(label: "醒图开发版"), cs: cs, visibility: .only) {
        case .found(let found):
            XCTAssertEqual(found.node.frame.origin.x, 22)
            XCTAssertEqual(found.node.frame.origin.y, 489)
        default:
            XCTFail("expected icon elements with empty visibleFrame to fallback to frame when frame is in bounds")
        }
    }

    func testRawFindInSnapshot_OnlyFallsBackToFrameForSearchField() {
        let search = FakeRawSnapshot(
            label: "Search",
            elementType: .searchField,
            frame: CGRect(x: 33, y: 781, width: 327, height: 38),
            visibleFrame: .zero,
            isVisible: true
        )
        let cs = makeCleanedSnapshot([makeSnapshotElement(SafeSnapshot(raw: search, appFrame: CGRect(x: 0, y: 0, width: 393, height: 852)))])

        switch rawFindInSnapshot(ForyTarget(label: "Search", traits: "SearchField"), cs: cs, visibility: .only) {
        case .found(let found):
            XCTAssertEqual(found.node.frame.origin.x, 33)
            XCTAssertEqual(found.node.frame.origin.y, 781)
        default:
            XCTFail("expected SearchField with empty visibleFrame to fallback to frame when frame is in bounds")
        }
    }

    func testRawFindInSnapshot_OnlyFuzzyIgnoresNotEffectivelyVisibleCandidates() {
        let offscreenLabel = FakeRawSnapshot(
            label: "Blue",
            elementType: .staticText,
            frame: CGRect(x: 0, y: 900, width: 80, height: 20),
            isVisible: true
        )
        let visibleLabel = FakeRawSnapshot(
            label: "Bloc",
            elementType: .staticText,
            frame: CGRect(x: 32, y: 100, width: 80, height: 20),
            isVisible: true
        )
        let table = FakeRawSnapshot(elementType: .table, children: [offscreenLabel, visibleLabel])
        let root = SafeSnapshot(raw: table, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))
        let offscreen = makeSnapshotElement(root.children[0])
        let visible = makeSnapshotElement(root.children[1])
        let cs = makeCleanedSnapshot([offscreen, visible])

        switch rawFindInSnapshot(ForyTarget(label: "Bloo"), cs: cs, visibility: .only) {
        case .fuzzy(let suggestions):
            XCTAssertEqual(suggestions, ["Bloc"])
        default:
            XCTFail("expected rawFindInSnapshot fuzzy suggestions to ignore not effectively visible candidates when visibility is .only")
        }
    }

    func testRawFindInSnapshot_AnyPreservesAllContainsMatchesWhenExactMisses() {
        let offscreenLabel = FakeRawSnapshot(
            label: "配置代理屏外",
            elementType: .staticText,
            frame: CGRect(x: 0, y: 900, width: 80, height: 20),
            isVisible: true
        )
        let visibleLabel = FakeRawSnapshot(
            label: "配置代理屏内",
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

        switch rawFindInSnapshot(ForyTarget(label: "配置代理"), cs: cs, visibility: .any) {
        case .ambiguous(let matches):
            XCTAssertEqual(matches.count, 2)
            XCTAssertEqual(matches[0].node.frame.origin.y, 900)
            XCTAssertEqual(matches[1].node.frame.origin.y, 600)
        default:
            XCTFail("expected rawFindInSnapshot to preserve all contains matches when visibility is .any and exact misses")
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
