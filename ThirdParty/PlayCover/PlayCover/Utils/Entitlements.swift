//
//  Entitlements.swift
//  PlayCover
//

import Foundation
import Yams

public final class Entitlements {
    // These are so critical they MUST be gone no matter what.
    static var critical = [
        "/bin/bash",
        "/usr/sbin/sshd",
        "/usr/libexec/ssh-keysign",
        "/bin/sh",
        "/etc/ssh/sshd_config",
        "/usr/libexec/sftp-server",
        "/usr/bin/ssh"
    ]

    static var playCoverEntitlementsDir: URL {
        let entFolder = PlayTools.playCoverContainer.appendingPathComponent("Entitlements")
        if !FileManager.default.fileExists(atPath: entFolder.path) {
            do {
                try FileManager.default.createDirectory(at: entFolder,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                Log.shared.error(error)
            }
        }
        return entFolder
    }

    public static func dumpEntitlements(exec: URL) throws -> [String: Any] {
        let result = try [String: Any].read(try copyEntitlements(exec: exec))
        return result ?? [:]
    }

    public static func areEntitlementsValid(
        app: BaseApp,
        discordActivityEnabled: Bool = false,
        bypass: Bool = false,
        playSignActive: Bool? = nil,
        defaultRulesData: Data,
        homeDirectory: URL
    ) throws -> Bool {
        guard let old = try dumpEntitlements(exec: app.executable) as? [String: AnyHashable] else { return false }
        guard let new = try composeEntitlements(
            app,
            discordActivityEnabled: discordActivityEnabled,
            bypass: bypass,
            playSignActive: playSignActive,
            defaultRulesData: defaultRulesData,
            homeDirectory: homeDirectory
        ) as? [String: AnyHashable] else { return false }
        return new.hashValue == old.hashValue
    }

    private static func setBaseEntitlements(_ base: inout [String: Any]) {
        base["com.apple.security.assets.movies.read-write"] = true
        base["com.apple.security.assets.music.read-write"] = true
        base["com.apple.security.assets.pictures.read-write"] = true
        base["com.apple.security.device.audio-input"] = true
        base["com.apple.security.network.client"] = true
        base["com.apple.security.network.server"] = true
        base["com.apple.security.device.bluetooth"] = true
        base["com.apple.security.device.camera"] = true
        base["com.apple.security.device.microphone"] = true
        base["com.apple.security.device.usb"] = true
        base["com.apple.security.files.downloads.read-write"] = true
        base["com.apple.security.files.user-selected.read-write"] = true
        base["com.apple.security.network.client"] = true
        base["com.apple.security.network.server"] = true
        base["com.apple.security.personal-information.addressbook"] = true
        base["com.apple.security.personal-information.calendars"] = true
        base["com.apple.security.personal-information.location"] = true
        base["com.apple.security.print"] = true
        base["com.apple.security.app-sandbox"] = true
    }

    // swiftlint:disable:next cyclomatic_complexity
    public static func composeEntitlements(
        _ app: BaseApp,
        discordActivityEnabled: Bool = false,
        bypass: Bool = false,
        playSignActive: Bool? = nil,
        defaultRulesData: Data,
        homeDirectory: URL
    ) throws -> [String: Any] {
        var base = [String: Any]()
        let bundleID = app.info.bundleIdentifier

        setBaseEntitlements(&base)

        if playSignActive ?? SystemConfig.isPlaySignActive {
            base["com.apple.private.tcc.allow"] = TCC.split(whereSeparator: \.isNewline)
            if let specific = try [String: Any].read(app.entitlements) {
                for key in specific.keys {
                    base[key] = specific[key]
                }
            }
        }

        var sandboxProfile = [String]()

        var rules = try getDefaultRules(defaultRulesData)
        if discordActivityEnabled {
             rules.allow?.append("(allow network* ipc-posix*)")
         }

        sandboxProfile.append(contentsOf: PlayRules.buildRules(
            rules: rules.allow ?? [],
            bundleID: bundleID,
            homeDirectory: homeDirectory
        ))
        sandboxProfile.append("(deny process-fork)")
        for file in critical {
            sandboxProfile.append("""
                    (deny file* file-read* file-read-metadata file-ioctl (literal "\(file)"))
                    """)
        }

        if bypass {
            for file in PlayRules.buildRules(
                rules: rules.blocklist ?? [],
                bundleID: bundleID,
                homeDirectory: homeDirectory
            ) {
                sandboxProfile.append(
                    """
                     (deny file* file-read* file-read-metadata file-ioctl (literal "\(file)"))
                    """)
            }

            for file in PlayRules.buildRules(
                rules: rules.greenlist ?? [],
                bundleID: bundleID,
                homeDirectory: homeDirectory
            ) {
                sandboxProfile.append(
                    """
                     (allow file* file-read* file-read-metadata file-ioctl (literal "\(file)"))
                    """)
            }

            sandboxProfile.append(contentsOf: PlayRules.buildRules(
                rules: rules.bypass ?? [],
                bundleID: bundleID,
                homeDirectory: homeDirectory
            ))
        }

        base["com.apple.security.temporary-exception.sbpl"] = sandboxProfile

        return base
    }

    private static func copyEntitlements(exec: URL) throws -> String {
        var entitlements = try excludeEntitlements(exec: exec)
        if !entitlements.contains("DOCTYPE plist PUBLIC") {
            entitlements = Entitlements.entitlements_template
        }
        return entitlements
    }

    private static func excludeEntitlements(exec: URL) throws -> String {
        let from = try PlayTools.fetchEntitlements(exec)
        if let range: Range<String.Index> = from.range(of: "<?xml") {
            return String(from[range.lowerBound...])
        } else {
            return Entitlements.entitlements_template
        }
    }

    private static let TCC =
        """
        kTCCService
        kTCCServiceAll
        kTCCServiceAddressBook
        kTCCServiceCalendar
        kTCCServiceReminders
        kTCCServiceLiverpool
        kTCCServiceUbiquity
        kTCCServiceShareKit
        kTCCServicePhotos
        kTCCServicePhotosAdd
        kTCCServiceMicrophone
        kTCCServiceCamera
        kTCCServiceMediaLibrary
        kTCCServiceSiri
        kTCCServiceAppleEvents
        kTCCServiceAccessibility
        kTCCServicePostEvent
        kTCCServiceLocation
        kTCCServiceSystemPolicyAllFiles
        kTCCServiceSystemPolicySysAdminFiles
        kTCCServiceSystemPolicyDeveloperFile
        kTCCServiceSystemPolicyDocumentsFolder
        """

    static func getDefaultRules(_ data: Data) throws -> PlayRules {
        do {
            let decoder = YAMLDecoder()
            let decoded: PlayRules = try decoder.decode(PlayRules.self, from: data)
            return decoded
        } catch {
            throw "failed to decode default sandbox rules: \(error)"
        }
    }

    public static func isAppRequireUnsandbox(_ app: BaseApp) -> Bool {
        unsandboxedApps.contains(app.info.bundleIdentifier)
    }

    private static let unsandboxedApps = ["com.devsisters.ck"]

    static let entitlements_template = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        </dict>
        </plist>
        """
}

public func == <K, L: Hashable, R: Hashable>(lhs: [K: L], rhs: [K: R]) -> Bool {
    (lhs as NSDictionary).isEqual(to: rhs)
}

extension Dictionary {
    func store(_ toUrl: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: self, format: .xml, options: 0)
        try data.write(to: toUrl, options: .atomic)
    }

    static func read(_ from: URL) throws -> Dictionary? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        if let data = FileManager.default.contents(atPath: from.path) {
            return try PropertyListSerialization.propertyList(
                from: data,
                options: .mutableContainersAndLeaves,
                format: &format) as? Dictionary
        }
        return nil
    }

    static func read(_ from: String) throws -> Dictionary? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        if let data = from.data(using: .utf8) {
            return try PropertyListSerialization.propertyList(
                from: data,
                options: .mutableContainersAndLeaves,
                format: &format) as? Dictionary
        }
        return nil
    }
}
