import Foundation
import IOSUseProtocol
#if canImport(AppKit)
import AppKit
#endif

enum OpenURLService {
    static var realDeviceURLLauncherForTesting: ((String, String) throws -> Void)?
    static var macURLLauncherForTesting: ((
        URL,
        URL,
        SessionService.Info
    ) throws -> Void)?

    enum MacOpenError:
        Error,
        Equatable,
        CustomStringConvertible,
        MachineErrorConvertible
    {
        case schemeNotRegistered(String)
        case targetMismatch(String)
        case dispatchRejected(String)
        case dispatchUnresolved(String)

        var description: String {
            switch self {
            case .schemeNotRegistered(let scheme):
                return "URL scheme \"\(scheme)\" is not registered by the active Mac App."
            case .targetMismatch(let message):
                return "Mac URL target does not match the active App: \(message)"
            case .dispatchRejected(let message):
                return "macOS did not accept the URL dispatch: \(message)"
            case .dispatchUnresolved(let message):
                return "macOS URL dispatch did not resolve: \(message)"
            }
        }

        var machineError: MachineError {
            switch self {
            case .schemeNotRegistered:
                return MachineError(
                    message: description,
                    category: IOSUseErrorCategory.validation,
                    code: "open_scheme_unregistered",
                    phase: IOSUseErrorPhase.validation,
                    retryable: false,
                    fatal: false,
                    mutationMayHaveApplied: false
                )
            case .targetMismatch:
                return MachineError(
                    message: description,
                    category: IOSUseErrorCategory.session,
                    code: "open_target_mismatch",
                    phase: IOSUseErrorPhase.session,
                    retryable: false,
                    fatal: false,
                    mutationMayHaveApplied: false
                )
            case .dispatchRejected:
                return MachineError(
                    message: description,
                    category: IOSUseErrorCategory.action,
                    code: "open_dispatch_rejected",
                    phase: IOSUseErrorPhase.dispatch,
                    retryable: true,
                    fatal: false,
                    mutationMayHaveApplied: false
                )
            case .dispatchUnresolved:
                return MachineError(
                    message: description,
                    category: IOSUseErrorCategory.action,
                    code: "open_dispatch_unresolved",
                    phase: IOSUseErrorPhase.dispatch,
                    retryable: false,
                    fatal: false,
                    mutationMayHaveApplied: true
                )
            }
        }
    }

    // MARK: - Scheme Registry

    enum SchemeRegistry {
        struct LookupResult {
            let registeredHandlers: [String]
            let lookupFailed: Bool
        }

        static var lookupOverrideForTesting: ((String, String) -> LookupResult?)?

        static func lookupScheme(_ scheme: String, udid: String) -> LookupResult {
            if let override = lookupOverrideForTesting, let result = override(scheme, udid) {
                return result
            }
            return performLookup(scheme: scheme, udid: udid)
        }

        static func parseSchemeHandlers(scheme: String, response: [String: Any]) -> [String] {
            let lower = scheme.lowercased()
            var handlers: [String] = []
            guard let lookupResult = response["LookupResult"] as? [String: Any] else { return [] }
            for (_, appInfo) in lookupResult {
                guard let info = appInfo as? [String: Any],
                      let bundleID = info["CFBundleIdentifier"] as? String,
                      let urlTypes = info["CFBundleURLTypes"] as? [[String: Any]] else { continue }
                for urlType in urlTypes {
                    if let schemes = urlType["CFBundleURLSchemes"] as? [String],
                       schemes.contains(where: { $0.lowercased() == lower }) {
                        if !handlers.contains(bundleID) {
                            handlers.append(bundleID)
                        }
                    }
                }
            }
            return handlers
        }

        private static func performLookup(scheme: String, udid: String) -> LookupResult {
            do {
                let response = try InstallationProxyClient.withClient(udid: udid) { client in
                    try client.lookup(attributes: ["CFBundleIdentifier", "CFBundleURLTypes"])
                }
                let handlers = parseSchemeHandlers(scheme: scheme, response: response)
                return LookupResult(registeredHandlers: handlers, lookupFailed: false)
            } catch {
                fputs("[open-url] scheme lookup failed for \(scheme) on \(udid): \(error)\n", stderr)
                return LookupResult(registeredHandlers: [], lookupFailed: true)
            }
        }
    }

    // MARK: - Public API

    struct OpenResult {
        let message: String
        let dom: ForyDomPayload?
        let url: String?
        let targetUdid: String?
        let deviceType: String?
        let registeredHandlers: [String]
        let schemeLookupVerified: Bool?
        let readiness: ForyWaitAppForegroundPayload?

