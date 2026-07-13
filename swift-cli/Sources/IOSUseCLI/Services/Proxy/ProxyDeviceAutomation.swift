import Foundation
import IOSUseProtocol

/// The small, product-specific device sequences needed by ProxyService.
///
/// These operations deliberately do not load or interpret a workflow file. The
/// equivalent shell scripts live under examples/proxy for users who want to
/// compose the same steps themselves; the built-in proxy command keeps its
/// state transitions and cleanup in-process.
enum ProxyDeviceAutomation {
    enum Operation: Equatable {
        case installAndTrustCA
        case configureWiFi(server: String, port: String)
        case clearWiFi
    }

    static var operationOverrideForTesting: ((Operation, IOSUsePaths) throws -> String)?

    static func installAndTrustCA(
        activeDriver: SessionService.Info,
        paths: IOSUsePaths,
        interruptMonitor: InterruptMonitor
    ) throws -> String {
        if let operationOverrideForTesting {
            return try operationOverrideForTesting(.installAndTrustCA, paths)
        }

        let session = LockedDriverClientSession(paths: paths)
        defer { session.close() }
        var output = ""

        // Preserve the former top-level `app: com.apple.Preferences` bootstrap
        // before the recipe opens Safari and later returns to Settings.
        append(&output, try execute(.terminateApp(bundleId: "com.apple.Preferences"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.activateApp(bundleId: "com.apple.Preferences"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.terminateApp(bundleId: "com.apple.mobilesafari"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try open(url: "http://127.0.0.1:9088/ca.cer", activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(tap("允许", traits: "Button"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.dismissAlert(index: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))

        append(&output, try execute(.activateApp(bundleId: "com.apple.Preferences"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.waitFor(label: "已下载描述文件", timeout: 5, traits: nil, cindex: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(tap("已下载描述文件"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))

        for _ in 0..<3 {
            append(&output, try execute(.waitFor(label: "安装", timeout: nil, traits: "Button", cindex: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
            append(&output, try execute(tap("安装", traits: "Button"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        }

        append(&output, try execute(.waitFor(label: "完成", timeout: nil, traits: nil, cindex: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(tap("完成"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.waitFor(label: "BackButton", timeout: nil, traits: nil, cindex: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(tap("BackButton"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.swipe(to: "关于本机", from: nil, dir: nil, distance: nil, traits: nil, cindex: nil, postDom: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(tap("关于本机"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.swipe(to: "证书信任设置", from: "iOS版本", dir: nil, distance: nil, traits: nil, cindex: nil, postDom: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(tap("证书信任设置"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(tap("mitmproxy", traits: "Cell,Switch", offsetRatio: "0.9,"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(tap("继续"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        return output
    }

    static func configureWiFi(
        server: String,
        port: String,
        activeDriver: SessionService.Info,
        paths: IOSUsePaths,
        interruptMonitor: InterruptMonitor
    ) throws -> String {
        if let operationOverrideForTesting {
            return try operationOverrideForTesting(.configureWiFi(server: server, port: port), paths)
        }

        let session = LockedDriverClientSession(paths: paths)
        defer { session.close() }
        var output = ""
        append(&output, try execute(.terminateApp(bundleId: "com.apple.Preferences"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.activateApp(bundleId: "com.apple.Preferences"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        try sleep(milliseconds: 1_000, interruptMonitor: interruptMonitor)
        append(&output, try execute(tap("com.apple.settings.wifi"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.waitFor(label: "信号强度", timeout: 5, traits: "Cell,selected", cindex: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(tap("信号强度", traits: "Cell,selected", offsetRatio: "0.9,0.5"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.swipe(to: "配置代理", from: nil, dir: nil, distance: nil, traits: nil, cindex: nil, postDom: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.waitFor(label: "配置代理", timeout: 3, traits: nil, cindex: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(tap("配置代理"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        try sleep(milliseconds: 500, interruptMonitor: interruptMonitor)
        append(&output, try execute(.waitFor(label: "手动", timeout: 3, traits: nil, cindex: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(tap("手动"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.waitFor(label: "服务器", timeout: 3, traits: nil, cindex: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.input(tap: "服务器", content: server, delete: 0, enter: false, traits: nil, cindex: nil, postDom: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.input(tap: "端口", content: port, delete: 0, enter: false, traits: nil, cindex: nil, postDom: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(tap("配置代理", traits: "NavigationBar", offsetRatio: "0.88,0.41"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        return output
    }

    static func clearWiFi(
        activeDriver: SessionService.Info,
        paths: IOSUsePaths,
        interruptMonitor: InterruptMonitor
    ) throws -> String {
        if let operationOverrideForTesting {
            return try operationOverrideForTesting(.clearWiFi, paths)
        }

        let session = LockedDriverClientSession(paths: paths)
        defer { session.close() }
        var output = ""
        append(&output, try execute(.terminateApp(bundleId: "com.apple.Preferences"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.activateApp(bundleId: "com.apple.Preferences"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        try sleep(milliseconds: 1_000, interruptMonitor: interruptMonitor)
        append(&output, try execute(tap("com.apple.settings.wifi"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.waitFor(label: "信号强度", timeout: 5, traits: "Cell,selected", cindex: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(tap("信号强度", traits: "Cell,selected", offsetRatio: "0.9,0.5"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.swipe(to: "配置代理", from: nil, dir: nil, distance: nil, traits: nil, cindex: nil, postDom: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(.waitFor(label: "配置代理", timeout: 3, traits: nil, cindex: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(tap("配置代理"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        try sleep(milliseconds: 500, interruptMonitor: interruptMonitor)
        append(&output, try execute(.waitFor(label: "关闭", timeout: 3, traits: nil, cindex: nil), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(tap("关闭"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        append(&output, try execute(tap("配置代理", traits: "NavigationBar", offsetRatio: "0.88,0.41"), session: session, activeDriver: activeDriver, paths: paths, interruptMonitor: interruptMonitor))
        return output
    }

    private static func execute(
        _ action: DriverAction,
        session: LockedDriverClientSession,
        activeDriver: SessionService.Info,
        paths: IOSUsePaths,
        interruptMonitor: InterruptMonitor
    ) throws -> String {
        try interruptMonitor.throwIfInterrupted()
        let result = try DriverCommandExecutor.execute(action: action, paths: paths, hostDeviceTypeHint: activeDriver.deviceType) { body in
            try session.run(body)
        }
        try interruptMonitor.throwIfInterrupted()
        return result.stdout
    }

    private static func open(
        url: String,
        activeDriver: SessionService.Info,
        paths: IOSUsePaths,
        interruptMonitor: InterruptMonitor
    ) throws -> String {
        try interruptMonitor.throwIfInterrupted()
        let validatedURL = try OpenURLService.validatedURL(url)
        guard let result = try OpenURLService.openHostSideIfAvailable(
            url: validatedURL,
            udid: activeDriver.udid,
            deviceType: activeDriver.deviceType,
            paths: paths
        ) else {
            throw CLIParseError.invalidValue("open target is unavailable. Pass a USB real device UDID, pass a booted Simulator UDID, or run `ios-use start` first.")
        }
        try interruptMonitor.throwIfInterrupted()
        return "\(result.message)\n"
    }

    private static func tap(
        _ target: String,
        traits: String? = nil,
        offsetRatio: String? = nil
    ) -> DriverAction {
        .tap(target: target, offset: nil, offsetRatio: offsetRatio, traits: traits, cindex: nil, postDom: nil)
    }

    private static func append(_ output: inout String, _ next: String) {
        output += next
        if !output.hasSuffix("\n") { output += "\n" }
    }

    private static func sleep(milliseconds: Int, interruptMonitor: InterruptMonitor) throws {
        var remaining = milliseconds
        while remaining > 0 {
            try interruptMonitor.throwIfInterrupted()
            let chunk = min(remaining, 100)
            usleep(useconds_t(chunk * 1_000))
            remaining -= chunk
        }
    }
}
