import Darwin
import Foundation

enum DeviceCommandLock {
    static func withExclusiveLock<T>(
        paths: IOSUsePaths,
        _ operation: () throws -> T
    ) throws -> T {
        let stateDirectory = URL(
            fileURLWithPath: paths.driverLock
        ).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockPath = stateDirectory
            .appendingPathComponent("command.lock")
            .path
        let descriptor = Darwin.open(
            lockPath,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CLIParseError.invalidValue(
                "Cannot lock Device command state: errno \(errno)."
            )
        }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw CLIParseError.invalidValue(
                "Cannot acquire Device command lock: errno \(errno)."
            )
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