        init(
            message: String,
            dom: ForyDomPayload? = nil,
            url: String? = nil,
            targetUdid: String? = nil,
            deviceType: String? = nil,
            registeredHandlers: [String] = [],
            schemeLookupVerified: Bool? = nil,
            readiness: ForyWaitAppForegroundPayload? = nil
        ) {
            self.message = message
            self.dom = dom
            self.url = url
            self.targetUdid = targetUdid
            self.deviceType = deviceType
            self.registeredHandlers = registeredHandlers
            self.schemeLookupVerified = schemeLookupVerified
            self.readiness = readiness
        }
    }

    struct ReadinessError: Error, CustomStringConvertible {
        let hostResult: OpenResult
        let underlying: Error

        var description: String {
            "URL dispatch was accepted (\(hostResult.message)); foreground DOM readiness failed: \(underlying)"
        }
    }

    static func validatedURL(_ url: String) throws -> String {
        guard !url.isEmpty,
              url.trimmingCharacters(in: .whitespacesAndNewlines) == url,
              let components = URLComponents(string: url),
              let scheme = components.scheme,
              !scheme.isEmpty else {
            throw CLIParseError.invalidValue("Invalid URL: \(url)")
        }
        return url
    }

    static func openHostSideIfAvailable(url: String, session: SessionOptions, paths: IOSUsePaths) throws -> OpenResult? {
        let validated = try validatedURL(url)
        let activeDriver = SessionService.read(paths: paths)
        if let activeDriver,
           activeDriver.deviceType
            == PlayCoverSessionService.deviceType {
            if let explicit = session.udid,
               explicit != activeDriver.udid {
                throw CLIParseError.invalidValue(
                    "open target \(explicit) does not match active "
                        + "Mac target \(activeDriver.udid)."
                )
            }
            return try openPlayCover(
                url: validated,
                session: activeDriver,
                paths: paths
            )
        }
        let targetUdid = try SessionService.resolveTargetUdid(
            explicitUdid: session.udid,
            paths: paths,
            missingMessage: "open requires --udid or an active driver. Run `ios-use start` or pass `--udid <UDID>`."
        )
        if activeDriver?.udid == targetUdid {
            if activeDriver?.deviceType == "simulator" {
                try openSimulator(url: validated, udid: targetUdid)
                return OpenResult(message: "Opened URL: \(validated)", url: validated, targetUdid: targetUdid, deviceType: "simulator")
            }
            return try openRealDevice(url: validated, udid: targetUdid)
        }
        if DeviceService.looksLikeSimulatorUDID(targetUdid) {
            let bootedSimulators = try DeviceService.listDevices(simulatorOnly: true, paths: paths)
            guard bootedSimulators.contains(where: { $0.udid == targetUdid }) else {
                return nil
            }
            try openSimulator(url: validated, udid: targetUdid)
            return OpenResult(message: "Opened URL: \(validated)", url: validated, targetUdid: targetUdid, deviceType: "simulator")
        }
        return try openRealDevice(url: validated, udid: targetUdid)
    }

    /// Dispatch the URL, wait for a registered handler when one is known, then
    /// obtain one fresh DOM. This is observation convenience, not proof that the
    /// deep-link destination finished loading.
    static func openWithDom(url: String, session: SessionOptions, paths: IOSUsePaths) throws -> OpenResult {
        let activeDriver = try SessionService.requireDriverLock(paths: paths)
        let targetUdid = try SessionService.resolveTargetUdid(
            explicitUdid: session.udid,
            paths: paths,
            missingMessage: "open --dom requires an active Driver target. Run `ios-use start` first."
        )
        guard activeDriver.udid == targetUdid else {
            throw CLIParseError.invalidValue("open --dom target \(targetUdid) does not match active Driver target \(activeDriver.udid). Run `ios-use stop` and `ios-use start \(targetUdid)`.")
        }
        if activeDriver.deviceType
            == PlayCoverSessionService.deviceType {
            let base: OpenResult
            do {
                base = try openPlayCover(
                    url: try validatedURL(url),
                    session: activeDriver,
                    paths: paths
                )
            } catch {
                throw error
            }
            do {
                let dom = try DriverCommandExecution.withLockedClient(
                    paths: paths,
                    verbose: session.verbose
                ) {
                    try $0.dom(
                        raw: false,
                        fresh: true,
                        waitQuiescence: false
                    )
                }
                return OpenResult(
                    message: base.message,
                    dom: dom,
                    url: base.url,
                    targetUdid: base.targetUdid,
                    deviceType: base.deviceType,
                    registeredHandlers: base.registeredHandlers,
                    schemeLookupVerified: base.schemeLookupVerified
                )
            } catch {
                throw ReadinessError(
                    hostResult: base,
                    underlying: error
                )
            }
        }
        let base = try openHostSideIfAvailable(url: url, session: session, paths: paths)
        guard let base else {
            throw CLIParseError.invalidValue("open target is unavailable. Pass a USB real device UDID, pass a booted Simulator UDID, or run `ios-use start` first.")
        }
        if base.deviceType == "real", base.schemeLookupVerified != true {
            throw ReadinessError(
                hostResult: base,
                underlying: CLIParseError.invalidValue("open --dom cannot verify the target App because URL handler lookup failed; retry the lookup, or compose `open` and `dom` explicitly")
            )
        }
        let acceptedBundleIds = readinessBundleIds(url: url, result: base)
        let readiness: ForyWaitAppForegroundPayload
        do {
            readiness = try DriverCommandExecution.withLockedClient(paths: paths, verbose: session.verbose) { client in
                try client.waitAppForeground(
                    acceptedBundleIds: acceptedBundleIds,
                    timeout: 0,
                    returnDom: true
                )
            }
        } catch {
            throw ReadinessError(hostResult: base, underlying: error)
        }
        guard readiness.snapshotReady else {
            throw ReadinessError(
                hostResult: base,
                underlying: CLIParseError.invalidValue("Driver returned readiness without a successful snapshot")
            )
        }
        return OpenResult(
            message: base.message,
            dom: readiness.dom,
            url: base.url,
            targetUdid: base.targetUdid,
            deviceType: base.deviceType,
            registeredHandlers: base.registeredHandlers,
            schemeLookupVerified: base.schemeLookupVerified,
            readiness: readiness
        )
    }

