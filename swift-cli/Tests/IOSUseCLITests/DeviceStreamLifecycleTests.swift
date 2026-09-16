import Foundation
import XCTest
import NIOCore
import NIOPosix
import NIOSSL
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import IOSUseCLI

final class DeviceStreamLifecycleTests: XCTestCase {
    private func withTLSServer(
        stalledRead: DispatchSemaphore? = nil,
        _ body: (Int, PairRecord) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = root.appendingPathComponent("key.pem")
        let cert = root.appendingPathComponent("cert.pem")
        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                             "-subj", "/CN=localhost", "-keyout", key.path, "-out", cert.path]
        openssl.standardOutput = FileHandle.nullDevice
        openssl.standardError = FileHandle.nullDevice
        try openssl.run()
        openssl.waitUntilExit()
        XCTAssertEqual(openssl.terminationStatus, 0)
        let pair = PairRecord(hostID: "test", systemBUID: "test",
                              hostPrivateKey: try Data(contentsOf: key), hostCertificate: try Data(contentsOf: cert))
        let context = try NIOSSLContext(configuration: .makeServerConfiguration(
            certificateChain: NIOSSLCertificate.fromPEMBytes(Array(pair.hostCertificate)).map { .certificate($0) },
            privateKey: .privateKey(NIOSSLPrivateKey(bytes: Array(pair.hostPrivateKey), format: .pem))
        ))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let server = try ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.socketOption(.so_rcvbuf), value: 4096)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(NIOSSLServerHandler(context: context)).flatMap {
                    channel.pipeline.addHandler(TLSEchoHandler(stalledRead: stalledRead))
                }
            }.bind(host: "127.0.0.1", port: 0).wait()
        defer { try? server.close().wait() }
        try body(try XCTUnwrap(server.localAddress?.port), pair)
    }

    func testConnectedSocketTLSAndDescriptorOwnership() throws {
        try withTLSServer { port, pair in
            for ownsFD in [false, true] {
                for iteration in 0..<12 {
                    let fd = try TCPConnector.connect(host: "127.0.0.1", port: port)
                    let stream = try NIOSSLDeviceStream(fd: fd, pairRecord: pair, ownsFD: ownsFD)
                    let payload = Data(repeating: UInt8(iteration), count: 128 * 1024)
                    try stream.write(payload)
                    XCTAssertEqual(try stream.readExact(byteCount: payload.count, timeoutSeconds: 5), payload)
                    stream.close()
                    stream.close()
                    if !ownsFD {
                        XCTAssertGreaterThanOrEqual(fcntl(fd, F_GETFD), 0)
                        _ = posixClose(fd)
                    }
                }
            }
        }
    }

    func testCloseCompletesBlockedTLSWriteBeforeNextConnection() throws {
        let received = DispatchSemaphore(value: 0)
        try withTLSServer(stalledRead: received) { port, pair in
            let fd = try TCPConnector.connect(host: "127.0.0.1", port: port)
            var sendBuffer: Int32 = 4096
            XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size)), 0)
            let stream = try NIOSSLDeviceStream(fd: fd, pairRecord: pair)
            let writer = DispatchGroup()
            writer.enter()
            DispatchQueue.global().async {
                defer { writer.leave() }
                do {
                    try stream.write(Data(repeating: 1, count: 8 * 1024 * 1024))
                    XCTFail("The deliberately stalled peer unexpectedly consumed the entire write")
                } catch { /* Closing the stream must release its blocked writer. */ }
            }
            XCTAssertEqual(received.wait(timeout: .now() + 5), .success)
            stream.close()
            XCTAssertEqual(writer.wait(timeout: .now() + 5), .success)
        }
        // A new TLS stream must still complete a handshake and exchange bytes.
        try withTLSServer { port, pair in
            let fd = try TCPConnector.connect(host: "127.0.0.1", port: port)
            let stream = try NIOSSLDeviceStream(fd: fd, pairRecord: pair)
            defer { stream.close() }
            try stream.write(Data([1, 2, 3]))
            XCTAssertEqual(try stream.readExact(byteCount: 3, timeoutSeconds: 5), Data([1, 2, 3]))
        }
    }

    func testInvalidIdentityPreservesBorrowedSocketAndClosesOwnedSocket() throws {
        let invalid = PairRecord(hostID: "test", systemBUID: "test", hostPrivateKey: Data(), hostCertificate: Data())
        for ownsFD in [false, true] {
            var sockets: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, posixStreamSocketType, 0, &sockets), 0)
            defer { _ = posixClose(sockets[1]) }
            XCTAssertThrowsError(try NIOSSLDeviceStream(fd: sockets[0], pairRecord: invalid, ownsFD: ownsFD))
            if ownsFD {
                XCTAssertEqual(fcntl(sockets[0], F_GETFD), -1)
                XCTAssertEqual(errno, EBADF)
            } else {
                let borrowed = PlainDeviceStream(fd: sockets[0])
                defer { borrowed.close() }
                try borrowed.write(Data([7]))
                XCTAssertEqual(try PlainDeviceStream(fd: sockets[1], ownsFD: false)
                    .readExact(byteCount: 1, timeoutSeconds: 2), Data([7]))
            }
        }
    }
}

private final class TLSEchoHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let stalledRead: DispatchSemaphore?
    init(stalledRead: DispatchSemaphore?) { self.stalledRead = stalledRead }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if let stalledRead {
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenSuccess {
                stalledRead.signal()
            }
        } else {
            context.writeAndFlush(wrapOutboundOut(unwrapInboundIn(data)), promise: nil)
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
