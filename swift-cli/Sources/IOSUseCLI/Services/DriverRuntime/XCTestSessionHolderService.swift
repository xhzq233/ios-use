import Darwin
import Foundation
import IOSUseProtocol

enum XCTestSessionHolderService {
    static let commandName = "__xctest-session-holder"
    static var driverReadinessConnectorForTesting: ((String, Int) throws -> Int32)?
    static var driverReadinessSleeperForTesting: ((useconds_t) -> Void)?
    static var driverReadinessTimeoutSecondsForTesting: Double?

    private struct Options {
        let udid: String
        let bundleId: String
        let controlSocket: String
    }

    static func run(arguments: [String], paths: IOSUsePaths) throws -> String {
        let options = try parse(arguments)
        try FileManager.default.createDirectory(atPath: paths.logs, withIntermediateDirectories: true)
        let log: (String) -> Void = { message in
            CLILogService.appendHolder(paths: paths, ["[xctest-holder] \(message)"])
        }

        var activeSession: RealDeviceXCTestActiveSession?
        let controlState = XCTestSessionHolderControlState(
            holderPid: Int(Darwin.getpid()),
            bundleId: options.bundleId,
            controlSocketPath: options.controlSocket
        )
        let controlServer = XCTestSessionHolderControlServer(
            socketPath: options.controlSocket,
            state: controlState,
            eventSink: log
        )
        try controlServer.start()
        defer { controlServer.stop() }

        do {
            log("starting holder udid=\(options.udid) bundleId=\(options.bundleId)")
            let lifecycle = RealDeviceXCTestDriverLifecycle(eventSink: log)
            let startedSession = try lifecycle.startDriverSession(
                udid: options.udid,
                bundleID: options.bundleId
            )
            activeSession = startedSession
            try waitForDriverReadiness(udid: options.udid, log: log)
            controlState.markReady(
                runnerPid: startedSession.runnerPid,
                sessionIdentifier: startedSession.sessionIdentifier.uuidString
            )
            log("holder start result runnerPid=\(startedSession.runnerPid) session=\(startedSession.sessionIdentifier.uuidString)")

            let interruptMonitor = InterruptMonitor(onInterrupt: {
                log("holder interrupted")
            })
            interruptMonitor.start()
            while !interruptMonitor.interrupted && !controlState.shouldStop {
                let startupFailure = startedSession.startupFailure
                let postConfigurationFailure = startupFailure == nil ? startedSession.takePostConfigurationFailure() : nil
                if let stopMessage = holderStopMessage(
                    startupFailure: startupFailure,
                    postConfigurationFailure: postConfigurationFailure
                ) {
                    log(stopMessage)
                    break
                }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
            }
            interruptMonitor.stop()
            startedSession.close(killRunner: true)
            clearDriverLockIfCurrent(
                paths: paths,
                options: options,
                runnerPid: startedSession.runnerPid,
                sessionIdentifier: startedSession.sessionIdentifier.uuidString
            )
            activeSession = nil
            controlState.markStopped()
            log("holder stopped")
            return ""
        } catch {
            controlState.markFailed(error)
            activeSession?.close(killRunner: true)
            if let activeSession {
                clearDriverLockIfCurrent(
                    paths: paths,
                    options: options,
                    runnerPid: activeSession.runnerPid,
                    sessionIdentifier: activeSession.sessionIdentifier.uuidString
                )
            }
            log("holder failed: \(error)")
            throw error
        }
    }

    static func holderStopMessage(startupFailure: Error?, postConfigurationFailure: Error?) -> String? {
        if let startupFailure {
            return "holder startup session failed after start result: \(startupFailure)"
        }
        if let postConfigurationFailure {
            return "XCTest session ended after configuration; stopping holder: \(postConfigurationFailure)"
        }
        return nil
    }

