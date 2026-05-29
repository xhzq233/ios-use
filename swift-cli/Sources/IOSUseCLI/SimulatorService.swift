import Darwin
import Foundation
import IOSUseProtocol

enum SimulatorService {
    struct ConfigureResult: Equatable {
        let udid: String
        let ipaPath: String
        let launchOutput: String
    }

    static func listBooted(paths _: IOSUsePaths) throws -> [IOSDevice] {
        let output = try Shell.run("xcrun", arguments: ["simctl", "list", "devices", "booted"])
        return parseBootedSimulators(output)
    }

    static func parseBootedSimulators(_ output: String) -> [IOSDevice] {
        var devices: [IOSDevice] = []
        var currentVersion = ""

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("-- ") {
                if let match = firstMatch(line, regex: Regexes.runtimeHeader) {
                    currentVersion = match[1].replacingOccurrences(of: #"^iOS\s+"#, with: "", options: .regularExpression)
                }
                continue
            }
            guard let match = firstMatch(line, regex: Regexes.bootedSimulator) else {
                continue
            }
            devices.append(IOSDevice(name: match[1].trimmingCharacters(in: .whitespacesAndNewlines), version: currentVersion, udid: match[2], kind: .simulator))
        }

        return devices
    }

    static func defaultBootedUdid(paths: IOSUsePaths) throws -> String {
        guard let simulator = try DeviceService.listDevices(simulatorOnly: true, paths: paths).first else {
            throw CLIParseError.invalidValue("No --udid and no booted Simulators found.")
        }
        return simulator.udid
    }

    static func configureDriver(udid requestedUdid: String?, paths: IOSUsePaths) throws -> ConfigureResult {
        let udid = try requestedUdid ?? defaultBootedUdid(paths: paths)
        let ipaPath = ConfigService.simulatorIPAPath(paths: paths)
        guard FileManager.default.fileExists(atPath: ipaPath) else {
            throw CLIParseError.invalidValue("Prebuilt Simulator driver IPA not found. Expected: assets/driver-sim.ipa")
        }

        let extracted = try extractSimulatorApp(ipaPath: ipaPath, udid: udid, paths: paths)
        defer { try? FileManager.default.removeItem(atPath: extracted.directory) }
        _ = try? Shell.run("xcrun", arguments: ["simctl", "terminate", udid, ConfigService.simulatorBundleId])
        do {
            _ = try Shell.run("xcrun", arguments: ["simctl", "install", udid, extracted.appPath])
        } catch {
            _ = try? Shell.run("xcrun", arguments: ["simctl", "boot", udid])
            _ = try Shell.run("xcrun", arguments: ["simctl", "bootstatus", udid, "-b"])
            _ = try Shell.run("xcrun", arguments: ["simctl", "install", udid, extracted.appPath])
        }

        let launchOutput = try Shell.run("xcrun", arguments: ["simctl", "launch", udid, ConfigService.simulatorBundleId])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        waitForDriver()
        return ConfigureResult(udid: udid, ipaPath: ipaPath, launchOutput: launchOutput)
    }

    static func ensureDriverRunning(
        udid: String,
        allowExistingDriver: Bool,
        isReachable: (() -> Bool)? = nil,
        launcher: ((String) throws -> Void)? = nil
    ) throws {
        let isReachable = isReachable ?? isLocalDriverPortReachable
        let launch = launcher ?? { targetUdid in
            _ = try Shell.run("xcrun", arguments: ["simctl", "launch", targetUdid, ConfigService.simulatorBundleId])
        }
        if allowExistingDriver, isReachable() {
            return
        }
        try launch(udid)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if isReachable() {
                return
            }
            usleep(useconds_t(IOSUseProtocol.driverStartReadinessPollIntervalMicroseconds))
        }
        throw CLIParseError.invalidValue("Simulator driver launched but port \(IOSUseProtocol.defaultDriverPort) did not become reachable for \(udid)")
    }

    static func terminateDriver(udid: String, terminator: ((String) throws -> Bool)? = nil) throws -> Bool {
        if let terminator {
            return try terminator(udid)
        }
        do {
            _ = try Shell.run("xcrun", arguments: ["simctl", "terminate", udid, ConfigService.simulatorBundleId])
            return true
        } catch {
            return false
        }
    }

    static func openURL(_ url: String, udid: String) throws {
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

    static func isLocalDriverPortReachable() -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(IOSUseProtocol.defaultDriverPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    private static func extractSimulatorApp(ipaPath: String, udid: String, paths: IOSUsePaths) throws -> (appPath: String, directory: String) {
        let extractDir = "\(paths.root)/driver-sim-install-\(udid)"
        try? FileManager.default.removeItem(atPath: extractDir)
        try FileManager.default.createDirectory(atPath: extractDir, withIntermediateDirectories: true, attributes: nil)

        _ = try Shell.run("unzip", arguments: ["-q", "-o", ipaPath, "-d", extractDir])
        let payloadDir = "\(extractDir)/Payload"
        let appEntries = (try FileManager.default.contentsOfDirectory(atPath: payloadDir)).filter { $0.hasSuffix(".app") }
        guard let appEntry = appEntries.first else {
            throw CLIParseError.invalidValue("No .app found in Simulator IPA")
        }
        return ("\(payloadDir)/\(appEntry)", extractDir)
    }

    private static func waitForDriver() {
        for _ in 0..<50 {
            let driver = DriverClient()
            defer { driver.close() }
            if (try? driver.dom(raw: false, fresh: false)) != nil {
                return
            }
            usleep(200_000)
        }
    }

    private enum Regexes {
        static let runtimeHeader = try! NSRegularExpression(pattern: #"^--\s+(.+?)\s+--"#)
        static let bootedSimulator = try! NSRegularExpression(pattern: #"^\s*(.+?)\s+\(([0-9A-Fa-f-]+)\)\s+\(Booted\)"#)
    }

    private static func firstMatch(_ text: String, regex: NSRegularExpression) -> [String]? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }
}
