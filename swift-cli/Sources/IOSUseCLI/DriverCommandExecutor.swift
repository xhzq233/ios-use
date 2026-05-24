import Foundation
import IOSUseProtocol

enum DriverCommandPayload {
    case dom(ForyDomPayload)
    case find(ForyFindPayload)
    case waitFor(ForyWaitForPayload)
    case screenshot(Data)
    case element(ForyElementPayload)
    case swipe(ForySwipePayload)
    case alert(ForyAlertPayload)
}

struct DriverCommandResult {
    var stdout: String
    var payload: DriverCommandPayload?
}

enum DriverCommandExecutor {
    typealias ClientRunner = ((DriverCommandClient) throws -> DriverCommandPayload?) throws -> DriverCommandPayload?

    static func execute(action: DriverAction, paths: IOSUsePaths, hostDeviceTypeHint: String? = nil, clientRunner: ClientRunner) throws -> DriverCommandResult {
        switch action {
        case .dom(let raw, let fresh):
            let payload = try requiredPayload(clientRunner { .dom(try $0.dom(raw: raw, fresh: fresh)) }, as: ForyDomPayload.self)
            return DriverCommandResult(stdout: DriverOutput.formatDom(payload), payload: .dom(payload))

        case .find(let label, let traits, let cindex):
            let payload = try requiredPayload(clientRunner { .find(try $0.find(label: label, traits: traits, cindex: cindex)) }, as: ForyFindPayload.self)
            return DriverCommandResult(stdout: DriverOutput.formatFind(label: label, payload: payload), payload: .find(payload))

        case .waitFor(let label, let timeout, let traits, let cindex):
            let payload = try requiredPayload(clientRunner { .waitFor(try $0.waitFor(label: label, timeout: timeout, traits: traits, cindex: cindex)) }, as: ForyWaitForPayload.self)
            return DriverCommandResult(stdout: DriverOutput.formatWaitFor(label: label, payload: payload), payload: .waitFor(payload))

        case .screenshot(let name):
            let data = try requiredPayload(clientRunner { .screenshot(try $0.screenshot()) }, as: Data.self)
            try FileManager.default.createDirectory(atPath: paths.artifacts, withIntermediateDirectories: true, attributes: nil)
            let path = try ArtifactPaths.file(paths: paths, name: name, defaultName: "screenshot", extension: "jpg")
            try data.write(to: URL(fileURLWithPath: path))
            return DriverCommandResult(stdout: "Screenshot saved: \(path)\n", payload: .screenshot(data))

        case .tap(let target, let offset, let offsetRatio, let traits, let cindex):
            let params = try resolveTapParams(target, offset: offset, offsetRatio: offsetRatio, traits: traits, cindex: cindex)
            let payload = try requiredPayload(clientRunner {
                .element(try $0.tap(target: params.target, traits: traits, cindex: cindex, offset: params.offset, ratio: params.ratio))
            }, as: ForyElementPayload.self)
            return DriverCommandResult(stdout: "Tap\n\(DriverOutput.formatElement(payload))", payload: .element(payload))

        case .longPress(let target, let duration, let traits, let cindex):
            let foryTarget = try resolveTarget(target, traits: traits, cindex: cindex)
            let payload = try requiredPayload(clientRunner {
                .element(try $0.longPress(target: foryTarget, durationMs: duration, traits: traits, cindex: cindex))
            }, as: ForyElementPayload.self)
            return DriverCommandResult(stdout: "Longpress\n\(DriverOutput.formatElement(payload))", payload: .element(payload))

        case .input(let label, let content, let traits, let cindex):
            _ = try clientRunner {
                try $0.input(label: label, content: content, traits: traits, cindex: cindex)
                return nil
            }
            return DriverCommandResult(stdout: "Input \"\(content)\" into \"\(label)\"\n", payload: nil)

        case .swipe(let to, let from, let dir, let distance, let traits, let cindex):
            let params = try resolveSwipeParams(to: to, from: from, traits: traits, cindex: cindex)
            let payload = try requiredPayload(clientRunner {
                .swipe(try $0.swipe(to: params.to, from: params.from, distance: distance, dir: dir, traits: traits, cindex: cindex))
            }, as: ForySwipePayload.self)
            return DriverCommandResult(stdout: DriverOutput.formatSwipe(payload), payload: .swipe(payload))

        case .activateApp(let bundleId):
            _ = try clientRunner {
                try $0.activateApp(bundleId: bundleId)
                return nil
            }
            return DriverCommandResult(stdout: "App \(bundleId) activated\n", payload: nil)

        case .terminateApp(let bundleId):
            do {
                _ = try clientRunner {
                    try $0.terminateApp(bundleId: bundleId)
                    return nil
                }
            } catch {
                if IOSUseCLI.isAppNotRunningError(error) {
                    return DriverCommandResult(stdout: "App \(bundleId) not running, skipped terminate\n", payload: nil)
                }
                throw error
            }
            return DriverCommandResult(stdout: "App \(bundleId) terminated\n", payload: nil)

        case .home:
            _ = try clientRunner {
                try $0.home()
                return nil
            }
            return DriverCommandResult(stdout: "Pressed Home\n", payload: nil)

        case .openURL(let url, let session):
            let validatedURL = try OpenURLService.validatedURL(url)
            if session.udid != nil || hostDeviceTypeHint != nil,
               let result = try OpenURLService.openHostSideIfAvailable(url: validatedURL, udid: session.udid, deviceType: hostDeviceTypeHint, paths: paths) {
                return DriverCommandResult(stdout: "\(result.message)\n", payload: nil)
            }
            if let result = try OpenURLService.openHostSideIfAvailable(url: validatedURL, session: session, paths: paths) {
                return DriverCommandResult(stdout: "\(result.message)\n", payload: nil)
            }
            throw CLIParseError.invalidValue("openURL requires a booted simulator, active driver, or USB real device")

        case .dismissAlert(let index):
            let payload = try requiredPayload(clientRunner { .alert(try $0.dismissAlert(index: index)) }, as: ForyAlertPayload.self)
            return DriverCommandResult(stdout: DriverOutput.formatAlert(payload), payload: .alert(payload))

        case .oslog(let pattern, let flags, let timeout, let name, let clear, let bundleId, let session):
            return DriverCommandResult(stdout: try oslog(pattern: pattern, flags: flags, timeout: timeout, name: name, clear: clear, bundleId: bundleId, session: session, paths: paths, hostDeviceTypeHint: hostDeviceTypeHint), payload: nil)
        }
    }

