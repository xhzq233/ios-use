//
//  Installer.swift
//  PlayCover
//
//  Created by Александр Дорофеев on 24.11.2021.
//

import Foundation

/// Headless source port of PlayCover's installer primitives.
///
/// The GUI prompt, IPA progress callbacks and Finder-library move are omitted.
/// The prepare engine retains their ordering while calling these same source
/// primitives for entitlement capture, Mach-O enumeration and provisioning
/// removal.
final class Installer {
    /// Returns URLs to every Mach-O in FileManager enumeration order.
    ///
    /// Upstream filters by an empty or `.dylib` extension. The headless port
    /// deliberately recognizes the same Mach-O magics at every regular-file
    /// path so extensions, versioned frameworks and nested plug-ins cannot be
    /// omitted from conversion/signing evidence.
    static func resolveValidMachOs(_ baseApp: BaseApp) throws -> [URL] {
        if let validMachOs = baseApp.validMachOs {
            return validMachOs
        }
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: baseApp.url,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw PlayCoverUpstreamError.invalidApp(
                "cannot enumerate \(baseApp.url.path)"
            )
        }

        let magics: Set<[UInt8]> = [
            [0xca, 0xfe, 0xba, 0xbe],
            [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf],
            [0xbf, 0xba, 0xfe, 0xca],
            [0xcf, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xcf],
        ]
        var resolved: [URL] = []
        for case let url as URL in enumerator {
            let attributes = try url.resourceValues(forKeys: Set(keys))
            guard attributes.isRegularFile == true,
                  let fileSize = attributes.fileSize,
                  fileSize > 4 else {
                continue
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: 4),
                  data.count == 4,
                  magics.contains(Array(data)) else {
                continue
            }
            resolved.append(url)
        }
        baseApp.validMachOs = resolved
        return resolved
    }

    /// Preserve the pinned PlayCover entitlement evidence location. This does
    /// not modify the source App.
    static func saveEntitlements(_ baseApp: BaseApp) throws {
        let toSave = try Entitlements.dumpEntitlements(
            exec: baseApp.executable
        )
        try toSave.store(baseApp.entitlements)
    }

    static func removeMobileProvision(_ baseApp: BaseApp) throws {
        let provision = baseApp.url.appendingPathComponent(
            "embedded.mobileprovision"
        )
        if FileManager.default.fileExists(atPath: provision.path) {
            try FileManager.default.removeItem(at: provision)
        }
    }
}
