import Foundation
import Fory

@ForyStruct
public struct ForyRect {
    public var x: Int32 = 0
    public var y: Int32 = 0
    public var w: Int32 = 0
    public var h: Int32 = 0

    public init(x: Int32 = 0, y: Int32 = 0, w: Int32 = 0, h: Int32 = 0) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

@ForyStruct
public struct ForyPoint {
    public var x: Double = 0
    public var y: Double = 0

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

@ForyStruct
public struct ForyTarget {
    public var label: String = ""
    public var point: ForyPoint? = nil
    public var traits: String = ""
    public var cindex: Int32? = nil

    public init(label: String = "", point: ForyPoint? = nil, traits: String = "", cindex: Int32? = nil) {
        self.label = label
        self.point = point
        self.traits = traits
        self.cindex = cindex
    }
}

@ForyStruct
public struct ForyRequestFrame {
    public var command: String = ""
    public var payload: Data = Data()

    public init(command: String = "", payload: Data = Data()) {
        self.command = command
        self.payload = payload
    }
}

@ForyStruct
public struct ForyResponseFrame {
    public var ok: Bool = false
    public var error: String = ""
    public var payload: Data = Data()

    public init(ok: Bool = false, error: String = "", payload: Data = Data()) {
        self.ok = ok
        self.error = error
        self.payload = payload
    }
}

@ForyStruct
public struct ForyEmptyPayload {
    public init() {}
}

@ForyStruct
public struct ForyFindMatch {
    public var elemType: Int32 = 0
    public var label: String = ""
    public var rect: ForyRect? = nil
    public var traits: [String] = []
    public var value: String = ""
    public var ancestors: [String] = []

    public init(elemType: Int32 = 0, label: String = "", rect: ForyRect? = nil, traits: [String] = [], value: String = "", ancestors: [String] = []) {
        self.elemType = elemType
        self.label = label
        self.rect = rect
        self.traits = traits
        self.value = value
        self.ancestors = ancestors
    }
}

@ForyStruct
public struct ForyErrorCandidate {
    public var element: ForyFindMatch = ForyFindMatch()
    public var rejectedBy: [String] = []

    public init(element: ForyFindMatch = ForyFindMatch(), rejectedBy: [String] = []) {
        self.element = element
        self.rejectedBy = rejectedBy
    }
}

@ForyStruct
public struct ForyErrorPayload {
    public var category: String = ""
    public var code: String = ""
    public var phase: String = ""
    public var retryable: Bool = false
    public var fatal: Bool = false
    public var target: ForyTarget? = nil
    public var candidateCount: Int32 = 0
    public var suggestions: [String] = []
    public var candidates: [ForyErrorCandidate] = []

    public init(
        category: String = "",
        code: String = "",
        phase: String = "",
        retryable: Bool = false,
        fatal: Bool = false,
        target: ForyTarget? = nil,
        candidateCount: Int32 = 0,
        suggestions: [String] = [],
        candidates: [ForyErrorCandidate] = []
    ) {
        self.category = category
        self.code = code
        self.phase = phase
        self.retryable = retryable
        self.fatal = fatal
        self.target = target
        self.candidateCount = candidateCount
        self.suggestions = suggestions
        self.candidates = candidates
    }
}

@ForyStruct
public struct ForyElementState {
    public var enabled: Bool = false
    public var visible: Bool = false
    public var selected: Bool = false
    public var focused: Bool = false
    public var opaque: Bool = false

    public init(
        enabled: Bool = false,
        visible: Bool = false,
        selected: Bool = false,
        focused: Bool = false,
        opaque: Bool = false
    ) {
        self.enabled = enabled
        self.visible = visible
        self.selected = selected
        self.focused = focused
        self.opaque = opaque
    }
}

@ForyStruct
public struct ForyElementHierarchy {
    public var parentID: String = ""
    public var depth: Int32 = 0
    public var index: Int32 = 0
    public var path: [String] = []

