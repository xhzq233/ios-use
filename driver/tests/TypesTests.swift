import XCTest

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
        self.visibleFrame = NSValue(cgRect: frame)
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
            byLabel: [:],
            searchEntries: searchEntries,
            searchCandidates: searchCandidates
        )
    }

    // MARK: - Command enum

    func testCommandRawValues() {
        let cmds: [Command] = [
            .createSession, .deleteSession,
            .activateApp, .terminateApp, .probeFetch, .screenshot, .oslog,
            .dom, .find, .tap, .longPress, .input, .swipe, .waitFor,
        ]
        for cmd in cmds {
            XCTAssertFalse(cmd.rawValue.isEmpty, "\(cmd) should have non-empty rawValue")
        }
        XCTAssertEqual(cmds.count, 14)
    }

    func testCommandDecoding_AllCases() throws {
        for raw in ["createSession", "deleteSession", "activateApp",
                    "terminateApp", "probeFetch", "screenshot", "oslog", "dom", "find",
                    "tap", "longPress", "input", "swipe", "waitFor"] {
            let json = "{\"c\":\"\(raw)\"}"
            let req = try JSONDecoder().decode(RequestFrame.self, from: json.data(using: .utf8)!)
            XCTAssertEqual(req.c.rawValue, raw)
        }
    }

    func testCommandDecoding_Unknown() {
        let json = "{\"c\":\"getLogs\"}"  // removed command
        XCTAssertThrowsError(try JSONDecoder().decode(RequestFrame.self, from: json.data(using: .utf8)!))
    }

    // MARK: - StringOrPoint (doc 1.2)

    func testStringOrPoint_DecodeString() throws {
        let data = "\"Settings\"".data(using: .utf8)!
        let v = try JSONDecoder().decode(StringOrPoint.self, from: data)
        XCTAssertEqual(v.asLabel, "Settings")
        XCTAssertNil(v.asPoint)
    }

    func testStringOrPoint_DecodePoint() throws {
        let data = "[100,200]".data(using: .utf8)!
        let v = try JSONDecoder().decode(StringOrPoint.self, from: data)
        XCTAssertEqual(v.asPoint, [100, 200])
        XCTAssertNil(v.asLabel)
    }

    func testStringOrPoint_RejectInvalid() {
        let data = "[1,2,3]".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(StringOrPoint.self, from: data))
    }

    func testStringOrPoint_RoundTrip() throws {
        let s = StringOrPoint.label("Hi")
        let enc = try JSONEncoder().encode(s)
        let dec = try JSONDecoder().decode(StringOrPoint.self, from: enc)
        XCTAssertEqual(dec.asLabel, "Hi")

        let p = StringOrPoint.point([10, 20])
        let enc2 = try JSONEncoder().encode(p)
        let dec2 = try JSONDecoder().decode(StringOrPoint.self, from: enc2)
        XCTAssertEqual(dec2.asPoint, [10, 20])
    }

    // MARK: - SwipeDir (doc 3.1)

    func testSwipeDirRawValues() {
        XCTAssertEqual(SwipeDir.forth.rawValue, "forth")
        XCTAssertEqual(SwipeDir.back.rawValue, "back")
    }

    // MARK: - Per-command Args (doc 1.2)

    func testCreateSessionArgs_Decode() throws {
        let a = try JSONDecoder().decode(CreateSessionArgs.self,
            from: "{\"bundleId\":\"com.apple.Preferences\"}".data(using: .utf8)!)
        XCTAssertEqual(a.bundleId, "com.apple.Preferences")
    }

    func testCreateSessionArgs_EmptyIsDeviceSession() throws {
        let a = try JSONDecoder().decode(CreateSessionArgs.self,
            from: "{}".data(using: .utf8)!)
        XCTAssertNil(a.bundleId)
    }

    func testActivateAppArgs_RequiresBundleId() {
        XCTAssertThrowsError(try JSONDecoder().decode(ActivateAppArgs.self,
            from: "{}".data(using: .utf8)!))
    }

    func testTapArgs_WithLabel() throws {
        let json = "{\"label\":\"Wi-Fi\",\"traits\":\"Cell,Button\"}"
        let a = try JSONDecoder().decode(TapArgs.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(a.label.asLabel, "Wi-Fi")
        XCTAssertEqual(a.traits, "Cell,Button")
    }

    func testTapArgs_WithPoint() throws {
        let json = "{\"label\":[100,200]}"
        let a = try JSONDecoder().decode(TapArgs.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(a.label.asPoint, [100, 200])
    }

    func testTapArgs_WithOffset() throws {
        let json = "{\"label\":\"Slider\",\"offset\":{\"x\":12,\"y\":5}}"
        let a = try JSONDecoder().decode(TapArgs.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(a.label.asLabel, "Slider")
        XCTAssertEqual(a.offset?.x, 12)
        XCTAssertEqual(a.offset?.y, 5)
        XCTAssertNil(a.offset?.xRatio)
    }

    func testLongPressArgs_DurationOptional() throws {
        let json = "{\"label\":\"Hold\",\"duration\":2.5}"
        let a = try JSONDecoder().decode(LongPressArgs.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(a.duration, 2.5)
    }

    func testInputArgs_RequiresLabelAndContent() throws {
        let json = "{\"label\":\"User\",\"content\":\"alice\"}"
        let a = try JSONDecoder().decode(InputArgs.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(a.label, "User")
        XCTAssertEqual(a.content, "alice")
    }

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

    func testSwipeArgs_AllFields() throws {
        let json = """
        {"to":"Developer","from":"Bluetooth","distance":100,"dir":"forth",\
        "traits":"Cell,Button"}
        """
        let a = try JSONDecoder().decode(SwipeArgs.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(a.to?.asLabel, "Developer")
        XCTAssertEqual(a.from?.asLabel, "Bluetooth")
        XCTAssertEqual(a.distance, 100)
        XCTAssertEqual(a.dir, .forth)
        XCTAssertEqual(a.traits, "Cell,Button")
    }

    func testSwipeArgs_AllOptional() throws {
        let a = try JSONDecoder().decode(SwipeArgs.self, from: "{}".data(using: .utf8)!)
        XCTAssertNil(a.to)
        XCTAssertNil(a.from)
        XCTAssertNil(a.distance)
        XCTAssertNil(a.dir)
    }

    func testSwipeArgs_ToIsPoint() throws {
        let json = "{\"to\":[100,200]}"
        let a = try JSONDecoder().decode(SwipeArgs.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(a.to?.asPoint, [100, 200])
    }

    func testOslogArgs_AllOptional() throws {
        let json = "{\"pattern\":\"error\",\"clear\":true,\"bundleId\":\"com.apple.Preferences\",\"timeout\":3}"
        let a = try JSONDecoder().decode(OslogArgs.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(a.pattern, "error")
        XCTAssertEqual(a.clear, true)
        XCTAssertEqual(a.bundleId, "com.apple.Preferences")
        XCTAssertEqual(a.timeout, 3)
        XCTAssertNil(a.name)
        XCTAssertNil(a.flags)
    }

    func testWaitForArgs_Decode() throws {
        let json = "{\"label\":\"Bluetooth\",\"timeout\":5}"
        let a = try JSONDecoder().decode(WaitForArgs.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(a.label, "Bluetooth")
        XCTAssertEqual(a.timeout, 5)
        XCTAssertNil(a.traits)
    }

    func testResolveTapPoint_DefaultsToCenter() throws {
        let point = try resolveTapPoint(frame: CGRect(x: 10, y: 20, width: 100, height: 40), offset: nil)
        XCTAssertEqual(point.x, 60)
        XCTAssertEqual(point.y, 40)
    }

    func testResolveTapPoint_UsesAbsoluteOffsetFromTopLeft() throws {
        let point = try resolveTapPoint(
            frame: CGRect(x: 10, y: 20, width: 100, height: 40),
            offset: TapOffset(x: 12, y: 5, xRatio: nil, yRatio: nil)
        )
        XCTAssertEqual(point.x, 22)
        XCTAssertEqual(point.y, 25)
    }

    func testResolveTapPoint_UsesRatioOffsetFromTopLeft() throws {
        let point = try resolveTapPoint(
            frame: CGRect(x: 10, y: 20, width: 100, height: 40),
            offset: TapOffset(x: nil, y: nil, xRatio: 0.8, yRatio: 0.5)
        )
        XCTAssertEqual(point.x, 90)
        XCTAssertEqual(point.y, 40)
    }

    func testResolveTapPoint_DefaultsMissingAxisToCenterRatio() throws {
        let point = try resolveTapPoint(
            frame: CGRect(x: 10, y: 20, width: 100, height: 40),
            offset: TapOffset(x: nil, y: nil, xRatio: 0.8, yRatio: nil)
        )
        XCTAssertEqual(point.x, 90)
        XCTAssertEqual(point.y, 40)
    }

    func testResolveTapPoint_DefaultsMissingAxisToCenterWhenUsingAbsoluteOffset() throws {
        let point = try resolveTapPoint(
            frame: CGRect(x: 10, y: 20, width: 100, height: 40),
            offset: TapOffset(x: 12, y: nil, xRatio: nil, yRatio: nil)
        )
        XCTAssertEqual(point.x, 22)
        XCTAssertEqual(point.y, 40)
    }

    func testResolveTapPoint_AllowsOutOfBoundsOffset() throws {
        let point = try resolveTapPoint(
            frame: CGRect(x: 10, y: 20, width: 100, height: 40),
            offset: TapOffset(x: 120, y: 5, xRatio: nil, yRatio: nil)
        )
        // frame.minX(10) + localX(120) = 130
        XCTAssertEqual(point.x, 130)
        // frame.minY(20) + localY(5) = 25
        XCTAssertEqual(point.y, 25)
    }

    func testMakeMatcher_WithFlags() throws {
        let matcher = try XCTUnwrap(makeMatcher(pattern: "error", flags: "i"))
        XCTAssertTrue(matcher("ERROR happened"))
        XCTAssertFalse(matcher("all good"))
    }

    func testFilterLines_WithoutMatcherReturnsOriginal() {
        let lines = ["a", "b"]
        XCTAssertEqual(filterLines(lines, matcher: nil), lines)
    }

    func testDomArgs_Raw() throws {
        let a = try JSONDecoder().decode(DomArgs.self, from: "{\"raw\":true}".data(using: .utf8)!)
        XCTAssertEqual(a.raw, true)
    }

    // MARK: - decodeArgs helper (doc 1.2)

    func testDecodeArgs_Missing_Throws() {
        XCTAssertThrowsError(try decodeArgs(nil, as: ActivateAppArgs.self))
    }

    func testDecodeArgs_Typed_OK() throws {
        let raw = AnyCodable(["bundleId": "com.apple.Preferences"])
        let decoded = try decodeArgs(raw, as: ActivateAppArgs.self)
        XCTAssertEqual(decoded.bundleId, "com.apple.Preferences")
    }

    func testDecodeArgsOptional_Absent_ReturnsNil() {
        let v = decodeArgsOptional(nil, as: OslogArgs.self)
        XCTAssertNil(v)
    }

    // MARK: - ResponseFrame / RequestFrame

    func testRequestFrame_WithNestedArgs() throws {
        let json = #"{"c":"tap","args":{"label":"OK"}}"#
        let req = try JSONDecoder().decode(RequestFrame.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(req.c, .tap)
        let tap = try decodeArgs(req.args, as: TapArgs.self)
        XCTAssertEqual(tap.label.asLabel, "OK")
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
        // Swift Character counts extended grapheme clusters; Chinese chars 1:1.
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

    func testFuzzySuggestions_SkipsBlankCandidates() {
        let candidates = [
            SearchCandidate(displayText: "", normalizedText: normalizeSearchText("")),
            SearchCandidate(displayText: "   ", normalizedText: normalizeSearchText("   ")),
            SearchCandidate(displayText: "天气", normalizedText: normalizeSearchText("天气")),
            SearchCandidate(displayText: "天气预报", normalizedText: normalizeSearchText("天气预报")),
        ]
        let suggestions = fuzzySuggestions(forNormalizedQuery: normalizeSearchText("天气"), from: candidates)
        XCTAssertEqual(suggestions.first, "天气")
        XCTAssertFalse(suggestions.contains(""))
    }

    func testFuzzySuggestions_UsesStrictThreshold() {
        let suggestions = fuzzySuggestions(forNormalizedQuery: normalizeSearchText("搜索"), from: [
            SearchCandidate(displayText: "设置", normalizedText: normalizeSearchText("设置")),
            SearchCandidate(displayText: "搜索", normalizedText: normalizeSearchText("搜索")),
            SearchCandidate(displayText: "搜", normalizedText: normalizeSearchText("搜")),
        ])
        XCTAssertTrue(suggestions.contains("搜索"))
        XCTAssertFalse(suggestions.contains("设置"))
    }

    func testFuzzySuggestions_ChineseTypo() {
        let suggestions = fuzzySuggestions(forNormalizedQuery: normalizeSearchText("天琪"), from: [
            SearchCandidate(displayText: "天气", normalizedText: normalizeSearchText("天气")),
            SearchCandidate(displayText: "日历", normalizedText: normalizeSearchText("日历")),
            SearchCandidate(displayText: "地图", normalizedText: normalizeSearchText("地图")),
        ])
        XCTAssertTrue(suggestions.contains("天气"))
    }

    func testFuzzySuggestions_WhitespaceDifference() {
        let suggestions = fuzzySuggestions(forNormalizedQuery: normalizeSearchText("编 辑"), from: [
            SearchCandidate(displayText: "编辑", normalizedText: normalizeSearchText("编辑")),
            SearchCandidate(displayText: "完成", normalizedText: normalizeSearchText("完成")),
            SearchCandidate(displayText: "取消", normalizedText: normalizeSearchText("取消")),
        ])
        XCTAssertTrue(suggestions.contains("编辑"))
    }

    func testFuzzySuggestions_CaseAndWhitespaceDifference() {
        let suggestions = fuzzySuggestions(forNormalizedQuery: normalizeSearchText("FAcetime通话"), from: [
            SearchCandidate(displayText: "FaceTime 通话", normalizedText: normalizeSearchText("FaceTime 通话")),
            SearchCandidate(displayText: "电话", normalizedText: normalizeSearchText("电话")),
            SearchCandidate(displayText: "信息", normalizedText: normalizeSearchText("信息")),
        ])
        XCTAssertTrue(suggestions.contains("FaceTime 通话"))
    }

    func testNormalizeSearchText_IgnoresWhitespaceCaseAndPunctuation() {
        XCTAssertEqual(normalizeSearchText(" 编 辑 "), "编辑")
        XCTAssertEqual(normalizeSearchText("FAcetime通话"), "facetime通话")
        XCTAssertEqual(normalizeSearchText("FaceTime 通话"), "facetime通话")
        XCTAssertEqual(normalizeSearchText("Wi-Fi"), "wifi")
    }

    func testSerializeDomForest_ReconstructsNestedTreeFromChildCount() {
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

        let dom = serializeDomForest(from: elements)

        XCTAssertEqual(dom.count, 1)
        XCTAssertEqual(dom[0]["l"] as? String, "Root")
        let children = dom[0]["c"] as? [[String: Any]]
        XCTAssertEqual(children?.count, 3)
        XCTAssertEqual(children?[0]["l"] as? String, "Child 1")
        XCTAssertEqual(children?[1]["l"] as? String, "Parent")
        let grandChildren = children?[1]["c"] as? [[String: Any]]
        XCTAssertEqual(grandChildren?.count, 1)
        XCTAssertEqual(grandChildren?[0]["l"] as? String, "Grandchild")
        XCTAssertEqual(children?[2]["l"] as? String, "Child 2")
    }

    func testSerializeDomForest_EmptyElementsReturnsEmptyDom() {
        XCTAssertTrue(serializeDomForest(from: []).isEmpty)
    }

    func testSerializeDomForest_ChildCountZeroSerializesLeafRect() {
        let leaf = makeElement(label: "Leaf", type: .button)
        let dom = serializeDomForest(from: [leaf])

        XCTAssertEqual(dom.count, 1)
        XCTAssertEqual(dom[0]["l"] as? String, "Leaf")
        XCTAssertNotNil(dom[0]["r"] as? [Double])
        XCTAssertNil(dom[0]["c"])
    }

    func testSerializeDomForest_StopsWhenChildCountExceedsRemainingElements() {
        let root = makeElement(label: "Root", type: .other)
        let child = makeElement(label: "Child", type: .button)
        let elements = [
            SnapshotElement(node: root.node, traits: root.traits, disabled: root.disabled, invisible: root.invisible, childCount: 2),
            child,
        ]

        let dom = serializeDomForest(from: elements)

        XCTAssertEqual(dom.count, 1)
        XCTAssertEqual(dom[0]["l"] as? String, "Root")
        let children = dom[0]["c"] as? [[String: Any]]
        XCTAssertEqual(children?.count, 1)
        XCTAssertEqual(children?.first?["l"] as? String, "Child")
    }

    func testDomCleaning_KeepsPromotedHomeScreenChildrenUnderParent() {
        let invisiblePage = FakeRawSnapshot(
            elementType: .icon,
            frame: .zero,
            isVisible: false,
            children: [
                FakeRawSnapshot(label: "天气", elementType: .icon, frame: .zero, isVisible: false),
            ]
        )
        let visiblePage = FakeRawSnapshot(
            elementType: .icon,
            frame: .zero,
            isVisible: false,
            children: [
                FakeRawSnapshot(label: "股市", elementType: .icon, frame: CGRect(x: 112, y: 65, width: 64, height: 87)),
                FakeRawSnapshot(label: "查找", elementType: .icon, frame: CGRect(x: 199, y: 65, width: 64, height: 87)),
            ]
        )
        let spotlight = FakeRawSnapshot(
            label: "spotlight-pill",
            elementType: .other,
            children: [
                FakeRawSnapshot(label: "搜索", elementType: .staticText, frame: CGRect(x: 183, y: 673, width: 24, height: 14)),
            ]
        )
        let home = FakeRawSnapshot(
            label: "Home screen icons",
            elementType: .other,
            children: [
                FakeRawSnapshot(
                    elementType: .other,
                    children: [
                        invisiblePage,
                        visiblePage,
                        spotlight,
                    ]
                ),
            ]
        )
        let rootRaw = FakeRawSnapshot(elementType: .window, children: [home])
        let root = SafeSnapshot(raw: rootRaw, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))

        let elements = buildCleanElements(from: root)
        let dom = serializeDomForest(from: elements)

        XCTAssertEqual(dom.count, 1)
        XCTAssertEqual(dom[0]["l"] as? String, "Home screen icons")
        let children = dom[0]["c"] as? [[String: Any]]
        XCTAssertEqual(children?.count, 3)
        XCTAssertEqual(children?[0]["tr"] as? [String], ["Icon", "invisible"])
        XCTAssertEqual(children?[1]["tr"] as? [String], ["Icon", "invisible"])
        XCTAssertEqual(children?[2]["l"] as? String, "spotlight-pill")

        let visibleIcons = children?[1]["c"] as? [[String: Any]]
        XCTAssertEqual(visibleIcons?.map { $0["l"] as? String }, ["股市", "查找"])
        XCTAssertFalse(dom.dropFirst().contains { ($0["l"] as? String) == "spotlight-pill" })
    }

    func testSearchableTexts_MergesLabelAndValueWithoutDuplicates() {
        XCTAssertEqual(
            searchableTexts(label: "搜索或输入网站", value: "搜索或输入网站"),
            ["搜索或输入网站"]
        )
        XCTAssertEqual(
            searchableTexts(label: "搜索", value: "搜索或输入网站"),
            ["搜索", "搜索或输入网站"]
        )
    }

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
        let element = makeElement(
            label: "FaceTime 通话",
            type: .button
        )
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

    func testRawFindInSnapshot_TraitFilter_CaseInsensitive() {
        let button = makeElement(label: "开关", type: .switch)
        let cs = makeCleanedSnapshot([button])

        switch rawFindInSnapshot("开关", traits: "Switch", cs: cs) {
        case .found(let found):
            XCTAssertEqual(found.node.elementType, XCUIElement.ElementType.switch.rawValue)
        default:
            XCTFail("expected trait filter to be case insensitive")
        }
    }

    func testRawFindInSnapshot_TraitFilter_Flags() {
        let element = makeElement(label: "蓝牙", type: .staticText)
        // Make it disabled
        let raw = FakeRawSnapshot(
            label: "蓝牙",
            elementType: .staticText,
            isEnabled: false
        )
        let snapshot = SafeSnapshot(raw: raw, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))
        let disabledElement = SnapshotElement(
            node: snapshot,
            traits: snapshotTraits(for: snapshot, disabled: true, invisible: false),
            disabled: true,
            invisible: false,
            childCount: 0
        )
        let cs = makeCleanedSnapshot([disabledElement])

        switch rawFindInSnapshot("蓝牙", traits: "disabled", cs: cs) {
        case .found(let found):
            XCTAssertTrue(found.traits.contains("disabled"))
        default:
            XCTFail("expected trait filter to match disabled flag")
        }
    }

    func testRawFindInSnapshot_TraitFilter_NoMatch() {
        let text = makeElement(label: "设置", type: .staticText)
        let cs = makeCleanedSnapshot([text])

        switch rawFindInSnapshot("设置", traits: "button", cs: cs) {
        case .notFound:
            break // expected
        default:
            XCTFail("expected trait filter to return notFound when no match")
        }
    }

    // MARK: - elementTypeName

    func testElementTypeName_OtherReturnsDash() {
        XCTAssertEqual(elementTypeName(.other), "-")
    }

    // MARK: - finalizeFindMatches (dedupe removed)

    func testFinalizeFindMatches_DoesNotDedupeAncestors() {
        let childRaw = FakeRawSnapshot(label: "设置", elementType: .staticText)
        let parentRaw = FakeRawSnapshot(label: "设置", elementType: .button, children: [childRaw])
        let parentNode = SafeSnapshot(raw: parentRaw, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))
        let childNode = parentNode.children[0]

        let parentElem = SnapshotElement(
            node: parentNode,
            traits: ["Button"],
            disabled: false,
            invisible: false,
            childCount: 1
        )
        let childElem = SnapshotElement(
            node: childNode,
            traits: ["StaticText"],
            disabled: false,
            invisible: false,
            childCount: 0
        )

        let cs = makeCleanedSnapshot([parentElem, childElem])

        switch rawFindInSnapshot("设置", cs: cs) {
        case .ambiguous(let matches):
            XCTAssertEqual(matches.count, 2, "dedupe removed: both ancestor and descendant should be returned")
        default:
            XCTFail("expected ambiguous with 2 matches after dedupe removal")
        }
    }

    // MARK: - descendantsOfType order (doc 5.5)

    func testCollectCellSnapshots_TopToBottomOrder() {
        let top = FakeRawSnapshot(label: "蓝牙", elementType: .cell, frame: CGRect(x: 0, y: 100, width: 375, height: 44))
        let mid = FakeRawSnapshot(label: "通用", elementType: .cell, frame: CGRect(x: 0, y: 200, width: 375, height: 44))
        let bottom = FakeRawSnapshot(label: "开发者", elementType: .cell, frame: CGRect(x: 0, y: 500, width: 375, height: 44))
        let scrollView = FakeRawSnapshot(
            elementType: .scrollView,
            children: [top, mid, bottom]
        )
        let root = SafeSnapshot(raw: scrollView, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))

        let cells = collectCellSnapshots(root)
        XCTAssertEqual(cells.map { $0.label }, ["蓝牙", "通用", "开发者"])
    }

    // MARK: - cleanTree Rule 6: same-label parent-child merge

    func testCleanTree_MergesSameLabelParentChild() {
        let grandchildRaw = FakeRawSnapshot(label: "文本", elementType: .staticText)
        let childRaw = FakeRawSnapshot(
            label: "WiFi",
            elementType: .button,
            children: [grandchildRaw]
        )
        let parentRaw = FakeRawSnapshot(
            label: "WiFi",
            elementType: .cell,
            children: [childRaw]
        )
        let root = SafeSnapshot(raw: parentRaw, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))

        let elements = buildCleanElements(from: root)

        // Should merge Cell + Button into one node because they share the same label.
        // Expected flat stream: [merged(Cell,Button,childCount=1), StaticText]
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements[0].traits, ["Cell", "Button"])
        XCTAssertEqual(elements[0].childCount, 1)
        XCTAssertEqual(elements[1].traits, ["StaticText"])
        XCTAssertEqual(elements[1].childCount, 0)
    }

    func testCleanTree_KeepsDifferentLabelParentChild() {
        let childRaw = FakeRawSnapshot(label: "子节点", elementType: .button)
        let parentRaw = FakeRawSnapshot(
            label: "父节点",
            elementType: .cell,
            children: [childRaw]
        )
        let root = SafeSnapshot(raw: parentRaw, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))

        let elements = buildCleanElements(from: root)

        // Labels differ, so Rule 6 should not merge.
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements[0].traits, ["Cell"])
        XCTAssertEqual(elements[0].childCount, 1)
        XCTAssertEqual(elements[1].traits, ["Button"])
        XCTAssertEqual(elements[1].childCount, 0)
    }

    // MARK: - FindArgs with traits

    func testFindArgs_WithTraits() throws {
        let json = "{\"label\":\"蓝牙\",\"traits\":\"switch\"}"
        let a = try JSONDecoder().decode(FindArgs.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(a.label, "蓝牙")
        XCTAssertEqual(a.traits, "switch")
    }

    func testFindArgs_TraitsOptional() throws {
        let json = "{\"label\":\"设置\"}"
        let a = try JSONDecoder().decode(FindArgs.self, from: json.data(using: .utf8)!)
        XCTAssertNil(a.traits)
    }

    // MARK: - Multi-trait AND filtering

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

    func testRawFindInSnapshot_MultiTraitAnd_MatchesTypeAndFlag() {
        let raw = FakeRawSnapshot(
            label: "蓝牙",
            elementType: .staticText,
            isEnabled: false
        )
        let snapshot = SafeSnapshot(raw: raw, appFrame: CGRect(x: 0, y: 0, width: 375, height: 812))
        let disabledElement = SnapshotElement(
            node: snapshot,
            traits: snapshotTraits(for: snapshot, disabled: true, invisible: false),
            disabled: true,
            invisible: false,
            childCount: 0
        )
        let cs = makeCleanedSnapshot([disabledElement])

        switch rawFindInSnapshot("蓝牙", traits: "statictext,disabled", cs: cs) {
        case .found(let found):
            XCTAssertTrue(found.traits.contains("disabled"))
        default:
            XCTFail("expected multi-trait AND to match")
        }
    }
}
