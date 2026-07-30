//
//  PlayTools.swift
//  PlayCover
//

import Foundation
import injection

public final class PlayTools {
    private static let managedContainerLock = NSRecursiveLock()
    private static var managedContainerOverride: URL?
    private static var bundledPlayToolsFrameworkOverride: URL?
    private static var headlessOracleTrace: [String]?
    private static let frameworksURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Frameworks")
    private static let playToolsFramework = frameworksURL
        .appendingPathComponent("PlayTools")
        .appendingPathExtension("framework")
    private static let playToolsPath = playToolsFramework
        .appendingPathComponent("PlayTools")
    private static let akInterfacePath = playToolsFramework
        .appendingPathComponent("PlugIns")
        .appendingPathComponent("AKInterface")
        .appendingPathExtension("bundle")
    private static var bundledPlayToolsFramework: URL {
        bundledPlayToolsFrameworkOverride
            ?? Bundle.main.bundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Frameworks")
                .appendingPathComponent("PlayTools")
                .appendingPathExtension("framework")
    }

    public static var playCoverContainer: URL {
        managedContainerLock.lock()
        defer { managedContainerLock.unlock() }
        if let managedContainerOverride {
            return managedContainerOverride
        }
        let playCoverPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("io.playcover.PlayCover")
        if !FileManager.default.fileExists(atPath: playCoverPath.path) {
            do {
                try FileManager.default.createDirectory(at: playCoverPath,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                Log.shared.error(error)
            }
        }

        return playCoverPath
    }

    /// ios-use local patch: the CLI owns the container and never discovers it
    /// through PlayCover GUI preferences or the user's default home.
    public static func configureManagedContainer(_ url: URL) throws {
        managedContainerLock.lock()
        defer { managedContainerLock.unlock() }
        let value = lexicallyStandardizedFileURL(url)
        try FileManager.default.createDirectory(
            at: value,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        managedContainerOverride = value
    }

    /// Runs one headless operation with an exact transaction-owned container
    /// and restores the prior process-global PlayCover setting.
    public static func withManagedContainer<T>(
        _ url: URL,
        _ operation: () throws -> T
    ) throws -> T {
        managedContainerLock.lock()
        defer { managedContainerLock.unlock() }
        let previous = managedContainerOverride
        defer { managedContainerOverride = previous }
        let value = lexicallyStandardizedFileURL(url)
        try FileManager.default.createDirectory(
            at: value,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        managedContainerOverride = value
        return try operation()
    }

    public static func withExistingManagedContainer<T>(
        _ url: URL,
        _ operation: () throws -> T
    ) throws -> T {
        managedContainerLock.lock()
        defer { managedContainerLock.unlock() }
        let previous = managedContainerOverride
        defer { managedContainerOverride = previous }
        managedContainerOverride = lexicallyStandardizedFileURL(url)
        return try operation()
    }

    private static func lexicallyStandardizedFileURL(
        _ url: URL
    ) -> URL {
        var components: [Substring] = []
        for component in url.path.split(separator: "/") {
            if component == "." {
                continue
            }
            if component == ".." {
                if !components.isEmpty {
                    components.removeLast()
                }
                continue
            }
            components.append(component)
        }
        return URL(
            fileURLWithPath: "/" + components.joined(separator: "/"),
            isDirectory: true
        )
    }

    /// Direct headless port of `installInIPA`, with the system PlayTools path
    /// replaced by the App-embedded IOSUse Runtime load path.
    public static func injectRuntime(
        _ exec: URL,
        loadPath: String
    ) throws {
        try validateRuntimeInjectionInput(exec)

        var injectionSucceeded = false
        Inject.injectMachO(
            machoPath: exec.path,
            cmdType: .loadDylib,
            backup: false,
            injectPath: loadPath,
            finishHandle: { injectionSucceeded = $0 }
        )
        guard injectionSucceeded else {
            throw PlayCoverUpstreamError.injectionFailed(exec.path)
        }
    }

    /// Preserve the pinned direct-helper failure boundary without eagerly
    /// copying the already-converted thin executable before Inject performs
    /// its single mutation read.
    static func validateRuntimeInjectionInput(_ exec: URL) throws {
        var binary = try Data(contentsOf: exec, options: .alwaysMapped)
        try Macho.stripBinary(&binary)
    }

    /// Executes the pinned `installInIPA` implementation with an explicit
    /// PlayCover app-bundle resource root for the headless differential
    /// fixture. The override replaces only `Bundle.main` discovery; injection,
    /// plugin copy/signing, and app signing remain in the upstream method.
    public static func installInIPAForHeadlessOracle(
        _ exec: URL,
        bundledFramework: URL
    ) async throws -> [String] {
        guard bundledPlayToolsFrameworkOverride == nil,
              headlessOracleTrace == nil else {
            throw PlayCoverUpstreamError.verificationFailed(
                "a pinned PlayTools resource override is already active"
            )
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: bundledFramework.path,
            isDirectory: &directory
        ), directory.boolValue else {
            throw PlayCoverUpstreamError.invalidApp(
                "pinned PlayTools.framework fixture is missing: "
                    + bundledFramework.path
            )
        }
        let sourceFrameworkExecutable =
            bundledFramework.appendingPathComponent("PlayTools")
        guard FileManager.default.isExecutableFile(
            atPath: sourceFrameworkExecutable.path
        ) else {
            throw PlayCoverUpstreamError.invalidApp(
                "pinned PlayTools framework executable is missing: "
                    + sourceFrameworkExecutable.path
            )
        }
        let sourcePlugin = bundledFramework
            .appendingPathComponent("PlugIns")
            .appendingPathComponent("AKInterface")
            .appendingPathExtension("bundle")
        guard FileManager.default.fileExists(
            atPath: sourcePlugin.path,
            isDirectory: &directory
        ), directory.boolValue else {
            throw PlayCoverUpstreamError.invalidApp(
                "pinned AKInterface.bundle fixture is missing: "
                    + sourcePlugin.path
            )
        }

        bundledPlayToolsFrameworkOverride =
            bundledFramework.standardizedFileURL
        headlessOracleTrace = []
        defer {
            bundledPlayToolsFrameworkOverride = nil
            headlessOracleTrace = nil
        }

        recordHeadlessOracleCall("PlayTools.installInIPA")
        try await installInIPA(exec)

        guard try installedInExec(atURL: exec) else {
            throw PlayCoverUpstreamError.injectionFailed(
                "pinned PlayTools.installInIPA did not add its load command"
            )
        }
        let installedPlugin = exec.deletingLastPathComponent()
            .appendingPathComponent("PlugIns")
            .appendingPathComponent("AKInterface")
            .appendingPathExtension("bundle")
        guard FileManager.default.fileExists(
            atPath: installedPlugin.path,
            isDirectory: &directory
        ), directory.boolValue else {
            throw PlayCoverUpstreamError.verificationFailed(
                "pinned PlayTools.installPluginInIPA did not copy "
                    + installedPlugin.path
            )
        }
        do {
            _ = try Shell.run(
                print: false,
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                installedPlugin.path
            )
            _ = try Shell.run(
                print: false,
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                exec.deletingLastPathComponent().path
            )
        } catch {
            throw PlayCoverUpstreamError.signingFailed(
                "pinned PlayTools.installInIPA output: \(error)"
            )
        }
        guard let observed = headlessOracleTrace else {
            throw PlayCoverUpstreamError.verificationFailed(
                "pinned PlayTools call-site trace disappeared"
            )
        }
        return observed
    }

    private static func recordHeadlessOracleCall(_ symbol: String) {
        headlessOracleTrace?.append(symbol)
    }

    static func installOnSystem() {
        Task(priority: .background) {
            do {
                Log.shared.log("Installing PlayTools")

                // Check if Frameworks folder exists, if not, create it
                if !FileManager.default.fileExists(atPath: frameworksURL.path) {
                    try FileManager.default.createDirectory(
                        atPath: frameworksURL.path,
                        withIntermediateDirectories: true,
                        attributes: [:])
                }

                // Check if a version of PlayTools is already installed, if so remove it
                FileManager.default.delete(at: URL(fileURLWithPath: playToolsFramework.path))

                // Install version of PlayTools bundled with PlayCover
                Log.shared.log("Copying PlayTools to Frameworks")
                if FileManager.default.fileExists(atPath: playToolsFramework.path) {
                    try FileManager.default.removeItem(at: playToolsFramework)
                }
                try FileManager.default.copyItem(at: bundledPlayToolsFramework, to: playToolsFramework)
            } catch {
                Log.shared.error(error)
            }
        }
    }

    static func installInIPA(_ exec: URL) async throws {
        var binary = try Data(contentsOf: exec)
        try Macho.stripBinary(&binary)

        recordHeadlessOracleCall(
            "Inject.injectMachO (called by PlayTools.installInIPA)"
        )
        Inject.injectMachO(machoPath: exec.path,
                           cmdType: .loadDylib,
                           backup: false,
                           injectPath: playToolsPath.path,
                           finishHandle: { result in
            if result {
                do {
                    recordHeadlessOracleCall(
                        "PlayTools.installPluginInIPA"
                    )
                    try installPluginInIPA(exec.deletingLastPathComponent())
                    recordHeadlessOracleCall(
                        "Shell.signApp(--deep "
                            + "--preserve-metadata=entitlements)"
                    )
                    try Shell.signApp(exec)
                } catch {
                    Log.shared.error(error)
                }
            }
        })
    }

    static func installPluginInIPA(_ payload: URL) throws {
        let allFiles = try FileManager.default.contentsOfDirectory(
            at: bundledPlayToolsFramework, includingPropertiesForKeys: [])
        for localizationDirectory in allFiles where localizationDirectory.pathExtension == "lproj" {
            _ = try copyAsset(target: payload,
                              directoryName: localizationDirectory.lastPathComponent,
                              component: "Playtools", pathExtension: "strings")
        }

        let bundledPlayToolsResources = bundledPlayToolsFramework
            .appendingPathComponent("Versions")
            .appendingPathComponent("A")
            .appendingPathComponent("Resources")
        if FileManager.default.fileExists(atPath: bundledPlayToolsResources.path) {
            let allFiles = try FileManager.default.contentsOfDirectory(
                at: bundledPlayToolsResources, includingPropertiesForKeys: [])
            for localizationDirectory in allFiles where localizationDirectory.pathExtension == "lproj" {
                _ = try copyAsset(source: bundledPlayToolsResources,
                                  target: payload,
                                  directoryName: localizationDirectory.lastPathComponent,
                                  component: "Playtools", pathExtension: "strings")
            }
        }

        let bundleTarget = try copyAsset(target: payload, directoryName: "PlugIns",
                                         component: "AKInterface", pathExtension: "bundle")
        try bundleTarget.fixExecutable()
        recordHeadlessOracleCall(
            "Shell.signMacho(AKInterface.bundle)"
        )
        try Shell.signMacho(bundleTarget)
    }

    static func copyAsset(source: URL = bundledPlayToolsFramework, target: URL, directoryName: String,
                          component: String, pathExtension: String) throws -> URL {
        let directory = target.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let target = directory
                    .appendingPathComponent(component)
                    .appendingPathExtension(pathExtension)

        let source = source
                    .appendingPathComponent(directoryName)
                    .appendingPathComponent(component)
                    .appendingPathExtension(pathExtension)
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            try FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }
        return target
    }

    static func injectInIPA(_ exec: URL, payload: URL) throws {
        var binary = try Data(contentsOf: exec)
        try Macho.stripBinary(&binary)

        Inject.injectMachO(machoPath: exec.path,
                           cmdType: .loadDylib,
                           backup: false,
                           injectPath: "@executable_path/Frameworks/PlayTools.dylib",
                           finishHandle: { result in
            if result {
                Task(priority: .background) {
                    do {
                        if !FileManager.default.fileExists(atPath: payload.appendingPathComponent("Frameworks").path) {
                            try FileManager.default.createDirectory(
                                at: payload.appendingPathComponent("Frameworks"),
                                withIntermediateDirectories: true)
                        }

                        let libraryTarget = payload.appendingPathComponent("Frameworks")
                            .appendingPathComponent("PlayTools")
                            .appendingPathExtension("dylib")

                        let tools = bundledPlayToolsFramework
                            .appendingPathComponent("PlayTools")

                        if FileManager.default.fileExists(atPath: libraryTarget.path) {
                            try FileManager.default.removeItem(at: libraryTarget)
                        }
                        try FileManager.default.copyItem(at: tools, to: libraryTarget)

                        try libraryTarget.fixExecutable()
                        try installPluginInIPA(payload)
                    } catch {
                        Log.shared.error(error)
                    }
                }
            }
        })
    }

    static func removeFromApp(_ exec: URL) async {
        Inject.removeMachO(machoPath: exec.path,
                           cmdType: .loadDylib,
                           backup: false,
                           injectPath: playToolsPath.path,
                           finishHandle: { result in
            if result {
                do {
                    let pluginUrl = exec.deletingLastPathComponent()
                        .appendingPathComponent("PlugIns")
                        .appendingPathComponent("AKInterface")
                        .appendingPathExtension("bundle")

                    if FileManager.default.fileExists(atPath: pluginUrl.path) {
                        try FileManager.default.removeItem(at: pluginUrl)
                    }
                    try Shell.signApp(exec)
                } catch {
                    Log.shared.error(error)
                }
            }
        })
    }

    static func installedInExec(atURL url: URL) throws -> Bool {
        var binary = try Data(contentsOf: url)
        try Macho.stripBinary(&binary)
        var result = false
        try _ = Macho.iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let loadCommand = binary.extract(load_command.self, offset: offset,
                                             swap: shouldSwap ? swap_load_command:nil)
            if loadCommand.cmd == UInt32(LC_LOAD_DYLIB) {
                let dylibCommand = binary.extract(dylib_command.self, offset: offset,
                                                  swap: shouldSwap ? swap_dylib_command:nil)

                let dylibName = String(data: binary,
                                       offset: offset,
                                       commandSize: Int(dylibCommand.cmdsize),
                                       loadCommandString: dylibCommand.dylib.name)
                if dylibName == playToolsPath.esc {
                    result = true
                    return true
                }
            }
            return false
        }
        return result
    }

    static func isInstalled() throws -> Bool {
        try FileManager.default.fileExists(atPath: playToolsPath.path)
            && FileManager.default.fileExists(atPath: akInterfacePath.path)
            && Macho.isMachoValidArch(playToolsPath)
    }

	static func fetchEntitlements(_ exec: URL) throws -> String {
        do {
            return try Shell.run("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", exec.path)
        } catch {
            if error.localizedDescription.contains("Document is empty") {
                // Empty entitlements
                return ""
            } else if error.localizedDescription.contains("code object is not signed at all") {
                // IPA not signed
                return ""
            } else {
                throw error
            }
        }
	}
}
