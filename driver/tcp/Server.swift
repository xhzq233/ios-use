import Foundation
import Fory

@objc final class DriverServer: NSObject {
    static let shared = DriverServer()

    @objc static func startSharedIfNeeded() {
        let server = DriverServer.shared
        guard !server.isRunning else { return }
        do {
            try server.start()
        } catch {
            NSLog("[driver] constructor start failed: \(error)")
        }
    }

    private let defaultPort = IOSUseProtocol.defaultDriverPort
    private let maxConnections = IOSUseProtocol.maxDriverConnections
    private var socketFD: Int32 = -1
    private var _running = false
    private var running: Bool {
        get { connectionLock.sync { _running } }
        set { connectionLock.sync { _running = newValue } }
    }
    private var activeConnections = 0
    private var activeConnectionFD: Int32?
    private var activeConnectionReceivedBytes = false
    private let connectionLock = DispatchQueue(label: "com.xcuidriver.connectionLock")
    private var acceptLoopSem: DispatchSemaphore?

    var isRunning: Bool { running }

    func start(port: UInt16? = nil) throws {
        let port = port ?? defaultPort
        NSLog("[driver] server start v3 (fory)")

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
        NSLog("[driver] listening on port \(port)")

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
                if running { NSLog("[driver] accept error: \(errno)") }
                break
            }

