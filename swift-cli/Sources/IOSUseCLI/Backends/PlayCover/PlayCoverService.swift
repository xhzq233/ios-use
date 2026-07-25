import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Darwin)
import Darwin
#endif

public enum PlayCoverService {
    public static let profileFilename = "IOSUsePlayProfile.plist"
    public static let manifestFilename = ".ios-use-playcover-manifest.json"
    public static let runtimeFrameworkName = "IOSUsePlayRuntime.framework"
    public static let runtimeExecutableName = "IOSUsePlayRuntime"
    static var failedLaunchTerminatorOverrideForTesting:
        ((Int32, PlayCoverPrepareManifest) throws -> Void)?

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
        try validateRuntimeStatePaths(paths)
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
            let preparedGenerationID = UUID().uuidString
            let helloPath = paths.playcoverHello
            try writeRuntimeProfile(
                profile,
                profileHash: profileHash,
                helloPath: helloPath,
                preparedGenerationID: preparedGenerationID,
                runtimeBootstrapPath: paths.playcoverRuntimeBootstrap,
                runtimeSocketPath: paths.playcoverRuntimeSocket,
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
                schemaVersion: 2,
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
                helloPath: helloPath,
                preparedGenerationID: preparedGenerationID,
                runtimeBootstrapPath: paths.playcoverRuntimeBootstrap,
                runtimeSocketPath: paths.playcoverRuntimeSocket
            )
            try writeJSON(manifest, to: prepared.url.appendingPathComponent(manifestFilename))

            try signPreparedApp(
                prepared.url,
                runtimeRunPath: paths.playcoverRun,
                runtimeSocketPath: paths.playcoverRuntimeSocket
            )
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
        let signedProfile: PlayCoverSignedRuntimeProfile
        do {
            signedProfile = try PropertyListDecoder().decode(
                PlayCoverSignedRuntimeProfile.self,
                from: Data(contentsOf: profileURL)
            )
        } catch {
            throw PlayCoverBackendError.verificationFailed(
                "cannot decode \(profileFilename): \(error)"
            )
        }
        let profile = signedProfile.deviceProfile
        try profile.validate()
        guard manifest.schemaVersion == 2,
              signedProfile.schemaVersion == 2,
              manifest.backend == "playcover-headless",
              signedProfile.backend == manifest.backend,
              !manifest.preparedGenerationID.isEmpty,
              !manifest.runtimeBootstrapPath.isEmpty,
              !manifest.runtimeSocketPath.isEmpty else {
            throw PlayCoverBackendError.verificationFailed(
                "prepared runtime profile/manifest schema is unsupported or incomplete"
            )
        }
        guard try profile.stableHash() == manifest.profileHash else {
            throw PlayCoverBackendError.verificationFailed("profile hash does not match the manifest")
        }
        guard signedProfile.profileHash == manifest.profileHash,
              signedProfile.helloPath == manifest.helloPath,
              signedProfile.preparedGenerationID == manifest.preparedGenerationID,
              signedProfile.runtimeBootstrapPath == manifest.runtimeBootstrapPath,
              signedProfile.runtimeSocketPath == manifest.runtimeSocketPath else {
            throw PlayCoverBackendError.verificationFailed(
                "signed runtime profile does not match the manifest"
            )
        }
        try validateRuntimeSocketPath(
            manifest.runtimeSocketPath,
            error: { PlayCoverBackendError.verificationFailed($0) }
        )
        let runtimeRunPath = try validateRuntimeManifestPaths(manifest)
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
        try verifyPreparedEntitlements(
            app.url,
            runtimeRunPath: runtimeRunPath,
            runtimeSocketPath: manifest.runtimeSocketPath
        )
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
        let manifest = verification.manifest
        let launchNonce = UUID().uuidString
        try prepareRuntimeStateForLaunch(
            manifest: manifest,
            launchNonce: launchNonce
        )
        var rollbackIdentity: PlayCoverHello?
        var launchedPID: Int32?
        do {
            let launchedApplication = try launchPreparedApplication(
                manifest: manifest
            )
            launchedPID = launchedApplication.pid
            guard launchedApplication.pid > 0,
                  launchedApplication.bundleIdentifier
                    == manifest.bundleIdentifier,
                  launchedApplication.bundleURLPath
                    == URL(
                        fileURLWithPath: manifest.preparedAppPath,
                        isDirectory: true
                    ).standardizedFileURL.path else {
                throw PlayCoverBackendError.launchFailed(
                    "NSWorkspace returned an App identity that does not match "
                        + "the prepared generation"
                )
            }

            let deadline = Date().addingTimeInterval(timeout)
            var lastHelloError: Error?
            while Date() < deadline {
                do {
                    let remaining = max(0.01, deadline.timeIntervalSinceNow)
                    let client = PlayCoverRuntimeClient(
                        socketPath: manifest.runtimeSocketPath,
                        launchNonce: launchNonce,
                        timeoutSeconds: min(0.25, remaining)
                    )
                    let payload = try client.hello()
                    let runtimeIdentity = try validateRuntimeIdentity(
                        payload,
                        launchNonce: launchNonce,
                        verification: verification
                    )
                    guard runtimeIdentity.pid == launchedPID else {
                        throw PlayCoverBackendError.launchFailed(
                            "Runtime PID does not match the App instance "
                                + "returned by NSWorkspace"
                        )
                    }
                    rollbackIdentity = runtimeIdentity
                    return try validateRuntimeHello(
                        payload,
                        launchNonce: launchNonce,
                        verification: verification
                    )
                } catch {
                    lastHelloError = error
                }
                if Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            let suffix = lastHelloError.map {
                "; last hello error: \($0)"
            } ?? ""
            throw PlayCoverBackendError.launchTimedOut(
                "no verified runtime hello at \(manifest.runtimeSocketPath) "
                    + "within \(timeout) seconds\(suffix)"
            )
        } catch {
            do {
                try rollbackFailedLaunch(
                    verification: verification,
                    launchNonce: launchNonce,
                    knownIdentity: rollbackIdentity,
                    launchedPID: launchedPID
                )
            } catch let rollbackError {
                throw PlayCoverBackendError.launchFailed(
                    "PlayCover launch failed: \(error); rollback failed: "
                        + "\(rollbackError)"
                )
            }
            throw error
        }
    }

