import Darwin
import Foundation

enum OpenURLService {
    // MARK: - Scheme Registry

    enum SchemeRegistry {
        struct LookupResult {
            let registeredHandlers: [String]
            let lookupFailed: Bool
        }

        static var lookupOverrideForTesting: ((String, String) -> LookupResult?)?

        static func lookupScheme(_ scheme: String, udid: String) -> LookupResult {
            if let override = lookupOverrideForTesting, let result = override(scheme, udid) {
                return result
            }
            return performLookup(scheme: scheme, udid: udid)
        }

        static func parseSchemeHandlers(scheme: String, response: [String: Any]) -> [String] {
            let lower = scheme.lowercased()
            var handlers: [String] = []
            guard let lookupResult = response["LookupResult"] as? [String: Any] else { return [] }
            for (_, appInfo) in lookupResult {
                guard let info = appInfo as? [String: Any],
                      let bundleID = info["CFBundleIdentifier"] as? String,
                      let urlTypes = info["CFBundleURLTypes"] as? [[String: Any]] else { continue }
                for urlType in urlTypes {
                    if let schemes = urlType["CFBundleURLSchemes"] as? [String],
                       schemes.contains(where: { $0.lowercased() == lower }) {
                        if !handlers.contains(bundleID) {
                            handlers.append(bundleID)
                        }
                    }
                }
            }
            return handlers
        }

        private static func performLookup(scheme: String, udid: String) -> LookupResult {
            do {
                let pairRecord = try PairRecord.load(udid: udid)
                let service = try startLockdownService("com.apple.mobile.installation_proxy", udid: udid, pairRecord: pairRecord)
                let fd = try Usbmux.connect(udid: udid, port: service.port)
                defer { Darwin.close(fd) }
                let stream: DeviceStream
                if service.enableServiceSSL {
                    stream = try OpenSSLDeviceStream(fd: fd, pairRecord: pairRecord)
                } else {
                    stream = PlainDeviceStream(fd: fd)
                }
                defer { stream.close() }

                let response = try sendInstallationProxyLookup(stream: stream)
                let handlers = parseSchemeHandlers(scheme: scheme, response: response)
                return LookupResult(registeredHandlers: handlers, lookupFailed: false)
            } catch {
                fputs("[open-url] scheme lookup failed for \(scheme) on \(udid): \(error)\n", stderr)
                return LookupResult(registeredHandlers: [], lookupFailed: true)
            }
        }

        private static func sendInstallationProxyLookup(stream: DeviceStream) throws -> [String: Any] {
            let body: [String: Any] = [
                "Command": "Lookup",
                "ClientOptions": [
                    "ApplicationType": "Any",
                    "ReturnAttributes": ["CFBundleIdentifier", "CFBundleURLTypes"],
                ],
            ]
            let xml = try serializePlist(body)
            try stream.write(uint32BE(UInt32(xml.count)) + xml)
            let header = try stream.readExact(byteCount: 4, timeoutSeconds: 10)
            let size = Int(readUInt32BE(header, 0))
            guard size > 0, size <= 50 * 1024 * 1024 else {
                throw CLIParseError.invalidValue("installation_proxy response too large: \(size)")
            }
            return try parsePlist(try stream.readExact(byteCount: size, timeoutSeconds: 10))
        }
    }

    // MARK: - Lockdown Service Helper

    private static func startLockdownService(_ serviceName: String, udid: String, pairRecord: PairRecord) throws -> LockdownService {
        let lockdown = try LockdownClient(udid: udid, pairRecord: pairRecord)
        do {
            try lockdown.startSession()
            try lockdown.enableSessionSSL()
            let service = try lockdown.startService(serviceName)
            lockdown.disconnect()
            return service
        } catch {
            lockdown.disconnect()
        }
        let fallback = try LockdownClient(udid: udid, pairRecord: pairRecord)
        do {
            try fallback.startSession()
            let service = try fallback.startService(serviceName)
            fallback.disconnect()
            return service
        } catch {
            fallback.disconnect()
            throw error
        }
    }

    // MARK: - Public API

    struct OpenResult {
        let message: String
    }

