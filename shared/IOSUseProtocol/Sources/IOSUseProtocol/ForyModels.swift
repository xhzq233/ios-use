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
public struct ForyDomElement {
    public var traits: [String] = []
    public var childCount: Int32 = 0
    public var label: String = ""
    public var value: String = ""
    public var rect: ForyRect? = nil

    public init(traits: [String] = [], childCount: Int32 = 0, label: String = "", value: String = "", rect: ForyRect? = nil) {
        self.traits = traits
        self.childCount = childCount
        self.label = label
        self.value = value
        self.rect = rect
    }
}

@ForyStruct
public struct ForyDomPayload {
    public var app: String = ""
    public var windowSize: ForyPoint = ForyPoint()
    public var raw: String = ""
    public var elements: [ForyDomElement] = []

    public init(app: String = "", windowSize: ForyPoint = ForyPoint(), raw: String = "", elements: [ForyDomElement] = []) {
        self.app = app
        self.windowSize = windowSize
        self.raw = raw
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
    public var elemType: Int32 = 0
    public var label: String = ""
    public var rect: ForyRect? = nil
    public var ancestors: [String] = []

    public init(elemType: Int32 = 0, label: String = "", rect: ForyRect? = nil, ancestors: [String] = []) {
        self.elemType = elemType
        self.label = label
        self.rect = rect
        self.ancestors = ancestors
    }
}

@ForyStruct
public struct ForyWaitForPayload {
    public var element: ForyElementSummary = ForyElementSummary()
    public var waited: Double = 0

    public init(element: ForyElementSummary = ForyElementSummary(), waited: Double = 0) {
        self.element = element
        self.waited = waited
    }

    public init(elemType: Int32 = 0, label: String = "", rect: ForyRect? = nil, waited: Double = 0) {
        self.element = ForyElementSummary(elemType: elemType, label: label, rect: rect)
        self.waited = waited
    }
}

@ForyStruct
public struct ForyElementPayload {
    public var element: ForyElementSummary = ForyElementSummary()

    public init(element: ForyElementSummary = ForyElementSummary()) {
        self.element = element
    }

    public init(elemType: Int32 = 0, label: String = "", rect: ForyRect? = nil, ancestors: [String] = []) {
        self.element = ForyElementSummary(elemType: elemType, label: label, rect: rect, ancestors: ancestors)
    }
}

@ForyStruct
public struct ForySwipePayload {
    public var element: ForyElementSummary = ForyElementSummary()
    public var scrolls: Int32 = 0
    public var scrollDirection: String = ""

    public init(element: ForyElementSummary = ForyElementSummary(), scrolls: Int32 = 0, scrollDirection: String = "") {
        self.element = element
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

    public init(dismissed: Bool = false, text: String = "", button: String = "", reason: String = "") {
        self.dismissed = dismissed
        self.text = text
        self.button = button
        self.reason = reason
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

    public init(target: ForyTarget = ForyTarget(), content: String = "") {
        self.target = target
        self.content = content
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
        try! fory.register(ForyDomElement.self, name: "ForyDomElement")
        try! fory.register(ForyDomPayload.self, name: "ForyDomPayload")
        try! fory.register(ForyScreenshotPayload.self, name: "ForyScreenshotPayload")
        try! fory.register(ForyElementSummary.self, name: "ForyElementSummary")
        try! fory.register(ForyWaitForPayload.self, name: "ForyWaitForPayload")
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
        try! fory.register(ForyProxyCAPushArgs.self, name: "ForyProxyCAPushArgs")
        try! fory.register(ForyWaitAppForegroundArgs.self, name: "ForyWaitAppForegroundArgs")
        try! fory.register(ForyWaitAppForegroundPayload.self, name: "ForyWaitAppForegroundPayload")
        return fory
    }
}

public func createFory() -> Fory {
    ForyRegistry.create()
}
