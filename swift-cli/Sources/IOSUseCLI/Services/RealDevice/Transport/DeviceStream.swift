import Darwin
import Foundation

protocol DeviceStream {
    func write(_ data: Data) throws
    func readExact(byteCount: Int, timeoutSeconds: Double) throws -> Data
    func readAvailable(maxBytes: Int, timeoutSeconds: Double) throws -> Data
    func close()
}

final class PlainDeviceStream: DeviceStream {
    let fd: Int32
    private let ownsFD: Bool
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32, ownsFD: Bool = true) {
        self.fd = fd
        self.ownsFD = ownsFD
        setSocketNoSigPipe(fd)
    }

    deinit {
        close()
    }

    func write(_ data: Data) throws {
        try writeAll(fd: fd, data: data)
    }

    func readExact(byteCount: Int, timeoutSeconds: Double) throws -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while out.count < byteCount {
            let chunk = try readAvailable(maxBytes: byteCount - out.count, timeoutSeconds: max(0, deadline.timeIntervalSinceNow))
            if chunk.isEmpty { throw CLIParseError.invalidValue("device read timeout") }
            out.append(chunk)
        }
        return out
    }

    func readAvailable(maxBytes: Int, timeoutSeconds: Double) throws -> Data {
        guard waitForReadable(fd: fd, timeoutSeconds: timeoutSeconds) else { return Data() }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let n = Darwin.read(fd, &buffer, maxBytes)
        if n > 0 { return Data(buffer.prefix(n)) }
        if n == 0 { return Data() }
        if errno == EINTR || errno == EAGAIN { return Data() }
        throw CLIParseError.invalidValue("device read failed: errno \(errno)")
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let shouldClose = ownsFD
        lock.unlock()

        guard shouldClose else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

final class OpenSSLDeviceStream: DeviceStream {
    private let process: Process
    private let proxy: LocalFDProxy
    private let tempDir: URL
    private let input: FileHandle
    private let outputPipe: Pipe
    private let errorPipe: Pipe
    private let condition = NSCondition()
    private var buffer = Data()
    private var stderrBuffer = Data()
    private var closed = false

    init(fd: Int32, pairRecord: PairRecord, ownsFD: Bool = true) throws {
        Self.debug("prepare openssl client credentials")
        let createdTempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-openssl-\(UUID().uuidString)", isDirectory: true)
        let keyPath = createdTempDir.appendingPathComponent("host.key").path
        let certPath = createdTempDir.appendingPathComponent("host.crt").path
        do {
            try FileManager.default.createDirectory(at: createdTempDir, withIntermediateDirectories: true)
            try pairRecord.hostPrivateKey.write(to: URL(fileURLWithPath: keyPath), options: .atomic)
            try pairRecord.hostCertificate.write(to: URL(fileURLWithPath: certPath), options: .atomic)
        } catch {
            if ownsFD {
                Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
            }
            try? FileManager.default.removeItem(at: createdTempDir)
            throw error
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: certPath)

        self.tempDir = createdTempDir
        let createdProxy: LocalFDProxy
        do {
            createdProxy = try LocalFDProxy(targetFD: fd, closeTargetOnClose: ownsFD)
        } catch {
            if ownsFD {
                Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
            }
            try? FileManager.default.removeItem(at: createdTempDir)
            throw error
        }
        self.proxy = createdProxy
        let inputPipe = Pipe()
        self.outputPipe = Pipe()
        self.errorPipe = Pipe()
        self.input = inputPipe.fileHandleForWriting
        setNoSigPipe(input.fileDescriptor)
        self.process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "openssl", "s_client",
            "-quiet",
            "-connect", "127.0.0.1:\(proxy.port)",
            "-cert", certPath,
            "-key", keyPath,
            "-ign_eof",
        ]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendOutput(data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendStderr(data)
        }
        process.terminationHandler = { [weak self] _ in
            self?.signal()
        }
        Self.debug("start openssl s_client on local proxy port \(proxy.port)")
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            proxy.close()
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }

    deinit {
        close()
    }

    func write(_ data: Data) throws {
        condition.lock()
        let isClosed = closed
        condition.unlock()
        if isClosed { throw CLIParseError.invalidValue("TLS stream is closed") }
        do {
            try input.write(contentsOf: data)
        } catch {
            throw CLIParseError.invalidValue("TLS write failed: \(error)")
        }
    }

    func readExact(byteCount: Int, timeoutSeconds: Double) throws -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while out.count < byteCount {
            let chunk = try readAvailable(maxBytes: byteCount - out.count, timeoutSeconds: max(0, deadline.timeIntervalSinceNow))
            if chunk.isEmpty { throw CLIParseError.invalidValue("TLS read timeout") }
            out.append(chunk)
        }
        return out
    }

    func readAvailable(maxBytes: Int, timeoutSeconds: Double) throws -> Data {
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        condition.lock()
        defer { condition.unlock() }
        while buffer.isEmpty, !closed, process.isRunning, Date() < deadline {
            let nextWake = Date().addingTimeInterval(0.05)
            condition.wait(until: nextWake < deadline ? nextWake : deadline)
        }
        if !buffer.isEmpty {
            let count = min(maxBytes, buffer.count)
            let out = buffer.prefix(count)
            buffer.removeFirst(count)
            return Data(out)
        }
        if !process.isRunning, !closed {
            let detail = String(data: stderrBuffer, encoding: .utf8)?
                .split(separator: "\n")
                .suffix(3)
                .joined(separator: "\n") ?? ""
            throw CLIParseError.invalidValue("TLS process exited\(detail.isEmpty ? "" : ": \(detail)")")
        }
        return Data()
    }

    func close() {
        condition.lock()
        if closed {
            condition.unlock()
            return
        }
        closed = true
        condition.broadcast()
        condition.unlock()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? input.close()
        if process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [process] in
                if process.isRunning { process.interrupt() }
            }
        }
        proxy.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func appendOutput(_ data: Data) {
        condition.lock()
        buffer.append(data)
        condition.broadcast()
        condition.unlock()
    }

    private func appendStderr(_ data: Data) {
        condition.lock()
        stderrBuffer.append(data)
        if stderrBuffer.count > 16 * 1024 {
            stderrBuffer.removeFirst(stderrBuffer.count - 16 * 1024)
        }
        condition.broadcast()
        condition.unlock()
    }

    private func signal() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    private static func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["IOS_USE_DEBUG_OSLOG"] == "1" else { return }
        FileHandle.standardError.write(Data("[real-oslog] \(message)\n".utf8))
    }
}

