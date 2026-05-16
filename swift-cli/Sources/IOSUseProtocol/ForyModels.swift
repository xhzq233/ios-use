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

    public init(label: String = "", point: ForyPoint? = nil) {
        self.label = label
        self.point = point
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
public struct ForyErrorPayload {
    public var hint: String = ""
    public var suggestions: [String] = []
    public var matches: [ForyFindMatch] = []
    public var atBoundary: Bool = false
    public var tooSmallToScroll: Bool = false
    public var direction: Int32 = -1
    public var minDragDistance: Double = 0
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

    public init(jpeg: Data = Data()) {
        self.jpeg = jpeg
    }
}

@ForyStruct
public struct ForyFindPayload {
    public var matches: [ForyFindMatch] = []
    public var hint: String = ""
    public var suggestions: [String] = []

    public init(matches: [ForyFindMatch] = [], hint: String = "", suggestions: [String] = []) {
        self.matches = matches
        self.hint = hint
        self.suggestions = suggestions
    }
}

@ForyStruct
public struct ForyWaitForPayload {
    public var elemType: Int32 = 0
    public var label: String = ""
    public var rect: ForyRect? = nil
    public var waited: Double = 0

    public init(elemType: Int32 = 0, label: String = "", rect: ForyRect? = nil, waited: Double = 0) {
        self.elemType = elemType
        self.label = label
        self.rect = rect
        self.waited = waited
    }
}

@ForyStruct
public struct ForyDomArgs {
    public var raw: Bool = false
    public var fresh: Bool = false

    public init(raw: Bool = false, fresh: Bool = false) {
        self.raw = raw
        self.fresh = fresh
    }
}

@ForyStruct
public struct ForyFindArgs {
    public var label: String = ""
    public var traits: String = ""

    public init(label: String = "", traits: String = "") {
        self.label = label
        self.traits = traits
    }
}

@ForyStruct
public struct ForyWaitForArgs {
    public var label: String = ""
    public var timeout: Double = 0
    public var traits: String = ""

    public init(label: String = "", timeout: Double = 0, traits: String = "") {
        self.label = label
        self.timeout = timeout
        self.traits = traits
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
        try! fory.register(ForyFindMatch.self, name: "ForyFindMatch")
        try! fory.register(ForyErrorPayload.self, name: "ForyErrorPayload")
        try! fory.register(ForyDomElement.self, name: "ForyDomElement")
        try! fory.register(ForyDomPayload.self, name: "ForyDomPayload")
        try! fory.register(ForyScreenshotPayload.self, name: "ForyScreenshotPayload")
        try! fory.register(ForyFindPayload.self, name: "ForyFindPayload")
        try! fory.register(ForyWaitForPayload.self, name: "ForyWaitForPayload")
        try! fory.register(ForyDomArgs.self, name: "ForyDomArgs")
        try! fory.register(ForyFindArgs.self, name: "ForyFindArgs")
        try! fory.register(ForyWaitForArgs.self, name: "ForyWaitForArgs")
        return fory
    }
}
