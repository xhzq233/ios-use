import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum DiskUsageService {
    struct Item: Equatable, Sendable {
        let scope: String
        let category: String
        let name: String
        let path: String
        let bytes: Int
        let modifiedAt: Date?
        let exists: Bool
        let details: [String: String]
    }

    struct Snapshot: Equatable, Sendable {
        let items: [Item]
        let warnings: [String]

        var totalBytes: Int {
            items.reduce(0) { $0 + $1.bytes }
        }

        var machineData: MachineValue {
            .object([
                "totalBytes": .integer(totalBytes),
                "items": .array(items.map(Self.machineItem)),
            ])
        }

        func formatted() -> String {
            guard !items.isEmpty else {
                return "ios-use disk usage: 0 bytes\n"
            }
            var lines = [
                "ios-use disk usage: \(Self.formatBytes(totalBytes))",
            ]
            var previousGroup: String?
            for item in items {
                let group = "\(item.scope) / \(item.category)"
                if group != previousGroup {
                    lines.append("")
                    lines.append(group)
                    previousGroup = group
                }
                let time = item.modifiedAt.map(Self.formatDate) ?? "—"
                let state = item.exists
                    ? Self.formatBytes(item.bytes)
                    : "missing"
                let detail = item.details.isEmpty
                    ? ""
                    : " (" + item.details.sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: ", ") + ")"
                lines.append("  \(state)  \(time)  \(item.name)\(detail)")
                lines.append("    \(item.path)")
            }
            if !warnings.isEmpty {
                lines.append("")
                lines.append("warnings")
                lines.append(contentsOf: warnings.map { "  \($0)" })
            }
            return lines.joined(separator: "\n") + "\n"
        }

        private static func machineItem(_ item: Item) -> MachineValue {
            .object([
                "scope": .string(item.scope),
                "category": .string(item.category),
                "name": .string(item.name),
                "path": .string(item.path),
                "bytes": .integer(item.bytes),
                "modifiedAt": item.modifiedAt.map {
                    .string(formatDate($0))
                } ?? .null,
                "exists": .boolean(item.exists),
                "details": .object(
                    item.details.mapValues(MachineValue.string)
                ),
            ])
        }

        private static func formatBytes(_ bytes: Int) -> String {
            if bytes == 0 {
                return "0 B"
            }
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useAll]
            formatter.countStyle = .file
            formatter.includesUnit = true
            formatter.isAdaptive = true
            return formatter.string(fromByteCount: Int64(bytes))
        }

        private static func formatDate(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds,
            ]
            return formatter.string(from: date)
        }
    }

    private struct Usage {
        var bytes = 0
        var modifiedAt: Date?
        var exists = false
    }

    static func snapshot(paths: IOSUsePaths) -> Snapshot {
        var items: [Item] = []
        var warnings: [String] = []

        appendChildren(
            of: paths.playcoverGlobalObjects,
            scope: "mac",
            category: "prepared",
            itemBuilder: preparedItem,
            items: &items,
            warnings: &warnings
        )
        appendPath(
            paths.playcoverGlobalLocks,
            scope: "mac",
            category: "cache",
            name: "prepare locks",
            details: [:],
            includeMissing: false,
            items: &items,
            warnings: &warnings
        )
        appendChildren(
            of: paths.playcoverFridaEngineObjects,
            scope: "mac",
            category: "frida-engine",
            itemBuilder: { url, usage, warnings in
                Item(
                    scope: "mac",
                    category: "frida-engine",
                    name: url.lastPathComponent,
                    path: url.path,
                    bytes: usage.bytes,
                    modifiedAt: usage.modifiedAt,
                    exists: usage.exists,
                    details: [:]
                )
            },
            items: &items,
            warnings: &warnings
        )
        appendPath(
            paths.playcoverFridaEngineLocks,
            scope: "mac",
            category: "cache",
            name: "Frida Engine locks",
            details: [:],
            includeMissing: false,
            items: &items,
            warnings: &warnings
        )
        appendChildren(
            of: paths.playcoverPlayChain,
            scope: "mac",
            category: "playchain",
            itemBuilder: { url, usage, warnings in
                Item(
                    scope: "mac",
                    category: "playchain",
                    name: url.lastPathComponent,
                    path: url.path,
                    bytes: usage.bytes,
                    modifiedAt: usage.modifiedAt,
                    exists: usage.exists,
                    details: [:]
                )
            },
            items: &items,
            warnings: &warnings
        )
        appendChildren(
            of: paths.knownHomes,
            scope: "shared",
            category: "home-index",
            itemBuilder: { url, usage, warnings in
                Item(
                    scope: "shared",
                    category: "home-index",
                    name: url.lastPathComponent,
                    path: url.path,
                    bytes: usage.bytes,
                    modifiedAt: usage.modifiedAt,
                    exists: usage.exists,
                    details: [:]
                )
            },
            items: &items,
            warnings: &warnings
        )

        let discovered = IOSUseHomeDiscoveryStore.read(paths: paths)
        warnings.append(contentsOf: discovered.warnings)
        var homes: [(id: String, root: String, current: Bool)] = [
            (
                id: paths.playcoverHomeID,
                root: canonicalPath(paths.root),
                current: true
            ),
        ]
        for home in discovered.homes {
            let root = canonicalPath(home.root)
            guard !homes.contains(where: { $0.root == root }) else {
                continue
            }
            homes.append((id: home.homeID, root: root, current: false))
        }
        for home in homes.sorted(by: {
            if $0.current != $1.current { return $0.current }
            return $0.root < $1.root
        }) {
            appendHome(
                id: home.id,
                root: home.root,
                current: home.current,
                items: &items,
                warnings: &warnings
            )
        }

        return Snapshot(
            items: items.sorted {
                ($0.scope, $0.category, $0.name, $0.path)
                    < ($1.scope, $1.category, $1.name, $1.path)
            },
            warnings: Array(Set(warnings)).sorted()
        )
    }

    private static func preparedItem(
        _ url: URL,
        _ usage: Usage,
        _ warnings: inout [String]
    ) -> Item {
        let generation = url.lastPathComponent
        var name = generation.hasPrefix(".staging-")
            ? "incomplete \(generation)"
            : generation
        var details: [String: String] = [
            "generation": generation,
        ]
        let app = url.appendingPathComponent("App.app", isDirectory: true)
        let plist = app.appendingPathComponent("Info.plist")
        if let metadata = appMetadata(at: plist, warnings: &warnings) {
            if let displayName = metadata.displayName {
                name = displayName
            }
            if let bundleIdentifier = metadata.bundleIdentifier {
                details["bundle"] = bundleIdentifier
            }
        }
        let manifest = url.appendingPathComponent("manifest.json")
        if let data = boundedRegularFileData(
            at: manifest,
            maximumBytes: 8 * 1_024 * 1_024,
            warnings: &warnings
        ),
           let value = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] {
            if value["fridaEnabled"] as? Bool == true {
                details["capability"] = "frida"
            } else {
                details["capability"] = "base"
            }
        } else if !generation.hasPrefix(".staging-") {
            warnings.append("cannot read prepared manifest: \(manifest.path)")
        }
        return Item(
            scope: "mac",
            category: "prepared",
            name: name,
            path: url.path,
            bytes: usage.bytes,
            modifiedAt: usage.modifiedAt,
            exists: usage.exists,
            details: details
        )
    }

    private static func appendHome(
        id: String,
        root: String,
        current: Bool,
        items: inout [Item],
        warnings: inout [String]
    ) {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        var rootStatus = stat()
        guard lstat(root, &rootStatus) == 0,
              rootStatus.st_mode & S_IFMT == S_IFDIR else {
            items.append(
                Item(
                    scope: "home",
                    category: "missing",
                    name: current ? "current Home" : "known Home",
                    path: root,
                    bytes: 0,
                    modifiedAt: nil,
                    exists: false,
                    details: ["homeID": id]
                )
            )
            return
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(
                atPath: root
            ).sorted()
        } catch {
            warnings.append("cannot list Home \(root): \(error)")
            return
        }
        if names.isEmpty {
            appendPath(
                root,
                scope: "home",
                category: "empty",
                name: current ? "current Home" : "known Home",
                details: ["homeID": id],
                includeMissing: true,
                items: &items,
                warnings: &warnings
            )
            return
        }
        for name in names {
            let category: String
            switch name {
            case "logs": category = "logs"
            case "artifacts": category = "artifacts"
            case "state": category = "state"
            case "mac": category = "mac"
            case "config.json": category = "config"
            default: category = "shared"
            }
            appendPath(
                rootURL.appendingPathComponent(name).path,
                scope: "home",
                category: category,
                name: "\(current ? "current" : "known") \(name)",
                details: ["homeID": id],
                includeMissing: false,
                items: &items,
                warnings: &warnings
            )
        }
    }

    private static func appendChildren(
        of root: String,
        scope: String,
        category: String,
        itemBuilder: (URL, Usage, inout [String]) -> Item,
        items: inout [Item],
        warnings: inout [String]
    ) {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(
                atPath: root
            ).sorted()
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileNoSuchFileError {
            return
        } catch {
            if FileManager.default.fileExists(atPath: root) {
                warnings.append("cannot list \(root): \(error)")
            }
            return
        }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        for name in names {
            let url = rootURL.appendingPathComponent(name)
            let usage = diskUsage(at: url.path, warnings: &warnings)
            items.append(itemBuilder(url, usage, &warnings))
        }
    }

    private static func appendPath(
        _ path: String,
        scope: String,
        category: String,
        name: String,
        details: [String: String],
        includeMissing: Bool,
        items: inout [Item],
        warnings: inout [String]
    ) {
        let usage = diskUsage(at: path, warnings: &warnings)
        guard usage.exists || includeMissing else { return }
        items.append(
            Item(
                scope: scope,
                category: category,
                name: name,
                path: path,
                bytes: usage.bytes,
                modifiedAt: usage.modifiedAt,
                exists: usage.exists,
                details: details
            )
        )
    }

    private static func diskUsage(
        at root: String,
        warnings: inout [String]
    ) -> Usage {
        var result = Usage()
        var pending = [root]
        while let path = pending.popLast() {
            var status = stat()
            guard lstat(path, &status) == 0 else {
                if errno != ENOENT {
                    warnings.append("cannot inspect \(path): errno \(errno)")
                }
                continue
            }
            result.exists = true
            let allocated = max(0, Int(status.st_blocks) * 512)
            result.bytes += allocated
            #if canImport(Darwin)
            let seconds = TimeInterval(status.st_mtimespec.tv_sec)
            let nanos = TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
            #else
            let seconds = TimeInterval(status.st_mtim.tv_sec)
            let nanos = TimeInterval(status.st_mtim.tv_nsec) / 1_000_000_000
            #endif
            let date = Date(timeIntervalSince1970: seconds + nanos)
            if result.modifiedAt == nil || date > result.modifiedAt! {
                result.modifiedAt = date
            }
            guard status.st_mode & S_IFMT == S_IFDIR else {
                continue
            }
            do {
                let names = try FileManager.default.contentsOfDirectory(
                    atPath: path
                )
                pending.append(
                    contentsOf: names.map {
                        URL(fileURLWithPath: path, isDirectory: true)
                            .appendingPathComponent($0).path
                    }
                )
            } catch {
                warnings.append("cannot list \(path): \(error)")
            }
        }
        return result
    }

    private static func appMetadata(
        at plist: URL,
        warnings: inout [String]
    ) -> (displayName: String?, bundleIdentifier: String?)? {
        guard let data = boundedRegularFileData(
            at: plist,
            maximumBytes: 2 * 1_024 * 1_024,
            warnings: &warnings
        ) else {
            return nil
        }
        guard let value = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            warnings.append("cannot decode App Info.plist: \(plist.path)")
            return nil
        }
        let displayName = value["CFBundleDisplayName"] as? String
            ?? value["CFBundleName"] as? String
        return (displayName, value["CFBundleIdentifier"] as? String)
    }

    private static func boundedRegularFileData(
        at url: URL,
        maximumBytes: Int,
        warnings: inout [String]
    ) -> Data? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return nil }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0,
              status.st_size <= maximumBytes else {
            warnings.append("ignored non-regular or oversized file: \(url.path)")
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            warnings.append("cannot read \(url.path): \(error)")
            return nil
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return url.path
        }
        return url.resolvingSymlinksInPath().path
    }
}
