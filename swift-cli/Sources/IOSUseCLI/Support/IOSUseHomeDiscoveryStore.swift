import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Minimal account-local index that lets `ios-use du` discover logical Homes
/// whose absolute paths are otherwise arbitrary. Lifecycle commands never
/// enumerate this directory.
enum IOSUseHomeDiscoveryStore {
    struct Home: Codable, Equatable, Sendable {
        let homeID: String
        let root: String
    }

    private static let maximumRecordBytes = 8 * 1_024
    private static let processLock = NSLock()

    static func registerIfExisting(paths: IOSUsePaths) {
        var rootStatus = stat()
        guard lstat(paths.root, &rootStatus) == 0,
              rootStatus.st_mode & S_IFMT == S_IFDIR else {
            return
        }
        processLock.lock()
        defer { processLock.unlock() }
        let descriptor = URL(
            fileURLWithPath: paths.knownHomes,
            isDirectory: true
        ).appendingPathComponent("\(paths.playcoverHomeID).json")
        var descriptorStatus = stat()
        if lstat(descriptor.path, &descriptorStatus) == 0 {
            return
        }
        guard errno == ENOENT else { return }
        do {
            let directory = descriptor.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            #if canImport(Darwin)
            guard chmod(directory.path, 0o700) == 0 else { return }
            #endif
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(
                Home(
                    homeID: paths.playcoverHomeID,
                    root: canonicalRoot(paths.root)
                )
            )
            guard data.count <= maximumRecordBytes else { return }
            try data.write(to: descriptor, options: .atomic)
            #if canImport(Darwin)
            guard chmod(descriptor.path, 0o600) == 0 else {
                try? FileManager.default.removeItem(at: descriptor)
                return
            }
            #endif
        } catch {
            // Discovery metadata never changes command success/failure.
        }
    }

    static func read(
        paths: IOSUsePaths
    ) -> (homes: [Home], warnings: [String]) {
        processLock.lock()
        defer { processLock.unlock() }
        let root = URL(
            fileURLWithPath: paths.knownHomes,
            isDirectory: true
        )
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: root.path
        ) else {
            return ([], [])
        }
        var homes: [Home] = []
        var warnings: [String] = []
        for name in names.sorted() {
            guard name.hasSuffix(".json") else {
                warnings.append(
                    "unknown Home discovery entry: "
                        + root.appendingPathComponent(name).path
                )
                continue
            }
            let path = root.appendingPathComponent(name).path
            do {
                let data = try readOwnerOnly(path)
                guard let object = try JSONSerialization
                        .jsonObject(with: data) as? [String: Any],
                      Set(object.keys) == Set(["homeID", "root"])
                else {
                    throw HomeDiscoveryError.invalid
                }
                let home = try JSONDecoder().decode(Home.self, from: data)
                guard "\(home.homeID).json" == name,
                      isLowercaseSHA256(home.homeID),
                      home.root.hasPrefix("/") else {
                    throw HomeDiscoveryError.invalid
                }
                homes.append(home)
            } catch {
                warnings.append(
                    "cannot read Home discovery record \(path): \(error)"
                )
            }
        }
        return (homes, warnings)
    }

    private static func readOwnerOnly(_ path: String) throws -> Data {
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= maximumRecordBytes else {
            throw HomeDiscoveryError.invalid
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count <= maximumRecordBytes else {
            throw HomeDiscoveryError.invalid
        }
        return data
    }

    private static func canonicalRoot(_ path: String) -> String {
        let url = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
        return url.resolvingSymlinksInPath().path
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value)
                || (97...102).contains($0.value)
        }
    }

    private enum HomeDiscoveryError: Error, CustomStringConvertible {
        case invalid

        var description: String {
            "invalid owner-only Home descriptor"
        }
    }
}