    @discardableResult
    static func terminate(session: SessionService.Info) throws -> Int32 {
        guard let appPath = session.playCoverAppPath,
              let pidValue = session.runnerPid,
              pidValue > 0,
              pidValue <= Int(Int32.max),
              let bundleIdentifier = session.bundleId,
              let profileHash = session.profileHash,
              let runtimeSocketPath = session.playCoverRuntimeSocketPath,
              let launchNonce = session.playCoverLaunchNonce,
              let preparedGenerationID = session.playCoverPreparedGenerationID,
              let runtimeInstanceID = session.playCoverRuntimeInstanceID else {
            throw PlayCoverBackendError.terminateFailed(
                "active session is missing PlayCover runtime identity"
            )
        }
        let pid = Int32(pidValue)
        let verification = try verify(appPath: appPath)
        let manifest = verification.manifest
        guard bundleIdentifier == manifest.bundleIdentifier,
              profileHash == manifest.profileHash,
              runtimeSocketPath == manifest.runtimeSocketPath,
              preparedGenerationID == manifest.preparedGenerationID,
              !launchNonce.isEmpty,
              !runtimeInstanceID.isEmpty else {
            throw PlayCoverBackendError.terminateFailed(
                "active session does not match the signed prepared generation"
            )
        }
        guard processExists(pid) else {
            try cleanupRuntimeState(
                verification: verification,
                pid: pid,
                launchNonce: launchNonce,
                runtimeInstanceID: runtimeInstanceID
            )
            return pid
        }

        let runtimePayload: PlayCoverRuntimeResponsePayload
        do {
            runtimePayload = try PlayCoverRuntimeClient(
                socketPath: runtimeSocketPath,
                launchNonce: launchNonce,
                timeoutSeconds: 1
            ).ping()
        } catch {
            throw PlayCoverBackendError.terminateFailed(
                "cannot authenticate the active PlayCover Runtime before "
                    + "termination: \(error)"
            )
        }
        guard runtimePayload.pid == pid,
              runtimePayload.bundleIdentifier == bundleIdentifier,
              runtimePayload.profileHash == profileHash,
              runtimePayload.preparedGenerationID == preparedGenerationID,
              runtimePayload.runtimeSocketPath == runtimeSocketPath,
              runtimePayload.runtimeInstanceID == runtimeInstanceID,
              runtimePayload.launchNonce == launchNonce else {
            throw PlayCoverBackendError.terminateFailed(
                "active Runtime identity no longer matches driver.lock"
            )
        }

        let ps = try Shell.runWithResult(
            "/bin/ps",
            arguments: ["-p", "\(pid)", "-o", "command="]
        )
        let command = ps.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ps.exitCode == 0,
              commandMatchesPreparedApp(command, manifest: manifest) else {
            throw PlayCoverBackendError.terminateFailed(
                "refusing to signal pid \(pid) because it is not the prepared App"
            )
        }
        #if canImport(Darwin)
        guard Darwin.kill(pid, SIGTERM) == 0 else {
            throw PlayCoverBackendError.terminateFailed(
                "kill(\(pid), SIGTERM) failed with errno \(errno)"
            )
        }
        let deadline = Date().addingTimeInterval(5)
        while processExists(pid), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !processExists(pid) else {
            throw PlayCoverBackendError.terminateFailed(
                "pid \(pid) did not exit within 5 seconds"
            )
        }
        #else
        throw PlayCoverBackendError.terminateFailed("process termination is only supported on macOS")
        #endif
        try cleanupRuntimeState(
            verification: verification,
            pid: pid,
            launchNonce: launchNonce,
            runtimeInstanceID: runtimeInstanceID
        )
        return pid
    }