    public init(
        parentID: String = "",
        depth: Int32 = 0,
        index: Int32 = 0,
        path: [String] = []
    ) {
        self.parentID = parentID
        self.depth = depth
        self.index = index
        self.path = path
    }
}

@ForyStruct
public struct ForyDomElement {
    public var nodeID: String = ""
    public var type: String = ""
    public var elementType: Int32 = 0
    public var traits: [String] = []
    public var childCount: Int32 = 0
    public var label: String = ""
    public var value: String = ""
    public var identifier: String = ""
    public var hint: String = ""
    public var className: String = ""
    public var state: ForyElementState = ForyElementState()
    public var hierarchy: ForyElementHierarchy = ForyElementHierarchy()
    public var ancestors: [String] = []
    public var zOrder: Int32 = 0
    public var snapshotGeneration: Int64 = 0
    public var rect: ForyRect? = nil

    public init(
        nodeID: String = "",
        type: String = "",
        elementType: Int32 = 0,
        traits: [String] = [],
        childCount: Int32 = 0,
        label: String = "",
        value: String = "",
        identifier: String = "",
        hint: String = "",
        className: String = "",
        state: ForyElementState = ForyElementState(),
        hierarchy: ForyElementHierarchy = ForyElementHierarchy(),
        ancestors: [String] = [],
        zOrder: Int32 = 0,
        snapshotGeneration: Int64 = 0,
        rect: ForyRect? = nil
    ) {
        self.nodeID = nodeID
        self.type = type
        self.elementType = elementType
        self.traits = traits
        self.childCount = childCount
        self.label = label
        self.value = value
        self.identifier = identifier
        self.hint = hint
        self.className = className
        self.state = state
        self.hierarchy = hierarchy
        self.ancestors = ancestors
        self.zOrder = zOrder
        self.snapshotGeneration = snapshotGeneration
        self.rect = rect
    }
}

@ForyStruct
public struct ForyDomPayload {
    public var app: String = ""
    public var windowSize: ForyPoint = ForyPoint()
    public var raw: String = ""
    public var snapshotGeneration: Int64 = 0
    public var elements: [ForyDomElement] = []

    public init(
        app: String = "",
        windowSize: ForyPoint = ForyPoint(),
        raw: String = "",
        snapshotGeneration: Int64 = 0,
        elements: [ForyDomElement] = []
    ) {
        self.app = app
        self.windowSize = windowSize
        self.raw = raw
        self.snapshotGeneration = snapshotGeneration
        self.elements = elements
    }
}

@ForyStruct
public struct ForyScreenshotPayload {
    public var jpeg: Data = Data()
    /// The current screen coordinate space in logical points, when the driver
    /// can report it reliably. A zero value asks the host to resolve geometry.
    public var logicalSize: ForyPoint = ForyPoint()
    /// The UIKit screen scale used for the screenshot coordinate space.
    public var scale: Double = 0

    public init(jpeg: Data = Data(), logicalSize: ForyPoint = ForyPoint(), scale: Double = 0) {
        self.jpeg = jpeg
        self.logicalSize = logicalSize
        self.scale = scale
    }
}

@ForyStruct
public struct ForyElementSummary {
    public var nodeID: String = ""
    public var type: String = ""
    public var elemType: Int32 = 0
    public var label: String = ""
    public var value: String = ""
    public var identifier: String = ""
    public var hint: String = ""
    public var className: String = ""
    public var traits: [String] = []
    public var state: ForyElementState = ForyElementState()
    public var rect: ForyRect? = nil
    public var hierarchy: ForyElementHierarchy = ForyElementHierarchy()
    public var ancestors: [String] = []
    public var zOrder: Int32 = 0
    public var snapshotGeneration: Int64 = 0