            let shouldAccept = reserveConnectionSlot(for: clientFD)
            if shouldAccept {
                DispatchQueue.global().async {
                    self.handleConnection(clientFD)
                }
            } else {
                NSLog("[driver] connection limit reached (\(maxConnections)), rejecting new connection")
                Darwin.close(clientFD)
            }
        }
    }

    private func reserveConnectionSlot(for clientFD: Int32) -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + Double(IOSUseProtocol.driverConnectionHandoffTimeoutMilliseconds) / IOSUseProtocol.millisecondsPerSecond
        while running {
            let retiredPendingFD = connectionLock.sync { () -> Int32? in
                if activeConnections >= maxConnections && !activeConnectionReceivedBytes {
                    let pendingFD = activeConnectionFD
                    activeConnectionFD = clientFD
                    activeConnectionReceivedBytes = false
                    activeConnections = maxConnections
                    return pendingFD
                }
                return nil
            }
            if let retiredPendingFD {
                _ = Darwin.shutdown(retiredPendingFD, SHUT_RDWR)
                return true
            }

            let didReserve = connectionLock.sync {
                if activeConnections < maxConnections {
                    activeConnections += 1
                    activeConnectionFD = clientFD
                    activeConnectionReceivedBytes = false
                    return true
                }
                return false
            }
            if didReserve {
                return true
            }
            if CFAbsoluteTimeGetCurrent() >= deadline {
                return false
            }
            usleep(useconds_t(IOSUseProtocol.driverConnectionHandoffPollMicroseconds))
        }
        return false
    }

    private func handleConnection(_ fd: Int32) {
        defer {
            Darwin.close(fd)
            connectionLock.sync {
                if activeConnectionFD == fd {
                    activeConnections -= 1
                    activeConnectionFD = nil
                    activeConnectionReceivedBytes = false
                }
            }
        }

        while self.running {
                do {
                    let foryReq = try Codec.readFrame(fd) {
                        self.connectionLock.sync {
                            if self.activeConnectionFD == fd {
                                self.activeConnectionReceivedBytes = true
                            }
                        }
                    }
                    let command = Command(rawValue: foryReq.command)
                    guard let command else {
                        let errFrame = ForyResponseFrame(ok: false, error: "unknown command: \(foryReq.command)")
                        try Codec.writeResponseFrame(fd, frame: errFrame)
                        continue
                    }

                    let foryResp: ForyResponseFrame
                    foryResp = try self.dispatchOnMainThread(foryReq.payload, command: command)

                    if !foryResp.ok && foryResp.error.hasPrefix("[FATAL]") {
                        try Codec.writeResponseFrame(fd, frame: foryResp)
                        break
                    }
                    try Codec.writeResponseFrame(fd, frame: foryResp)
                } catch FrameError.readFailed {
                    break
                } catch {
                    let errFrame = ForyResponseFrame(ok: false, error: "\(error)")
                    _ = try? Codec.writeResponseFrame(fd, frame: errFrame)
                    break
                }
        }
    }

    // MARK: - Main-thread dispatch

    private func dispatchOnMainThread(_ payload: Data, command: Command) throws -> ForyResponseFrame {
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
                NSLog("[driver] dispatch start command=\(command.rawValue)")
                let response = try self.dispatchFory(payload, command: command)
                NSLog("[driver] dispatch finish command=\(command.rawValue) ok=\(response.ok) elapsed=\(Int((CFAbsoluteTimeGetCurrent() - startedAt) * IOSUseProtocol.millisecondsPerSecond))ms")
                result = response
            } catch {
                NSLog("[driver] dispatch error command=\(command.rawValue) error=\(error)")
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
            if !commandStarted {
                return ForyResponseFrame(ok: false, error: "[FATAL] Command timed out after \(IOSUseProtocol.commandTimeoutSeconds)s (XCTest main thread may be blocked or crashed)")
            }

            let completionWaitResult = sem.wait(timeout: .now() + .seconds(IOSUseProtocol.commandCompletionTimeoutSeconds))
            if completionWaitResult == .timedOut {
                return ForyResponseFrame(ok: false, error: "[FATAL] Command started on the XCTest main thread but did not finish within 120s; driver state may be inconsistent")
            }
        }

        if let error = dispatchError {
            throw error
        }
        return result ?? ForyResponseFrame(ok: false, error: "Command dispatch failed: result is nil after wait")
    }

    // MARK: - Dispatch

    private func dispatchFory(_ payload: Data, command: Command) throws -> ForyResponseFrame {
        switch command {
        case .activateApp:
            let args = try Codec.sharedFory.deserialize(payload, as: ForyActivateAppArgs.self)
            return try AppCommands.activateApp(args)

        case .terminateApp:
            let args = try Codec.sharedFory.deserialize(payload, as: ForyTerminateAppArgs.self)
            return try AppCommands.terminateApp(args)

        case .home:
            return try AppCommands.home()

        case .proxyCAPush:
            let args = try Codec.sharedFory.deserialize(payload, as: ForyProxyCAPushArgs.self)
            return try ProxyCommands.proxyCAPush(args)

        case .screenshot:
            return try ScreenCommands.screenshot()

        case .dom:
            let args = payload.count > 0 ? try Codec.sharedFory.deserialize(payload, as: ForyDomArgs.self) : ForyDomArgs()
            return try DomCommands.dom(args)

        case .find:
            let args = try Codec.sharedFory.deserialize(payload, as: ForyFindArgs.self)
            return try FindCommands.find(args)

        case .tap:
            let args = try Codec.sharedFory.deserialize(payload, as: ForyTapArgs.self)
            return try TouchCommands.tap(args)

        case .longPress:
            let args = try Codec.sharedFory.deserialize(payload, as: ForyLongPressArgs.self)
            return try TouchCommands.longPress(args)

        case .input:
            let args = try Codec.sharedFory.deserialize(payload, as: ForyInputArgs.self)
            return try InputCommands.input(args)

        case .swipe:
            let args = payload.count > 0 ? try Codec.sharedFory.deserialize(payload, as: ForySwipeArgs.self) : ForySwipeArgs()
            return try SwipeCommands.swipe(args)

        case .waitFor:
            let args = try Codec.sharedFory.deserialize(payload, as: ForyWaitForArgs.self)
            return try WaitForCommands.waitFor(args)

        case .dismissAlert:
            let args = payload.count > 0 ? try Codec.sharedFory.deserialize(payload, as: ForyDismissAlertArgs.self) : nil
            return try AlertCommands.dismissAlert(args)
        }
    }
}
