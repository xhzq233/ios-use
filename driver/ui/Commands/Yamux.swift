import Foundation

// MARK: - Yamux Protocol (HashiCorp-compatible, client side only)

/// Minimal yamux client for byte-transparent multiplexing over a single TCP connection.
/// Device acts as yamux CLIENT: opens streams to forward proxy traffic to Mac.
enum Yamux {
    static let protocolVersion: UInt8 = 0

    enum FrameType: UInt8 {
        case data = 0
        case windowUpdate = 1
        case ping = 2
        case goAway = 3
    }

    enum Flag: UInt16 {
        case syn = 0x1
        case ack = 0x2
        case fin = 0x4
        case rst = 0x8
    }

    // HashiCorp yamux frame header:
    // version(1) + type(1) + flags(2) + streamID(4) + length(4) = 12 bytes
    static let headerSize = 12
    static let initialStreamWindow: UInt32 = 256 * 1024
}

// MARK: - Yamux Frame

struct YamuxFrame {
    let type: Yamux.FrameType
    let flags: UInt16
    let streamID: UInt32
    let data: Data

    func encode() -> Data {
        var buf = Data(count: Yamux.headerSize)
        buf[0] = Yamux.protocolVersion
        buf[1] = type.rawValue
        buf[2] = UInt8(flags >> 8)
        buf[3] = UInt8(flags & 0xFF)
        buf[4] = UInt8(streamID >> 24)
        buf[5] = UInt8((streamID >> 16) & 0xFF)
        buf[6] = UInt8((streamID >> 8) & 0xFF)
        buf[7] = UInt8(streamID & 0xFF)
        let len = UInt32(data.count)
        buf[8] = UInt8(len >> 24)
        buf[9] = UInt8((len >> 16) & 0xFF)
        buf[10] = UInt8((len >> 8) & 0xFF)
        buf[11] = UInt8(len & 0xFF)
        buf.append(data)
        return buf
    }

    static func decode(from socket: Int32) -> YamuxFrame? {
        var header = [UInt8](repeating: 0, count: Yamux.headerSize)
        guard readFully(socket, into: &header, count: Yamux.headerSize) else { return nil }

        guard let type = Yamux.FrameType(rawValue: header[1]) else { return nil }
        let flags = UInt16(header[2]) << 8 | UInt16(header[3])
        let streamID = UInt32(header[4]) << 24 | UInt32(header[5]) << 16
            | UInt32(header[6]) << 8 | UInt32(header[7])
        let length = UInt32(header[8]) << 24 | UInt32(header[9]) << 16
            | UInt32(header[10]) << 8 | UInt32(header[11])

        guard length <= 1024 * 1024 else { return nil } // 1MB sanity cap

        var payload = Data()
        if length > 0 {
            payload = Data(count: Int(length))
            var mutablePayload = payload
            guard mutablePayload.withUnsafeMutableBytes({ ptr -> Bool in
                guard let base = ptr.baseAddress else { return false }
                return readFully(socket, into: base.assumingMemoryBound(to: UInt8.self), count: Int(length))
            }) else { return nil }
            payload = mutablePayload
        }

        return YamuxFrame(type: type, flags: flags, streamID: streamID, data: payload)
    }

    private static func readFully(_ socket: Int32, into buf: UnsafeMutablePointer<UInt8>, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = recv(socket, buf.advanced(by: offset), count - offset, 0)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}

// MARK: - Yamux Client Session

/// Yamux client that manages multiple streams over a single socket.
/// Thread-safe: streams can be opened from any thread.
final class YamuxClient {
    private let fd: Int32
    private let writeLock = NSLock()
    private var streams: [UInt32: YamuxStream] = [:]
    private let streamLock = NSLock()
    private var nextStreamID: UInt32 = 1 // odd = client-initiated
    private var closed = false

    init(socket: Int32) {
        self.fd = socket
    }

    /// Open a new yamux stream. Returns stream ID.
    func openStream() -> UInt32 {
        streamLock.lock()
        let id = nextStreamID
        nextStreamID += 2
        let stream = YamuxStream(id: id, session: self)
        streams[id] = stream
        streamLock.unlock()

        // Send SYN
        sendFrame(YamuxFrame(type: .data, flags: Yamux.Flag.syn.rawValue, streamID: id, data: Data()))
        return id
    }

    /// Get stream by ID.
    func getStream(_ id: UInt32) -> YamuxStream? {
        streamLock.lock()
        defer { streamLock.unlock() }
        return streams[id]
    }

    /// Remove stream.
    func removeStream(_ id: UInt32) {
        streamLock.lock()
        streams.removeValue(forKey: id)
        streamLock.unlock()
    }

    /// Send data frame on a stream.
    func sendData(_ data: Data, streamID: UInt32) {
        sendFrame(YamuxFrame(type: .data, flags: 0, streamID: streamID, data: data))
    }

    /// Send FIN on a stream.
    func sendFin(streamID: UInt32) {
        sendFrame(YamuxFrame(type: .data, flags: Yamux.Flag.fin.rawValue, streamID: streamID, data: Data()))
    }

