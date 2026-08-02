import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum DiskUsageService {
    struct Item: Equatable, Sendable {
        let scope: String
        let category: String
        let storageClass: String
        let name: String
        let path: String
        let bytes: Int
        let modifiedAt: Date?
        let exists: Bool
        let complete: Bool
        let cleanupImpact: String
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
                "measurement": .string("allocated-bytes"),
                "groups": .array(Self.storageClassOrder.compactMap {
                    storageClass in
                    let matching = items.filter {
                        $0.storageClass == storageClass
                    }
                    guard !matching.isEmpty else { return nil }
                    return .object([
                        "storageClass": .string(storageClass),
                        "bytes": .integer(
                            matching.reduce(0) { $0 + $1.bytes }
                        ),
                    ])
                }),
                "items": .array(items.map(Self.machineItem)),
            ])
        }

        func formatted() -> String {
            var lines = [
                "ios-use disk usage: \(Self.formatBytes(totalBytes)) allocated",
            ]
            for storageClass in Self.storageClassOrder {
                let matching = items.filter {
                    $0.storageClass == storageClass
                }
                guard !matching.isEmpty else { continue }
                lines.append("")
                lines.append(
                    "\(Self.storageClassTitle(storageClass)) — "
                        + Self.formatBytes(
                            matching.reduce(0) { $0 + $1.bytes }
                        )
                )
                lines.append(
                    "  \(Self.storageClassGuidance(storageClass))"
                )
                if storageClass == "home-data" {
                    lines.append(contentsOf: Self.formatHomes(
                        matching,
                        allItems: items
                    ))
                    continue
                }
                if storageClass == "app-data" {
                    lines.append(contentsOf: Self.formatAppData(
                        matching,
                        allItems: items
                    ))
                    continue
                }
                if storageClass == "metadata-residue" {
                    lines.append(contentsOf: Self.formatMetadata(matching))
                    continue
                }
                for item in matching.sorted(by: Self.itemOrder) {
                    lines.append(contentsOf: Self.formatItem(item))
                }
            }
            if items.isEmpty {
                lines.append("  No ios-use-owned files were found.")
            }
            if !warnings.isEmpty {
                lines.append("")
                lines.append("Warnings — totals may be incomplete")
                lines.append(contentsOf: warnings.map { "  \($0)" })
            }
            return lines.joined(separator: "\n") + "\n"
        }

        static let storageClassOrder = [
            "rebuildable-cache",
            "app-data",
            "home-data",
            "metadata-residue",
        ]

        private static func storageClassTitle(
            _ storageClass: String
        ) -> String {
            switch storageClass {
            case "rebuildable-cache": return "Rebuildable cache"
            case "app-data": return "Persistent App data"
            case "home-data": return "IOS_USE_HOME data"
            default: return "Metadata and residue"
            }
        }

        private static func storageClassGuidance(
            _ storageClass: String
        ) -> String {
            switch storageClass {
            case "rebuildable-cache":
                return "Removing it saves space; a later command may prepare, build, or download it again."
            case "app-data":
                return "Removing it resets persistent data for the named Mac App."
            case "home-data":
                return "Removing a Home loses its config, logs, artifacts, and session/reuse state."
            default:
                return "Review before removing; entries may be identity evidence or belong to a running command."
            }
        }

        private static func itemOrder(_ lhs: Item, _ rhs: Item) -> Bool {
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return (lhs.name, lhs.path) < (rhs.name, rhs.path)
        }

        private static func formatItem(_ item: Item) -> [String] {
            let time = item.modifiedAt.map(formatDate) ?? "—"
            let state = item.exists ? formatBytes(item.bytes) : "missing"
            let partial = item.complete ? "" : "  partial"
            return [
                "  \(state)  \(time)  \(item.name)"
                    + humanDetails(item) + partial,
                "    \(item.path)",
            ]
        }

        private static func humanDetails(_ item: Item) -> String {
            var values: [String] = []
            if let version = item.details["version"] {
                let build = item.details["build"].map { " (\($0))" } ?? ""
                values.append("v\(version)\(build)")
            }
            if let capability = item.details["capability"] {
                values.append(capability)
            }
            if let references = item.details["homeReferences"] {
                values.append(
                    "\(references) Home ref\(references == "1" ? "" : "s")"
                )
            }
            if let sessions = item.details["sessionReferences"],
               sessions != "0" {
                values.append(
                    "\(sessions) session record\(sessions == "1" ? "" : "s")"
                )
            }
            if let role = item.details["role"] {
                values.append(role)
            }
            return values.isEmpty
                ? ""
                : "  [" + values.joined(separator: ", ") + "]"
        }

        private static func formatHomes(
            _ homeItems: [Item],
            allItems: [Item]
        ) -> [String] {
            let preparedNames: [String: String] = Dictionary(
                uniqueKeysWithValues: allItems.compactMap { item in
                    guard item.category == "prepared",
                          let generation = item.details["generation"] else {
                        return nil
                    }
                    return (generation, item.name)
                }
            )
            let grouped = Dictionary(grouping: homeItems) {
                $0.details["homeRoot"] ?? $0.path
            }
            return grouped.keys.sorted { lhs, rhs in
                let left = grouped[lhs] ?? []
                let right = grouped[rhs] ?? []
                let leftCurrent = left.contains {
                    $0.details["homeRole"] == "current"
                }
                let rightCurrent = right.contains {
                    $0.details["homeRole"] == "current"
                }
                if leftCurrent != rightCurrent { return leftCurrent }
                let leftBytes = left.reduce(0) { $0 + $1.bytes }
                let rightBytes = right.reduce(0) { $0 + $1.bytes }
                if leftBytes != rightBytes { return leftBytes > rightBytes }
                return lhs < rhs
            }.flatMap { root -> [String] in
                let group = grouped[root] ?? []
                let current = group.contains {
                    $0.details["homeRole"] == "current"
                }
                let exists = group.contains { $0.exists }
                let bytes = group.reduce(0) { $0 + $1.bytes }
                let modified = group.compactMap(\.modifiedAt).max()
                let complete = group.allSatisfy(\.complete)
                var result = [
                    "  \(exists ? formatBytes(bytes) : "missing")  "
                        + "\(modified.map(formatDate) ?? "—")  "
                        + "\(current ? "current Home" : "known Home")"
                        + (complete ? "" : "  partial"),
                    "    \(root)",
                ]
                let byCategory = Dictionary(
                    grouping: group.filter(\.exists),
                    by: \.category
                )
                let contents = byCategory.map { category, values in
                    (
                        category,
                        values.reduce(0) { $0 + $1.bytes }
                    )
                }.filter {
                    $0.1 > 0
                }.sorted {
                    if $0.1 != $1.1 { return $0.1 > $1.1 }
                    return $0.0 < $1.0
                }.map { "\($0.0) \(formatBytes($0.1))" }
                if !contents.isEmpty {
                    result.append(
                        "    contains: " + contents.joined(separator: ", ")
                    )
                }
                if let generation = group.compactMap({
                    $0.details["generation"]
                }).first {
                    let target = preparedNames[generation]
                        ?? "missing prepared generation \(generation.prefix(12))…"
                    result.append("    reuses: \(target)")
                }
                if group.contains(where: {
                    $0.details["sessionGeneration"] != nil
                }) {
                    result.append("    Mac session record present")
                }
                if let descriptor = group.compactMap({
                    $0.details["discoveryRecord"]
                }).first,
                   !exists {
                    result.append("    stale discovery record: \(descriptor)")
                }
                return result
            }
        }

        private static func formatAppData(
            _ appItems: [Item],
            allItems: [Item]
        ) -> [String] {
            var preparedNames: [String: String] = [:]
            for item in allItems where item.category == "prepared" {
                guard let bundle = item.details["bundle"],
                      preparedNames[bundle] == nil else {
                    continue
                }
                preparedNames[bundle] = item.name
            }
            let grouped = Dictionary(grouping: appItems) {
                $0.details["bundle"] ?? $0.name
            }
            return grouped.keys.sorted { lhs, rhs in
                let left = grouped[lhs] ?? []
                let right = grouped[rhs] ?? []
                let leftBytes = left.reduce(0) { $0 + $1.bytes }
                let rightBytes = right.reduce(0) { $0 + $1.bytes }
                if leftBytes != rightBytes { return leftBytes > rightBytes }
                return lhs < rhs
            }.flatMap { bundle -> [String] in
                let group = grouped[bundle] ?? []
                let bytes = group.reduce(0) { $0 + $1.bytes }
                let modified = group.compactMap(\.modifiedAt).max()
                let complete = group.allSatisfy(\.complete)
                let displayName = preparedNames[bundle].map {
                    "\($0) (\(bundle))"
                } ?? bundle
                let fileCount = group.count
                let root = group.first.map {
                    URL(fileURLWithPath: $0.path)
                        .deletingLastPathComponent().path
                } ?? ""
                return [
                    "  \(formatBytes(bytes))  "
                        + "\(modified.map(formatDate) ?? "—")  "
                        + displayName
                        + (complete ? "" : "  partial"),
                    "    \(fileCount) PlayChain file"
                        + (fileCount == 1 ? "" : "s")
                        + " under \(root); exact paths in --json",
                ]
            }
        }

        private static func formatMetadata(_ metadataItems: [Item]) -> [String] {
            let directCategories = Set([
                "home-discovery",
                "signing-identity",
            ])
            let direct = metadataItems.filter {
                directCategories.contains($0.category)
            }.sorted(by: itemOrder).flatMap(formatItem)
            let grouped = Dictionary(grouping: metadataItems.filter {
                !directCategories.contains($0.category)
            }) { item in
                item.category == "lock"
                    ? "\(item.category):\(item.name)"
                    : item.category
            }
            let summaries = grouped.values.sorted { lhs, rhs in
                let leftBytes = lhs.reduce(0) { $0 + $1.bytes }
                let rightBytes = rhs.reduce(0) { $0 + $1.bytes }
                if leftBytes != rightBytes { return leftBytes > rightBytes }
                return metadataTitle(lhs) < metadataTitle(rhs)
            }.flatMap { group -> [String] in
                let bytes = group.reduce(0) { $0 + $1.bytes }
                let modified = group.compactMap(\.modifiedAt).max()
                let complete = group.allSatisfy(\.complete)
                let count = group.count
                let roots = Set(group.map {
                    URL(fileURLWithPath: $0.path)
                        .deletingLastPathComponent().path
                }).sorted()
                var result = [
                    "  \(formatBytes(bytes))  "
                        + "\(modified.map(formatDate) ?? "—")  "
                        + metadataTitle(group)
                        + " (\(count) entr\(count == 1 ? "y" : "ies"); "
                        + "exact paths in --json)"
                        + (complete ? "" : "  partial"),
                ]
                if roots.count == 1, let root = roots.first {
                    result.append("    \(root)")
                }
                return result
            }
            return direct + summaries
        }

        private static func metadataTitle(_ items: [Item]) -> String {
            guard let item = items.first else { return "Residue" }
            switch item.category {
            case "launch-facade": return "Launch facades"
            case "runtime-socket": return "Runtime sockets"
            case "lock":
                return item.name == "Frida Engine lock"
                    ? "Frida Engine locks"
                    : "Prepare locks"
            default: return item.name
            }
        }

        private static func machineItem(_ item: Item) -> MachineValue {
            .object([
                "scope": .string(item.scope),
                "category": .string(item.category),
                "storageClass": .string(item.storageClass),
                "name": .string(item.name),
                "path": .string(item.path),
                "bytes": .integer(item.bytes),
                "modifiedAt": item.modifiedAt.map {
                    .string(formatDate($0))
                } ?? .null,
                "exists": .boolean(item.exists),
                "complete": .boolean(item.complete),
                "cleanupImpact": .string(item.cleanupImpact),
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
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.string(from: date)
        }
    }

    private struct Usage {
        var bytes = 0
        var modifiedAt: Date?
        var exists = false
        var complete = true
    }

    private struct WalkBudget {
        var remaining: Int
        var warned = false
    }

    private struct HomeInfo {
        let id: String
        let root: String
        let current: Bool
        let discoveryRecord: String?
        let generation: String?
        let sessionGeneration: String?
    }

    static func snapshot(
        paths: IOSUsePaths,
        traversalEntryLimit: Int = 200_000
    ) -> Snapshot {
        var items: [Item] = []
        var warnings: [String] = []
        var budget = WalkBudget(remaining: max(1, traversalEntryLimit))

        let homes = collectHomes(paths: paths, warnings: &warnings)
        let generationReferences = Dictionary(grouping: homes.compactMap {
            home -> (String, Bool)? in
            guard let generation = home.generation else { return nil }
            return (generation, home.sessionGeneration == generation)
        }, by: { $0.0 })

        appendChildren(
            of: paths.playcoverGlobalObjects,
            scope: "mac",
            category: "prepared",
            itemBuilder: { url, usage, warnings in
                let generation = url.lastPathComponent
                let references = generationReferences[generation] ?? []
                return preparedItem(
                    url,
                    usage,
                    homeReferences: references.count,
                    sessionReferences: references.filter(\.1).count,
                    warnings: &warnings
                )
            },
            items: &items,
            warnings: &warnings,
            budget: &budget
        )
        appendChildren(
            of: paths.playcoverGlobalLocks,
            scope: "mac",
            category: "lock",
            itemBuilder: { url, usage, _ in
                usageItem(
                    url: url,
                    usage: usage,
                    scope: "mac",
                    category: "lock",
                    storageClass: "metadata-residue",
                    name: "prepare lock",
                    cleanupImpact:
                        "May belong to a running prepare or launch."
                )
            },
            items: &items,
            warnings: &warnings,
            budget: &budget
        )
        appendChildren(
            of: paths.playcoverFridaEngineObjects,
            scope: "mac",
            category: "frida-engine",
            itemBuilder: { url, usage, _ in
                usageItem(
                    url: url,
                    usage: usage,
                    scope: "mac",
                    category: "frida-engine",
                    storageClass: "rebuildable-cache",
                    name: "Frida Engine "
                        + PlayCoverFridaEngineService.descriptorVersion,
                    cleanupImpact:
                        "A later Frida-enabled prepare must reacquire this Engine.",
                    details: ["digest": url.lastPathComponent]
                )
            },
            items: &items,
            warnings: &warnings,
            budget: &budget
        )
        for (path, name) in [
            (
                "\(paths.playcoverFridaEngineRoot)/source",
                "Frida source cache"
            ),
            (
                "\(paths.playcoverFridaEngineRoot)/build",
                "Frida build cache"
            ),
        ] {
            appendPath(
                path,
                scope: "mac",
                category: "frida-development",
                storageClass: "rebuildable-cache",
                name: name,
                cleanupImpact:
                    "A later local Frida build must recreate it.",
                details: [:],
                includeMissing: false,
                items: &items,
                warnings: &warnings,
                budget: &budget
            )
        }
        appendChildren(
            of: paths.playcoverFridaEngineLocks,
            scope: "mac",
            category: "lock",
            itemBuilder: { url, usage, _ in
                usageItem(
                    url: url,
                    usage: usage,
                    scope: "mac",
                    category: "lock",
                    storageClass: "metadata-residue",
                    name: "Frida Engine lock",
                    cleanupImpact:
                        "May belong to a running Engine acquisition."
                )
            },
            items: &items,
            warnings: &warnings,
            budget: &budget
        )
        appendChildren(
            of: paths.playcoverPlayChain,
            scope: "mac",
            category: "playchain",
            itemBuilder: { url, usage, _ in
                let identity = playchainFileIdentity(url.lastPathComponent)
                return usageItem(
                    url: url,
                    usage: usage,
                    scope: "mac",
                    category: "playchain",
                    storageClass: "app-data",
                    name: identity.bundle,
                    cleanupImpact:
                        "Resets persistent data for this Mac App bundle.",
                    details: [
                        "bundle": identity.bundle,
                        "fileRole": identity.role,
                    ]
                )
            },
            items: &items,
            warnings: &warnings,
            budget: &budget
        )
        appendPath(
            paths.knownHomes,
            scope: "shared",
            category: "home-discovery",
            storageClass: "metadata-residue",
            name: "Home discovery records",
            cleanupImpact:
                "Removing records only makes those Homes undiscoverable to `ios-use du`.",
            details: ["role": "discovery metadata"],
            includeMissing: false,
            items: &items,
            warnings: &warnings,
            budget: &budget
        )
        appendPath(
            paths.playcoverSigningBinding,
            scope: "shared",
            category: "signing-identity",
            storageClass: "metadata-residue",
            name: "Mac signing identity binding",
            cleanupImpact:
                "Removing it requires `ios-use config --mac` and may make existing prepared Apps unusable.",
            details: ["role": "do not remove during normal cleanup"],
            includeMissing: false,
            items: &items,
            warnings: &warnings,
            budget: &budget
        )
        appendChildren(
            of: paths.playcoverLaunchFacades,
            scope: "mac",
            category: "launch-facade",
            itemBuilder: { url, usage, _ in
                usageItem(
                    url: url,
                    usage: usage,
                    scope: "mac",
                    category: "launch-facade",
                    storageClass: "metadata-residue",
                    name: url.lastPathComponent,
                    cleanupImpact:
                        "May belong to a running Mac App session."
                )
            },
            items: &items,
            warnings: &warnings,
            budget: &budget
        )
        appendChildren(
            of: paths.playcoverSocketRoot,
            scope: "mac",
            category: "runtime-socket",
            itemBuilder: { url, usage, _ in
                usageItem(
                    url: url,
                    usage: usage,
                    scope: "mac",
                    category: "runtime-socket",
                    storageClass: "metadata-residue",
                    name: url.lastPathComponent,
                    cleanupImpact:
                        "May belong to a running Mac Runtime session."
                )
            },
            items: &items,
            warnings: &warnings,
            budget: &budget
        )

        for home in homes {
            appendHome(
                home,
                items: &items,
                warnings: &warnings,
                budget: &budget
            )
        }

        return Snapshot(
            items: items.sorted {
                let leftClass = Snapshot.storageClassOrder
                    .firstIndex(of: $0.storageClass) ?? Int.max
                let rightClass = Snapshot.storageClassOrder
                    .firstIndex(of: $1.storageClass) ?? Int.max
                if leftClass != rightClass { return leftClass < rightClass }
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                return ($0.scope, $0.category, $0.name, $0.path)
                    < ($1.scope, $1.category, $1.name, $1.path)
            },
            warnings: Array(Set(warnings)).sorted()
        )
    }

    private static func preparedItem(
        _ url: URL,
        _ usage: Usage,
        homeReferences: Int,
        sessionReferences: Int,
        warnings: inout [String]
    ) -> Item {
        let generation = url.lastPathComponent
        var name = generation.hasPrefix(".staging-")
            ? "incomplete \(generation)"
            : generation
        var details: [String: String] = [
            "generation": generation,
            "homeReferences": String(homeReferences),
            "sessionReferences": String(sessionReferences),
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
            if let version = metadata.version {
                details["version"] = version
            }
            if let build = metadata.build {
                details["build"] = build
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
            storageClass: "rebuildable-cache",
            name: name,
            path: url.path,
            bytes: usage.bytes,
            modifiedAt: usage.modifiedAt,
            exists: usage.exists,
            complete: usage.complete,
            cleanupImpact:
                "A later start must prepare this App again.",
            details: details
        )
    }

    private static func usageItem(
        url: URL,
        usage: Usage,
        scope: String,
        category: String,
        storageClass: String,
        name: String,
        cleanupImpact: String,
        details: [String: String] = [:]
    ) -> Item {
        Item(
            scope: scope,
            category: category,
            storageClass: storageClass,
            name: name,
            path: url.path,
            bytes: usage.bytes,
            modifiedAt: usage.modifiedAt,
            exists: usage.exists,
            complete: usage.complete,
            cleanupImpact: cleanupImpact,
            details: details
        )
    }

    private static func collectHomes(
        paths: IOSUsePaths,
        warnings: inout [String]
    ) -> [HomeInfo] {
        let discovered = IOSUseHomeDiscoveryStore.read(paths: paths)
        warnings.append(contentsOf: discovered.warnings)
        let currentRoot = canonicalPath(paths.root)
        var candidates: [String: (
            id: String,
            current: Bool,
            discoveryRecord: String?
        )] = [
            currentRoot: (
                id: paths.playcoverHomeID,
                current: true,
                discoveryRecord: nil
            ),
        ]
        for home in discovered.homes {
            let root = canonicalPath(home.root)
            let record = URL(
                fileURLWithPath: paths.knownHomes,
                isDirectory: true
            ).appendingPathComponent("\(home.homeID).json").path
            if let existing = candidates[root] {
                candidates[root] = (
                    id: existing.id,
                    current: existing.current,
                    discoveryRecord: record
                )
            } else {
                candidates[root] = (
                    id: home.homeID,
                    current: false,
                    discoveryRecord: record
                )
            }
        }
        return candidates.map { root, value in
            HomeInfo(
                id: value.id,
                root: root,
                current: value.current,
                discoveryRecord: value.discoveryRecord,
                generation: readGenerationReference(
                    root: root,
                    warnings: &warnings
                ),
                sessionGeneration: readSessionGeneration(
                    root: root,
                    warnings: &warnings
                )
            )
        }.sorted {
            if $0.current != $1.current { return $0.current }
            return $0.root < $1.root
        }
    }

    private static func appendHome(
        _ home: HomeInfo,
        items: inout [Item],
        warnings: inout [String],
        budget: inout WalkBudget
    ) {
        let root = home.root
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        var rootStatus = stat()
        guard lstat(root, &rootStatus) == 0,
              rootStatus.st_mode & S_IFMT == S_IFDIR else {
            guard home.discoveryRecord != nil else {
                return
            }
            let details = homeDetails(home)
            items.append(
                Item(
                    scope: "home",
                    category: "missing",
                    storageClass: "home-data",
                    name: home.current ? "current Home" : "known Home",
                    path: root,
                    bytes: 0,
                    modifiedAt: nil,
                    exists: false,
                    complete: true,
                    cleanupImpact:
                        "The Home is already missing; only its discovery metadata may remain.",
                    details: details
                )
            )
            return
        }
        guard let listing = boundedChildNames(
            at: root,
            maximumCount: budget.remaining,
            warnings: &warnings
        ) else {
            return
        }
        let names = listing.names
        if listing.truncated {
            markTraversalLimit(budget: &budget, warnings: &warnings)
        }
        if names.isEmpty {
            guard home.discoveryRecord != nil else {
                return
            }
            appendPath(
                root,
                scope: "home",
                category: "empty",
                storageClass: "home-data",
                name: home.current ? "current Home" : "known Home",
                cleanupImpact: "Removes this empty logical Home.",
                details: homeDetails(home),
                includeMissing: true,
                items: &items,
                warnings: &warnings,
                budget: &budget
            )
            return
        }
        for name in names {
            guard let category = homeCategory(for: name) else {
                warnings.append(
                    "ignored unrecognized item in Home: "
                        + rootURL.appendingPathComponent(name).path
                )
                continue
            }
            appendPath(
                rootURL.appendingPathComponent(name).path,
                scope: "home",
                category: category,
                storageClass: "home-data",
                name: name,
                cleanupImpact: homeCleanupImpact(category: category),
                details: homeDetails(home),
                includeMissing: false,
                items: &items,
                warnings: &warnings,
                budget: &budget
            )
        }
    }

    private static func homeDetails(_ home: HomeInfo) -> [String: String] {
        var details = [
            "homeID": home.id,
            "homeRoot": home.root,
            "homeRole": home.current ? "current" : "known",
        ]
        if let discoveryRecord = home.discoveryRecord {
            details["discoveryRecord"] = discoveryRecord
        }
        if let generation = home.generation {
            details["generation"] = generation
        }
        if let sessionGeneration = home.sessionGeneration {
            details["sessionGeneration"] = sessionGeneration
        }
        return details
    }

    private static func homeCategory(for name: String) -> String? {
        switch name {
        case "logs", "cli.log": return "logs"
        case "artifacts": return "artifacts"
        case "state": return "state"
        case "mac": return "mac"
        case "config.json": return "config"
        case "runtime": return "runtime"
        case "mitmproxy": return "proxy"
        case "altsign-cli": return "signing-tool"
        case "driver.ipa", "driver-sim.ipa": return "driver-assets"
        default:
            if name.hasPrefix("driver-signed-") && name.hasSuffix(".ipa") {
                return "driver-assets"
            }
            if name.hasPrefix("driver-sim-install-") {
                return "simulator-driver"
            }
            if name.hasPrefix("ipa-rewrite-")
                || name.hasPrefix("signed-preflight-") {
                return "incomplete-work"
            }
            return nil
        }
    }

    private static func playchainFileIdentity(
        _ name: String
    ) -> (bundle: String, role: String) {
        for (suffix, role) in [
            (".db-journal", "journal"),
            (".db-wal", "write-ahead log"),
            (".db-shm", "shared memory"),
            (".db", "database"),
        ] where name.hasSuffix(suffix) {
            return (String(name.dropLast(suffix.count)), role)
        }
        return (name, "data")
    }

    private static func homeCleanupImpact(category: String) -> String {
        switch category {
        case "logs": return "Deletes diagnostic logs."
        case "artifacts": return "Deletes user-created screenshots and artifacts."
        case "config": return "Removes configured device and signing metadata."
        case "state", "mac":
            return "Removes session and Mac reuse state; stop active commands first."
        case "proxy": return "Removes proxy state and local CA material."
        case "driver-assets", "simulator-driver", "signing-tool":
            return "A later setup must reinstall or rebuild this tool or driver."
        case "runtime": return "Removes generated local Runtime credentials."
        default: return "Removes incomplete work left by an interrupted command."
        }
    }

    private static func appendChildren(
        of root: String,
        scope: String,
        category: String,
        itemBuilder: (URL, Usage, inout [String]) -> Item,
        items: inout [Item],
        warnings: inout [String],
        budget: inout WalkBudget
    ) {
        guard let listing = boundedChildNames(
            at: root,
            maximumCount: budget.remaining,
            warnings: &warnings
        ) else {
            return
        }
        let names = listing.names
        if listing.truncated {
            markTraversalLimit(budget: &budget, warnings: &warnings)
        }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        for name in names {
            let url = rootURL.appendingPathComponent(name)
            let usage = diskUsage(
                at: url.path,
                warnings: &warnings,
                budget: &budget
            )
            items.append(itemBuilder(url, usage, &warnings))
        }
    }

    private static func appendPath(
        _ path: String,
        scope: String,
        category: String,
        storageClass: String,
        name: String,
        cleanupImpact: String,
        details: [String: String],
        includeMissing: Bool,
        items: inout [Item],
        warnings: inout [String],
        budget: inout WalkBudget
    ) {
        let usage = diskUsage(
            at: path,
            warnings: &warnings,
            budget: &budget
        )
        guard usage.exists || includeMissing else { return }
        items.append(
            Item(
                scope: scope,
                category: category,
                storageClass: storageClass,
                name: name,
                path: path,
                bytes: usage.bytes,
                modifiedAt: usage.modifiedAt,
                exists: usage.exists,
                complete: usage.complete,
                cleanupImpact: cleanupImpact,
                details: details
            )
        )
    }

    private static func diskUsage(
        at root: String,
        warnings: inout [String],
        budget: inout WalkBudget
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
            guard budget.remaining > 0 else {
                result.complete = false
                markTraversalLimit(budget: &budget, warnings: &warnings)
                break
            }
            budget.remaining -= 1
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
            let available = max(0, budget.remaining - pending.count)
            guard let listing = boundedChildNames(
                at: path,
                maximumCount: available,
                warnings: &warnings
            ) else {
                result.complete = false
                continue
            }
            if listing.truncated {
                result.complete = false
                markTraversalLimit(budget: &budget, warnings: &warnings)
            }
            pending.append(
                contentsOf: listing.names.map {
                    URL(fileURLWithPath: path, isDirectory: true)
                        .appendingPathComponent($0).path
                }
            )
        }
        return result
    }

    private static func boundedChildNames(
        at root: String,
        maximumCount: Int,
        warnings: inout [String]
    ) -> (names: [String], truncated: Bool)? {
        var status = stat()
        guard lstat(root, &status) == 0 else {
            if errno != ENOENT && errno != ENOTDIR {
                warnings.append("cannot inspect \(root): errno \(errno)")
            }
            return nil
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            warnings.append("cannot list non-directory \(root)")
            return nil
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            warnings.append("cannot list \(root)")
            return nil
        }
        var names: [String] = []
        var truncated = false
        while let child = enumerator.nextObject() as? URL {
            if names.count >= maximumCount {
                truncated = true
                break
            }
            names.append(child.lastPathComponent)
        }
        if let enumerationError {
            warnings.append("cannot list \(root): \(enumerationError)")
            return nil
        }
        return (names.sorted(), truncated)
    }

    private static func markTraversalLimit(
        budget: inout WalkBudget,
        warnings: inout [String]
    ) {
        guard !budget.warned else { return }
        warnings.append(
            "disk usage traversal limit reached; remaining totals are partial"
        )
        budget.warned = true
    }

    private static func appMetadata(
        at plist: URL,
        warnings: inout [String]
    ) -> (
        displayName: String?,
        bundleIdentifier: String?,
        version: String?,
        build: String?
    )? {
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
        return (
            displayName,
            value["CFBundleIdentifier"] as? String,
            value["CFBundleShortVersionString"] as? String,
            value["CFBundleVersion"] as? String
        )
    }

    private static func readGenerationReference(
        root: String,
        warnings: inout [String]
    ) -> String? {
        let path = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("mac", isDirectory: true)
            .appendingPathComponent("last-generation.json").path
        guard let data = ownerOnlyRegularFileData(
            at: path,
            maximumBytes: 32 * 1_024,
            label: "Mac last-generation reference",
            warnings: &warnings
        ) else {
            return nil
        }
        guard let value = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(value.keys) == Set(["generationKey"]),
              let generation = value["generationKey"] as? String,
              isLowercaseSHA256(generation) else {
            warnings.append("invalid Mac generation reference: \(path)")
            return nil
        }
        return generation
    }

    private static func readSessionGeneration(
        root: String,
        warnings: inout [String]
    ) -> String? {
        let path = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("driver.lock").path
        guard let data = ownerOnlyRegularFileData(
            at: path,
            maximumBytes: DriverSessionStore.maximumDriverLockBytes,
            label: "driver.lock",
            warnings: &warnings
        ) else {
            return nil
        }
        guard let value = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            warnings.append("invalid driver.lock JSON: \(path)")
            return nil
        }
        guard value["deviceType"] as? String == "mac" else {
            return nil
        }
        guard let generation = value["macGenerationKey"] as? String,
              isLowercaseSHA256(generation) else {
            warnings.append("invalid Mac generation in driver.lock: \(path)")
            return nil
        }
        return generation
    }

    private static func ownerOnlyRegularFileData(
        at path: String,
        maximumBytes: Int,
        label: String,
        warnings: inout [String]
    ) -> Data? {
        #if canImport(Darwin)
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno != ENOENT && errno != ENOTDIR {
                warnings.append("cannot open \(label): \(path) (errno \(errno))")
            }
            return nil
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= maximumBytes else {
            warnings.append(
                "ignored unsafe or oversized \(label): \(path)"
            )
            return nil
        }
        var data = Data(count: Int(status.st_size))
        let succeeded = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        guard succeeded else {
            warnings.append("cannot read \(label): \(path)")
            return nil
        }
        return data
        #else
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              data.count <= maximumBytes else {
            return nil
        }
        return data
        #endif
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value)
                || (97...102).contains($0.value)
        }
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
