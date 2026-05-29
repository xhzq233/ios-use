import Foundation

public enum SessionService {
    public struct Info: Equatable, Sendable {
        public let udid: String
        public let deviceName: String
        public let deviceVersion: String
        public let deviceType: String
        public let startedAt: Int

        public init(udid: String, deviceName: String, deviceVersion: String, deviceType: String, startedAt: Int = Int(Date().timeIntervalSince1970 * 1000)) {
            self.udid = udid
            self.deviceName = deviceName
            self.deviceVersion = deviceVersion
            self.deviceType = deviceType
            self.startedAt = startedAt
        }
    }

    static var simulatorDriverReachableForTesting: (() -> Bool)?
    static var simulatorDriverLauncherForTesting: ((String) throws -> Void)?
    static var simulatorDriverTerminatorForTesting: ((String) throws -> Bool)?
    static var realDriverReachableForTesting: ((String) -> Bool)?
    static var realDriverLauncherForTesting: ((String, String) throws -> Void)?
    static var realDriverTerminatorForTesting: ((String) throws -> Bool)?
    static var coreDeviceLifecycleFactoryForTesting: ((((String) -> Void)?) -> CoreDeviceDriverLifecycleManaging)?

    public static func clear(paths: IOSUsePaths) {
        DriverSessionStore.clear(paths: paths)
    }

    public static func readDriverLock(paths: IOSUsePaths) -> String? {
        DriverSessionStore.readDriverLock(paths: paths)
    }

    public static func readDriverLockInfo(paths: IOSUsePaths) throws -> Info? {
        try DriverSessionStore.readInfo(paths: paths)
    }

    public static func requireDriverLock(paths: IOSUsePaths) throws -> Info {
        try DriverSessionStore.requireInfo(paths: paths)
    }

    public static func writeDriverLock(info: Info, paths: IOSUsePaths) throws {
        try DriverSessionStore.write(info: info, paths: paths)
    }

    public static func clearDriverLock(paths: IOSUsePaths) {
        DriverSessionStore.clearDriverLock(paths: paths)
    }

    public static func start(udid: String, paths: IOSUsePaths, verbose: Bool) throws -> String {
        if let current = try readDriverLockInfo(paths: paths) {
            throw CLIParseError.invalidValue("Driver already started for \(current.udid). Run `ios-use stop` before starting another driver.")
        }
        let info = try resolveDriverInfo(udid: udid, paths: paths)
        try launchDriver(for: info, paths: paths, verbose: verbose)
        try writeDriverLock(info: info, paths: paths)
        return "Driver started for \(udid)\n"
    }

    public static func stop(paths: IOSUsePaths) throws -> String {
        let current = try requireDriverLock(paths: paths)
        var output = try DriverLifecycleService.terminateDriver(
            for: current,
            paths: paths,
            simulatorTerminator: simulatorDriverTerminatorForTesting,
            realTerminator: realDriverTerminatorForTesting,
            coreDeviceFactory: coreDeviceLifecycleFactoryForTesting
        )
        clearDriverLock(paths: paths)
        output += "Driver stopped\n"
        return output
    }

    public static func read(paths: IOSUsePaths) -> Info? {
        try? readDriverLockInfo(paths: paths)
    }

    public static func resolveDriverInfo(udid: String, paths: IOSUsePaths) throws -> Info {
        try DriverLifecycleService.resolveDriverInfo(udid: udid, paths: paths)
    }

    public static func launchDriver(for info: Info, paths: IOSUsePaths, verbose: Bool) throws {
        try DriverLifecycleService.launchDriver(
            for: info,
            paths: paths,
            verbose: verbose,
            simulatorReachable: simulatorDriverReachableForTesting,
            simulatorLauncher: simulatorDriverLauncherForTesting,
            realReachable: realDriverReachableForTesting,
            realLauncher: realDriverLauncherForTesting,
            coreDeviceFactory: coreDeviceLifecycleFactoryForTesting
        )
    }
}