    static func waitForDriverReadiness(udid: String, log: (String) -> Void) throws {
        let connector = driverReadinessConnectorForTesting ?? { try Usbmux.connect(udid: $0, port: $1) }
        let sleeper = driverReadinessSleeperForTesting ?? { _ = Darwin.usleep($0) }
        let timeout = driverReadinessTimeoutSecondsForTesting ?? IOSUseProtocol.realDeviceDriverReadinessTimeoutSeconds
        let initialDelay = useconds_t(IOSUseProtocol.realDeviceDriverReadinessInitialDelayMicroseconds)
        let pollDelay = useconds_t(IOSUseProtocol.realDeviceDriverReadinessPollMicroseconds)
        let postSuccessDelay = useconds_t(IOSUseProtocol.realDeviceDriverReadinessPostSuccessDelayMicroseconds)
        let startedAt = CFAbsoluteTimeGetCurrent()
        let deadline = Date().addingTimeInterval(max(0, timeout))
        var attempts = 0
        var lastError: Error?

        log("waiting for driver TCP readiness port=\(IOSUseProtocol.defaultDriverPort) initialDelayMs=\(initialDelay / 1_000) pollMs=\(pollDelay / 1_000) timeoutSeconds=\(timeout)")
        sleeper(initialDelay)

        while true {
            attempts += 1
            do {
                let fd = try connector(udid, Int(IOSUseProtocol.defaultDriverPort))
                _ = Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * IOSUseProtocol.millisecondsPerSecond)
                log("driver TCP readiness confirmed attempts=\(attempts) elapsed=\(elapsedMs)ms")
                sleeper(postSuccessDelay)
                return
            } catch {
                lastError = error
                if Date() >= deadline {
                    break
                }
                sleeper(pollDelay)
            }
        }

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * IOSUseProtocol.millisecondsPerSecond)
        let detail = lastError.map { " lastError=\($0)" } ?? ""
        throw CLIParseError.invalidValue("Driver TCP readiness timed out after \(elapsedMs)ms attempts=\(attempts)\(detail)")
    }

    private static func parse(_ arguments: [String]) throws -> Options {
        var udid: String?
        var bundleId: String?
        var controlSocket: String?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--udid":
                index += 1
                guard index < arguments.count else { throw CLIParseError.missingOptionValue("--udid") }
                udid = arguments[index]
            case "--bundle-id":
                index += 1
                guard index < arguments.count else { throw CLIParseError.missingOptionValue("--bundle-id") }
                bundleId = arguments[index]
            case "--control-socket":
                index += 1
                guard index < arguments.count else { throw CLIParseError.missingOptionValue("--control-socket") }
                controlSocket = arguments[index]
            case "--verbose":
                break
            default:
                if argument.hasPrefix("-") {
                    throw CLIParseError.unknownOption(argument)
                }
                throw CLIParseError.unexpectedArgument(argument)
            }
            index += 1
        }

        guard let udid, !udid.isEmpty else { throw CLIParseError.missingRequiredOption("--udid") }
        guard let bundleId, !bundleId.isEmpty else { throw CLIParseError.missingRequiredOption("--bundle-id") }
        guard let controlSocket, !controlSocket.isEmpty else { throw CLIParseError.missingRequiredOption("--control-socket") }
        return Options(udid: udid, bundleId: bundleId, controlSocket: controlSocket)
    }

    private static func clearDriverLockIfCurrent(
        paths: IOSUsePaths,
        options: Options,
        runnerPid: Int,
        sessionIdentifier: String
    ) {
        guard let info = try? DriverSessionStore.readInfo(paths: paths),
              driverLockMatchesCurrentHolder(
                info: info,
                udid: options.udid,
                bundleId: options.bundleId,
                holderPid: Int(Darwin.getpid()),
                runnerPid: runnerPid,
                sessionIdentifier: sessionIdentifier,
                controlSocketPath: options.controlSocket
              ) else {
            return
        }
        try? DriverSessionStore.removeDriverLock(paths: paths)
    }

    static func driverLockMatchesCurrentHolder(
        info: SessionService.Info,
        udid: String,
        bundleId: String,
        holderPid: Int,
        runnerPid: Int,
        sessionIdentifier: String,
        controlSocketPath: String
    ) -> Bool {
        info.deviceType == "real"
            && info.udid == udid
            && info.bundleId == bundleId
            && info.holderPid == holderPid
            && info.runnerPid == runnerPid
            && info.sessionIdentifier == sessionIdentifier
            && info.controlSocketPath == controlSocketPath
    }
}
