#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation
import CoreFoundation
import IOSUseProtocol
import NIOCore
import NIOPosix
import NIOSSL

protocol DeviceStream {
    func write(_ data: Data) throws
    func readExact(byteCount: Int, timeoutSeconds: Double) throws -> Data
    func readAvailable(maxBytes: Int, timeoutSeconds: Double) throws -> Data
    func close()
}

enum DeviceStreamError: Error, CustomStringConvertible, Equatable {
    case timeout(String)
    case closed(String)
    case readFailed(String, errno: Int32)
    case writeFailed(String, errno: Int32)
    case writeFailedWithError(String)

    var description: String {
        switch self {
        case .timeout(let context):
            return "\(context) timeout"
        case .closed(let context):
            return "\(context) closed"
        case .readFailed(let context, let errno):
            return "\(context) read failed: errno \(errno)"
        case .writeFailed(let context, let errno):
            return "\(context) write failed: errno \(errno)"
        case .writeFailedWithError(let detail):
            return "stream write failed: \(detail)"
        }
    }

    var isTimeout: Bool {
        if case .timeout = self { return true }
        return false
    }
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
            if chunk.isEmpty { throw DeviceStreamError.timeout("device read") }
            out.append(chunk)
        }
        return out
    }

    func readAvailable(maxBytes: Int, timeoutSeconds: Double) throws -> Data {
        guard waitForReadable(fd: fd, timeoutSeconds: timeoutSeconds) else { return Data() }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let n = posixRead(fd, &buffer, maxBytes)
        if n > 0 { return Data(buffer.prefix(n)) }
        if n == 0 { throw DeviceStreamError.closed("device stream") }
        if errno == EINTR || errno == EAGAIN { return Data() }
        throw DeviceStreamError.readFailed("device", errno: errno)
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
        posixShutdown(fd, Int32(SHUT_RDWR))
        posixClose(fd)
    }
}

final class NIOSSLDeviceStream: DeviceStream {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let inbound: NIOSSLDeviceStreamInbound
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32, pairRecord: PairRecord, ownsFD: Bool = true) throws {
        // NIO owns its socket through close completion. For a borrowed Lockdown
        // descriptor, duplicate it so the caller retains its original ownership.
        let socketFD = ownsFD ? fd : dup(fd)
        guard socketFD >= 0 else {
            throw DeviceStreamError.readFailed("duplicate TLS socket", errno: errno)
        }
        var handedToNIO = false
        defer {
            if !handedToNIO { _ = posixClose(socketFD) }
        }

        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .none
        configuration.certificateChain = try NIOSSLCertificate.fromPEMBytes(
            Array(pairRecord.hostCertificate)
        ).map { .certificate($0) }
        configuration.privateKey = .privateKey(try NIOSSLPrivateKey(
            bytes: Array(pairRecord.hostPrivateKey), format: .pem
        ))
        let sslContext = try NIOSSLContext(configuration: configuration)
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let inboundHandler = NIOSSLDeviceStreamInbound()
        self.inbound = inboundHandler

        do {
            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer { channel in
                    do {
                        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: nil)
                        return channel.pipeline.addHandler(sslHandler).flatMap {
                            channel.pipeline.addHandler(inboundHandler)
                        }
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
            handedToNIO = true
            self.channel = try bootstrap.withConnectedSocket(socketFD).wait()
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    deinit {
        close()
    }

    func write(_ data: Data) throws {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        if isClosed { throw CLIParseError.invalidValue("TLS stream is closed") }

        var offset = 0
        while offset < data.count {
            let end = min(offset + IOSUseProtocol.XCConstants.deviceStreamWriteChunkBytes, data.count)
            var buffer = channel.allocator.buffer(capacity: end - offset)
            buffer.writeBytes(data[offset..<end])
            do {
                try channel.writeAndFlush(buffer).wait()
            } catch {
                throw DeviceStreamError.writeFailedWithError("TLS \(error)")
            }
            offset = end
        }
    }

    func readExact(byteCount: Int, timeoutSeconds: Double) throws -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while out.count < byteCount {
            let chunk = try readAvailable(maxBytes: byteCount - out.count, timeoutSeconds: max(0, deadline.timeIntervalSinceNow))
            if chunk.isEmpty { throw DeviceStreamError.timeout("TLS read") }
            out.append(chunk)
        }
        return out
    }

    func readAvailable(maxBytes: Int, timeoutSeconds: Double) throws -> Data {
        try inbound.readAvailable(maxBytes: maxBytes, timeoutSeconds: timeoutSeconds)
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }
}

private final class NIOSSLDeviceStreamInbound: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let condition = NSCondition()
    private var buffer = Data()
    private var closed = false
    private var error: Error?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var byteBuffer = unwrapInboundIn(data)
        guard let incoming = byteBuffer.readBytes(length: byteBuffer.readableBytes), !incoming.isEmpty else {
            return
        }
        condition.lock()
        buffer.append(contentsOf: incoming)
        condition.broadcast()
        condition.unlock()
    }

    func channelInactive(context: ChannelHandlerContext) {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        condition.lock()
        self.error = error
        closed = true
        condition.broadcast()
        condition.unlock()
        context.close(promise: nil)
    }

    func readAvailable(maxBytes: Int, timeoutSeconds: Double) throws -> Data {
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        condition.lock()
        defer { condition.unlock() }

        while buffer.isEmpty, error == nil, !closed, Date() < deadline {
            condition.wait(until: deadline)
        }
        if !buffer.isEmpty {
            let count = min(maxBytes, buffer.count)
            let out = buffer.prefix(count)
            buffer.removeFirst(count)
            return Data(out)
        }
        if let error {
            throw CLIParseError.invalidValue("TLS stream failed: \(error)")
        }
        if closed {
            throw DeviceStreamError.closed("TLS stream")
        }
        return Data()
    }
}