    static func validate(action: DriverAction) throws {
        switch action {
        case .tap(let target, let offset, let offsetRatio, let traits, let cindex):
            _ = try resolveTapParams(target, offset: offset, offsetRatio: offsetRatio, traits: traits, cindex: cindex)
        case .longPress(let target, _, let traits, let cindex):
            _ = try resolveTarget(target, traits: traits, cindex: cindex)
        case .swipe(let to, let from, _, _, let traits, let cindex):
            _ = try resolveSwipeParams(to: to, from: from, traits: traits, cindex: cindex)
        case .openURL(let url, _):
            _ = try OpenURLService.validatedURL(url)
        default:
            break
        }
    }

    static func resolveTapParams(
        _ target: String,
        offset: String?,
        offsetRatio: String?,
        traits: String?,
        cindex: Int32?
    ) throws -> (target: ForyTarget, offset: ForyPoint?, ratio: ForyPoint) {
        let foryTarget = try resolveTarget(target, traits: traits, cindex: cindex)
        if foryTarget.point != nil && (offset != nil || offsetRatio != nil) {
            throw CLIParseError.invalidValue("offset requires element label, not absolute point")
        }
        let offsetPoint = try offset.map { try pointPair($0, emptyDefault: 0) }
        let ratioPoint = try offsetPoint == nil
            ? (offsetRatio.map { try pointPair($0, emptyDefault: IOSUseProtocol.defaultTargetRatio) }
                ?? ForyPoint(x: IOSUseProtocol.defaultTargetRatio, y: IOSUseProtocol.defaultTargetRatio))
            : ForyPoint(x: IOSUseProtocol.defaultTargetRatio, y: IOSUseProtocol.defaultTargetRatio)
        return (foryTarget, offsetPoint, ratioPoint)
    }