    public init(
        nodeID: String = "",
        type: String = "",
        elemType: Int32 = 0,
        label: String = "",
        value: String = "",
        identifier: String = "",
        hint: String = "",
        className: String = "",
        traits: [String] = [],
        state: ForyElementState = ForyElementState(),
        rect: ForyRect? = nil,
        hierarchy: ForyElementHierarchy = ForyElementHierarchy(),
        ancestors: [String] = [],
        zOrder: Int32 = 0,
        snapshotGeneration: Int64 = 0
    ) {
        self.nodeID = nodeID
        self.type = type
        self.elemType = elemType
        self.label = label
        self.value = value
        self.identifier = identifier
        self.hint = hint
        self.className = className
        self.traits = traits
        self.state = state
        self.rect = rect
        self.hierarchy = hierarchy
        self.ancestors = ancestors
        self.zOrder = zOrder
        self.snapshotGeneration = snapshotGeneration
    }
}

@ForyStruct
public struct ForyWaitForPayload {
    public var element: ForyElementSummary = ForyElementSummary()
    public var waited: Double = 0
    public var snapshotGeneration: Int64 = 0

    public init(
        element: ForyElementSummary = ForyElementSummary(),
        waited: Double = 0,
        snapshotGeneration: Int64 = 0
    ) {
        self.element = element
        self.waited = waited
        self.snapshotGeneration = snapshotGeneration
    }

    public init(elemType: Int32 = 0, label: String = "", rect: ForyRect? = nil, waited: Double = 0) {
        self.element = ForyElementSummary(elemType: elemType, label: label, rect: rect)
        self.waited = waited
    }
}

@ForyStruct
public struct ForyHitView {
    public var className: String = ""
    public var rect: ForyRect? = nil
    public var accessibilityIdentifier: String = ""
    public var label: String = ""

    public init(
        className: String = "",
        rect: ForyRect? = nil,
        accessibilityIdentifier: String = "",
        label: String = ""
    ) {
        self.className = className
        self.rect = rect
        self.accessibilityIdentifier = accessibilityIdentifier
        self.label = label
    }
}

@ForyStruct
public struct ForyTouchFinalState {
    public var point: ForyPoint = ForyPoint()
    public var touchID: Int64 = 0
    public var phase: String = ""
    public var firstResponderClass: String = ""

    public init(
        point: ForyPoint = ForyPoint(),
        touchID: Int64 = 0,
        phase: String = "",
        firstResponderClass: String = ""
    ) {
        self.point = point
        self.touchID = touchID
        self.phase = phase
        self.firstResponderClass = firstResponderClass
    }
}

@ForyStruct
public struct ForyPixelPostcondition {
    public var beforeHash: String = ""
    public var afterHash: String = ""
    public var beforeCaptureGeneration: Int64 = 0
    public var afterCaptureGeneration: Int64 = 0
    public var logicalX: Double = 0
    public var logicalY: Double = 0
    public var logicalWidth: Double = 0
    public var logicalHeight: Double = 0
    public var changed: Bool = false

    public init(
        beforeHash: String = "",
        afterHash: String = "",
        beforeCaptureGeneration: Int64 = 0,
        afterCaptureGeneration: Int64 = 0,
        logicalX: Double = 0,
        logicalY: Double = 0,
        logicalWidth: Double = 0,
        logicalHeight: Double = 0,
        changed: Bool = false
    ) {
        self.beforeHash = beforeHash
        self.afterHash = afterHash
        self.beforeCaptureGeneration =
            beforeCaptureGeneration
        self.afterCaptureGeneration =
            afterCaptureGeneration
        self.logicalX = logicalX
        self.logicalY = logicalY
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.changed = changed
    }
}

@ForyStruct
public struct ForyActionPostcondition {
    public var snapshotGeneration: Int64 = 0
    public var element: ForyElementSummary? = nil
    public var changed: Bool = false
    public var domChanged: Bool = false
    public var pixelEvidence: ForyPixelPostcondition? = nil

    public init(
        snapshotGeneration: Int64 = 0,
        element: ForyElementSummary? = nil,
        changed: Bool = false,
        domChanged: Bool = false,
        pixelEvidence: ForyPixelPostcondition? = nil
    ) {
        self.snapshotGeneration = snapshotGeneration
        self.element = element
        self.changed = changed
        self.domChanged = domChanged
        self.pixelEvidence = pixelEvidence
    }
}

@ForyStruct
public struct ForyElementPayload {
    public var element: ForyElementSummary = ForyElementSummary()
    public var hitView: ForyHitView? = nil
    public var finalState: ForyTouchFinalState? = nil
    public var postcondition: ForyActionPostcondition? = nil

