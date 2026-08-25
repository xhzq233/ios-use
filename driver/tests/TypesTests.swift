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
        type: XCUIElement.ElementType = .staticText,
        frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 40),
        visibleFrame: CGRect? = nil,
        isVisible: Bool = true
    ) -> SnapshotElement {
        let raw = FakeRawSnapshot(
            label: label,
            identifier: identifier,
            value: value,
            placeholderValue: placeholderValue,
            elementType: type,
            frame: frame,
            visibleFrame: visibleFrame,
            isVisible: isVisible
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

    func testAmbiguityResponseUsesStructuredPayloadWithoutHint() throws {
        let first = makeElement(label: "关闭", type: .button)
        let second = makeElement(label: "关闭", type: .button)

        let response = try ambiguityResponse(ForyTarget(label: "关闭"), matches: [first, second])

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error.contains("label '关闭' is ambiguous (2 matches)"))
        XCTAssertFalse(response.error.contains("hint:"))
        let payload = try createFory().deserialize(response.payload, as: ForyErrorPayload.self)
        XCTAssertEqual(payload.category, IOSUseErrorCategory.lookup)
        XCTAssertEqual(payload.code, IOSUseErrorCode.elementAmbiguous)
        XCTAssertEqual(payload.candidateCount, 2)
        XCTAssertEqual(payload.candidates.count, 2)
        XCTAssertEqual(payload.candidates.first?.element.label, "关闭")
    }

    func testNotFoundResponseUsesStructuredPayloadWithoutHint() throws {
        let response = try notFoundResponse(
            ForyTarget(label: "Bluetoth"),
            suggestions: ["Bluetooth"]
        )

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error.contains("label 'Bluetoth' not found"))
        XCTAssertFalse(response.error.contains("hint:"))
        let payload = try createFory().deserialize(response.payload, as: ForyErrorPayload.self)
        XCTAssertEqual(payload.code, IOSUseErrorCode.elementNotFound)
        XCTAssertEqual(payload.suggestions, ["Bluetooth"])
        XCTAssertTrue(payload.candidates.isEmpty)
    }

    // MARK: - interactionFrame

    func testInteractionFrame_ClipsValidVisibleFrameToAppFrame() throws {
        let raw = FakeRawSnapshot(
            elementType: .collectionView,
            frame: CGRect(x: -200, y: 696, width: 602, height: 90),
            visibleFrame: CGRect(x: -200, y: 696, width: 602, height: 90)
        )
        let node = SafeSnapshot(raw: raw, appFrame: CGRect(x: 0, y: 0, width: 402, height: 874))

        let frame = try XCTUnwrap(interactionFrame(node))

        XCTAssertEqual(frame, CGRect(x: 0, y: 696, width: 402, height: 90))
        let tapPoint = resolveTapPoint(
            frame: frame,
            offset: nil,
            ratio: ForyPoint(x: 0.5, y: 0.5)
        )
        XCTAssertEqual(tapPoint, CGPoint(x: 201, y: 741))
    }

    func testInteractionFrame_ValidVisibleFrameIsAuthoritativeOverInvisibleAncestor() {
        let child = FakeRawSnapshot(
            label: "可见按钮",
            elementType: .button,
            frame: CGRect(x: 20, y: 100, width: 80, height: 40),
            visibleFrame: CGRect(x: 20, y: 100, width: 80, height: 40)
        )
        let hiddenParent = FakeRawSnapshot(
            elementType: .other,
            frame: CGRect(x: 0, y: 80, width: 375, height: 100),
            isVisible: false,
            children: [child]
        )
        let root = SafeSnapshot(raw: hiddenParent, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))

        XCTAssertEqual(
            interactionFrame(root.children[0]),
            CGRect(x: 20, y: 100, width: 80, height: 40)
        )
    }

    func testInteractionFrame_FallsBackToClippedRawFrameForVisibleNode() {
        let raw = FakeRawSnapshot(
            elementType: .collectionView,
            frame: CGRect(x: -200, y: 696, width: 602, height: 90),
            visibleFrame: .zero,
            isVisible: true
        )
        let node = SafeSnapshot(raw: raw, appFrame: CGRect(x: 0, y: 0, width: 402, height: 874))

        XCTAssertEqual(
            interactionFrame(node),
            CGRect(x: 0, y: 696, width: 402, height: 90)
        )
    }

    func testInteractionFrame_TreatsInfiniteZeroVisibleFrameAsInvalidAndFallsBack() {
        let raw = FakeRawSnapshot(
            elementType: .button,
            frame: CGRect(x: 20, y: 100, width: 80, height: 40),
            visibleFrame: CGRect(
                x: CGFloat.infinity,
                y: CGFloat.infinity,
                width: 0,
                height: 0
            ),
            isVisible: true
        )
        let node = SafeSnapshot(raw: raw, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))

        XCTAssertEqual(
            interactionFrame(node),
            CGRect(x: 20, y: 100, width: 80, height: 40)
        )
    }

    func testInteractionFrame_RejectsRawFallbackForInvisibleNode() {
        let raw = FakeRawSnapshot(
            elementType: .button,
            frame: CGRect(x: 20, y: 100, width: 80, height: 40),
            visibleFrame: .zero,
            isVisible: false
        )
        let node = SafeSnapshot(raw: raw, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))

        XCTAssertNil(interactionFrame(node))
        XCTAssertEqual(
            interactionFrameRejectionReason(node, in: node.appFrame),
            IOSUseCandidateRejection.snapshotInvisible
        )
    }

    func testInteractionFrame_RejectsRawFallbackOutsideAppFrame() {
        let raw = FakeRawSnapshot(
            elementType: .button,
            frame: CGRect(x: 20, y: 900, width: 80, height: 40),
            visibleFrame: .zero,
            isVisible: true
        )
        let node = SafeSnapshot(raw: raw, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))

        XCTAssertNil(interactionFrame(node))
        XCTAssertEqual(
            interactionFrameRejectionReason(node, in: node.appFrame),
            IOSUseCandidateRejection.outsideAppBounds
        )
    }

    func testInteractionFrame_AllowsSpringBoardIconPlaceholderAncestor() {
        let appIcon = FakeRawSnapshot(
            label: "设置",
            elementType: .icon,
            frame: CGRect(x: 22, y: 489, width: 80, height: 90),
            visibleFrame: .zero,
            isVisible: true
        )
        let placeholder = FakeRawSnapshot(
            elementType: .icon,
            frame: .zero,
            visibleFrame: .zero,
            isVisible: false,
            children: [appIcon]
        )
        let root = SafeSnapshot(raw: placeholder, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))

        XCTAssertEqual(
            interactionFrame(root.children[0]),
            CGRect(x: 22, y: 489, width: 80, height: 90)
        )
    }

    func testInteractionFrame_NamedZeroAreaIconAncestorStillBlocksFallback() {
        let appIcon = FakeRawSnapshot(
            label: "设置",
            elementType: .icon,
            frame: CGRect(x: 22, y: 489, width: 80, height: 90),
            visibleFrame: .zero,
            isVisible: true
        )
        let hiddenIcon = FakeRawSnapshot(
            label: "不是占位容器",
            elementType: .icon,
            frame: .zero,
            visibleFrame: .zero,
            isVisible: false,
            children: [appIcon]
        )
        let root = SafeSnapshot(raw: hiddenIcon, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))

        XCTAssertNil(interactionFrame(root.children[0]))
        XCTAssertEqual(
            interactionFrameRejectionReason(root.children[0], in: root.children[0].appFrame),
            IOSUseCandidateRejection.ancestorInvisible
        )
    }

    func testRawFindInSnapshot_DisableFuzzyReturnsNotFoundWithoutSuggestions() {
        let element = makeElement(label: "Bluetooth")
        let cs = makeCleanedSnapshot([element])

        switch rawFindInSnapshot(ForyTarget(label: "Bluetoth"), cs: cs, enableFuzzy: false) {
        case .notFound(let suggestions, let rejected):
            XCTAssertTrue(suggestions.isEmpty)
            XCTAssertTrue(rejected.isEmpty)
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

    func testNormalizeSearchText_IgnoresWhitespaceCaseAndPunctuation() {
        XCTAssertEqual(normalizeSearchText(" 编 辑 "), "编辑")
        XCTAssertEqual(normalizeSearchText("FAcetime通话"), "facetime通话")
        XCTAssertEqual(normalizeSearchText("FaceTime 通话"), "facetime通话")
        XCTAssertEqual(normalizeSearchText("Wi-Fi"), "wifi")
    }

    // MARK: - serializeDomFlat (ForyDomElement)

    func testSerializeDomFlat_SerializesPreorderElements() {
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
        XCTAssertNotNil(dom[0].rect)
        XCTAssertEqual(dom[1].label, "Child 1")
        XCTAssertEqual(dom[1].childCount, 0)
        XCTAssertNotNil(dom[1].rect)
        XCTAssertEqual(dom[2].label, "Parent")
        XCTAssertEqual(dom[2].childCount, 1)
        XCTAssertNotNil(dom[2].rect)
        XCTAssertEqual(dom[3].label, "Grandchild")
        XCTAssertEqual(dom[3].childCount, 0)
        XCTAssertNotNil(dom[3].rect)
        XCTAssertEqual(dom[4].label, "Child 2")
        XCTAssertEqual(dom[4].childCount, 0)
        XCTAssertNotNil(dom[4].rect)
    }

    func testCleanTree_SortsChildrenByYAndKeepsSameYStable() {
        let bottom = FakeRawSnapshot(label: "Bottom", elementType: .button, frame: CGRect(x: 0, y: 300, width: 100, height: 44))
        let sameA = FakeRawSnapshot(label: "Same A", elementType: .button, frame: CGRect(x: 200, y: 150, width: 100, height: 44))
        let top = FakeRawSnapshot(label: "Top", elementType: .button, frame: CGRect(x: 0, y: 100, width: 100, height: 44))
        let sameB = FakeRawSnapshot(label: "Same B", elementType: .button, frame: CGRect(x: 0, y: 150, width: 100, height: 44))
        let app = FakeRawSnapshot(label: "App", elementType: .application, children: [bottom, sameA, top, sameB])

        let elements = buildCleanElements(from: SafeSnapshot(raw: app, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812)))

        XCTAssertEqual(elements.map { $0.node.label }, ["App", "Top", "Same A", "Same B", "Bottom"])
    }

    func testCleanTree_SortsAfterRule3AndRule6() {
        let mergedChild = FakeRawSnapshot(label: "Merged", elementType: .staticText, frame: CGRect(x: 0, y: 300, width: 100, height: 44))
        let mergedParent = FakeRawSnapshot(label: "Merged", elementType: .button, frame: CGRect(x: 0, y: 300, width: 100, height: 44), children: [mergedChild])
        let emptyTrimmed = FakeRawSnapshot(elementType: .other, frame: CGRect(x: 0, y: 150, width: 0, height: 0))
        let top = FakeRawSnapshot(label: "Top", elementType: .button, frame: CGRect(x: 0, y: 100, width: 100, height: 44))
        let app = FakeRawSnapshot(label: "App", elementType: .application, children: [mergedParent, emptyTrimmed, top])

        let elements = buildCleanElements(from: SafeSnapshot(raw: app, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812)))

        XCTAssertEqual(elements.map { $0.node.label }, ["App", "Top", "Merged"])
        XCTAssertEqual(elements.map { $0.traits.first }, ["App", "Button", "Button"])
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

        XCTAssertEqual(displayName(for: elements[1].node), "SettingsAppc1")
        XCTAssertEqual(serializeDomFlat(from: elements)[1].label, "SettingsAppc1")

        switch rawFindInSnapshot(ForyTarget(label: "SettingsAppc1", traits: "Table"), cs: cs, visibility: .any) {
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

        XCTAssertEqual(displayName(for: elements[1].node), "AppApp")

        switch rawFindInSnapshot(ForyTarget(label: "AppApp", traits: "Cell", cindex: -1), cs: cs, visibility: .any) {
        case .found(let found):
            XCTAssertEqual(displayName(for: found.node), "Open")
            XCTAssertEqual(ancestorChainNames(found.node), ["App[App]", "Cell[AppApp]"])
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

    func testRawFindInSnapshot_StandardModeTracksDynamicTextByStableSubstring() {
        let element = makeElement(label: "优化身形线条中... 17%", type: .staticText)
        let cs = makeCleanedSnapshot([element])

        switch rawFindInSnapshot(
            ForyTarget(label: "优化身形线条中"),
            cs: cs,
            enableFuzzy: false,
            textMatch: .standard
        ) {
        case .found(let found):
            XCTAssertEqual(found.node.label, "优化身形线条中... 17%")
        default:
            XCTFail("expected standard matching to find a stable substring in dynamic text")
        }
    }

    func testRawFindInSnapshot_ExactModeRejectsDynamicSuffix() {
        let element = makeElement(label: "优化身形线条中... 17%", type: .staticText)
        let cs = makeCleanedSnapshot([element])

        switch rawFindInSnapshot(
            ForyTarget(label: "优化身形线条中"),
            cs: cs,
            textMatch: .exact
        ) {
        case .notFound:
            break
        default:
            XCTFail("expected exact matching to reject a dynamic suffix")
        }
    }

    func testRawFindInSnapshot_RegexModeMatchesDynamicPercentage() throws {
        let element = makeElement(label: "优化身形线条中... 17%", type: .staticText)
        let cs = makeCleanedSnapshot([element])
        let expression = try NSRegularExpression(pattern: #"^优化身形线条中.*\d+%$"#)

        switch rawFindInSnapshot(
            ForyTarget(label: expression.pattern),
            cs: cs,
            enableFuzzy: false,
            textMatch: .regex(expression)
        ) {
        case .found(let found):
            XCTAssertEqual(found.node.label, "优化身形线条中... 17%")
        default:
            XCTFail("expected regex matching to track a changing percentage")
        }
    }

    func testRawFindInSnapshot_RegexModeDoesNotNormalizePatternCharactersAway() throws {
        let element = makeElement(label: "A", type: .staticText)
        let cs = makeCleanedSnapshot([element])
        let expression = try NSRegularExpression(pattern: ".")

        switch rawFindInSnapshot(
            ForyTarget(label: expression.pattern),
            cs: cs,
            enableFuzzy: false,
            textMatch: .regex(expression)
        ) {
        case .found:
            break
        default:
            XCTFail("expected punctuation-only regex syntax to remain valid")
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
        case .notFound(_, let rejected):
            XCTAssertEqual(rejected.count, 1)
            XCTAssertEqual(rejected.first?.element.label, "Settings")
            XCTAssertEqual(rejected.first?.rejectedBy, [IOSUseCandidateRejection.traitMismatch])
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
        case .notFound(_, let rejected):
            XCTAssertEqual(rejected.count, 1)
            XCTAssertEqual(rejected.first?.element.label, "蓝牙")
            XCTAssertEqual(rejected.first?.rejectedBy, [IOSUseCandidateRejection.childIndexOutOfRange])
        default:
            XCTFail("expected positive out-of-bounds cindex to return notFound")
        }

        switch rawFindInSnapshot(ForyTarget(label: "蓝牙", traits: "Cell", cindex: -2), cs: cs) {
        case .notFound(_, let rejected):
            XCTAssertEqual(rejected.count, 1)
            XCTAssertEqual(rejected.first?.rejectedBy, [IOSUseCandidateRejection.childIndexOutOfRange])
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
        let cell = FakeRawSnapshot(
            label: "配置代理",
            elementType: .cell,
            isVisible: false,
            children: [hiddenChild]
        )
        let root = SafeSnapshot(raw: cell, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))
        let cs = makeCleanedSnapshot(buildCleanElements(from: root))

        switch rawFindInSnapshot(ForyTarget(label: "配置代理", traits: "Cell", cindex: 0), cs: cs, visibility: .only) {
        case .notFound(_, let rejected):
            XCTAssertEqual(rejected.count, 1)
            XCTAssertEqual(rejected.first?.element.label, "关闭")
            XCTAssertEqual(rejected.first?.rejectedBy, [IOSUseCandidateRejection.ancestorInvisible])
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

    func testRawFindInSnapshot_OnlyReturnsElementWithInteractionFrame() {
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
            XCTFail("expected rawFindInSnapshot to return the element with an interaction frame")
        }
    }

    func testRawFindInSnapshot_OnlyReturnsNotFoundWhenMatchesHaveNoInteractionFrame() {
        let offscreenLabel = FakeRawSnapshot(
            label: "配置代理",
            elementType: .staticText,
            frame: CGRect(x: 0, y: 900, width: 80, height: 20),
            isVisible: true
        )
        let cs = makeCleanedSnapshot([makeSnapshotElement(SafeSnapshot(raw: offscreenLabel, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812)))])

        switch rawFindInSnapshot(ForyTarget(label: "配置代理"), cs: cs, visibility: .only) {
        case .notFound(_, let rejected):
            XCTAssertEqual(rejected.count, 1)
            XCTAssertEqual(rejected.first?.element.label, "配置代理")
            XCTAssertEqual(rejected.first?.rejectedBy, [IOSUseCandidateRejection.outsideAppBounds])
        default:
            XCTFail("expected rawFindInSnapshot to return notFound when visibility is .only and matches have no interaction frame")
        }
    }

    func testRawFindInSnapshot_OnlyFallsBackToFrameForGenericButton() {
        let closeButton = FakeRawSnapshot(
            label: "关闭",
            elementType: .button,
            frame: CGRect(x: 0, y: 116, width: 80, height: 20),
            visibleFrame: .zero,
            isVisible: true
        )
        let cs = makeCleanedSnapshot([makeSnapshotElement(SafeSnapshot(raw: closeButton, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812)))])

        switch rawFindInSnapshot(ForyTarget(label: "关闭"), cs: cs, visibility: .only) {
        case .found(let found):
            XCTAssertEqual(found.node.label, "关闭")
        default:
            XCTFail("expected visible Button with empty visibleFrame to fallback to raw frame")
        }
    }

    func testRawFindInSnapshot_ConfigurationProxyButtonBlockedByInvisibleCellAncestor() {
        let proxyButton = FakeRawSnapshot(
            label: "配置代理",
            elementType: .button,
            frame: CGRect(x: 20, y: 700, width: 120, height: 44),
            visibleFrame: .zero,
            isVisible: true
        )
        let offscreenCell = FakeRawSnapshot(
            elementType: .cell,
            frame: CGRect(x: 0, y: 900, width: 375, height: 64),
            visibleFrame: .zero,
            isVisible: false,
            children: [proxyButton]
        )
        let root = SafeSnapshot(raw: offscreenCell, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))
        let proxy = makeSnapshotElement(root.children[0])
        let cs = makeCleanedSnapshot([proxy])

        switch rawFindInSnapshot(ForyTarget(label: "配置代理"), cs: cs, visibility: .only) {
        case .notFound(_, let rejected):
            XCTAssertEqual(rejected.count, 1)
            XCTAssertEqual(rejected.first?.element.label, "配置代理")
            XCTAssertEqual(rejected.first?.rejectedBy, [IOSUseCandidateRejection.ancestorInvisible])
        default:
            XCTFail("expected 配置代理 under an invisible Cell to be non-interactable")
        }
    }

    func testRawFindInSnapshot_OnlyFuzzyIgnoresCandidatesWithoutInteractionFrames() {
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
            XCTFail("expected rawFindInSnapshot fuzzy suggestions to ignore candidates without interaction frames when visibility is .only")
        }
    }

    // MARK: - SafeSnapshot children pruning

    func testSafeSnapshotChildrenPruning_DropsChildrenOutsideThreeViewports() {
        var children = [
            FakeRawSnapshot(
                label: "far-above",
                elementType: .cell,
                frame: CGRect(x: 0, y: -2600, width: 375, height: 44),
                isVisible: true
            ),
            FakeRawSnapshot(
                label: "near-above",
                elementType: .cell,
                frame: CGRect(x: 0, y: -2400, width: 375, height: 44),
                isVisible: false
            ),
            FakeRawSnapshot(
                label: "onscreen",
                elementType: .cell,
                frame: CGRect(x: 0, y: 640, width: 375, height: 44),
                isVisible: false
            ),
            FakeRawSnapshot(
                label: "far-below",
                elementType: .cell,
                frame: CGRect(x: 0, y: 3500, width: 375, height: 44),
                isVisible: true
            ),
        ]
        for i in 0..<72 {
            children.append(FakeRawSnapshot(
                label: "far-below-\(i)",
                elementType: .cell,
                frame: CGRect(x: 0, y: 3600 + CGFloat(i * 50), width: 375, height: 44),
                isVisible: false
            ))
        }
        let table = FakeRawSnapshot(elementType: .table, children: children)
        let root = SafeSnapshot(raw: table, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))

        let labels = root.children.compactMap { $0.label }
        XCTAssertEqual(labels, ["near-above", "onscreen"])
    }

    func testSafeSnapshotChildrenPruning_DoesNotPruneAtThreshold() {
        let children = (0..<75).map { i in
            FakeRawSnapshot(
                label: "far-above-\(i)",
                elementType: .cell,
                frame: CGRect(x: 0, y: -4000 - CGFloat(i * 50), width: 375, height: 44),
                isVisible: false
            )
        }
        let table = FakeRawSnapshot(elementType: .table, children: children)
        let root = SafeSnapshot(raw: table, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))

        XCTAssertEqual(root.children.count, 75)
    }

    func testSafeSnapshotChildrenPruning_KeepsChildrenWithEmptyFrames() {
        var children = [
            FakeRawSnapshot(label: "empty-frame", elementType: .cell, frame: .zero, isVisible: false)
        ]
        for i in 0..<75 {
            children.append(FakeRawSnapshot(
                label: "far-above-\(i)",
                elementType: .cell,
                frame: CGRect(x: 0, y: -4000 - CGFloat(i * 50), width: 375, height: 44),
                isVisible: false
            ))
        }
        let table = FakeRawSnapshot(elementType: .table, children: children)
        let root = SafeSnapshot(raw: table, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))

        XCTAssertEqual(root.children.compactMap { $0.label }, ["empty-frame"])
    }

}