    static func resolveSwipeParams(to: String?, from: String?, traits: String?, cindex: Int32?) throws -> (to: ForyTarget, from: ForyTarget) {
        let toTarget = try resolveTarget(to, traits: traits, cindex: cindex)
        let fromTarget = try resolveTarget(from)
        return (toTarget, fromTarget)
    }

    static func resolveTarget(_ value: String?, traits: String? = nil, cindex: Int32? = nil) throws -> ForyTarget {
        guard let value, !value.isEmpty else {
            if traits != nil || cindex != nil {
                throw CLIParseError.invalidValue("traits or cindex require label target")
            }
            return ForyTarget()
        }
        if let point = try? pointPair(value, emptyDefault: 0) {
            if traits != nil || cindex != nil {
                throw CLIParseError.invalidValue("point target does not support traits or cindex")
            }
            return ForyTarget(label: "", point: point)
        }
        return ForyTarget(label: value, point: nil, traits: traits ?? "", cindex: cindex)
    }

    static func pointPair(_ value: String, emptyDefault: Double) throws -> ForyPoint {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw CLIParseError.invalidValue("Invalid point pair: \"\(value)\"")
        }
        let rawX = parts[0].trimmingCharacters(in: .whitespaces)
        let rawY = parts[1].trimmingCharacters(in: .whitespaces)
        let x = rawX.isEmpty ? emptyDefault : Double(rawX)
        let y = rawY.isEmpty ? emptyDefault : Double(rawY)
        guard let x, let y, x.isFinite, y.isFinite else {
            throw CLIParseError.invalidValue("Invalid point pair: \"\(value)\"")
        }
        return ForyPoint(x: x, y: y)
    }

    private static func oslog(pattern: String?, flags: String?, timeout: Double?, name: String?, clear: Bool, bundleId: String?, session: SessionOptions, paths: IOSUsePaths, hostDeviceTypeHint: String?) throws -> String {
        if clear {
            if let udid = session.udid ?? SessionService.read(paths: paths)?.udid {
                return OSLogService.clear(udid: udid)
            }
            return OSLogService.clear()
        }
        let activeDriver = SessionService.read(paths: paths)
        let defaultUsbUdid = try session.udid == nil && activeDriver?.udid == nil
            ? DeviceService.listDevices(simulatorOnly: false, paths: paths).first?.udid
            : nil
        guard let udid = session.udid ?? activeDriver?.udid ?? defaultUsbUdid else {
            throw CLIParseError.invalidValue("oslog requires --udid, an active driver, or a connected USB device")
        }
        return try OSLogService.fetch(
            udid: udid,
            pattern: pattern,
            flags: flags,
            bundleId: bundleId,
            timeout: timeout,
            name: name,
            paths: paths,
            deviceTypeHint: hostDeviceTypeHint ?? (activeDriver?.udid == udid ? activeDriver?.deviceType : (defaultUsbUdid == udid ? "real" : nil))
        )
    }

    private static func requiredPayload<T>(_ payload: DriverCommandPayload?, as type: T.Type) throws -> T {
        let value: Any?
        switch payload {
        case .dom(let payload): value = payload
        case .find(let payload): value = payload
        case .waitFor(let payload): value = payload
        case .screenshot(let payload): value = payload
        case .element(let payload): value = payload
        case .swipe(let payload): value = payload
        case .alert(let payload): value = payload
        case nil: value = nil
        }
        guard let typed = value as? T else {
            throw CLIParseError.invalidValue("internal error: unexpected driver command payload")
        }
        return typed
    }
}
