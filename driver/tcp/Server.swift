import Foundation

final class DriverServer {
    static let shared = DriverServer()

    private let defaultPort: UInt16 = 8100
    private let maxConnections = 8
    private var socketFD: Int32 = -1
    private var _running = false
    private var running: Bool {
        get { connectionLock.sync { _running } }
        set { connectionLock.sync { _running = newValue } }
    }
    private var activeConnections = 0
    private let connectionLock = DispatchQueue(label: "com.xcuidriver.connectionLock")
    private var acceptLoopSem: DispatchSemaphore?

    var isRunning: Bool { running }

    func start(port: UInt16? = nil) throws {
        let port = port ?? defaultPort
        NSLog("[driver] server start v2")

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
        guard bindResult >= 0 else { throw DriverError.serverError("bind failed: \(errno)") }

        guard Darwin.listen(socketFD, 5) >= 0 else { throw DriverError.serverError("listen failed: \(errno)") }

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
            running = false
            let fd = socketFD
            socketFD = -1
            return fd
        }
        if fd >= 0 {
            Darwin.close(fd)
        }
        _ = acceptLoopSem?.wait(timeout: .now() + .seconds(5))
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
            }
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                if running { NSLog("[driver] accept error: \(errno)") }
                break
            }

            let shouldAccept = connectionLock.sync {
                if activeConnections < maxConnections {
                    activeConnections += 1
                    return true
                }
                return false
            }

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

    private func handleConnection(_ fd: Int32) {
        defer {
            Darwin.close(fd)
            connectionLock.sync { activeConnections -= 1 }
        }

        do {
            while self.running {
                do {
                    let req = try Codec.readFrame(fd)

                    // doc 6.2 — screenshot uses a two-frame protocol:
                    //   1) JSON {ok:true, data:{size:N}}
                    //   2) raw JPEG bytes
                    // Handled specially since ResponseFrame cannot carry the
                    // binary payload.
                    if req.c == .screenshot {
                        try handleScreenshot(fd: fd)
                        continue
                    }

                    // All other commands: dispatch (on main thread for UI
                    // XCTest calls) and write a single JSON frame.
                    let prepared = try dispatchOnMainThread(req)
                    if !prepared.response.ok, let err = prepared.response.error, err.contains("timed out") {
                        _ = try? Codec.writeFrameData(fd, data: prepared.encoded)
                        break
                    }
                    try Codec.writeFrameData(fd, data: prepared.encoded)
                } catch FrameError.readFailed {
                    break
                } catch {
                    let resp = Codec.makeError("\(error)")
                    _ = try? Codec.writeResponse(fd, resp: resp)
                    break
                }
            }
        } catch {
            NSLog("[driver] handleConnection fatal error: \(error)")
        }
    }

    // MARK: - Screenshot (doc 6.2)

    /// Run screenshot on main thread, then write JSON header frame + raw JPEG
    /// frame. The header contains `{size: N}` so the client can read exactly N
    /// bytes from the next frame.
    private func handleScreenshot(fd: Int32) throws {
        let sem = DispatchSemaphore(value: 0)
        var result: ScreenshotResult?
        var captureError: Error?

        DispatchQueue.main.async {
            do {
                result = try ScreenCommands.screenshot()
            } catch {
                captureError = error
            }
            sem.signal()
        }
        let waitResult = sem.wait(timeout: .now() + .seconds(60))
        if waitResult == .timedOut {
            let err = Codec.makeError("screenshot timed out after 60s")
            try Codec.writeResponse(fd, resp: err)
            return
        }
        if let e = captureError {
            let err = Codec.makeError("screenshot failed: \(e)")
            try Codec.writeResponse(fd, resp: err)
            return
        }
        guard let result else {
            let err = Codec.makeError("screenshot returned no data")
            try Codec.writeResponse(fd, resp: err)
            return
        }

        // Frame 1: JSON header.
        let header = Codec.makeOK(["size": result.size])
        try Codec.writeResponse(fd, resp: header)
        // Frame 2: raw JPEG payload.
        try Codec.writeBinaryFrame(fd, data: result.jpegData)
    }

    // MARK: - Main-thread dispatch

    private struct PreparedResponse {
        let response: ResponseFrame
        let encoded: Data
    }

    private func dispatchOnMainThread(_ req: RequestFrame) throws -> PreparedResponse {
        // oslog does not touch XCTest UI APIs and is safe on any thread.
        if req.c == .oslog {
            let response = try self.dispatch(req)
            let encoded = try Codec.encodeResponse(response)
            return PreparedResponse(response: response, encoded: encoded)
        }

        let sem = DispatchSemaphore(value: 0)
        var result: PreparedResponse?
        var dispatchError: Error?
        let cancelLock = NSLock()
        var cancelled = false

        DispatchQueue.main.async {
            cancelLock.lock()
            let shouldSkip = cancelled
            cancelLock.unlock()
            if shouldSkip {
                sem.signal()
                return
            }
            do {
                let response = try self.dispatch(req)
                let encoded = try Codec.encodeResponse(response)
                result = PreparedResponse(response: response, encoded: encoded)
            } catch {
                dispatchError = error
            }
            sem.signal()
        }
        let waitResult = sem.wait(timeout: .now() + .seconds(60))
        if waitResult == .timedOut {
            cancelLock.lock()
            cancelled = true
            cancelLock.unlock()
            let timeoutResponse = Codec.makeError("Command timed out after 60s (XCTest main thread may be blocked or crashed)")
            let encoded = try Codec.encodeResponse(timeoutResponse)
            return PreparedResponse(response: timeoutResponse, encoded: encoded)
        }

        if let error = dispatchError {
            throw error
        }
        guard let result else {
            let fallback = Codec.makeError("Command dispatch failed: result is nil after wait (this should not happen)")
            let encoded = try Codec.encodeResponse(fallback)
            return PreparedResponse(response: fallback, encoded: encoded)
        }
        return result
    }

    // MARK: - Dispatch

    private func dispatch(_ req: RequestFrame) throws -> ResponseFrame {
        switch req.c {
        case .createSession: return try AppCommands.createSession(req.args)
        case .deleteSession: return try AppCommands.deleteSession(req.args)
        case .activateApp:   return try AppCommands.activateApp(req.args)
        case .terminateApp:  return try AppCommands.terminateApp(req.args)
        case .screenshot:
            // Handled by handleConnection's two-frame path; dispatch should
            // never see it.
            return Codec.makeError("screenshot must use binary protocol path")
        case .oslog:         return try OslogCommands.oslog(req.args)
        case .dom:           return try DomCommands.dom(req.args)
        case .find:          return try FindCommands.find(req.args)
        case .tap:           return try TouchCommands.tap(req.args)
        case .longPress:     return try TouchCommands.longPress(req.args)
        case .input:         return try InputCommands.input(req.args)
        case .swipe:         return try SwipeCommands.swipe(req.args)
        case .waitFor:       return try WaitForCommands.waitFor(req.args)
        }
    }
}