    public init(
        element: ForyElementSummary,
        hitView: ForyHitView? = nil,
        finalState: ForyTouchFinalState? = nil,
        postcondition: ForyActionPostcondition? = nil
    ) {
        self.element = element
        self.hitView = hitView
        self.finalState = finalState
        self.postcondition = postcondition
    }

    public init(elemType: Int32 = 0, label: String = "", rect: ForyRect? = nil, ancestors: [String] = []) {
        self.element = ForyElementSummary(elemType: elemType, label: label, rect: rect, ancestors: ancestors)
    }
}

@ForyStruct
public struct ForySwipePayload {
    public var element: ForyElementSummary = ForyElementSummary()
    public var hitView: ForyHitView? = nil
    public var finalState: ForyTouchFinalState? = nil
    public var postcondition: ForyActionPostcondition? = nil
    public var scrolls: Int32 = 0
    public var scrollDirection: String = ""

    public init(
        element: ForyElementSummary,
        hitView: ForyHitView? = nil,
        finalState: ForyTouchFinalState? = nil,
        postcondition: ForyActionPostcondition? = nil,
        scrolls: Int32 = 0,
        scrollDirection: String = ""
    ) {
        self.element = element
        self.hitView = hitView
        self.finalState = finalState
        self.postcondition = postcondition
        self.scrolls = scrolls
        self.scrollDirection = scrollDirection
    }

    public init(ancestors: [String] = [], elemType: Int32 = 0, label: String = "", rect: ForyRect? = nil, scrolls: Int32 = 0, scrollDirection: String = "") {
        self.element = ForyElementSummary(elemType: elemType, label: label, rect: rect, ancestors: ancestors)
        self.scrolls = scrolls
        self.scrollDirection = scrollDirection
    }
}

@ForyStruct
public struct ForyAlertPayload {
    public var dismissed: Bool = false
    public var text: String = ""
    public var button: String = ""
    public var reason: String = ""
    public var hitView: ForyHitView? = nil
    public var finalState: ForyTouchFinalState? = nil
    public var postcondition: ForyActionPostcondition? = nil

    public init(
        dismissed: Bool = false,
        text: String = "",
        button: String = "",
        reason: String = "",
        hitView: ForyHitView? = nil,
        finalState: ForyTouchFinalState? = nil,
        postcondition: ForyActionPostcondition? = nil
    ) {
        self.dismissed = dismissed
        self.text = text
        self.button = button
        self.reason = reason
        self.hitView = hitView
        self.finalState = finalState
        self.postcondition = postcondition
    }
}

@ForyStruct
public struct ForySimpleStringPayload {
    public var value: String = ""

    public init(value: String = "") {
        self.value = value
    }
}

@ForyStruct
public struct ForyProxyPayload {
    public var status: String = ""

    public init(status: String = "") {
        self.status = status
    }
}

@ForyStruct
public struct ForyActivateAppArgs {
    public var bundleId: String = ""

    public init(bundleId: String = "") {
        self.bundleId = bundleId
    }
}

@ForyStruct
public struct ForyTerminateAppArgs {
    public var bundleId: String = ""

    public init(bundleId: String = "") {
        self.bundleId = bundleId
    }
}

@ForyStruct
public struct ForyDomArgs {
    public var raw: Bool = false
    public var fresh: Bool = false
    public var waitQuiescence: Bool = false

    public init(raw: Bool = false, fresh: Bool = false, waitQuiescence: Bool = false) {
        self.raw = raw
        self.fresh = fresh
        self.waitQuiescence = waitQuiescence
    }
}

@ForyStruct
public struct ForyWaitForArgs {
    public var target: ForyTarget = ForyTarget()
    public var timeout: Double = 0
    public var gone: Bool = false
    public var matchMode: Int32 = IOSUseWaitForMatchMode.standard.rawValue

