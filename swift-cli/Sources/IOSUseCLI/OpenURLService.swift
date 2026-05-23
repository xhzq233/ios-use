import Foundation

enum OpenURLService {
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

    static func openHostSideIfAvailable(url: String, session: SessionOptions, paths: IOSUsePaths) throws -> Bool {
        let validated = try validatedURL(url)
        if let simulatorUdid = try simulatorUdid(session: session, paths: paths) {
            try openSimulator(url: validated, udid: simulatorUdid)
            return true
        }
        if let realUdid = try realDeviceUdid(session: session, paths: paths) {
            try openRealDevice(url: validated, udid: realUdid)
            return true
        }
        return false
    }

    static func openHostSideIfAvailable(url: String, udid: String?, deviceType: String?, paths: IOSUsePaths) throws -> Bool {
        let validated = try validatedURL(url)
        switch deviceType {
        case "simulator":
            guard let udid, !udid.isEmpty else {
                throw CLIParseError.invalidValue("openURL requires a simulator UDID")
            }
            try openSimulator(url: validated, udid: udid)
            return true
        case "real":
            guard let udid, !udid.isEmpty else {
                throw CLIParseError.invalidValue("openURL requires a real device UDID")
            }
            try openRealDevice(url: validated, udid: udid)
            return true
        default:
            return false
        }
    }

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

    private static func openRealDevice(url: String, udid: String) throws {
        _ = try Shell.run("xcrun", arguments: [
            "devicectl",
            "device",
            "process",
            "launch",
            "--device", udid,
            "--payload-url", url,
            "com.apple.springboard",
        ])
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

    private static func openSimulator(url: String, udid: String) throws {
        _ = try Shell.run("xcrun", arguments: ["simctl", "openurl", udid, url])
    }
}
