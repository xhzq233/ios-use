import Foundation
import Fory

// MARK: - Shared Types

@ForyStruct
struct ForyRect {
    var x: Int32 = 0
    var y: Int32 = 0
    var w: Int32 = 0
    var h: Int32 = 0
}

@ForyStruct
struct ForyPoint {
    var x: Double = 0
    var y: Double = 0
}

@ForyStruct
struct ForyTarget {
    var label: String = ""
    var point: ForyPoint? = nil
}

// MARK: - Frames

@ForyStruct
struct ForyRequestFrame {
    var command: String = ""
    var payload: Data = Data()
}

@ForyStruct
struct ForyResponseFrame {
    var ok: Bool = false
    var error: String = ""
    var payload: Data = Data()
}

// MARK: - Error

@ForyStruct
struct ForyErrorPayload {
    var hint: String = ""
    var suggestions: [String] = []
    var matches: [ForyFindMatch] = []
    var atBoundary: Bool = false
    var tooSmallToScroll: Bool = false
    var direction: Int32 = -1
    var minDragDistance: Double = 0
}

// MARK: - DOM

@ForyStruct
struct ForyDomElement {
    var traits: [String] = []
    var childCount: Int32 = 0
    var label: String = ""
    var value: String = ""
    var rect: ForyRect? = nil
}

@ForyStruct
struct ForyDomPayload {
    var app: String = ""
    var windowSize: ForyPoint = ForyPoint()
    var raw: String = ""
    var elements: [ForyDomElement] = []
}

// MARK: - Screenshot

@ForyStruct
struct ForyScreenshotPayload {
    var jpeg: Data = Data()
}

// MARK: - Find

@ForyStruct
struct ForyFindMatch {
    var elemType: Int32 = 0
    var label: String = ""
    var rect: ForyRect? = nil
    var traits: [String] = []
    var value: String = ""
    var ancestors: [String] = []
}

@ForyStruct
struct ForyFindPayload {
    var matches: [ForyFindMatch] = []
    var hint: String = ""
    var suggestions: [String] = []
}

// MARK: - Element (tap/longPress/input)

@ForyStruct
struct ForyElementPayload {
    var elemType: Int32 = 0
    var label: String = ""
    var rect: ForyRect? = nil
}

// MARK: - Swipe

@ForyStruct
struct ForySwipePayload {
    var ancestors: [String] = []
    var elemType: Int32 = 0
    var label: String = ""
    var rect: ForyRect? = nil
    var scrolls: Int32 = 0
}

// MARK: - WaitFor

@ForyStruct
struct ForyWaitForPayload {
    var elemType: Int32 = 0
    var label: String = ""
    var rect: ForyRect? = nil
    var waited: Double = 0
}

// MARK: - Alert

@ForyStruct
struct ForyAlertPayload {
    var dismissed: Bool = false
    var text: String = ""
    var button: String = ""
    var reason: String = ""
}

// MARK: - Proxy

@ForyStruct
struct ForyProxyPayload {
    var status: String = ""
}

// MARK: - Simple String

@ForyStruct
struct ForySimpleStringPayload {
    var value: String = ""
}

// MARK: - Request Args

@ForyStruct
struct ForyCreateSessionArgs {
    var bundleId: String = ""
    var terminate: Bool = false
}

@ForyStruct
struct ForyActivateAppArgs {
    var bundleId: String = ""
}

@ForyStruct
struct ForyTerminateAppArgs {
    var bundleId: String = ""
}

@ForyStruct
struct ForyOpenURLArgs {
    var url: String = ""
}

@ForyStruct
struct ForyDomArgs {
    var raw: Bool = false
    var fresh: Bool = false
}

@ForyStruct
struct ForyFindArgs {
    var label: String = ""
    var traits: String = ""
}

@ForyStruct
struct ForyInputArgs {
    var label: String = ""
    var content: String = ""
    var traits: String = ""
}