final class LocalFDProxy {
    let port: Int
    private let listenerFD: Int32
    private let targetFD: Int32
    private let closeTargetOnClose: Bool
    private let lock = NSLock()
    private var clientFD: Int32 = -1
    private var closed = false

    init(targetFD: Int32, closeTargetOnClose: Bool = false) throws {
        self.targetFD = targetFD
        self.closeTargetOnClose = closeTargetOnClose
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIParseError.invalidValue("failed to create TLS proxy socket") }
        setSocketNoSigPipe(fd)
        setSocketNoSigPipe(targetFD)
        self.listenerFD = fd

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw CLIParseError.invalidValue("failed to bind TLS proxy socket: errno \(err)")
        }
        guard Darwin.listen(fd, 1) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw CLIParseError.invalidValue("failed to listen on TLS proxy socket: errno \(err)")
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw CLIParseError.invalidValue("failed to inspect TLS proxy socket: errno \(err)")
        }
        self.port = Int(UInt16(bigEndian: bound.sin_port))
        startAccepting()
    }

    deinit {
        close()
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let localClient = clientFD
        clientFD = -1
        lock.unlock()

        Darwin.close(listenerFD)
        if localClient >= 0 {
            Darwin.shutdown(localClient, SHUT_RDWR)
            Darwin.close(localClient)
        }
        if closeTargetOnClose {
            Darwin.shutdown(targetFD, SHUT_RDWR)
            Darwin.close(targetFD)
        }
    }

    private func startAccepting() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let accepted = Darwin.accept(self.listenerFD, &addr, &len)
            guard accepted >= 0 else { return }
            setSocketNoSigPipe(accepted)
            self.lock.lock()
            if self.closed {
                self.lock.unlock()
                Darwin.close(accepted)
                return
            }
            self.clientFD = accepted
            self.lock.unlock()
            Self.bridge(from: accepted, to: self.targetFD, shutdownTargetOnEOF: true)
            Self.bridge(from: self.targetFD, to: accepted, shutdownTargetOnEOF: true)
        }
    }

    private static func bridge(from source: Int32, to destination: Int32, shutdownTargetOnEOF: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = Darwin.read(source, &buffer, buffer.count)
                if n > 0 {
                    do {
                        try writeAll(fd: destination, data: Data(buffer.prefix(n)))
                    } catch {
                        break
                    }
                } else if n == 0 {
                    break
                } else if errno != EINTR {
                    break
                }
            }
            if shutdownTargetOnEOF {
                Darwin.shutdown(destination, SHUT_WR)
            }
        }
    }
}