    /// Send RST on a stream.
    func sendRst(streamID: UInt32) {
        sendFrame(YamuxFrame(type: .data, flags: Yamux.Flag.rst.rawValue, streamID: streamID, data: Data()))
    }

    /// Send a raw frame (thread-safe).
    func sendFrame(_ frame: YamuxFrame) {
        let encoded = frame.encode()
        writeLock.lock()
        encoded.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var sent = 0
            while sent < encoded.count {
                let n = send(fd, base.advanced(by: sent), encoded.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
        writeLock.unlock()
    }

    /// Read loop: demux incoming frames to streams. Blocks until connection closes.
    func readLoop() {
        while !closed {
            guard let frame = YamuxFrame.decode(from: fd) else {
                close()
                return
            }
            switch frame.type {
            case .data:
                handleDataFrame(frame)
            case .windowUpdate:
                break // MVP: ignore flow control
            case .ping:
                // Reply with ACK only if this is a request (not an ACK reply)
                if frame.flags & Yamux.Flag.ack.rawValue == 0 {
                    sendFrame(YamuxFrame(type: .ping, flags: Yamux.Flag.ack.rawValue, streamID: 0, data: frame.data))
                }
            case .goAway:
                close()
                return
            }
        }
    }

    private func handleDataFrame(_ frame: YamuxFrame) {
        let id = frame.streamID
        let flags = frame.flags

        if flags & Yamux.Flag.syn.rawValue != 0 {
            // Server opened a stream (shouldn't happen for client, but handle gracefully)
            streamLock.lock()
            if streams[id] == nil {
                streams[id] = YamuxStream(id: id, session: self)
            }
            streamLock.unlock()
        }

        if flags & Yamux.Flag.rst.rawValue != 0 {
            if let stream = getStream(id) {
                stream.close()
            }
            removeStream(id)
            return
        }

        if let stream = getStream(id) {
            if !frame.data.isEmpty {
                stream.receiveData(frame.data)
            }
            if flags & Yamux.Flag.fin.rawValue != 0 {
                stream.remoteClosed()
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        sendFrame(YamuxFrame(type: .goAway, flags: 0, streamID: 0, data: Data()))
        streamLock.lock()
        let allStreams = streams
        streams.removeAll()
        streamLock.unlock()
        for (_, stream) in allStreams {
            stream.close()
        }
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    var isClosed: Bool { closed }
}

// MARK: - Yamux Stream

/// A single yamux stream. Provides async read/write via callbacks.
final class YamuxStream {
    let id: UInt32
    private weak var session: YamuxClient?
    private let readLock = NSLock()
    private var readBuffer = Data()
    private var readSem = DispatchSemaphore(value: 0)
    private var _remoteClosed = false
    private var _closed = false

    init(id: UInt32, session: YamuxClient) {
        self.id = id
        self.session = session
    }

    /// Called by session when data arrives on this stream.
    func receiveData(_ data: Data) {
        readLock.lock()
        readBuffer.append(data)
        readLock.unlock()
        readSem.signal()
    }

    /// Called by session when remote sends FIN.
    func remoteClosed() {
        readLock.lock()
        _remoteClosed = true
        readLock.unlock()
        readSem.signal()
    }

    /// Read data from this stream (blocks until data available or closed).
    func read(timeout: TimeInterval = 30) -> Data? {
        let result = readSem.wait(timeout: .now() + timeout)
        if result == .timedOut { return nil }

        readLock.lock()
        defer { readLock.unlock() }

        if readBuffer.isEmpty {
            return _remoteClosed ? nil : Data()
        }
        let data = readBuffer
        readBuffer = Data()
        return data
    }

    /// Write data to this stream.
    func write(_ data: Data) {
        guard !isClosed else { return }
        session?.sendData(data, streamID: id)
    }

    /// Close this stream (send FIN).
    func close() {
        guard !_closed else { return }
        _closed = true
        session?.sendFin(streamID: id)
    }

    /// Reset this stream (send RST).
    func reset() {
        guard !_closed else { return }
        _closed = true
        session?.sendRst(streamID: id)
    }

    var isClosed: Bool { _closed }
    var isRemoteClosed: Bool {
        readLock.lock()
        defer { readLock.unlock() }
        return _remoteClosed
    }
}

// MARK: - Stream Relay

/// Relay bytes between a POSIX file descriptor and a yamux stream.
func relayFdToStream(_ fd: Int32, stream: YamuxStream, queue: DispatchQueue) {
    queue.async {
        var buf = [UInt8](repeating: 0, count: 16384)
        while !stream.isClosed {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            stream.write(Data(bytes: buf, count: n))
        }
        stream.close()
    }
}

func relayStreamToFd(_ stream: YamuxStream, fd: Int32, queue: DispatchQueue) {
    queue.async {
        while !stream.isClosed {
            guard let data = stream.read(timeout: 60) else { break }
            if data.isEmpty && stream.isRemoteClosed { break }
            var sent = 0
            let bytes = [UInt8](data)
            while sent < bytes.count {
                let n = bytes.withUnsafeBufferPointer { ptr in
                    send(fd, ptr.baseAddress! + sent, bytes.count - sent, 0)
                }
                if n <= 0 { return }
                sent += n
            }
        }
        Darwin.shutdown(fd, SHUT_WR)
    }
}