    public init(
        target: ForyTarget = ForyTarget(),
        timeout: Double = 0,
        gone: Bool = false,
        matchMode: Int32 = IOSUseWaitForMatchMode.standard.rawValue
    ) {
        self.target = target
        self.timeout = timeout
        self.gone = gone
        self.matchMode = matchMode
    }
}

@ForyStruct
public struct ForyInputArgs {
    public var target: ForyTarget = ForyTarget()
    public var content: String = ""
    public var deleteCount: Int32 = 0
    public var enter: Bool = false

    public init(
        target: ForyTarget = ForyTarget(),
        content: String = "",
        deleteCount: Int32 = 0,
        enter: Bool = false
    ) {
        self.target = target
        self.content = content
        self.deleteCount = deleteCount
        self.enter = enter
    }
}

@ForyStruct
public struct ForyTapArgs {
    public var target: ForyTarget = ForyTarget()
    public var offset: ForyPoint? = nil
    public var ratio: ForyPoint = ForyPoint(x: IOSUseProtocol.defaultTargetRatio, y: IOSUseProtocol.defaultTargetRatio)

    public init(target: ForyTarget = ForyTarget(), offset: ForyPoint? = nil, ratio: ForyPoint = ForyPoint(x: IOSUseProtocol.defaultTargetRatio, y: IOSUseProtocol.defaultTargetRatio)) {
        self.target = target
        self.offset = offset
        self.ratio = ratio
    }
}

@ForyStruct
public struct ForyLongPressArgs {
    public var target: ForyTarget = ForyTarget()
    public var duration: Double = 0

    public init(target: ForyTarget = ForyTarget(), duration: Double = 0) {
        self.target = target
        self.duration = duration
    }
}

@ForyStruct
public struct ForySwipeArgs {
    public var toTarget: ForyTarget = ForyTarget()
    public var fromTarget: ForyTarget = ForyTarget()
    public var distance: Double = 0
    public var dir: Int32 = IOSUseProtocol.XCConstants.swipeDirectionUnspecified

    public init(toTarget: ForyTarget = ForyTarget(), fromTarget: ForyTarget = ForyTarget(), distance: Double = 0, dir: Int32 = IOSUseProtocol.XCConstants.swipeDirectionUnspecified) {
        self.toTarget = toTarget
        self.fromTarget = fromTarget
        self.distance = distance
        self.dir = dir
    }
}

@ForyStruct
public struct ForyDismissAlertArgs {
    public var index: Int32 = IOSUseProtocol.XCConstants.defaultAlertButtonIndex

    public init(index: Int32 = IOSUseProtocol.XCConstants.defaultAlertButtonIndex) {
        self.index = index
    }
}

@ForyStruct
public struct ForyDismissAlertByLabelArgs {
    public var label: String = ""

    public init(label: String = "") {
        self.label = label
    }
}

@ForyStruct
public struct ForyProxyCAPushArgs {
    public var caBase64: String = ""

    public init(caBase64: String = "") {
        self.caBase64 = caBase64
    }
}

@ForyStruct
public struct ForyWaitAppForegroundArgs {
    /// Empty means the currently foreground interactive application.
    public var expectedBundleId: String = ""
    /// When expectedBundleId is empty, wait for any foreground app in this set.
    /// An empty set preserves the "any foreground app" behavior.
    public var acceptedBundleIds: [String] = []
    /// Zero selects IOSUseProtocol.appForegroundTimeoutSeconds.
    public var timeout: Double = 0
    /// Include the successful readiness snapshot in the response.
    public var returnDom: Bool = false

    public init(
        expectedBundleId: String = "",
        acceptedBundleIds: [String] = [],
        timeout: Double = 0,
        returnDom: Bool = false
    ) {
        self.expectedBundleId = expectedBundleId
        self.acceptedBundleIds = acceptedBundleIds
        self.timeout = timeout
        self.returnDom = returnDom
    }
}

@ForyStruct
public struct ForyWaitAppForegroundPayload {
    public var expectedBundleId: String = ""
    public var activeBundleId: String = ""
    public var appState: Int32 = IOSUseAppState.unknown.rawValue
    public var snapshotReady: Bool = false
    public var elapsed: Double = 0
    public var dom: ForyDomPayload? = nil

