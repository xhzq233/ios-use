import Darwin
import Foundation
import PlayCoverUpstream

/// Runs outside the sandboxed App so SIGKILL and crashes also release the
/// session. A kernel process event binds the observation to this process,
/// rather than a PID that might later be reused.
enum PlayCoverSessionMonitor {
    static let commandName = "__mac-session-monitor"
    static var startOverrideForTesting:
        ((SessionService.Info, IOSUsePaths) throws -> Void)?

    static func start(session: SessionService.Info, paths: IOSUsePaths) throws {
        if let startOverrideForTesting {
            return try startOverrideForTesting(session, paths)
        }
        guard let pid = session.runnerPid.flatMap(Int32.init(exactly:)),
              let sessionID = session.sessionIdentifier,
              let executable = Bundle.main.executableURL else {
            throw PlayCoverBackendError.launchFailed("missing Mac monitor identity")
        }
        let birth = PlayCoverService.processStartTimeMicroseconds(for: pid)
        guard birth != nil || PlayCoverSessionService.processState(pid) == .missing else {
            throw PlayCoverBackendError.launchFailed("cannot identify Mac process birth")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [commandName, sessionID, String(pid),
                             String(birth ?? 0), paths.deviceID ?? ""]
        var environment = ProcessInfo.processInfo.environment
        environment["IOS_USE_HOME"] = paths.root
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let ready = Pipe()
        process.standardOutput = ready
        let log = try CLILogService.openAppendHandle(path: CLILogService.logPath(paths: paths))
        defer { try? log.close() }
        process.standardError = log
        try process.run()
        try ready.fileHandleForWriting.close()
        defer { try? ready.fileHandleForReading.close() }
        var descriptor = pollfd(fd: ready.fileHandleForReading.fileDescriptor,
                                events: Int16(POLLIN), revents: 0)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            let result = poll(&descriptor, 1, 100)
            if result < 0 && errno == EINTR { continue }
            if result > 0 {
                let data = try ready.fileHandleForReading.read(upToCount: 6)
                if data == Data("ready\n".utf8) { return }
                break
            }
            if result < 0 { break }
        }
        if process.isRunning { process.terminate() }
        throw PlayCoverBackendError.launchFailed(
            "Mac exit monitor did not become ready; see \(CLILogService.logPath(paths: paths))"
        )
    }

    static func run(arguments: [String], paths basePaths: IOSUsePaths) throws {
        guard arguments.count == 4,
              UUID(uuidString: arguments[0]) != nil,
              let pid = Int32(arguments[1]), pid > 0,
              let birth = UInt64(arguments[2]) else {
            throw CLIParseError.invalidValue("invalid Mac monitor identity")
        }
        let paths = arguments[3].isEmpty
            ? basePaths : try basePaths.deviceContext(arguments[3])
        guard let session = try DriverSessionStore.readInfo(paths: paths),
              session.deviceType == "mac",
              session.sessionIdentifier == arguments[0],
              session.runnerPid == Int(pid) else {
            throw CLIParseError.invalidValue("Mac monitor session changed")
        }
        try observeExit(pid: pid, birth: birth, executablePath: session.macExecutablePath) {
            try FileHandle.standardOutput.write(contentsOf: Data("ready\n".utf8))
            try FileHandle.standardOutput.close()
        }
        try SessionOperationLock.withExclusiveLock(paths: paths) {
            try cleanupExitedSession(session, paths: paths)
        }
    }

    /// Registers before rechecking birth and path to cover exit during startup
    /// without accidentally waiting for a later owner of the same PID.
    static func observeExit(
        pid: Int32,
        birth: UInt64,
        executablePath: String?,
        ready: () throws -> Void
    ) throws {
        let queue = kqueue()
        guard queue >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(queue) }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC),
                            flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        let registered = kevent(queue, &change, 1, nil, 0, nil)
        if registered < 0 && errno != ESRCH {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let state = PlayCoverSessionService.processState(pid)
        let sameProcess: Bool
        switch state {
        case .missing:
            sameProcess = false
        case .running(let actual):
            sameProcess = birth > 0
                && PlayCoverService.processStartTimeMicroseconds(for: pid) == birth
                && executablePath.map { PlayCoverRuntimeClient.canonicalPath($0)
                    == PlayCoverRuntimeClient.canonicalPath(actual) } == true
        case .unverifiable(let error):
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        try ready()
        guard registered == 0, sameProcess else { return }
        var event = kevent()
        while kevent(queue, nil, 0, &event, 1, nil) < 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Caller holds SessionOperationLock. Only this exact session may be
    /// removed; a delayed exit notification must leave its successor alone.
    static func cleanupExitedSession(
        _ expected: SessionService.Info,
        paths: IOSUsePaths
    ) throws {
        guard expected.deviceType == "mac",
              let current = try DriverSessionStore.readInfo(paths: paths),
              current.deviceType == "mac",
              current.sessionIdentifier == expected.sessionIdentifier,
              current.runnerPid == expected.runnerPid,
              current.bundleId == expected.bundleId,
              current.macInstallRevision == expected.macInstallRevision,
              current.macExecutablePath == expected.macExecutablePath else { return }
        let slot = try PlayCoverSessionService.validateSlot(session: current, paths: paths)
        let acquisition = try PlayCoverBundleStartLock.acquireForRecovery(
            bundleIdentifier: slot.metadata.bundleIdentifier, paths: paths
        )
        defer { _ = acquisition.lock }
        // Another Home may already have restarted this Bundle. Its PlayChain
        // must stay unlocked while the old Home drops its own session record.
        if acquisition.runningPIDs.isEmpty {
            try PlayCoverHeadlessKeyCover.lock(
                bundleIdentifier: slot.metadata.bundleIdentifier,
                playChainDirectory: URL(fileURLWithPath: paths.playcoverPlayChain)
            )
        }
        if let sessionID = current.sessionIdentifier,
           let record = try PlayCoverLaunchingStore.load(paths: paths),
           record.sessionID == sessionID {
            try PlayCoverLaunchingStore.remove(sessionID: sessionID, paths: paths)
        }
        if let socket = current.macRuntimeSocketPath {
            var status = stat()
            if lstat(socket, &status) == 0,
               status.st_mode & S_IFMT == S_IFSOCK,
               status.st_uid == geteuid() {
                if unlink(socket) != 0 && errno != ENOENT {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        try DriverSessionStore.removeDriverLock(paths: paths)
    }
}
