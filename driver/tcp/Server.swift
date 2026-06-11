import Foundation

@objc final class DriverServer: NSObject {
    static let shared = DriverServer()
    #if DEBUG
    private static let testingHookLock = NSLock()
    private static var _dispatchForyForTesting: ((Command) throws -> ForyResponseFrame)?
    static var dispatchForyForTesting: ((Command) throws -> ForyResponseFrame)? {
        get {
            testingHookLock.lock()
            defer { testingHookLock.unlock() }
            return _dispatchForyForTesting
        }
        set {
            testingHookLock.lock()
            _dispatchForyForTesting = newValue
            testingHookLock.unlock()
        }
    }
    #endif

    @objc static func startSharedIfNeeded() {
        let server = DriverServer.shared
        guard !server.isRunning else { return }
        do {
            try server.start()
        } catch {
            DriverLog.error("[driver] constructor start failed: \(error)")
        }
    }

    private let defaultPort = IOSUseProtocol.defaultDriverPort
    private var socketFD: Int32 = -1
    private var _running = false
    private var running: Bool {
        get { connectionLock.sync { _running } }
        set { connectionLock.sync { _running = newValue } }
    }
    private var nextConnectionID = 1
    private let connectionLock = DispatchQueue(label: "com.xcuidriver.connectionLock")
    private var acceptLoopSem: DispatchSemaphore?

    var isRunning: Bool { running }

    func start(port: UInt16? = nil) throws {
        let port = port ?? defaultPort
        DriverLog.info("[driver] server start v3 (fory)")

        guard !running else {
            throw DriverError.serverError("server already running")
        }

        socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw DriverError.serverError("socket create failed: \(errno)") }

        var yes: Int32 = 1
        Darwin.setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, UInt32(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, UInt32(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult >= 0 else {
            let err = errno
            Darwin.close(socketFD)
            socketFD = -1
            throw DriverError.serverError("bind failed: \(err)")
        }

        guard Darwin.listen(socketFD, IOSUseProtocol.listenBacklog) >= 0 else {
            let err = errno
            Darwin.close(socketFD)
            socketFD = -1
            throw DriverError.serverError("listen failed: \(err)")
        }

        running = true
        DriverLog.info("[driver] listening on port \(port)")

        acceptLoopSem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [weak self] in
            self?.acceptLoop()
            self?.acceptLoopSem?.signal()
        }
    }

    func stop() {
        let fd = connectionLock.sync {
            _running = false
            let fd = socketFD
            socketFD = -1
            return fd
        }
        if fd >= 0 {
            Darwin.close(fd)
        }
        _ = acceptLoopSem?.wait(timeout: .now() + .seconds(IOSUseProtocol.serverStopTimeoutSeconds))
        acceptLoopSem = nil
    }

    private func acceptLoop() {
        while running {
            let fd = connectionLock.sync { socketFD }
            guard fd >= 0 else { break }
            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD >= 0 {
                var yes: Int32 = 1
                Darwin.setsockopt(clientFD, SOL_SOCKET, SO_KEEPALIVE, &yes, UInt32(MemoryLayout<Int32>.size))
                Darwin.setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &yes, UInt32(MemoryLayout<Int32>.size))
            }
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                if running { DriverLog.error("[driver] accept error: \(errno)") }
                break
            }

