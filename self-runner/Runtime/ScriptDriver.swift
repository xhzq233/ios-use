import Foundation
import XCTest
import Fory

@objc(IOSUseSelfRunnerDriver)
final class ScriptDriver: NSObject {
    @objc(execute:arguments:error:)
    static func execute(_ command: String, arguments args: NSDictionary) throws -> NSDictionary {
        precondition(Thread.isMainThread)
        XCPrepareDisplays()
        func number(_ key: String, default fallback: Double = 0) throws -> Double {
            guard let raw = args[key] else { return fallback }
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
                throw DriverError.invalidArgs("\(key) must be a finite number")
            }
            return n.doubleValue
        }
        func text(_ key: String, required: Bool = false) throws -> String {
            guard let value = args[key] else {
                if required { throw DriverError.invalidArgs("Missing \(key)") }
                return ""
            }
            guard let value = value as? String, !required || !value.isEmpty else { throw DriverError.invalidArgs("Invalid \(key)") }
            return value
        }
        func target(prefix: String = "") throws -> ForyTarget {
            let label = try text(prefix.isEmpty ? "label" : prefix + "Label")
            let xKey = prefix.isEmpty ? "x" : prefix + "X", yKey = prefix.isEmpty ? "y" : prefix + "Y"
            if args[xKey] != nil || args[yKey] != nil {
                guard args[xKey] != nil, args[yKey] != nil, label.isEmpty else { throw DriverError.invalidArgs("Supply label or both x and y") }
                return ForyTarget(point: ForyPoint(x: try number(xKey), y: try number(yKey)))
            }
            guard !label.isEmpty else { throw DriverError.invalidArgs("Supply a target label or x/y") }
            return ForyTarget(label: label, traits: try text("traits"))
        }
        let response: ForyResponseFrame
        switch command {
        case "activateApp": response = try AppCommands.activateApp(ForyActivateAppArgs(bundleId: text("bundleID", required: true)))
        case "home": response = try AppCommands.home()
        case "dom": response = try DomCommands.dom(ForyDomArgs(raw: true))
        case "screenshot": response = try ScreenCommands.screenshot()
        case "tap": response = try TouchCommands.tap(ForyTapArgs(target: target()))
        case "longPress":
            let duration = try number("duration", default: 1)
            guard duration > 0, duration <= 30 else { throw DriverError.invalidArgs("duration must be 0...30 seconds") }
            response = try TouchCommands.longPress(ForyLongPressArgs(target: target(), duration: duration))
        case "input":
            response = try InputCommands.input(ForyInputArgs(target: target(), content: text("text", required: true)))
        case "waitFor":
            let timeout = try number("timeout", default: 10)
            guard timeout > 0, timeout <= 300 else { throw DriverError.invalidArgs("timeout must be 0...300 seconds") }
            response = try WaitForCommands.waitFor(ForyWaitForArgs(target: target(), timeout: timeout, gone: args["gone"] as? Bool ?? false))
        case "swipe":
            response = try SwipeCommands.swipe(ForySwipeArgs(toTarget: target(prefix: "to"), fromTarget: target(prefix: "from")))
        default: throw DriverError.invalidArgs("Unsupported script command \(command)")
        }
        guard response.ok else { throw DriverError.serverError(response.error) }
        if command == "dom" {
            let payload = try ForyRegistry.create().deserialize(response.payload, as: ForyDomPayload.self)
            return ["app": payload.app, "text": payload.raw]
        }
        if command == "screenshot" {
            let payload = try ForyRegistry.create().deserialize(response.payload, as: ForyScreenshotPayload.self)
            return ["jpeg": payload.jpeg]
        }
        return ["ok": true]
    }
}