    static func commandMatchesPreparedApp(
        _ command: String,
        manifest: PlayCoverPrepareManifest
    ) -> Bool {
        let executableCandidates = [
            URL(
                fileURLWithPath: manifest.preparedAppPath,
                isDirectory: true
            ).appendingPathComponent(manifest.executableName).path,
            URL(
                fileURLWithPath: manifest.preparedAppPath,
                isDirectory: true
            )
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(manifest.executableName).path,
        ]
        return executableCandidates.contains(where: {
            command == $0 || command.hasPrefix($0 + " ")
        })
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
        preparedGenerationID: String,
        runtimeBootstrapPath: String,
        runtimeSocketPath: String,
        to url: URL
    ) throws {
        var dictionary: [String: Any] = [
            "schemaVersion": 2,
            "deviceProfileSchemaVersion": profile.schemaVersion,
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
            "preparedGenerationID": preparedGenerationID,
            "runtimeBootstrapPath": runtimeBootstrapPath,
            "runtimeSocketPath": runtimeSocketPath,
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

    private static func signPreparedApp(
        _ app: URL,
        runtimeRunPath: String,
        runtimeSocketPath: String
    ) throws {
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

        let sandboxRules = runtimeSandboxRules(
            runtimeRunPath: runtimeRunPath,
            runtimeSocketPath: runtimeSocketPath
        )
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
            "com.apple.security.temporary-exception.sbpl": sandboxRules,
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

    private static func verifyPreparedEntitlements(
        _ app: URL,
        runtimeRunPath: String,
        runtimeSocketPath: String
    ) throws {
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
        let expectedRules = runtimeSandboxRules(
            runtimeRunPath: runtimeRunPath,
            runtimeSocketPath: runtimeSocketPath
        )
        guard let rules = dictionary[
            "com.apple.security.temporary-exception.sbpl"
        ] as? [String],
              rules == expectedRules else {
            throw PlayCoverBackendError.verificationFailed(
                "prepared App sandbox exceptions do not exactly match the "
                    + "runtime run directory and socket"
            )
        }
    }

    static func runtimeSandboxRules(
        runtimeRunPath: String,
        runtimeSocketPath: String
    ) -> [String] {
        [
            "(allow file-read* file-write* file-read-metadata "
                + "(subpath \"\(sandboxEscaped(runtimeRunPath))\"))",
            "(allow network-bind network-inbound "
                + "(literal \"\(sandboxEscaped(runtimeSocketPath))\"))",
        ]
    }

    private static func sandboxEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func prepareRuntimeStateForLaunch(
        manifest: PlayCoverPrepareManifest,
        launchNonce: String
    ) throws {
        guard !launchNonce.isEmpty else {
            throw PlayCoverBackendError.launchFailed(
                "launch nonce must be non-empty"
            )
        }
        let runPath: String
        do {
            runPath = try validateRuntimeManifestPaths(manifest)
        } catch {
            throw PlayCoverBackendError.launchFailed(String(describing: error))
        }
        try validateRuntimeSocketPath(
            manifest.runtimeSocketPath,
            error: { PlayCoverBackendError.launchFailed($0) }
        )
        try ensurePrivateRunDirectory(runPath)
        try removeStaleRuntimeSocket(at: manifest.runtimeSocketPath)
        try removeOwnedRegularFileIfPresent(
            at: manifest.helloPath,
            operation: "remove stale runtime hello"
        )

        let bootstrap = PlayCoverRuntimeBootstrap(
            schemaVersion: 1,
            launchNonce: launchNonce,
            runtimeSocketPath: manifest.runtimeSocketPath,
            profileHash: manifest.profileHash,
            bundleIdentifier: manifest.bundleIdentifier,
            preparedGenerationID: manifest.preparedGenerationID
        )
        try writePrivateJSONAtomically(
            bootstrap,
            to: manifest.runtimeBootstrapPath
        )
    }

    static func validateRuntimeHello(
        _ payload: PlayCoverRuntimeResponsePayload,
        launchNonce: String,
        verification: PlayCoverVerification
    ) throws -> PlayCoverHello {
        let hello = try validateRuntimeIdentity(
            payload,
            launchNonce: launchNonce,
            verification: verification
        )
        guard payload.protocolVersion == PlayCoverRuntimeClient.schemaVersion,
              payload.logicalWidth
                == Double(verification.profile.logicalWidth),
              payload.logicalHeight
                == Double(verification.profile.logicalHeight),
              payload.nativeWidth
                == Double(verification.profile.nativeWidth),
              payload.nativeHeight
                == Double(verification.profile.nativeHeight),
              payload.scale == verification.profile.scale,
              presentationSizeIsValid(
                  width: payload.windowWidth,
                  height: payload.windowHeight,
                  logicalWidth: Double(verification.profile.logicalWidth),
                  logicalHeight: Double(verification.profile.logicalHeight)
              ) else {
            throw PlayCoverBackendError.launchFailed(
                "runtime hello geometry does not match the fixed profile"
            )
        }
        guard payload.stage == "window-configured" else {
            throw PlayCoverBackendError.launchFailed(
                "runtime is not ready: stage \(payload.stage)"
            )
        }
        return hello
    }

    private static func presentationSizeIsValid(
        width: Double?,
        height: Double?,
        logicalWidth: Double,
        logicalHeight: Double
    ) -> Bool {
        guard let width,
              let height,
              width.isFinite,
              height.isFinite,
              width > 0,
              height > 0 else {
            return false
        }
        let scaleX = width / logicalWidth
        let scaleY = height / logicalHeight
        guard scaleX > 0,
              scaleY > 0,
              scaleX <= 1,
              scaleY <= 1 else {
            return false
        }
        let maximumScale = max(scaleX, scaleY)
        return abs(scaleX - scaleY) <= maximumScale * 0.01
    }

    static func validateRuntimeIdentity(
        _ payload: PlayCoverRuntimeResponsePayload,
        launchNonce: String,
        verification: PlayCoverVerification
    ) throws -> PlayCoverHello {
        let manifest = verification.manifest
        guard payload.protocolVersion == PlayCoverRuntimeClient.schemaVersion,
              payload.launchNonce == launchNonce,
              payload.bundleIdentifier == manifest.bundleIdentifier,
              payload.profileHash == manifest.profileHash,
              payload.preparedGenerationID == manifest.preparedGenerationID,
              payload.runtimeSocketPath == manifest.runtimeSocketPath,
              !payload.runtimeInstanceID.isEmpty else {
            throw PlayCoverBackendError.launchFailed(
                "runtime hello does not match the signed prepared generation"
            )
        }
        guard payload.pid > 0, processExists(payload.pid) else {
            throw PlayCoverBackendError.launchFailed(
                "runtime hello reported a process that is no longer running"
            )
        }
        return PlayCoverHello(
            schemaVersion: payload.protocolVersion,
            launchNonce: launchNonce,
            preparedGenerationID: payload.preparedGenerationID,
            runtimeInstanceID: payload.runtimeInstanceID,
            runtimeSocketPath: payload.runtimeSocketPath,
            pid: payload.pid,
            bundleIdentifier: payload.bundleIdentifier,
            profileHash: payload.profileHash,
            logicalWidth: payload.logicalWidth,
            logicalHeight: payload.logicalHeight,
            nativeWidth: payload.nativeWidth,
            nativeHeight: payload.nativeHeight,
            scale: payload.scale,
            windowWidth: payload.windowWidth,
            windowHeight: payload.windowHeight,
            stage: payload.stage
        )
    }

    private static func ensurePrivateRunDirectory(_ path: String) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw PlayCoverBackendError.launchFailed(
                "cannot create runtime run directory \(path): \(error)"
            )
        }
        #if canImport(Darwin)
        guard let info = try lstatInfo(
            at: path,
            error: { PlayCoverBackendError.launchFailed($0) }
        ) else {
            throw PlayCoverBackendError.launchFailed(
                "runtime run directory disappeared: \(path)"
            )
        }
        guard fileType(info) == mode_t(S_IFDIR),
              info.st_uid == geteuid() else {
            throw PlayCoverBackendError.launchFailed(
                "runtime run path must be an owned directory, not a symlink or other file: \(path)"
            )
        }
        guard Darwin.chmod(path, 0o700) == 0 else {
            throw PlayCoverBackendError.launchFailed(
                "cannot set runtime run directory to mode 0700: errno \(errno)"
            )
        }
        #endif
    }

    private static func removeStaleRuntimeSocket(at path: String) throws {
        #if canImport(Darwin)
        guard let original = try lstatInfo(
            at: path,
            error: { PlayCoverBackendError.launchFailed($0) }
        ) else {
            return
        }
        let originalType = fileType(original)
        guard originalType != mode_t(S_IFLNK) else {
            throw PlayCoverBackendError.launchFailed(
                "refusing symlink at runtime socket path: \(path)"
            )
        }
        guard originalType == mode_t(S_IFSOCK) else {
            throw PlayCoverBackendError.launchFailed(
                "refusing non-socket at runtime socket path: \(path)"
            )
        }
        guard original.st_uid == geteuid() else {
            throw PlayCoverBackendError.launchFailed(
                "refusing runtime socket not owned by the current user: \(path)"
            )
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw PlayCoverBackendError.launchFailed(
                "cannot create stale-socket probe: errno \(errno)"
            )
        }
        defer { Darwin.close(fd) }
        var address = try playCoverUnixSocketAddress(path: path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    fd,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if connected == 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            throw PlayCoverBackendError.launchFailed(
                "a live PlayCover runtime is already listening at \(path)"
            )
        }
        let connectErrno = errno
        guard connectErrno == ECONNREFUSED || connectErrno == ENOENT else {
            throw PlayCoverBackendError.launchFailed(
                "cannot prove runtime socket is stale (connect errno \(connectErrno)): \(path)"
            )
        }
        guard let current = try lstatInfo(
            at: path,
            error: { PlayCoverBackendError.launchFailed($0) }
        ) else {
            return
        }
        guard current.st_dev == original.st_dev,
              current.st_ino == original.st_ino,
              fileType(current) == mode_t(S_IFSOCK),
              current.st_uid == geteuid() else {
            throw PlayCoverBackendError.launchFailed(
                "runtime socket changed during stale cleanup: \(path)"
            )
        }
        guard Darwin.unlink(path) == 0 || errno == ENOENT else {
            throw PlayCoverBackendError.launchFailed(
                "cannot remove stale runtime socket \(path): errno \(errno)"
            )
        }
        #else
        throw PlayCoverBackendError.launchFailed(
            "PlayCover runtime sockets are only supported on macOS"
        )
        #endif
    }

    private static func removeOwnedRegularFileIfPresent(
        at path: String,
        operation: String
    ) throws {
        #if canImport(Darwin)
        guard let info = try lstatInfo(
            at: path,
            error: { PlayCoverBackendError.launchFailed($0) }
        ) else {
            return
        }
        guard fileType(info) == mode_t(S_IFREG),
              info.st_uid == geteuid() else {
            throw PlayCoverBackendError.launchFailed(
                "refusing to \(operation) because the path is not an owned regular file: \(path)"
            )
        }
        guard Darwin.unlink(path) == 0 || errno == ENOENT else {
            throw PlayCoverBackendError.launchFailed(
                "cannot \(operation) at \(path): errno \(errno)"
            )
        }
        #endif
    }

    private static func writePrivateJSONAtomically<T: Encodable>(
        _ value: T,
        to path: String
    ) throws {
        #if canImport(Darwin)
        if let existing = try lstatInfo(
            at: path,
            error: { PlayCoverBackendError.launchFailed($0) }
        ) {
            guard fileType(existing) == mode_t(S_IFREG),
                  existing.st_uid == geteuid() else {
                throw PlayCoverBackendError.launchFailed(
                    "refusing to replace runtime bootstrap because it is not an owned regular file: \(path)"
                )
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let destination = URL(fileURLWithPath: path)
        let temporaryPath = destination.deletingLastPathComponent()
            .appendingPathComponent(".bootstrap-\(UUID().uuidString).tmp")
            .path
        let fd = Darwin.open(
            temporaryPath,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else {
            throw PlayCoverBackendError.launchFailed(
                "cannot create private runtime bootstrap: errno \(errno)"
            )
        }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(fd)
            if shouldRemoveTemporary {
                Darwin.unlink(temporaryPath)
            }
        }
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let count = Darwin.write(
                        fd,
                        base.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    if count < 0, errno == EINTR {
                        continue
                    }
                    guard count > 0 else {
                        throw PlayCoverBackendError.launchFailed(
                            "cannot write runtime bootstrap: errno \(errno)"
                        )
                    }
                    offset += count
                }
            }
            guard Darwin.fsync(fd) == 0 else {
                throw PlayCoverBackendError.launchFailed(
                    "cannot sync runtime bootstrap: errno \(errno)"
                )
            }
            guard Darwin.rename(temporaryPath, path) == 0 else {
                throw PlayCoverBackendError.launchFailed(
                    "cannot atomically install runtime bootstrap: errno \(errno)"
                )
            }
            shouldRemoveTemporary = false
            guard Darwin.chmod(path, 0o600) == 0 else {
                throw PlayCoverBackendError.launchFailed(
                    "cannot set runtime bootstrap to mode 0600: errno \(errno)"
                )
            }
        } catch let error as PlayCoverBackendError {
            throw error
        } catch {
            throw PlayCoverBackendError.launchFailed(
                "cannot encode runtime bootstrap: \(error)"
            )
        }
        #else
        throw PlayCoverBackendError.launchFailed(
            "PlayCover runtime bootstrap is only supported on macOS"
        )
        #endif
    }

    static func rollbackFailedLaunch(
        verification: PlayCoverVerification,
        launchNonce: String,
        knownIdentity: PlayCoverHello?,
        launchedPID: Int32? = nil
    ) throws {
        let identity = knownIdentity ?? matchingHelloForFailedLaunch(
            verification: verification,
            launchNonce: launchNonce
        )
        if let pid = launchedPID ?? identity?.pid {
            try terminateFailedLaunchProcess(
                pid: pid,
                manifest: verification.manifest
            )
        }
        try cleanupFailedLaunchState(
            verification: verification,
            launchNonce: launchNonce,
            identity: identity
        )
    }

    private struct LaunchedApplicationIdentity {
        let pid: Int32
        let bundleIdentifier: String?
        let bundleURLPath: String?
    }

    private final class ApplicationLaunchResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<LaunchedApplicationIdentity, Error>?

        func set(
            _ value: Result<LaunchedApplicationIdentity, Error>
        ) {
            lock.lock()
            result = value
            lock.unlock()
        }

        func get() -> Result<LaunchedApplicationIdentity, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    private static func launchPreparedApplication(
        manifest: PlayCoverPrepareManifest
    ) throws -> LaunchedApplicationIdentity {
        #if canImport(AppKit)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.environment = sanitizedLaunchEnvironment()
        let result = ApplicationLaunchResultBox()
        let completion = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(
            at: URL(
                fileURLWithPath: manifest.preparedAppPath,
                isDirectory: true
            ),
            configuration: configuration
        ) { application, error in
            if let application {
                result.set(
                    .success(
                        LaunchedApplicationIdentity(
                            pid: application.processIdentifier,
                            bundleIdentifier: application.bundleIdentifier,
                            bundleURLPath: application.bundleURL?
                                .standardizedFileURL.path
                        )
                    )
                )
            } else if let error {
                result.set(.failure(error))
            } else {
                result.set(
                    .failure(
                        PlayCoverBackendError.launchFailed(
                            "NSWorkspace returned neither an App nor an error"
                        )
                    )
                )
            }
            completion.signal()
        }
        completion.wait()
        guard let launchResult = result.get() else {
            throw PlayCoverBackendError.launchFailed(
                "NSWorkspace completion did not publish an App identity"
            )
        }
        do {
            return try launchResult.get()
        } catch {
            throw PlayCoverBackendError.launchFailed(
                "NSWorkspace could not launch the prepared App: \(error)"
            )
        }
        #else
        throw PlayCoverBackendError.launchFailed(
            "PlayCover App launch is only supported on macOS"
        )
        #endif
    }

    private static func terminateFailedLaunchProcess(
        pid: Int32,
        manifest: PlayCoverPrepareManifest
    ) throws {
        guard pid > 0 else {
            throw PlayCoverBackendError.launchFailed(
                "rollback identity contains an invalid pid"
            )
        }
        if let failedLaunchTerminatorOverrideForTesting {
            try failedLaunchTerminatorOverrideForTesting(pid, manifest)
            return
        }
        guard processExists(pid) else {
            return
        }
        let ps = try Shell.runWithResult(
            "/bin/ps",
            arguments: ["-p", "\(pid)", "-o", "command="]
        )
        let command = ps.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard ps.exitCode == 0,
              commandMatchesPreparedApp(command, manifest: manifest) else {
            throw PlayCoverBackendError.launchFailed(
                "refusing to roll back pid \(pid) because it is not the "
                    + "prepared App"
            )
        }
        #if canImport(Darwin)
        guard Darwin.kill(pid, SIGTERM) == 0 else {
            throw PlayCoverBackendError.launchFailed(
                "rollback kill(\(pid), SIGTERM) failed with errno \(errno)"
            )
        }
        let deadline = Date().addingTimeInterval(5)
        while processExists(pid), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !processExists(pid) else {
            throw PlayCoverBackendError.launchFailed(
                "rollback pid \(pid) did not exit within 5 seconds"
            )
        }
        #else
        throw PlayCoverBackendError.launchFailed(
            "PlayCover rollback is only supported on macOS"
        )
        #endif
    }

    private static func matchingHelloForFailedLaunch(
        verification: PlayCoverVerification,
        launchNonce: String
    ) -> PlayCoverHello? {
        #if canImport(Darwin)
        let manifest = verification.manifest
        let original: stat?
        do {
            original = try lstatInfo(
                at: manifest.helloPath,
                error: { PlayCoverBackendError.launchFailed($0) }
            )
        } catch {
            return nil
        }
        guard let original,
              fileType(original) == mode_t(S_IFREG),
              original.st_uid == geteuid(),
              let data = try? Data(
                  contentsOf: URL(fileURLWithPath: manifest.helloPath)
              ),
              let hello = try? JSONDecoder().decode(
                  PlayCoverHello.self,
                  from: data
              ),
              hello.schemaVersion == 1,
              hello.pid > 0,
              hello.bundleIdentifier == manifest.bundleIdentifier,
              hello.profileHash == manifest.profileHash,
              hello.launchNonce == launchNonce,
              hello.preparedGenerationID == manifest.preparedGenerationID,
              let runtimeInstanceID = hello.runtimeInstanceID,
              !runtimeInstanceID.isEmpty,
              hello.runtimeSocketPath == manifest.runtimeSocketPath,
              fileIdentityStillMatches(
                  path: manifest.helloPath,
                  original: original,
                  expectedType: mode_t(S_IFREG)
              ) else {
            return nil
        }
        return hello
        #else
        return nil
        #endif
    }

    private static func cleanupFailedLaunchState(
        verification: PlayCoverVerification,
        launchNonce: String,
        identity: PlayCoverHello?
    ) throws {
        #if canImport(Darwin)
        let manifest = verification.manifest
        guard let bootstrapInfo = try lstatInfo(
            at: manifest.runtimeBootstrapPath,
            error: { PlayCoverBackendError.launchFailed($0) }
        ) else {
            let socketExists = try lstatInfo(
                at: manifest.runtimeSocketPath,
                error: { PlayCoverBackendError.launchFailed($0) }
            ) != nil
            let helloExists = try lstatInfo(
                at: manifest.helloPath,
                error: { PlayCoverBackendError.launchFailed($0) }
            ) != nil
            guard !socketExists, !helloExists else {
                throw PlayCoverBackendError.launchFailed(
                    "rollback state lost its bootstrap identity"
                )
            }
            return
        }
        guard fileType(bootstrapInfo) == mode_t(S_IFREG),
              bootstrapInfo.st_uid == geteuid(),
              let bootstrap = try? JSONDecoder().decode(
                  PlayCoverRuntimeBootstrap.self,
                  from: Data(
                      contentsOf: URL(
                          fileURLWithPath: manifest.runtimeBootstrapPath
                      )
                  )
              ),
              bootstrap.schemaVersion == 1,
              bootstrap.launchNonce == launchNonce,
              bootstrap.runtimeSocketPath == manifest.runtimeSocketPath,
              bootstrap.profileHash == manifest.profileHash,
              bootstrap.bundleIdentifier == manifest.bundleIdentifier,
              bootstrap.preparedGenerationID
                == manifest.preparedGenerationID,
              fileIdentityStillMatches(
                  path: manifest.runtimeBootstrapPath,
                  original: bootstrapInfo,
                  expectedType: mode_t(S_IFREG)
              ) else {
            throw PlayCoverBackendError.launchFailed(
                "rollback bootstrap does not match this launch"
            )
        }

        let helloInfo = try lstatInfo(
            at: manifest.helloPath,
            error: { PlayCoverBackendError.launchFailed($0) }
        )
        if let helloInfo {
            guard let identity,
                  fileType(helloInfo) == mode_t(S_IFREG),
                  helloInfo.st_uid == geteuid(),
                  let onDiskHello = try? JSONDecoder().decode(
                      PlayCoverHello.self,
                      from: Data(
                          contentsOf: URL(fileURLWithPath: manifest.helloPath)
                      )
                  ),
                  onDiskHello.pid == identity.pid,
                  onDiskHello.bundleIdentifier == manifest.bundleIdentifier,
                  onDiskHello.profileHash == manifest.profileHash,
                  onDiskHello.launchNonce == launchNonce,
                  onDiskHello.preparedGenerationID
                    == manifest.preparedGenerationID,
                  onDiskHello.runtimeInstanceID
                    == identity.runtimeInstanceID,
                  onDiskHello.runtimeSocketPath
                    == manifest.runtimeSocketPath,
                  fileIdentityStillMatches(
                      path: manifest.helloPath,
                      original: helloInfo,
                      expectedType: mode_t(S_IFREG)
                  ) else {
                throw PlayCoverBackendError.launchFailed(
                    "rollback hello does not match this launch"
                )
            }
        }

        try removeStaleRuntimeSocket(at: manifest.runtimeSocketPath)
        if let helloInfo {
            unlinkIfUnchanged(
                path: manifest.helloPath,
                original: helloInfo,
                expectedType: mode_t(S_IFREG)
            )
        }
        unlinkIfUnchanged(
            path: manifest.runtimeBootstrapPath,
            original: bootstrapInfo,
            expectedType: mode_t(S_IFREG)
        )
        #else
        throw PlayCoverBackendError.launchFailed(
            "PlayCover rollback is only supported on macOS"
        )
        #endif
    }

    private static func cleanupRuntimeState(
        verification: PlayCoverVerification,
        pid: Int32,
        launchNonce: String,
        runtimeInstanceID: String
    ) throws {
        #if canImport(Darwin)
        let manifest = verification.manifest
        guard let bootstrapInfo = try lstatInfo(
            at: manifest.runtimeBootstrapPath,
            error: { PlayCoverBackendError.terminateFailed($0) }
        ) else {
            let socketExists = try lstatInfo(
                at: manifest.runtimeSocketPath,
                error: { PlayCoverBackendError.terminateFailed($0) }
            ) != nil
            let helloExists = try lstatInfo(
                at: manifest.helloPath,
                error: { PlayCoverBackendError.terminateFailed($0) }
            ) != nil
            guard !socketExists, !helloExists else {
                throw PlayCoverBackendError.terminateFailed(
                    "runtime state lost its bootstrap identity"
                )
            }
            return
        }
        guard
              fileType(bootstrapInfo) == mode_t(S_IFREG),
              bootstrapInfo.st_uid == geteuid(),
              let bootstrap = try? JSONDecoder().decode(
                  PlayCoverRuntimeBootstrap.self,
                  from: Data(
                      contentsOf: URL(
                          fileURLWithPath: manifest.runtimeBootstrapPath
                      )
                  )
              ),
              bootstrap.schemaVersion == 1,
              bootstrap.launchNonce == launchNonce,
              bootstrap.runtimeSocketPath == manifest.runtimeSocketPath,
              bootstrap.profileHash == manifest.profileHash,
              bootstrap.bundleIdentifier == manifest.bundleIdentifier,
              bootstrap.preparedGenerationID == manifest.preparedGenerationID,
              fileIdentityStillMatches(
                  path: manifest.runtimeBootstrapPath,
                  original: bootstrapInfo,
                  expectedType: mode_t(S_IFREG)
              ) else {
            throw PlayCoverBackendError.terminateFailed(
                "runtime bootstrap does not match the active session"
            )
        }

        let helloInfo = try lstatInfo(
            at: manifest.helloPath,
            error: { PlayCoverBackendError.terminateFailed($0) }
        )
        if let helloInfo {
            guard fileType(helloInfo) == mode_t(S_IFREG),
                  helloInfo.st_uid == geteuid(),
                  let hello = try? JSONDecoder().decode(
                      PlayCoverHello.self,
                      from: Data(
                          contentsOf: URL(
                              fileURLWithPath: manifest.helloPath
                          )
                      )
                  ),
                  hello.schemaVersion == 1,
                  hello.pid == pid,
                  hello.bundleIdentifier == manifest.bundleIdentifier,
                  hello.profileHash == manifest.profileHash,
                  hello.launchNonce == launchNonce,
                  hello.preparedGenerationID
                    == manifest.preparedGenerationID,
                  hello.runtimeInstanceID == runtimeInstanceID,
                  hello.runtimeSocketPath == manifest.runtimeSocketPath,
                  fileIdentityStillMatches(
                      path: manifest.helloPath,
                      original: helloInfo,
                      expectedType: mode_t(S_IFREG)
                  ) else {
                throw PlayCoverBackendError.terminateFailed(
                    "runtime hello does not match the active session"
                )
            }
        }

        do {
            try removeStaleRuntimeSocket(at: manifest.runtimeSocketPath)
        } catch {
            throw PlayCoverBackendError.terminateFailed(
                "cannot clean the stopped Runtime socket: \(error)"
            )
        }

        if let helloInfo {
            guard unlinkIfUnchanged(
                path: manifest.helloPath,
                original: helloInfo,
                expectedType: mode_t(S_IFREG)
            ) else {
                throw PlayCoverBackendError.terminateFailed(
                    "runtime hello changed during cleanup"
                )
            }
        }
        guard unlinkIfUnchanged(
            path: manifest.runtimeBootstrapPath,
            original: bootstrapInfo,
            expectedType: mode_t(S_IFREG)
        ) else {
            throw PlayCoverBackendError.terminateFailed(
                "runtime bootstrap changed during cleanup"
            )
        }
        #else
        throw PlayCoverBackendError.terminateFailed(
            "PlayCover cleanup is only supported on macOS"
        )
        #endif
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

    private static func validateRuntimeStatePaths(_ paths: IOSUsePaths) throws {
        let run = URL(fileURLWithPath: paths.playcoverRun, isDirectory: true)
            .standardizedFileURL.path
        let expectedBootstrap = URL(fileURLWithPath: run, isDirectory: true)
            .appendingPathComponent("bootstrap.json").path
        let expectedSocket = URL(fileURLWithPath: run, isDirectory: true)
            .appendingPathComponent("runtime.sock").path
        let expectedHello = URL(fileURLWithPath: run, isDirectory: true)
            .appendingPathComponent("hello.json").path
        guard paths.playcoverRuntimeBootstrap == expectedBootstrap,
              paths.playcoverRuntimeSocket == expectedSocket,
              paths.playcoverHello == expectedHello else {
            throw PlayCoverBackendError.prepareFailed(
                "PlayCover runtime paths must be direct children of \(run)"
            )
        }
        try validateRuntimeSocketPath(
            paths.playcoverRuntimeSocket,
            error: { PlayCoverBackendError.prepareFailed($0) }
        )
    }

    private static func validateRuntimeManifestPaths(
        _ manifest: PlayCoverPrepareManifest
    ) throws -> String {
        let socketURL = URL(fileURLWithPath: manifest.runtimeSocketPath)
            .standardizedFileURL
        let bootstrapURL = URL(fileURLWithPath: manifest.runtimeBootstrapPath)
            .standardizedFileURL
        let helloURL = URL(fileURLWithPath: manifest.helloPath)
            .standardizedFileURL
        let runURL = socketURL.deletingLastPathComponent()
        guard manifest.runtimeSocketPath == socketURL.path,
              manifest.runtimeBootstrapPath == bootstrapURL.path,
              manifest.helloPath == helloURL.path,
              socketURL.lastPathComponent == "runtime.sock",
              bootstrapURL.lastPathComponent == "bootstrap.json",
              helloURL.lastPathComponent == "hello.json",
              bootstrapURL.deletingLastPathComponent() == runURL,
              helloURL.deletingLastPathComponent() == runURL,
              runURL.lastPathComponent == "run" else {
            throw PlayCoverBackendError.verificationFailed(
                "runtime socket, bootstrap, and hello paths must be fixed children of one run directory"
            )
        }
        return runURL.path
    }

    private static func validateRuntimeSocketPath<E: Error>(
        _ path: String,
        error makeError: (String) -> E
    ) throws {
        // Darwin's sockaddr_un.sun_path is 104 bytes including the trailing NUL.
        guard !path.utf8.contains(0), path.utf8.count <= 103 else {
            throw makeError(
                "runtime socket path is too long for Darwin AF_UNIX "
                    + "(\(path.utf8.count) UTF-8 bytes; maximum 103): \(path)"
            )
        }
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

}

#if canImport(Darwin)
private func lstatInfo<E: Error>(
    at path: String,
    error makeError: (String) -> E
) throws -> stat? {
    var info = stat()
    if Darwin.lstat(path, &info) == 0 {
        return info
    }
    if errno == ENOENT {
        return nil
    }
    throw makeError("cannot inspect \(path) with lstat: errno \(errno)")
}

private func fileType(_ info: stat) -> mode_t {
    info.st_mode & mode_t(S_IFMT)
}

@discardableResult
private func unlinkIfUnchanged(
    path: String,
    original: stat,
    expectedType: mode_t
) -> Bool {
    guard fileIdentityStillMatches(
        path: path,
        original: original,
        expectedType: expectedType
    ) else {
        return false
    }
    return Darwin.unlink(path) == 0 || errno == ENOENT
}

private func fileIdentityStillMatches(
    path: String,
    original: stat,
    expectedType: mode_t
) -> Bool {
    guard let current = try? lstatInfo(
        at: path,
        error: { PlayCoverBackendError.terminateFailed($0) }
    ) else {
        return false
    }
    return current.st_dev == original.st_dev
        && current.st_ino == original.st_ino
        && fileType(current) == expectedType
        && current.st_uid == geteuid()
}

private func playCoverUnixSocketAddress(path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8)
    let maximumLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    guard bytes.count <= maximumLength else {
        throw PlayCoverBackendError.launchFailed(
            "runtime socket path is too long for Darwin AF_UNIX: \(path)"
        )
    }
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(
            to: Int8.self,
            capacity: maximumLength + 1
        ) { raw in
            for index in bytes.indices {
                raw[index] = Int8(bitPattern: bytes[index])
            }
            raw[bytes.count] = 0
        }
    }
    return address
}
#endif
