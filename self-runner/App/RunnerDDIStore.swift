import Foundation

/// Images are resources, not credentials. Keep the imported copy out of backups
/// and replace it only after a complete, validated import has finished.
enum RunnerDDIStore {
    static let imported = URL.applicationSupportDirectory.appendingPathComponent("DDI", isDirectory: true)
    static var bundled: URL? { Bundle.main.resourceURL?.appendingPathComponent("DDI", isDirectory: true) }
    static var description: String {
        if FileManager.default.fileExists(atPath: imported.appendingPathComponent("BuildManifest.plist").path) { return "Imported image available" }
        if let bundled, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("BuildManifest.plist").path) { return "Bundled image available" }
        return "Import an image folder if DDI is not already mounted"
    }

    static func resolve(identifiers: DeveloperDiskImageBuildManifest.DeviceIdentifiers) throws -> ResolvedDeveloperDiskImage {
        // An explicit import overrides the bundled image, including its errors.
        for root in [imported, bundled].compactMap({ $0 }) where FileManager.default.fileExists(atPath: root.path) {
            if let resolved = try ResolvedDeveloperDiskImage.directory(root, identifiers: identifiers) { return resolved }
            throw DeveloperDiskImageError.commandFailed("DDI folder has no BuildManifest.plist; import the extracted Restore folder")
        }
        throw DeveloperDiskImageError.commandFailed("DDI is not mounted. Import a matching extracted Restore folder, or install a Runner built with --ddi. Then start again.")
    }

    static func importFolder(_ selected: URL) throws {
        let scoped = selected.startAccessingSecurityScopedResource()
        defer { if scoped { selected.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let root = fm.fileExists(atPath: selected.appendingPathComponent("BuildManifest.plist").path)
            ? selected : selected.appendingPathComponent("Restore", isDirectory: true)
        let manifestURL = try ResolvedDeveloperDiskImage.containedFile("BuildManifest.plist", in: root)
        let manifest = try DeveloperDiskImageBuildManifest(url: manifestURL)
        guard let identities = manifest.root["BuildIdentities"] as? [[String: Any]], !identities.isEmpty else {
            throw DeveloperDiskImageError.missingManifestEntry("BuildIdentities")
        }
        var paths: Set<String> = ["BuildManifest.plist"]
        for raw in identities {
            guard let entries = raw["Manifest"] as? [String: Any],
                  entries["PersonalizedDMG"] != nil || entries["PersonalizedDmg"] != nil else { continue }
            guard let board = DeveloperDiskImageBuildManifest.integer(raw["ApBoardID"]),
                  let chip = DeveloperDiskImageBuildManifest.integer(raw["ApChipID"]) else {
                throw DeveloperDiskImageError.missingManifestEntry("ApBoardID/ApChipID")
            }
            let identity = try manifest.identity(for: .init(boardID: board, chipID: chip, securityDomain: 1, apTags: [:]))
            paths.insert(identity.imageRelativePath); paths.insert(identity.trustCacheRelativePath)
        }
        guard paths.count > 1 else { throw DeveloperDiskImageError.missingManifestEntry("PersonalizedDMG") }
        let stage = URL.applicationSupportDirectory.appendingPathComponent("ddi-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        var total: Int64 = 0
        for path in paths.sorted() {
            let source = try ResolvedDeveloperDiskImage.containedFile(path, in: root)
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            total += Int64(size)
            guard size > 0, total <= 1_073_741_824 else {
                throw DeveloperDiskImageError.commandFailed("DDI files must be nonempty and total at most 1 GiB")
            }
            let destination = stage.appendingPathComponent(path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
        }
        var stageURL = stage
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try stageURL.setResourceValues(values)
        if fm.fileExists(atPath: imported.path) {
            _ = try fm.replaceItemAt(imported, withItemAt: stage)
        } else { try fm.moveItem(at: stage, to: imported) }
    }

    static func removeImport() throws {
        if FileManager.default.fileExists(atPath: imported.path) { try FileManager.default.removeItem(at: imported) }
    }
}
