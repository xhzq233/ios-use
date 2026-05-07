import Foundation

/// Minimal HTTP proxy for forwarding traffic over usbmux to Mac mitmdump.
/// Listens on device, accepts HTTP proxy requests, and tunnels them upstream.
enum ProxyCommands {
    private static var listenSource: DispatchSourceRead?
    private static var listenFd: Int32 = -1
    private static var isRunning = false
    private static let proxyQueue = DispatchQueue(label: "com.iosuse.proxy", qos: .userInitiated)

    static func proxyStart(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        guard !isRunning else {
            return Codec.makeError("proxy already running")
        }

        let args = try decodeArgs(rawArgs, as: ProxyStartArgs.self)
        let port = UInt16(args.port ?? 9090)

        NSLog("[proxy] starting on 0.0.0.0:%d", port)

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return Codec.makeError("socket() failed") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else {
            close(fd)
            return Codec.makeError("bind() failed: \(String(cString: strerror(errno)))")
        }

        guard listen(fd, 128) == 0 else {
            close(fd)
            return Codec.makeError("listen() failed")
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: proxyQueue)
        source.setEventHandler {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &clientLen) }
            }
            guard clientFd >= 0 else { return }
            handleClient(clientFd)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()

        listenFd = fd
        listenSource = source
        isRunning = true

        NSLog("[proxy] listening on 0.0.0.0:%d", port)
        return Codec.makeOK(["port": Int(port), "status": "running"])
    }

    static func proxyStop(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        guard isRunning else {
            return Codec.makeOK(["status": "not_running"])
        }

        listenSource?.cancel()
        listenSource = nil
        listenFd = -1
        isRunning = false
        NSLog("[proxy] stopped")
        return Codec.makeOK(["status": "stopped"])
    }

    private static func handleClient(_ clientFd: Int32) {
        // Handle each client on a separate queue to avoid blocking
        DispatchQueue.global(qos: .userInitiated).async {
            handleClientSync(clientFd)
        }
    }

    private static func handleClientSync(_ clientFd: Int32) {
        defer { close(clientFd) }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = recv(clientFd, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return }

        let request = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""

        if firstLine.hasPrefix("CONNECT ") {
            // HTTPS CONNECT tunnel
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else { return }
            let hostPort = String(parts[1])
            let host: String
            let port: UInt16
            if let colonIdx = hostPort.lastIndex(of: ":") {
                host = String(hostPort[hostPort.startIndex..<colonIdx])
                port = UInt16(hostPort[hostPort.index(after: colonIdx)...]) ?? 443
            } else {
                host = hostPort
                port = 443
            }

            NSLog("[proxy] CONNECT %@:%d", host, port)

            guard let upstreamFd = connectUpstream(host: host, port: port) else {
                NSLog("[proxy] CONNECT failed to connect upstream %@:%d", host, port)
                let resp = "HTTP/1.1 502 Bad Gateway\r\n\r\n"
                _ = resp.withCString { send(clientFd, $0, strlen($0), 0) }
                return
            }
            defer { close(upstreamFd) }

            let okResp = "HTTP/1.1 200 Connection Established\r\n\r\n"
            _ = okResp.withCString { send(clientFd, $0, strlen($0), 0) }

            relay(clientFd, upstreamFd)
        } else {
            // Plain HTTP request — forward as-is
            let components = firstLine.split(separator: " ")
            guard components.count >= 2 else { return }
            let urlStr = String(components[1])

            NSLog("[proxy] HTTP %@ %@", String(components[0]), urlStr)

            guard let url = URL(string: urlStr),
                  let host = url.host else {
                let resp = "HTTP/1.1 400 Bad Request\r\n\r\n"
                _ = resp.withCString { send(clientFd, $0, strlen($0), 0) }
                return
            }
            let port = UInt16(url.port ?? (url.scheme == "https" ? 443 : 80))

            guard let upstreamFd = connectUpstream(host: host, port: port) else {
                NSLog("[proxy] HTTP failed to connect upstream %@:%d", host, port)
                let resp = "HTTP/1.1 502 Bad Gateway\r\n\r\n"
                _ = resp.withCString { send(clientFd, $0, strlen($0), 0) }
                return
            }
            defer { close(upstreamFd) }

            // Forward original request
            buffer.withUnsafeBufferPointer { ptr in
                _ = send(upstreamFd, ptr.baseAddress!, bytesRead, 0)
            }

            relay(upstreamFd, clientFd)
        }
    }

    /// Connect to upstream. Direct TCP for now; will be replaced with usbmux bridge.
    private static func connectUpstream(host: String, port: UInt16) -> Int32? {
        let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard sock >= 0 else { return nil }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        guard getaddrinfo(host, portStr, &hints, &result) == 0, let info = result else {
            close(sock)
            return nil
        }
        defer { freeaddrinfo(info) }

        if connect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen) < 0 {
            close(sock)
            return nil
        }

        return sock
    }

    private static func relay(_ fd1: Int32, _ fd2: Int32) {
        let sem = DispatchSemaphore(value: 0)
        var buf = [UInt8](repeating: 0, count: 16384)

        DispatchQueue.global().async {
            forward(from: fd1, to: fd2, buf: &buf)
            sem.signal()
        }
        DispatchQueue.global().async {
            forward(from: fd2, to: fd1, buf: &buf)
            sem.signal()
        }
        sem.wait()
    }

    private static func forward(from src: Int32, to dst: Int32, buf: inout [UInt8]) {
        while true {
            let n = recv(src, &buf, buf.count, 0)
            if n <= 0 { break }
            var sent = 0
            while sent < n {
                let s = buf.withUnsafeBufferPointer { ptr in
                    send(dst, ptr.baseAddress! + sent, n - sent, 0)
                }
                if s <= 0 { return }
                sent += s
            }
        }
    }
}

struct ProxyStartArgs: Codable {
    let port: Int?
}
