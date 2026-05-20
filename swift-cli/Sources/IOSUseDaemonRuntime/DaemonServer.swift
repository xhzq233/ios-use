import Darwin
import Foundation

public struct DaemonOutputHandles: Sendable {
    private let stdout: Int32?
    private let stderr: Int32?

    public init(stdout: Int32?, stderr: Int32?) {
        self.stdout = stdout
        self.stderr = stderr
    }

    public func writeStdout(_ text: String) {
        write(text, to: stdout)
    }

    public func writeStderr(_ text: String) {
        write(text, to: stderr)
    }

    public func close() {
        if let stdout { Darwin.close(stdout) }
        if let stderr, stderr != stdout { Darwin.close(stderr) }
    }

    private func write(_ text: String, to fd: Int32?) {
        guard let fd, !text.isEmpty else { return }
        let bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { pointer in
                Darwin.write(fd, pointer.baseAddress!.advanced(by: written), bytes.count - written)
            }
            if count > 0 {
                written += count
            } else if errno != EINTR {
                return
            }
        }
    }
}

public final class DaemonCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledValue = false
    private var signalValue: String?
    private var handlers: [@Sendable () -> Void] = []

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledValue
    }

    public var signal: String? {
        lock.lock()
        defer { lock.unlock() }
        return signalValue
    }

    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelledValue {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
    }

    public func cancel(signal: String) {
        lock.lock()
        if cancelledValue {
            lock.unlock()
            return
        }
        cancelledValue = true
        signalValue = signal
        let callbacks = handlers
        handlers.removeAll(keepingCapacity: false)
        lock.unlock()
        for callback in callbacks {
            callback()
        }
    }

    public func cancelledExit(id: String) -> DaemonExit {
        DaemonExit(id: id, exitCode: 130)
    }
}

private final class DaemonRequestRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: DaemonCancellationToken] = [:]

    func register(id: String) -> DaemonCancellationToken {
        let token = DaemonCancellationToken()
        lock.lock()
        tokens[id] = token
        lock.unlock()
        return token
    }

    func cancel(id: String, signal: String) -> Bool {
        lock.lock()
        let token = tokens[id]
        lock.unlock()
        token?.cancel(signal: signal)
        return token != nil
    }

    func unregister(id: String) {
        lock.lock()
        tokens.removeValue(forKey: id)
        lock.unlock()
    }
}

public final class DaemonServer: @unchecked Sendable {
    public struct Response: Sendable {
        public let exit: DaemonExit
        public let shouldStopDaemon: Bool

        public init(exit: DaemonExit, shouldStopDaemon: Bool = false) {
            self.exit = exit
            self.shouldStopDaemon = shouldStopDaemon
        }
    }

    public typealias Responder = @Sendable (DaemonRequest, DaemonOutputHandles, DaemonCancellationToken) -> Response

