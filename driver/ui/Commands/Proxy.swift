import Foundation

/// Proxy helper for `ios-use proxy configca`.
///
/// The driver's only proxy responsibility is receiving a CA certificate via TCP
/// and triggering the profile install page so the CA can be installed on device.
/// All other proxy operations (mitmdump, Wi-Fi proxy config) are handled by
/// CLI flows using tap/input/swipe commands.
enum ProxyCommands {
    private static let queue = DispatchQueue(label: "com.iosuse.proxy-ca", qos: .userInitiated)
    private static var serverFd: Int32 = -1
    private static var serverSource: DispatchSourceRead?
    private static var caData: Data?
    private static let lock = NSLock()

    // MARK: - Command

    static func proxyCAPush(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = try decodeArgs(rawArgs, as: ProxyCAPushArgs.self)

        guard let certData = Data(base64Encoded: args.caBase64) else {
            return Codec.makeError("invalid CA base64 payload")
        }

        // Store cert and start a temporary HTTP server to serve it
        lock.lock()
        caData = certData
        lock.unlock()

        // Start profile server if not already running
        if serverFd < 0 {
            let port: UInt16 = 9088
            let fd = startListener(port: port) { connFd in handleConn(connFd) }
            guard fd >= 0 else {
                return Codec.makeError("failed to bind CA server on port \(port)")
            }
            serverFd = fd
            NSLog("[proxy] CA server listening on port %d", port)
        }

        NSLog("[proxy] CA pushed (%d bytes), server on :9088/ca.cer", certData.count)
        return Codec.makeOK(["status": "pushed", "installURL": "http://127.0.0.1:9088/ca.cer"] as [String: Any])
    }

    // MARK: - HTTP Server

    private static func startListener(port: UInt16, handler: @escaping (Int32) -> Void) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return -1 }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else {
            close(fd)
            return -1
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            return -1
        }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler {
            var ca = sockaddr_in()
            var cl = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &ca) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &cl) }
            }
            guard cfd >= 0 else { return }
            handler(cfd)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        serverSource = src
        return fd
    }

    private static func handleConn(_ fd: Int32) {
        DispatchQueue.global(qos: .userInitiated).async {
            var buf = [UInt8](repeating: 0, count: 2048)
            let n = recv(fd, &buf, buf.count, 0)
            let request = n > 0 ? String(bytes: buf[0..<n], encoding: .utf8) ?? "" : ""
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let reqPath = parts.count >= 2 ? String(parts[1]) : "/"

            lock.lock()
            let cert = caData
            lock.unlock()

            let response: Data
            if reqPath == "/ca.cer", let body = cert {
                response = httpResponse(body: body, contentType: "application/x-x509-ca-cert", filename: "mitmproxy-ca.cer")
            } else {
                let body = "Not Found".data(using: .utf8)!
                response = httpResponse(status: "404 Not Found", body: body, contentType: "text/plain", filename: nil)
            }

            response.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                var sent = 0
                while sent < response.count {
                    let s = send(fd, base.advanced(by: sent), response.count - sent, 0)
                    if s <= 0 { break }
                    sent += s
                }
            }
            close(fd)
        }
    }

    private static func httpResponse(status: String = "200 OK", body: Data, contentType: String, filename: String?) -> Data {
        var header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let filename = filename {
            header += "Content-Disposition: attachment; filename=\"\(filename)\"\r\n"
        }
        header += "\r\n"
        return header.data(using: .utf8)! + body
    }
}

// MARK: - Args

struct ProxyCAPushArgs: Codable {
    let caBase64: String
}
