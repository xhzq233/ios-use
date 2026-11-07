import Foundation

enum DeveloperDiskImageResolver {
    static let defaultSearchPaths = [
        "/Library/Developer/DeveloperDiskImages/iOS_DDI/Restore",
        "/Library/Developer/DeveloperDiskImages/iOS_DDI.dmg",
        "/Library/Developer/CoreDevice/CandidateDDIs/iOS_DDI.dmg",
        "/Library/Developer/CoreDevice/CandidateDDIs/iOS",
        "~/Library/Developer/DeveloperDiskImages/iOS_DDI/Restore",
        "~/Library/Developer/DeveloperDiskImages/iOS_DDI.dmg",
    ]

    static func resolve(path: String?, identifiers: DeveloperDiskImageBuildManifest.DeviceIdentifiers) throws -> ResolvedDeveloperDiskImage {
        if let path, !path.isEmpty {
            return try resolveCandidate(expandHome(path), identifiers: identifiers)
        }
        var searched: [String] = []
        for candidate in defaultSearchPaths.map(expandHome) {
            searched.append(candidate)
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            do {
                return try resolveCandidate(candidate, identifiers: identifiers)
            } catch DeveloperDiskImageError.invalidPath {
                continue
            }
        }
        throw DeveloperDiskImageError.notFound(searched)
    }

    private static func resolveCandidate(_ path: String, identifiers: DeveloperDiskImageBuildManifest.DeviceIdentifiers) throws -> ResolvedDeveloperDiskImage {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw DeveloperDiskImageError.invalidPath(path)
        }
        let url = URL(fileURLWithPath: path)
        if isDirectory.boolValue {
            if let resolved = try resolveDirectory(url, identifiers: identifiers, cleanup: {}) {
                return resolved
            }
            throw DeveloperDiskImageError.invalidPath(path)
        }
        guard url.pathExtension.lowercased() == "dmg" else {
            throw DeveloperDiskImageError.invalidPath(path)
        }
        return try withAttachedDMG(url, identifiers: identifiers)
    }

    private static func resolveDirectory(
        _ url: URL,
        identifiers: DeveloperDiskImageBuildManifest.DeviceIdentifiers,
        cleanup: @escaping () -> Void
    ) throws -> ResolvedDeveloperDiskImage? {
        try ResolvedDeveloperDiskImage.directory(url, identifiers: identifiers, cleanup: cleanup)
    }

    private static func withAttachedDMG(_ dmgURL: URL, identifiers: DeveloperDiskImageBuildManifest.DeviceIdentifiers) throws -> ResolvedDeveloperDiskImage {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-ddi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        do {
            _ = try Shell.run("hdiutil", arguments: ["attach", dmgURL.path, "-readonly", "-nobrowse", "-mountpoint", mountPoint.path])
            guard let resolved = try resolveDirectory(mountPoint, identifiers: identifiers, cleanup: {
                _ = try? Shell.run("hdiutil", arguments: ["detach", mountPoint.path, "-quiet"])
                try? FileManager.default.removeItem(at: mountPoint)
            }) else {
                _ = try? Shell.run("hdiutil", arguments: ["detach", mountPoint.path, "-quiet"])
                try? FileManager.default.removeItem(at: mountPoint)
                throw DeveloperDiskImageError.invalidPath(dmgURL.path)
            }
            return resolved
        } catch {
            _ = try? Shell.run("hdiutil", arguments: ["detach", mountPoint.path, "-quiet"])
            try? FileManager.default.removeItem(at: mountPoint)
            throw error
        }
    }

    private static func expandHome(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
    }
}

enum DeveloperDiskImageService {
    static var mountForTesting: ((String, String?) throws -> String)?

    static func mount(options: DDIMountOptions, paths: IOSUsePaths) throws -> String {
        let udid = try resolveRealDeviceTargetUdid(
            explicitUdid: options.udid,
            paths: paths,
            missingMessage: "ddi-mount requires --udid, an active real-device driver, or exactly one connected USB real device."
        )
        if let mountForTesting {
            return try mountForTesting(udid, options.path)
        }
        return try mount(udid: udid, path: options.path)
    }

    static func mount(udid: String, path: String?) throws -> String {
        var source = ""
        let mounted = try PersonalizedDDIMounter.ensureMounted(udid: udid) { identifiers in
            let resolved = try DeveloperDiskImageResolver.resolve(path: path, identifiers: identifiers)
            source = resolved.sourceDescription
            return resolved
        }
        return mounted ? "Mounted Developer Disk Image on \(udid) from \(source)\n"
            : "Developer Disk Image already mounted on \(udid)\n"
    }

    private static func resolveRealDeviceTargetUdid(
        explicitUdid: String?,
        paths: IOSUsePaths,
        missingMessage: String
    ) throws -> String {
        try SessionService.resolveTargetUdid(
            explicitUdid: explicitUdid,
            paths: paths,
            missingMessage: missingMessage,
            fallbackUdid: {
                let realDevices = try DeviceService.listDevices(simulatorOnly: false, paths: paths).filter { $0.kind == .real }
                return realDevices.count == 1 ? realDevices[0].udid : nil
            }
        )
    }

}