    private let paths: IOSUsePaths
    private let responder: Responder
    private let registry = DaemonRequestRegistry()
    private let acceptQueue = DispatchQueue(label: "ios-use.daemon.accept")
    private let handlerQueue = DispatchQueue(label: "ios-use.daemon.handler", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var running = false

    public init(paths: IOSUsePaths, responder: @escaping Responder) {
        self.paths = paths
        self.responder = responder
    }

    public func start() throws {
        guard listenFD < 0 else { return }
        signal(SIGPIPE, SIG_IGN)
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: paths.daemonSocket).deletingLastPathComponent().path,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: paths.daemonLog).deletingLastPathComponent().path,
            withIntermediateDirectories: true
        )
        let startupLockFD = try acquireStartupLock()
        defer { releaseStartupLock(startupLockFD) }
        if FileManager.default.fileExists(atPath: paths.daemonSocket) {
            if daemonSocketCanConnect(path: paths.daemonSocket) {
                throw DaemonSocketError.socketFailure("daemon already running for \(paths.root)")
            }
            try? FileManager.default.removeItem(atPath: paths.daemonSocket)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonSocketError.socketFailure(daemonErrnoMessage("socket")) }

        do {
            try bindAndListen(fd)
            listenFD = fd
            running = true
            try writePidFile()
            acceptQueue.async { [weak self] in self?.acceptLoop() }
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    public func wait() {
        while running {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    public func stop() {
        running = false
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
        try? FileManager.default.removeItem(atPath: paths.daemonSocket)
        try? FileManager.default.removeItem(atPath: paths.daemonPid)
    }

    private func bindAndListen(_ fd: Int32) throws {
        var address = try daemonUnixAddress(path: paths.daemonSocket)
        let length = socklen_t(MemoryLayout<sa_family_t>.size + paths.daemonSocket.utf8.count + 1)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, length)
            }
        }
        guard bindResult == 0 else { throw DaemonSocketError.socketFailure(daemonErrnoMessage("bind")) }
        chmod(paths.daemonSocket, S_IRUSR | S_IWUSR)
        guard listen(fd, SOMAXCONN) == 0 else { throw DaemonSocketError.socketFailure(daemonErrnoMessage("listen")) }
    }

    private func acquireStartupLock() throws -> Int32 {
        let lockPath = "\(paths.daemonPid).lock"
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw DaemonSocketError.socketFailure(daemonErrnoMessage("open \(lockPath)")) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR {
                let message = daemonErrnoMessage("flock \(lockPath)")
                Darwin.close(fd)
                throw DaemonSocketError.socketFailure(message)
            }
        }
        return fd
    }

    private func releaseStartupLock(_ fd: Int32) {
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD >= 0 {
                let registry = self.registry
                let server = self
                handlerQueue.async { [responder, registry, server] in
                    Self.handle(clientFD: clientFD, responder: responder, registry: registry) {
                        server.stop()
                    }
                }
            } else if errno != EINTR {
                break
            }
        }
    }

    private static func handle(
        clientFD: Int32,
        responder: Responder,
        registry: DaemonRequestRegistry?,
        stopServer: @escaping @Sendable () -> Void
    ) {
        defer { Darwin.close(clientFD) }
        do {
            let received = try readMessage(clientFD: clientFD)
            let output = DaemonOutputHandles(
                stdout: received.fileDescriptors.first,
                stderr: received.fileDescriptors.dropFirst().first
            )
            defer { output.close() }
            let message = try DaemonControlProtocol.decode(received.frame)
            let response: DaemonControlMessage
            var shouldStopDaemon = false
            switch message {
            case .request(let request):
                let token = registry?.register(id: request.id) ?? DaemonCancellationToken()
                defer { registry?.unregister(id: request.id) }
                let daemonResponse = token.isCancelled
                    ? Response(exit: token.cancelledExit(id: request.id))
                    : responder(request, output, token)
                response = .exit(daemonResponse.exit)
                shouldStopDaemon = daemonResponse.shouldStopDaemon
            case .interrupt(let interrupt):
                _ = registry?.cancel(id: interrupt.id, signal: interrupt.signal)
                response = .exit(DaemonExit(id: interrupt.id, exitCode: 130))
            case .exit(let exit):
                response = .exit(exit)
            }
            try write(response, clientFD: clientFD)
            if shouldStopDaemon {
                DispatchQueue.global().async {
                    stopServer()
                }
            }
        } catch {
            if case DaemonSocketError.connectionClosedBeforeExit = error {
                return
            }
            let response = DaemonControlMessage.exit(DaemonExit(id: "decode-error", exitCode: 64))
            try? write(response, clientFD: clientFD)
        }
    }

    private static func readMessage(clientFD: Int32) throws -> (frame: Data, fileDescriptors: [Int32]) {
        var data = Data()
        var descriptors: [Int32] = []
        var needsFirstRead = true

        while !data.contains(0x0a) {
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            var control = [UInt8](repeating: 0, count: daemonCmsgSpace(2))
            let byteCapacity = bytes.count
            let readCount: Int = try bytes.withUnsafeMutableBytes { bytesPointer in
                var iov = iovec(iov_base: bytesPointer.baseAddress, iov_len: byteCapacity)
                return try withUnsafeMutablePointer(to: &iov) { iovPointer in
                    try control.withUnsafeMutableBytes { controlPointer in
                        var header = msghdr()
                        header.msg_iov = iovPointer
                        header.msg_iovlen = 1
                        header.msg_control = needsFirstRead ? controlPointer.baseAddress : nil
                        header.msg_controllen = needsFirstRead ? socklen_t(controlPointer.count) : 0
                        let count = recvmsg(clientFD, &header, 0)
                        guard count >= 0 else { throw DaemonSocketError.socketFailure(daemonErrnoMessage("recvmsg")) }
                        if needsFirstRead {
                            descriptors.append(contentsOf: fileDescriptors(from: &header))
                            needsFirstRead = false
                        }
                        return count
                    }
                }
            }
            guard readCount > 0 else { throw DaemonSocketError.connectionClosedBeforeExit }
            data.append(contentsOf: bytes.prefix(readCount))
        }

        guard let newline = data.firstIndex(of: 0x0a) else {
            throw DaemonSocketError.connectionClosedBeforeExit
        }
        return (Data(data[...newline]), descriptors)
    }

    private static func fileDescriptors(from header: inout msghdr) -> [Int32] {
        guard let first = daemonFirstCmsg(&header),
              first.pointee.cmsg_level == SOL_SOCKET,
              first.pointee.cmsg_type == SCM_RIGHTS else {
            return []
        }
        let payloadLength = Int(first.pointee.cmsg_len) - daemonCmsgAlign(MemoryLayout<cmsghdr>.size)
        guard payloadLength > 0 else { return [] }
        let count = payloadLength / MemoryLayout<Int32>.stride
        let pointer = daemonCmsgData(first).assumingMemoryBound(to: Int32.self)
        return (0..<count).map { pointer[$0] }
    }

    private static func write(_ message: DaemonControlMessage, clientFD: Int32) throws {
        let data = try DaemonControlProtocol.encode(message)
        try data.withUnsafeBytes { pointer in
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let count = Darwin.write(clientFD, pointer.baseAddress!.advanced(by: offset), remaining)
                if count > 0 {
                    remaining -= count
                    offset += count
                } else if errno != EINTR {
                    throw DaemonSocketError.socketFailure(daemonErrnoMessage("write"))
                }
            }
        }
    }

    private func writePidFile() throws {
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: paths.daemonPid).deletingLastPathComponent().path,
            withIntermediateDirectories: true
        )
        let body = [
            "pid": "\(getpid())",
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "socket": paths.daemonSocket
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: paths.daemonPid), options: [.atomic])
    }
}
