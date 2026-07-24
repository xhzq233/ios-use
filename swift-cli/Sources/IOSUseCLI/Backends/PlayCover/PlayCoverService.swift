import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum PlayCoverService {
    public static let profileFilename = "IOSUsePlayProfile.plist"
    public static let manifestFilename = ".ios-use-playcover-manifest.json"
    public static let runtimeFrameworkName = "IOSUsePlayRuntime.framework"
    public static let runtimeExecutableName = "IOSUsePlayRuntime"

    public static func inspect(
        appPath: String,
        profile: PlayCoverDeviceProfile = .vphoneDefault
    ) throws -> PlayCoverAppInspection {
        try profile.validate()
        let app = try resolveApp(at: appPath)
        let executableInspection = try PlayCoverMachO.inspect(at: app.executable)
        return PlayCoverAppInspection(
            appPath: app.url.path,
            bundleIdentifier: app.bundleIdentifier,
            executableName: app.executableName,
            executablePath: app.executable.path,
            profile: profile,
            profileHash: try profile.stableHash(),
            mainExecutable: executableInspection
        )
    }

    public static func prepare(
        sourceAppPath: String,
        outputAppPath: String,
        runtimeFrameworkPath: String,
        paths: IOSUsePaths,
        profile: PlayCoverDeviceProfile = .vphoneDefault
    ) throws -> PlayCoverPrepareManifest {
        try profile.validate()
        let source = try resolveApp(at: sourceAppPath)
        let output = URL(fileURLWithPath: outputAppPath).standardizedFileURL
        let runtime = URL(fileURLWithPath: runtimeFrameworkPath).standardizedFileURL
        let fileManager = FileManager.default

        guard output.pathExtension == "app" else {
            throw PlayCoverBackendError.invalidApp("prepared output must end in .app: \(output.path)")
        }
        guard output.path != source.url.path,
              !output.path.hasPrefix(source.url.path + "/") else {
            throw PlayCoverBackendError.invalidApp("prepared output must be outside the source App")
        }
        guard !fileManager.fileExists(atPath: output.path) else {
            throw PlayCoverBackendError.outputExists(output.path)
        }
        let runtimeExecutable = runtime.appendingPathComponent(runtimeExecutableName)
        var runtimeIsDirectory: ObjCBool = false
        guard runtime.lastPathComponent == runtimeFrameworkName,
              fileManager.fileExists(atPath: runtime.path, isDirectory: &runtimeIsDirectory),
              runtimeIsDirectory.boolValue,
              fileManager.isExecutableFile(atPath: runtimeExecutable.path) else {
            throw PlayCoverBackendError.missingRuntime(runtime.path)
        }
        let runtimeInspection = try PlayCoverMachO.inspect(at: runtimeExecutable)
        guard runtimeInspection.isMacCatalyst, !runtimeInspection.encrypted else {
            throw PlayCoverBackendError.missingRuntime(
                "\(runtimeExecutable.path) must be an unencrypted Mac Catalyst arm64 Mach-O"
            )
        }

        let sourceMachOs = try resolveMachOs(in: source.url)
        guard sourceMachOs.contains(where: { $0.path == source.executable.path }) else {
            throw PlayCoverBackendError.invalidApp(
                "main executable was not found during source preflight"
            )
        }
        for macho in sourceMachOs {
            let inspection = try PlayCoverMachO.inspect(at: macho)
            if inspection.encrypted {
                throw PlayCoverBackendError.encryptedMachO(macho.path)
            }
            guard inspection.platform == PlayCoverMachO.platformIPhoneOS
                    || inspection.platform == PlayCoverMachO.platformMacCatalyst else {
                throw PlayCoverBackendError.unsupportedMachO(
                    "\(macho.path) is platform \(inspection.platform.map(String.init) ?? "unknown")"
                )
            }
        }

        try fileManager.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var shouldRollback = false
        defer {
            if shouldRollback {
                try? fileManager.removeItem(at: output)
            }
        }

        do {
            _ = try Shell.run("/bin/cp", arguments: ["-cR", source.url.path, output.path])
            shouldRollback = true

            let prepared = try resolveApp(at: output.path)
            let frameworks = prepared.url.appendingPathComponent("Frameworks", isDirectory: true)
            try fileManager.createDirectory(at: frameworks, withIntermediateDirectories: true)
            let embeddedRuntime = frameworks.appendingPathComponent(runtimeFrameworkName, isDirectory: true)
            try fileManager.copyItem(at: runtime, to: embeddedRuntime)

            try updatePreparedInfoPlist(prepared.infoPlist)
            let mobileProvision = prepared.url.appendingPathComponent("embedded.mobileprovision")
            if fileManager.fileExists(atPath: mobileProvision.path) {
                try fileManager.removeItem(at: mobileProvision)
            }

            let profileHash = try profile.stableHash()
            let helloPath = try makeHelloPath(
                bundleIdentifier: prepared.bundleIdentifier,
                preparedApp: prepared.url,
                paths: paths
            )
            try writeRuntimeProfile(
                profile,
                profileHash: profileHash,
                helloPath: helloPath,
                to: prepared.url.appendingPathComponent(profileFilename)
            )

            let machOs = try resolveMachOs(in: prepared.url)
            guard machOs.contains(where: { $0.path == prepared.executable.path }) else {
                throw PlayCoverBackendError.invalidApp(
                    "main executable was not found in the prepared Mach-O set"
                )
            }
            var converted: [String] = []
            for macho in machOs {
                let inspection = try PlayCoverMachO.inspect(at: macho)
                if inspection.encrypted {
                    throw PlayCoverBackendError.encryptedMachO(macho.path)
                }
                if inspection.platform == PlayCoverMachO.platformMacCatalyst {
                    continue
                }
                guard inspection.platform == PlayCoverMachO.platformIPhoneOS else {
                    throw PlayCoverBackendError.unsupportedMachO(
                        "\(macho.path) is platform \(inspection.platform.map(String.init) ?? "unknown")"
                    )
                }
                _ = try PlayCoverMachO.convert(
                    at: macho,
                    injectRuntime: macho.path == prepared.executable.path
                )
                converted.append(relativePath(of: macho, inside: prepared.url))
            }
            if !converted.contains(relativePath(of: prepared.executable, inside: prepared.url)) {
                let main = try PlayCoverMachO.inspect(at: prepared.executable)
                if !main.runtimeInjected {
                    _ = try PlayCoverMachO.convert(at: prepared.executable, injectRuntime: true)
                }
            }

            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: prepared.executable.path
            )

            let manifest = PlayCoverPrepareManifest(
                schemaVersion: 1,
                backend: "playcover-headless",
                sourceAppPath: source.url.path,
                preparedAppPath: prepared.url.path,
                bundleIdentifier: prepared.bundleIdentifier,
                executableName: prepared.executableName,
                profileHash: profileHash,
                runtimeLoadPath: PlayCoverMachO.runtimeLoadPath,
                runtimeFrameworkName: runtimeFrameworkName,
                convertedMachOs: converted.sorted(),
                preparedAt: ISO8601DateFormatter().string(from: Date()),
                helloPath: helloPath
            )
            try writeJSON(manifest, to: prepared.url.appendingPathComponent(manifestFilename))

            try signPreparedApp(prepared.url, helloPath: helloPath)
            _ = try Shell.run("/usr/bin/xattr", arguments: [
                "-dr", "com.apple.quarantine", prepared.url.path,
            ])
            _ = try verify(appPath: prepared.url.path)
            shouldRollback = false
            return manifest
        } catch let error as PlayCoverBackendError {
            throw error
        } catch {
            throw PlayCoverBackendError.prepareFailed(String(describing: error))
        }
    }

    public static func verify(appPath: String) throws -> PlayCoverVerification {
        let app = try resolveApp(at: appPath)
        let manifestURL = app.url.appendingPathComponent(manifestFilename)
        let profileURL = app.url.appendingPathComponent(profileFilename)
        let manifest: PlayCoverPrepareManifest = try readJSON(
            PlayCoverPrepareManifest.self,
            from: manifestURL
        )
        let profile: PlayCoverDeviceProfile
        do {
            profile = try PropertyListDecoder().decode(
                PlayCoverDeviceProfile.self,
                from: Data(contentsOf: profileURL)
            )
        } catch {
            throw PlayCoverBackendError.verificationFailed(
                "cannot decode \(profileFilename): \(error)"
            )
        }
        try profile.validate()
        guard try profile.stableHash() == manifest.profileHash else {
            throw PlayCoverBackendError.verificationFailed("profile hash does not match the manifest")
        }
        guard manifest.preparedAppPath == app.url.path,
              manifest.bundleIdentifier == app.bundleIdentifier,
              manifest.executableName == app.executableName,
              manifest.runtimeLoadPath == PlayCoverMachO.runtimeLoadPath else {
            throw PlayCoverBackendError.verificationFailed("manifest does not describe this App")
        }

        let runtime = app.url
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent(runtimeFrameworkName, isDirectory: true)
            .appendingPathComponent(runtimeExecutableName)
        guard FileManager.default.isExecutableFile(atPath: runtime.path) else {
            throw PlayCoverBackendError.verificationFailed("embedded runtime is missing")
        }
        let runtimeInspection = try PlayCoverMachO.inspect(at: runtime)
        guard runtimeInspection.isMacCatalyst, !runtimeInspection.encrypted else {
            throw PlayCoverBackendError.verificationFailed("embedded runtime is not valid Mac Catalyst arm64")
        }

        let main = try PlayCoverMachO.inspect(at: app.executable)
        guard main.isMacCatalyst, main.runtimeInjected, !main.encrypted else {
            throw PlayCoverBackendError.verificationFailed(
                "main executable is not converted, is encrypted, or does not load the runtime"
            )
        }

        for relative in manifest.convertedMachOs {
            let url = app.url.appendingPathComponent(relative)
            let converted = try PlayCoverMachO.inspect(at: url)
            guard converted.isMacCatalyst, !converted.encrypted else {
                throw PlayCoverBackendError.verificationFailed(
                    "converted Mach-O failed verification: \(relative)"
                )
            }
            try verifyCodeSignature(at: url, label: relative)
        }
        try verifyCodeSignature(at: runtime, label: runtimeFrameworkName)

        let signature = try Shell.runWithResult(
            "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", app.url.path]
        )
        guard signature.exitCode == 0 else {
            let detail = signature.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PlayCoverBackendError.verificationFailed(
                detail.isEmpty ? "code signature is invalid" : detail
            )
        }
        try verifyPreparedEntitlements(app.url)
        return PlayCoverVerification(
            manifest: manifest,
            profile: profile,
            mainExecutable: main,
            signatureValid: true
        )
    }

    public static func launch(
        appPath: String,
        timeout: Double = 15
    ) throws -> PlayCoverHello {
        guard timeout > 0, timeout <= 60 else {
            throw PlayCoverBackendError.launchFailed("timeout must be in (0, 60] seconds")
        }
        let verification = try verify(appPath: appPath)
        let helloURL = URL(fileURLWithPath: verification.manifest.helloPath)
        if FileManager.default.fileExists(atPath: helloURL.path) {
            try FileManager.default.removeItem(at: helloURL)
        }
        let result = try Shell.runWithResult(
            "/usr/bin/open",
            arguments: ["-n", verification.manifest.preparedAppPath],
            environment: sanitizedLaunchEnvironment()
        )
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PlayCoverBackendError.launchFailed(
                detail.isEmpty ? "open exited with \(result.exitCode)" : detail
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        var lastDecodeError: Error?
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: helloURL.path) {
                do {
                    let hello: PlayCoverHello = try readJSON(PlayCoverHello.self, from: helloURL)
                    guard hello.profileHash == verification.manifest.profileHash,
                          hello.bundleIdentifier == verification.manifest.bundleIdentifier else {
                        throw PlayCoverBackendError.launchFailed(
                            "runtime hello does not match the prepared generation"
                        )
                    }
                    let profile = verification.profile
                    guard approximatelyEqual(hello.logicalWidth, Double(profile.logicalWidth)),
                          approximatelyEqual(hello.logicalHeight, Double(profile.logicalHeight)),
                          approximatelyEqual(hello.nativeWidth, Double(profile.nativeWidth)),
                          approximatelyEqual(hello.nativeHeight, Double(profile.nativeHeight)),
                          approximatelyEqual(hello.scale, profile.scale),
                          hello.windowWidth.map({
                              approximatelyEqual($0, Double(profile.logicalWidth))
                          }) ?? false,
                          hello.windowHeight.map({
                              approximatelyEqual($0, Double(profile.logicalHeight))
                          }) ?? false else {
                        throw PlayCoverBackendError.launchFailed(
                            "runtime hello geometry does not match the fixed profile"
                        )
                    }
                    guard hello.pid > 0, processExists(hello.pid) else {
                        throw PlayCoverBackendError.launchFailed(
                            "runtime hello reported a process that is no longer running"
                        )
                    }
                    return hello
                } catch {
                    lastDecodeError = error
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let suffix = lastDecodeError.map { "; last hello error: \($0)" } ?? ""
        throw PlayCoverBackendError.launchTimedOut(
            "no verified runtime hello at \(helloURL.path) within \(timeout) seconds\(suffix)"
        )
    }

    @discardableResult
    public static func terminate(appPath: String) throws -> Int32 {
        let verification = try verify(appPath: appPath)
        let helloURL = URL(fileURLWithPath: verification.manifest.helloPath)
        let hello: PlayCoverHello = try readJSON(PlayCoverHello.self, from: helloURL)
        guard hello.profileHash == verification.manifest.profileHash,
              hello.bundleIdentifier == verification.manifest.bundleIdentifier,
              hello.pid > 0 else {
            throw PlayCoverBackendError.terminateFailed("runtime hello does not match the App")
        }
        guard processExists(hello.pid) else {
            return hello.pid
        }

        let ps = try Shell.runWithResult(
            "/bin/ps",
            arguments: ["-p", "\(hello.pid)", "-o", "command="]
        )
        let command = ps.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ps.exitCode == 0,
              command.contains(verification.manifest.preparedAppPath)
                || command.contains("/\(verification.manifest.executableName)") else {
            throw PlayCoverBackendError.terminateFailed(
                "refusing to signal pid \(hello.pid) because it is not the prepared App"
            )
        }
        #if canImport(Darwin)
        guard Darwin.kill(hello.pid, SIGTERM) == 0 else {
            throw PlayCoverBackendError.terminateFailed(
                "kill(\(hello.pid), SIGTERM) failed with errno \(errno)"
            )
        }
        let deadline = Date().addingTimeInterval(5)
        while processExists(hello.pid), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !processExists(hello.pid) else {
            throw PlayCoverBackendError.terminateFailed(
                "pid \(hello.pid) did not exit within 5 seconds"
            )
        }
        #else
        throw PlayCoverBackendError.terminateFailed("process termination is only supported on macOS")
        #endif
        return hello.pid
    }

    private struct ResolvedApp {
        let url: URL
        let infoPlist: URL
        let bundleIdentifier: String
        let executableName: String
        let executable: URL
    }

    private static func resolveApp(at path: String) throws -> ResolvedApp {
        let url = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard url.pathExtension == "app",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PlayCoverBackendError.invalidApp("expected an existing .app directory at \(url.path)")
        }
        let infoPlist = url.appendingPathComponent("Info.plist")
        let dictionary: [String: Any]
        do {
            let data = try Data(contentsOf: infoPlist)
            guard let decoded = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else {
                throw PlayCoverBackendError.invalidApp("Info.plist is not a dictionary")
            }
            dictionary = decoded
        } catch let error as PlayCoverBackendError {
            throw error
        } catch {
            throw PlayCoverBackendError.invalidApp("cannot read Info.plist: \(error)")
        }
        guard let bundleIdentifier = dictionary["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty,
              let executableName = dictionary["CFBundleExecutable"] as? String,
              !executableName.isEmpty else {
            throw PlayCoverBackendError.invalidApp(
                "Info.plist must contain CFBundleIdentifier and CFBundleExecutable"
            )
        }
        let executable = url.appendingPathComponent(executableName)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PlayCoverBackendError.invalidApp(
                "main executable does not exist or is not executable: \(executable.path)"
            )
        }
        return ResolvedApp(
            url: url,
            infoPlist: infoPlist,
            bundleIdentifier: bundleIdentifier,
            executableName: executableName,
            executable: executable
        )
    }

    private static func updatePreparedInfoPlist(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var dictionary = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else {
            throw PlayCoverBackendError.invalidApp("Info.plist is not a dictionary")
        }
        if let version = dictionary["MinimumOSVersion"] as? String,
           let numeric = Double(version),
           numeric > 11 {
            dictionary["MinimumOSVersion"] = "11.0"
        }
        let rewritten = try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: format,
            options: 0
        )
        try rewritten.write(to: url, options: .atomic)
    }

    private static func writeRuntimeProfile(
        _ profile: PlayCoverDeviceProfile,
        profileHash: String,
        helloPath: String,
        to url: URL
    ) throws {
        var dictionary: [String: Any] = [
            "schemaVersion": profile.schemaVersion,
            "identifier": profile.identifier,
            "productType": profile.productType,
            "hardwareTarget": profile.hardwareTarget,
            "logicalWidth": profile.logicalWidth,
            "logicalHeight": profile.logicalHeight,
            "nativeWidth": profile.nativeWidth,
            "nativeHeight": profile.nativeHeight,
            "scale": profile.scale,
            "pixelsPerInch": profile.pixelsPerInch,
            "orientation": profile.orientation,
            "profileHash": profileHash,
            "helloPath": helloPath,
        ]
        // Keep this mutable local explicit so the on-disk plist remains a
        // straightforward Objective-C dictionary for the injected runtime.
        dictionary["backend"] = "playcover-headless"
        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    private static func resolveMachOs(in app: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: app,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PlayCoverBackendError.invalidApp("cannot enumerate \(app.path)")
        }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) >= 32 else {
                continue
            }
            guard url.pathExtension.isEmpty || url.pathExtension == "dylib" else {
                continue
            }
            let handle = try FileHandle(forReadingFrom: url)
            let magic: Data
            do {
                magic = try handle.read(upToCount: 4) ?? Data()
            } catch {
                try? handle.close()
                throw error
            }
            try handle.close()
            let magicBytes = Array(magic)
            let unsupportedMachOMagics: Set<[UInt8]> = [
                [0xca, 0xfe, 0xba, 0xbe],
                [0xbe, 0xba, 0xfe, 0xca],
                [0xca, 0xfe, 0xba, 0xbf],
                [0xbf, 0xba, 0xfe, 0xca],
                [0xfe, 0xed, 0xfa, 0xcf],
            ]
            if unsupportedMachOMagics.contains(magicBytes) {
                throw PlayCoverBackendError.unsupportedMachO(
                    "\(url.path) is fat or byte-swapped; the first backend slice requires thin arm64"
                )
            }
            guard magicBytes == [0xcf, 0xfa, 0xed, 0xfe] else {
                continue
            }
            guard try PlayCoverMachO.isThinArm64MachO(at: url) else {
                throw PlayCoverBackendError.unsupportedMachO(
                    "\(url.path) is a non-arm64 Mach-O"
                )
            }
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func signPreparedApp(_ app: URL, helloPath: String) throws {
        let resolved = try resolveApp(at: app.path)
        let nestedMachOs = try resolveMachOs(in: app)
            .filter { $0.path != resolved.executable.path }
            .sorted { $0.path.count > $1.path.count }
        for macho in nestedMachOs {
            let nestedResult = try Shell.runWithResult(
                "/usr/bin/codesign",
                arguments: [
                    "--force",
                    "--sign", "-",
                    "--timestamp=none",
                    macho.path,
                ]
            )
            guard nestedResult.exitCode == 0 else {
                let detail = nestedResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw PlayCoverBackendError.prepareFailed(
                    detail.isEmpty
                        ? "codesign failed for \(relativePath(of: macho, inside: app))"
                        : detail
                )
            }
        }

        let helloDirectory = URL(fileURLWithPath: helloPath)
            .deletingLastPathComponent()
            .path
        let sandboxRule = "(allow file-read* file-write* file-read-metadata " +
            "(subpath \"\(sandboxEscaped(helloDirectory))\"))"
        // This is the automation-specific minimum derived from PlayCover's
        // base Catalyst entitlement composition. Never preserve iOS
        // application-identifier or team-identifier entitlements in an
        // ad-hoc signature: AMFI treats those as unsatisfied restrictions.
        let entitlements: [String: Any] = [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.assets.pictures.read-write": true,
            "com.apple.security.device.audio-input": true,
            "com.apple.security.device.camera": true,
            "com.apple.security.device.microphone": true,
            "com.apple.security.files.user-selected.read-write": true,
            "com.apple.security.network.client": true,
            "com.apple.security.network.server": true,
            "com.apple.security.personal-information.location": true,
            "com.apple.security.temporary-exception.sbpl": [sandboxRule],
        ]
        let entitlementsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-play-entitlements-\(UUID().uuidString)")
            .appendingPathExtension("plist")
        let entitlementData = try PropertyListSerialization.data(
            fromPropertyList: entitlements,
            format: .xml,
            options: 0
        )
        try entitlementData.write(to: entitlementsURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: entitlementsURL) }

        let result = try Shell.runWithResult(
            "/usr/bin/codesign",
            arguments: [
                "--force",
                "--deep",
                "--sign", "-",
                "--timestamp=none",
                "--entitlements", entitlementsURL.path,
                app.path,
            ]
        )
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PlayCoverBackendError.prepareFailed(
                detail.isEmpty ? "codesign exited with \(result.exitCode)" : detail
            )
        }
    }

    private static func verifyCodeSignature(at url: URL, label: String) throws {
        let result = try Shell.runWithResult(
            "/usr/bin/codesign",
            arguments: ["--verify", "--strict", url.path]
        )
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PlayCoverBackendError.verificationFailed(
                detail.isEmpty ? "invalid code signature: \(label)" : detail
            )
        }
    }

    private static func verifyPreparedEntitlements(_ app: URL) throws {
        let result = try Shell.runWithResult(
            "/usr/bin/codesign",
            arguments: ["-d", "--entitlements", ":-", app.path]
        )
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let dictionary = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any] else {
            throw PlayCoverBackendError.verificationFailed(
                "cannot decode prepared App entitlements"
            )
        }
        let restricted = [
            "application-identifier",
            "com.apple.application-identifier",
            "com.apple.developer.team-identifier",
            "keychain-access-groups",
        ]
        guard restricted.allSatisfy({ dictionary[$0] == nil }) else {
            throw PlayCoverBackendError.verificationFailed(
                "prepared App retained restricted iOS signing entitlements"
            )
        }
        guard dictionary["com.apple.security.app-sandbox"] as? Bool == true else {
            throw PlayCoverBackendError.verificationFailed(
                "prepared App is missing the headless backend sandbox entitlement"
            )
        }
    }

    private static func sandboxEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func sanitizedLaunchEnvironment(
        source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        let allowedKeys = [
            "HOME",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "LOGNAME",
            "TMPDIR",
            "USER",
            "__CF_USER_TEXT_ENCODING",
        ]
        var result: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        for key in allowedKeys {
            if let value = source[key], !value.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private static func makeHelloPath(
        bundleIdentifier: String,
        preparedApp: URL,
        paths: IOSUsePaths
    ) throws -> String {
        try FileManager.default.createDirectory(
            atPath: paths.playcoverHello,
            withIntermediateDirectories: true
        )
        let safeBundle = bundleIdentifier.map {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-"
        }
        let digest = SHA256.hash(data: Data(preparedApp.path.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        return URL(fileURLWithPath: paths.playcoverHello, isDirectory: true)
            .appendingPathComponent("\(String(safeBundle))-\(digest).json")
            .path
    }

    private static func relativePath(of url: URL, inside root: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(url.path.dropFirst(prefix.count))
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch {
            throw PlayCoverBackendError.verificationFailed(
                "cannot decode \(url.lastPathComponent): \(error)"
            )
        }
    }

    private static func processExists(_ pid: Int32) -> Bool {
        #if canImport(Darwin)
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
        #else
        return false
        #endif
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.01
    }
}