@ForyStruct
struct ForyWaitForArgs {
    var label: String = ""
    var timeout: Double = 0
    var traits: String = ""
}

@ForyStruct
struct ForyTapArgs {
    var target: ForyTarget = ForyTarget()
    var traits: String = ""
    var offset: ForyPoint? = nil
    var ratio: ForyPoint = ForyPoint(x: 0.5, y: 0.5)
}

@ForyStruct
struct ForyLongPressArgs {
    var target: ForyTarget = ForyTarget()
    var duration: Double = 0
    var traits: String = ""
}

@ForyStruct
struct ForySwipeArgs {
    var toTarget: ForyTarget = ForyTarget()
    var fromTarget: ForyTarget = ForyTarget()
    var distance: Double = 0
    var dir: Int32 = 0
    var traits: String = ""
}

@ForyStruct
struct ForyDismissAlertArgs {
    var index: Int32 = -1
}

@ForyStruct
struct ForyProxyCAPushArgs {
    var caBase64: String = ""
}

// MARK: - Fory Registration

func createFory() -> Fory {
    let fory = Fory()
    // Shared types (must be registered before types that reference them)
    try! fory.register(ForyRect.self, name: "ForyRect")
    try! fory.register(ForyPoint.self, name: "ForyPoint")
    try! fory.register(ForyTarget.self, name: "ForyTarget")
    // Frames
    try! fory.register(ForyRequestFrame.self, name: "ForyRequestFrame")
    try! fory.register(ForyResponseFrame.self, name: "ForyResponseFrame")
    // DOM
    try! fory.register(ForyDomElement.self, name: "ForyDomElement")
    try! fory.register(ForyDomPayload.self, name: "ForyDomPayload")
    // Screenshot
    try! fory.register(ForyScreenshotPayload.self, name: "ForyScreenshotPayload")
    // Find
    try! fory.register(ForyFindMatch.self, name: "ForyFindMatch")
    // Error
    try! fory.register(ForyErrorPayload.self, name: "ForyErrorPayload")
    try! fory.register(ForyFindPayload.self, name: "ForyFindPayload")
    // Element
    try! fory.register(ForyElementPayload.self, name: "ForyElementPayload")
    // Swipe
    try! fory.register(ForySwipePayload.self, name: "ForySwipePayload")
    // WaitFor
    try! fory.register(ForyWaitForPayload.self, name: "ForyWaitForPayload")
    // Alert
    try! fory.register(ForyAlertPayload.self, name: "ForyAlertPayload")
    // Proxy
    try! fory.register(ForyProxyPayload.self, name: "ForyProxyPayload")
    // Simple String
    try! fory.register(ForySimpleStringPayload.self, name: "ForySimpleStringPayload")
    // Request Args
    try! fory.register(ForyCreateSessionArgs.self, name: "ForyCreateSessionArgs")
    try! fory.register(ForyActivateAppArgs.self, name: "ForyActivateAppArgs")
    try! fory.register(ForyTerminateAppArgs.self, name: "ForyTerminateAppArgs")
    try! fory.register(ForyOpenURLArgs.self, name: "ForyOpenURLArgs")
    try! fory.register(ForyDomArgs.self, name: "ForyDomArgs")
    try! fory.register(ForyFindArgs.self, name: "ForyFindArgs")
    try! fory.register(ForyInputArgs.self, name: "ForyInputArgs")
    try! fory.register(ForyWaitForArgs.self, name: "ForyWaitForArgs")
    try! fory.register(ForyTapArgs.self, name: "ForyTapArgs")
    try! fory.register(ForyLongPressArgs.self, name: "ForyLongPressArgs")
    try! fory.register(ForySwipeArgs.self, name: "ForySwipeArgs")
    try! fory.register(ForyDismissAlertArgs.self, name: "ForyDismissAlertArgs")
    try! fory.register(ForyProxyCAPushArgs.self, name: "ForyProxyCAPushArgs")
    return fory
}