    static func validatedURL(_ url: String) throws -> String {
        guard !url.isEmpty,
              url.trimmingCharacters(in: .whitespacesAndNewlines) == url,
              let components = URLComponents(string: url),
              let scheme = components.scheme,
              !scheme.isEmpty else {
            throw CLIParseError.invalidValue("Invalid URL: \(url)")
        }
        return url
    }

    static func openHostSideIfAvailable(url: String, session: SessionOptions, paths: IOSUsePaths) throws -> OpenResult? {
        let validated = try validatedURL(url)
        if let simulatorUdid = try simulatorUdid(session: session, paths: paths) {
            try openSimulator(url: validated, udid: simulatorUdid)
            return OpenResult(message: "Opened URL: \(validated)")
        }
        if let realUdid = try realDeviceUdid(session: session, paths: paths) {
            return try openRealDevice(url: validated, udid: realUdid)
        }
        return nil
    }

    static func openHostSideIfAvailable(url: String, udid: String?, deviceType: String?, paths: IOSUsePaths) throws -> OpenResult? {
        let validated = try validatedURL(url)
        switch deviceType {
        case "simulator":
            guard let udid, !udid.isEmpty else {
                throw CLIParseError.invalidValue("openURL requires a simulator UDID")
            }
            try openSimulator(url: validated, udid: udid)
            return OpenResult(message: "Opened URL: \(validated)")
        case "real":
            guard let udid, !udid.isEmpty else {
                throw CLIParseError.invalidValue("openURL requires a real device UDID")
            }
            return try openRealDevice(url: validated, udid: udid)
        default:
            return nil
        }
    }

    // MARK: - Simulator

    private static func openSimulator(url: String, udid: String) throws {
        let result = try Shell.runWithResult("xcrun", arguments: ["simctl", "openurl", udid, url])
        switch result.exitCode {
        case 0:
            break
        case 194:
            let scheme = URLComponents(string: url)?.scheme ?? url
            throw CLIParseError.invalidValue("URL scheme \"\(scheme)\" not registered on device")
        default:
            throw CLIParseError.invalidValue(result.stderr.isEmpty
                ? "simctl openurl failed with exit \(result.exitCode)"
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Real Device

    private static func openRealDevice(url: String, udid: String) throws -> OpenResult {
        let scheme = URLComponents(string: url)?.scheme ?? ""
        let lookup = SchemeRegistry.lookupScheme(scheme, udid: udid)

        if !lookup.lookupFailed, lookup.registeredHandlers.isEmpty {
            throw CLIParseError.invalidValue("URL scheme \"\(scheme)\" not registered on device")
        }

        _ = try Shell.run("xcrun", arguments: [
            "devicectl", "device", "process", "launch",
            "--device", udid,
            "--payload-url", url,
            "com.apple.springboard",
        ])

        if lookup.lookupFailed {
            return OpenResult(message: "Sent URL request: \(url) (unable to verify scheme registration)")
        }

        let handlers = lookup.registeredHandlers.joined(separator: ", ")
        return OpenResult(message: "Opened URL: \(url) (handler: \(handlers))")
    }

    // MARK: - Device Resolution

    private static func realDeviceUdid(session: SessionOptions, paths: IOSUsePaths) throws -> String? {
        if let requested = session.udid {
            if let current = SessionService.read(paths: paths),
               current.udid == requested,
               current.deviceType == "real" {
                return requested
            }
            if (try? DeviceService.isUsbDeviceConnected(udid: requested)) == true {
                return requested
            }
            return nil
        }

        guard let current = SessionService.read(paths: paths),
              current.deviceType == "real" else {
            return try DeviceService.listDevices(simulatorOnly: false, paths: paths).first?.udid
        }
        return current.udid
    }

    private static func simulatorUdid(session: SessionOptions, paths: IOSUsePaths) throws -> String? {
        if let requested = session.udid {
            if let current = SessionService.read(paths: paths),
               current.udid == requested,
               current.deviceType == "simulator" {
                return requested
            }
            let bootedSimulators = try DeviceService.listDevices(simulatorOnly: true, paths: paths)
            return bootedSimulators.contains { $0.udid == requested } ? requested : nil
        }

        guard let current = SessionService.read(paths: paths),
              current.deviceType == "simulator" else {
            return nil
        }
        return current.udid
    }
}