            let connectionID = allocateConnectionID()
            DriverLog.info("[driver-connection] id=\(connectionID) event=accept fd=\(clientFD)")
            DispatchQueue.global().async {
                self.handleConnection(clientFD, connectionID: connectionID)
            }
        }
    }

    private func allocateConnectionID() -> Int {
        connectionLock.sync {
            let id = nextConnectionID
            nextConnectionID += 1
            return id
        }
    }

    private func handleConnection(_ fd: Int32, connectionID: Int) {
        let codec = Codec.Context()
        defer {
            DriverLog.info("[driver-connection] id=\(connectionID) event=close fd=\(fd)")
            Darwin.close(fd)
        }

        while self.running {
            do {
                let foryReq = try codec.readFrame(fd)
                let command = Command(rawValue: foryReq.command)
                guard let command else {
                    let errFrame = ForyResponseFrame(ok: false, error: "unknown command: \(foryReq.command)")
                    try codec.writeResponseFrame(fd, frame: errFrame)
                    DriverLog.info("[driver-connection] id=\(connectionID) command=\(foryReq.command) ok=false")
                    continue
                }

                let invocation = try CommandInvocation(name: command, payload: foryReq.payload, codec: codec)
                let foryResp = try self.dispatchOnMainThread(invocation)

                if !foryResp.ok && foryResp.error.hasPrefix("[FATAL]") {
                    try codec.writeResponseFrame(fd, frame: foryResp)
                    DriverLog.info("[driver-connection] id=\(connectionID) command=\(foryReq.command) ok=false fatal=true")
                    break
                }
                try codec.writeResponseFrame(fd, frame: foryResp)
                DriverLog.info("[driver-connection] id=\(connectionID) command=\(foryReq.command) ok=\(foryResp.ok)")
            } catch FrameError.readFailed {
                DriverLog.info("[driver-connection] id=\(connectionID) event=eof fd=\(fd)")
                break
            } catch {
                let errFrame = ForyResponseFrame(ok: false, error: "\(error)")
                _ = try? codec.writeResponseFrame(fd, frame: errFrame)
                DriverLog.error("[driver-connection] id=\(connectionID) event=error fd=\(fd) error=\(error)")
                break
            }
        }
    }

    // MARK: - Main-thread dispatch

    private func dispatchOnMainThread(_ invocation: CommandInvocation) throws -> ForyResponseFrame {
        let sem = DispatchSemaphore(value: 0)
        var result: ForyResponseFrame?
        var dispatchError: Error?
        let cancelLock = NSLock()
        var cancelled = false
        var started = false

        DispatchQueue.main.async {
            cancelLock.lock()
            let shouldSkip = cancelled
            if !shouldSkip {
                started = true
            }
            cancelLock.unlock()
            if shouldSkip {
                sem.signal()
                return
            }
            do {
                let startedAt = CFAbsoluteTimeGetCurrent()
                let startMessage = "[driver] dispatch start command=\(invocation.name.rawValue)"
                DriverLog.info(startMessage)
                let response = try self.execute(invocation)
                let finishMessage = "[driver] dispatch finish command=\(invocation.name.rawValue) ok=\(response.ok) elapsed=\(DriverPerf.elapsedMilliseconds(since: startedAt))ms"
                DriverLog.info(finishMessage)
                result = response
            } catch {
                let errorMessage = "[driver] dispatch error command=\(invocation.name.rawValue) error=\(error)"
                DriverLog.error(errorMessage)
                dispatchError = error
            }
            sem.signal()
        }
        let waitResult = sem.wait(timeout: .now() + .seconds(IOSUseProtocol.commandTimeoutSeconds))
        if waitResult == .timedOut {
            cancelLock.lock()
            let commandStarted = started
            if !commandStarted {
                cancelled = true
            }
            cancelLock.unlock()
            let detail = commandStarted ? "after starting on the XCTest main thread" : "before starting on the XCTest main thread"
            return ForyResponseFrame(ok: false, error: "[FATAL] Command timed out after \(IOSUseProtocol.commandTimeoutSeconds)s \(detail)")
        }

        if let error = dispatchError {
            throw error
        }
        return result ?? ForyResponseFrame(ok: false, error: "Command dispatch failed: result is nil after wait")
    }

    // MARK: - Dispatch

    private func execute(_ invocation: CommandInvocation) throws -> ForyResponseFrame {
        #if DEBUG
        if let dispatchForyForTesting = Self.dispatchForyForTesting {
            return try dispatchForyForTesting(invocation.name)
        }
        #endif

        switch invocation.arguments {
        case .activateApp(let args):
            return try AppCommands.activateApp(args)

        case .terminateApp(let args):
            return try AppCommands.terminateApp(args)

        case .home:
            return try AppCommands.home()

        case .proxyCAPush(let args):
            return try ProxyCommands.proxyCAPush(args)

        case .screenshot:
            return try ScreenCommands.screenshot()

        case .dom(let args):
            return try DomCommands.dom(args)

        case .tap(let args):
            return try TouchCommands.tap(args)

        case .longPress(let args):
            return try TouchCommands.longPress(args)

        case .input(let args):
            return try InputCommands.input(args)

        case .swipe(let args):
            return try SwipeCommands.swipe(args)

        case .waitFor(let args):
            return try WaitForCommands.waitFor(args)

        case .dismissAlert(let args):
            return try AlertCommands.dismissAlert(args)
        }
    }
}

private struct CommandInvocation {
    let name: Command
    let arguments: Arguments

    init(name: Command, payload: Data, codec: Codec.Context) throws {
        self.name = name
        switch name {
        case .activateApp:
            self.arguments = .activateApp(try codec.deserialize(payload, as: ForyActivateAppArgs.self))

        case .terminateApp:
            self.arguments = .terminateApp(try codec.deserialize(payload, as: ForyTerminateAppArgs.self))

        case .home:
            self.arguments = .home

        case .proxyCAPush:
            self.arguments = .proxyCAPush(try codec.deserialize(payload, as: ForyProxyCAPushArgs.self))

        case .screenshot:
            self.arguments = .screenshot

        case .dom:
            self.arguments = .dom(payload.count > 0 ? try codec.deserialize(payload, as: ForyDomArgs.self) : ForyDomArgs())

        case .tap:
            self.arguments = .tap(try codec.deserialize(payload, as: ForyTapArgs.self))

        case .longPress:
            self.arguments = .longPress(try codec.deserialize(payload, as: ForyLongPressArgs.self))

        case .input:
            self.arguments = .input(try codec.deserialize(payload, as: ForyInputArgs.self))

        case .swipe:
            self.arguments = .swipe(payload.count > 0 ? try codec.deserialize(payload, as: ForySwipeArgs.self) : ForySwipeArgs())

        case .waitFor:
            self.arguments = .waitFor(try codec.deserialize(payload, as: ForyWaitForArgs.self))

        case .dismissAlert:
            self.arguments = .dismissAlert(payload.count > 0 ? try codec.deserialize(payload, as: ForyDismissAlertArgs.self) : nil)
        }
    }

    enum Arguments {
        case activateApp(ForyActivateAppArgs)
        case terminateApp(ForyTerminateAppArgs)
        case home
        case proxyCAPush(ForyProxyCAPushArgs)
        case screenshot
        case dom(ForyDomArgs)
        case tap(ForyTapArgs)
        case longPress(ForyLongPressArgs)
        case input(ForyInputArgs)
        case swipe(ForySwipeArgs)
        case waitFor(ForyWaitForArgs)
        case dismissAlert(ForyDismissAlertArgs?)
    }
}