    public init(
        expectedBundleId: String = "",
        activeBundleId: String = "",
        appState: Int32 = IOSUseAppState.unknown.rawValue,
        snapshotReady: Bool = false,
        elapsed: Double = 0,
        dom: ForyDomPayload? = nil
    ) {
        self.expectedBundleId = expectedBundleId
        self.activeBundleId = activeBundleId
        self.appState = appState
        self.snapshotReady = snapshotReady
        self.elapsed = elapsed
        self.dom = dom
    }
}

public enum ForyRegistry {
    public static func create() -> Fory {
        let fory = Fory()
        try! fory.register(ForyRect.self, name: "ForyRect")
        try! fory.register(ForyPoint.self, name: "ForyPoint")
        try! fory.register(ForyTarget.self, name: "ForyTarget")
        try! fory.register(ForyRequestFrame.self, name: "ForyRequestFrame")
        try! fory.register(ForyResponseFrame.self, name: "ForyResponseFrame")
        try! fory.register(ForyEmptyPayload.self, name: "ForyEmptyPayload")
        try! fory.register(ForyFindMatch.self, name: "ForyFindMatch")
        try! fory.register(ForyErrorCandidate.self, name: "ForyErrorCandidate")
        try! fory.register(ForyErrorPayload.self, name: "ForyErrorPayload")
        try! fory.register(ForyElementState.self, name: "ForyElementState")
        try! fory.register(ForyElementHierarchy.self, name: "ForyElementHierarchy")
        try! fory.register(ForyDomElement.self, name: "ForyDomElement")
        try! fory.register(ForyDomPayload.self, name: "ForyDomPayload")
        try! fory.register(ForyScreenshotPayload.self, name: "ForyScreenshotPayload")
        try! fory.register(ForyElementSummary.self, name: "ForyElementSummary")
        try! fory.register(ForyWaitForPayload.self, name: "ForyWaitForPayload")
        try! fory.register(ForyHitView.self, name: "ForyHitView")
        try! fory.register(ForyTouchFinalState.self, name: "ForyTouchFinalState")
        try! fory.register(ForyPixelPostcondition.self, name: "ForyPixelPostcondition")
        try! fory.register(ForyActionPostcondition.self, name: "ForyActionPostcondition")
        try! fory.register(ForyElementPayload.self, name: "ForyElementPayload")
        try! fory.register(ForySwipePayload.self, name: "ForySwipePayload")
        try! fory.register(ForyAlertPayload.self, name: "ForyAlertPayload")
        try! fory.register(ForySimpleStringPayload.self, name: "ForySimpleStringPayload")
        try! fory.register(ForyProxyPayload.self, name: "ForyProxyPayload")
        try! fory.register(ForyActivateAppArgs.self, name: "ForyActivateAppArgs")
        try! fory.register(ForyTerminateAppArgs.self, name: "ForyTerminateAppArgs")
        try! fory.register(ForyDomArgs.self, name: "ForyDomArgs")
        try! fory.register(ForyWaitForArgs.self, name: "ForyWaitForArgs")
        try! fory.register(ForyInputArgs.self, name: "ForyInputArgs")
        try! fory.register(ForyTapArgs.self, name: "ForyTapArgs")
        try! fory.register(ForyLongPressArgs.self, name: "ForyLongPressArgs")
        try! fory.register(ForySwipeArgs.self, name: "ForySwipeArgs")
        try! fory.register(ForyDismissAlertArgs.self, name: "ForyDismissAlertArgs")
        try! fory.register(ForyDismissAlertByLabelArgs.self, name: "ForyDismissAlertByLabelArgs")
        try! fory.register(ForyProxyCAPushArgs.self, name: "ForyProxyCAPushArgs")
        try! fory.register(ForyWaitAppForegroundArgs.self, name: "ForyWaitAppForegroundArgs")
        try! fory.register(ForyWaitAppForegroundPayload.self, name: "ForyWaitAppForegroundPayload")
        return fory
    }
}

public func createFory() -> Fory {
    ForyRegistry.create()
}
