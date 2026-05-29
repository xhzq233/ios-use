import Foundation

enum OpenURLService {
    static var realDeviceURLLauncherForTesting: ((String, String) throws -> Void)?

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
                let response = try InstallationProxyClient.withClient(udid: udid) { client in
                    try client.lookup(attributes: ["CFBundleIdentifier", "CFBundleURLTypes"])
                }
                let handlers = parseSchemeHandlers(scheme: scheme, response: response)
                return LookupResult(registeredHandlers: handlers, lookupFailed: false)
            } catch {
                fputs("[open-url] scheme lookup failed for \(scheme) on \(udid): \(error)\n", stderr)
                return LookupResult(registeredHandlers: [], lookupFailed: true)
            }
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
        let activeDriver = SessionService.read(paths: paths)
        let targetUdid = try SessionService.resolveTargetUdid(
            explicitUdid: session.udid,
            paths: paths,
            missingMessage: "open requires --udid or an active driver. Run `ios-use start <UDID>` or pass `--udid <UDID>`."
        )
        if activeDriver?.udid == targetUdid {
            if activeDriver?.deviceType == "simulator" {
                try openSimulator(url: validated, udid: targetUdid)
                return OpenResult(message: "Opened URL: \(validated)")
            }
            return try openRealDevice(url: validated, udid: targetUdid)
        }
        if DeviceService.looksLikeSimulatorUDID(targetUdid) {
            let bootedSimulators = try DeviceService.listDevices(simulatorOnly: true, paths: paths)
            guard bootedSimulators.contains(where: { $0.udid == targetUdid }) else {
                return nil
            }
            try openSimulator(url: validated, udid: targetUdid)
            return OpenResult(message: "Opened URL: \(validated)")
        }
        return try openRealDevice(url: validated, udid: targetUdid)
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
        try SimulatorService.openURL(url, udid: udid)
    }

    // MARK: - Real Device

    private static func openRealDevice(url: String, udid: String) throws -> OpenResult {
        let scheme = URLComponents(string: url)?.scheme ?? ""
        let lookup = SchemeRegistry.lookupScheme(scheme, udid: udid)

        if !lookup.lookupFailed, lookup.registeredHandlers.isEmpty {
            throw CLIParseError.invalidValue("URL scheme \"\(scheme)\" not registered on device")
        }

        try openRealDeviceURL(url: url, udid: udid)

        if lookup.lookupFailed {
            return OpenResult(message: "Sent URL request: \(url) (unable to verify scheme registration)")
        }

        let handlers = lookup.registeredHandlers.joined(separator: ", ")
        return OpenResult(message: "Opened URL: \(url) (handler: \(handlers))")
    }

    private static func openRealDeviceURL(url: String, udid: String) throws {
        if let launcher = realDeviceURLLauncherForTesting {
            try launcher(url, udid)
            return
        }
        try CoreDeviceURLLauncher().open(url: url, udid: udid)
    }

}