    static func readinessBundleIds(url: String, result: OpenResult) -> [String] {
        if result.schemeLookupVerified == true, !result.registeredHandlers.isEmpty {
            return result.registeredHandlers
        }
        guard result.deviceType == "simulator",
              let scheme = URLComponents(string: url)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return []
        }
        return ["com.apple.mobilesafari"]
    }

    static func openHostSideIfAvailable(url: String, udid: String?, deviceType: String?, paths: IOSUsePaths) throws -> OpenResult? {
        let validated = try validatedURL(url)
        switch deviceType {
        case "simulator":
            guard let udid, !udid.isEmpty else {
                throw CLIParseError.invalidValue("openURL requires a simulator UDID")
            }
            try openSimulator(url: validated, udid: udid)
            return OpenResult(message: "Opened URL: \(validated)", url: validated, targetUdid: udid, deviceType: "simulator")
        case "real":
            guard let udid, !udid.isEmpty else {
                throw CLIParseError.invalidValue("openURL requires a real device UDID")
            }
            return try openRealDevice(url: validated, udid: udid)
        default:
            return nil
        }
    }

    // MARK: - Simulator

    private static func openSimulator(url: String, udid: String) throws {
        try SimulatorService.openURL(url, udid: udid)
    }

    // MARK: - Real Device

    private static func openRealDevice(url: String, udid: String) throws -> OpenResult {
        let scheme = URLComponents(string: url)?.scheme ?? ""
        let lookup = SchemeRegistry.lookupScheme(scheme, udid: udid)

        if !lookup.lookupFailed, lookup.registeredHandlers.isEmpty {
            throw CLIParseError.invalidValue("URL scheme \"\(scheme)\" not registered on device")
        }

        try openRealDeviceURL(url: url, udid: udid)

        if lookup.lookupFailed {
            return OpenResult(
                message: "Sent URL request: \(url) (unable to verify scheme registration)",
                url: url,
                targetUdid: udid,
                deviceType: "real",
                schemeLookupVerified: false
            )
        }

        let handlers = lookup.registeredHandlers.joined(separator: ", ")
        return OpenResult(
            message: "Opened URL: \(url) (handler: \(handlers))",
            url: url,
            targetUdid: udid,
            deviceType: "real",
            registeredHandlers: lookup.registeredHandlers,
            schemeLookupVerified: true
        )
    }

    static func machineData(_ result: OpenResult) -> MachineValue {
        .object([
            "url": result.url.map(MachineValue.string) ?? .null,
            "deviceUdid": result.targetUdid.map(MachineValue.string) ?? .null,
            "deviceType": result.deviceType.map(MachineValue.string) ?? .null,
            "mutationDispatched": .boolean(true),
            "schemeLookupVerified": result.schemeLookupVerified.map(MachineValue.boolean) ?? .null,
            "registeredHandlers": .array(result.registeredHandlers.map(MachineValue.string)),
            "readiness": result.readiness.map(AppLifecycleService.machineReadiness) ?? .null,
            "dom": result.dom.map(machineDom) ?? .null,
        ])
    }

    private static func openPlayCover(
        url: String,
        session: SessionService.Info,
        paths: IOSUsePaths
    ) throws -> OpenResult {
        let slot: PlayCoverInstalledSlot
        do {
            slot = try PlayCoverSessionService.validateSlot(
                session: session,
                paths: paths
            )
        } catch {
            throw MacOpenError.targetMismatch(String(describing: error))
        }
        guard let dispatchURL = URL(string: url),
              let scheme = dispatchURL.scheme?.lowercased() else {
            throw CLIParseError.invalidValue("Invalid URL: \(url)")
        }
        guard registeredSchemes(in: slot.appPath).contains(scheme) else {
            throw MacOpenError.schemeNotRegistered(scheme)
        }
        let appURL = URL(
            fileURLWithPath: slot.appPath,
            isDirectory: true
        )
        try openMacURL(
            dispatchURL,
            withApplicationAt: appURL,
            session: session
        )
        return OpenResult(
            message: "Opened URL in active Mac App: \(url)",
            url: url,
            targetUdid: session.udid,
            deviceType: PlayCoverSessionService.deviceType,
            registeredHandlers: session.bundleId.map { [$0] } ?? [],
            schemeLookupVerified: true
        )
    }

    private static func registeredSchemes(in appPath: String) -> Set<String> {
        let plistURL = URL(
            fileURLWithPath: appPath,
            isDirectory: true
        ).appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let types = plist["CFBundleURLTypes"] as? [[String: Any]] else {
            return []
        }
        return Set(types.flatMap { type in
            (type["CFBundleURLSchemes"] as? [String] ?? [])
                .map { $0.lowercased() }
        })
    }

    private static func openMacURL(
        _ url: URL,
        withApplicationAt appURL: URL,
        session: SessionService.Info
    ) throws {
        if let launcher = macURLLauncherForTesting {
            try launcher(url, appURL, session)
            return
        }
        #if canImport(AppKit)
        guard let storedRunnerPID = session.runnerPid,
              let runnerPID = Int32(exactly: storedRunnerPID),
              let bundleIdentifier = session.bundleId,
              let executablePath = session.macExecutablePath else {
            throw MacOpenError.targetMismatch(
                "driver.lock is missing the running process identity"
            )
        }
        guard let activeApplication = NSRunningApplication
                .runningApplications(
                    withBundleIdentifier: bundleIdentifier
                ).first(where: {
                    !$0.isTerminated
                        && $0.processIdentifier == runnerPID
                }),
              PlayCoverRuntimeClient.canonicalPath(
                activeApplication.bundleURL?.path ?? ""
              ) == PlayCoverRuntimeClient.canonicalPath(appURL.path),
              PlayCoverRuntimeClient.canonicalPath(
                activeApplication.executableURL?.path ?? ""
              ) == PlayCoverRuntimeClient.canonicalPath(executablePath) else {
            throw MacOpenError.targetMismatch(
                "the recorded process is no longer running from the active slot"
            )
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.createsNewApplicationInstance = false
        let box = MacOpenCompletionBox()
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: appURL,
            configuration: configuration
        ) { application, error in
            if let error {
                box.resolve(.failure(error))
            } else if let application {
                box.resolve(.success(application))
            } else {
                box.resolve(.failure(
                    MacOpenError.dispatchRejected(
                        "LaunchServices returned no application"
                    )
                ))
            }
            semaphore.signal()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while box.value == nil,
              ProcessInfo.processInfo.systemUptime < deadline {
            if Thread.isMainThread {
                _ = RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.05)
                )
            } else {
                _ = semaphore.wait(timeout: .now() + 0.05)
            }
        }
        guard let result = box.value else {
            throw MacOpenError.dispatchUnresolved(
                "LaunchServices completion timed out"
            )
        }
        let application: NSRunningApplication
        do {
            application = try result.get()
        } catch let error as MacOpenError {
            throw error
        } catch {
            throw MacOpenError.dispatchRejected(
                String(describing: error)
            )
        }
        guard !application.isTerminated,
              application.processIdentifier == runnerPID,
              application.bundleIdentifier == bundleIdentifier,
              PlayCoverRuntimeClient.canonicalPath(
                application.bundleURL?.path ?? ""
              ) == PlayCoverRuntimeClient.canonicalPath(appURL.path),
              PlayCoverRuntimeClient.canonicalPath(
                application.executableURL?.path ?? ""
              ) == PlayCoverRuntimeClient.canonicalPath(executablePath) else {
            throw MacOpenError.dispatchUnresolved(
                "LaunchServices returned a different process or App path"
            )
        }
        #else
        throw MacOpenError.dispatchRejected(
            "AppKit is unavailable on this host"
        )
        #endif
    }

    #if canImport(AppKit)
    private final class MacOpenCompletionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored:
            Result<NSRunningApplication, Error>?

        var value: Result<NSRunningApplication, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func resolve(_ result: Result<NSRunningApplication, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard stored == nil else { return }
            stored = result
        }
    }
    #endif

    private static func openRealDeviceURL(url: String, udid: String) throws {
        if let launcher = realDeviceURLLauncherForTesting {
            try launcher(url, udid)
            return
        }
        try CoreDeviceURLLauncher().open(url: url, udid: udid)
    }

}
