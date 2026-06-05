import Darwin
import Foundation
import IOSUseProtocol

struct XCTestSessionHolderReadiness: Codable, Equatable {
    let status: String
    let holderPid: Int?
    let runnerPid: Int?
    let sessionIdentifier: String?
    let error: String?
}

enum XCTestSessionHolderService {
    static let commandName = "__xctest-session-holder"

    private struct Options {
        let udid: String
        let bundleId: String
        let readyFile: String
    }

    static func run(arguments: [String], paths: IOSUsePaths) throws -> String {
        let options = try parse(arguments)
        try FileManager.default.createDirectory(atPath: paths.logs, withIntermediateDirectories: true)
        let log: (String) -> Void = { message in
            CLILogService.appendHolder(paths: paths, ["[xctest-holder] \(message)"])
        }

        var activeSession: RealDeviceXCTestActiveSession?
        do {
            log("starting holder udid=\(options.udid) bundleId=\(options.bundleId)")
            let lifecycle = RealDeviceXCTestDriverLifecycle(eventSink: log)
            let startedSession = try lifecycle.startDriverSession(
                udid: options.udid,
                bundleID: options.bundleId,
                timeoutSeconds: IOSUseProtocol.driverStartReadinessTimeoutSeconds
            )
            activeSession = startedSession
            try writeReadiness(
                XCTestSessionHolderReadiness(
                    status: "ready",
                    holderPid: Int(Darwin.getpid()),
                    runnerPid: startedSession.runnerPid,
                    sessionIdentifier: startedSession.sessionIdentifier.uuidString,
                    error: nil
                ),
                path: options.readyFile
            )
            log("holder ready runnerPid=\(startedSession.runnerPid) session=\(startedSession.sessionIdentifier.uuidString)")

            let interruptMonitor = InterruptMonitor(onInterrupt: {
                log("holder interrupted")
            })
            interruptMonitor.start()
            while !interruptMonitor.interrupted {
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
            activeSession = nil
            log("holder stopped")
            return ""
        } catch {
            activeSession?.close(killRunner: true)
            try? writeReadiness(
                XCTestSessionHolderReadiness(
                    status: "error",
                    holderPid: Int(Darwin.getpid()),
                    runnerPid: nil,
                    sessionIdentifier: nil,
                    error: String(describing: error)
                ),
                path: options.readyFile
            )
            log("holder failed: \(error)")
            throw error
        }
    }

    static func holderStopMessage(startupFailure: Error?, postConfigurationFailure: Error?) -> String? {
        if let startupFailure {
            return "holder startup session failed after readiness: \(startupFailure)"
        }
        if let postConfigurationFailure {
            return "XCTest session ended after configuration; stopping holder: \(postConfigurationFailure)"
        }
        return nil
    }

    private static func parse(_ arguments: [String]) throws -> Options {
        var udid: String?
        var bundleId: String?
        var readyFile: String?
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
            case "--ready-file":
                index += 1
                guard index < arguments.count else { throw CLIParseError.missingOptionValue("--ready-file") }
                readyFile = arguments[index]
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
        guard let readyFile, !readyFile.isEmpty else { throw CLIParseError.missingRequiredOption("--ready-file") }
        return Options(udid: udid, bundleId: bundleId, readyFile: readyFile)
    }

    private static func writeReadiness(_ readiness: XCTestSessionHolderReadiness, path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder().encode(readiness)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
