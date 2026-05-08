import Foundation

/// Profile helper for `ios-use proxy`.
///
/// The data plane is Wi-Fi -> Mac LAN IP -> mitmdump. The driver only serves
/// profile files to Safari over device loopback during the proxy session.
enum ProxyCommands {
    private static let queue = DispatchQueue(label: "com.iosuse.profile-server", qos: .userInitiated)
    private static var profileFd: Int32 = -1
    private static var profileSource: DispatchSourceRead?
    private static var isRunning = false

    private static var profileHtml: Data?
    private static var proxyMobileconfig: Data?
    private static var cleanupMobileconfig: Data?
    private static var caMobileconfig: Data?
    private static var caCertificate: Data?
    private static let profileLock = NSLock()

    // MARK: - Commands

    static func proxyIngressStart(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        guard !isRunning else {
            return Codec.makeOK([
                "proxyPort": 0,
                "controlPort": 0,
                "profilePort": 9088,
                "status": "running",
            ] as [String: Any])
        }

        let args = decodeArgsOptional(rawArgs, as: ProxyIngressStartArgs.self)
        let profilePort = UInt16(args?.profilePort ?? 9088)

        NSLog("[profile] starting profile server port=%d", profilePort)
        let rfd = startListener(port: profilePort) { fd in handleProfileConn(fd) }
        guard rfd >= 0 else { return Codec.makeError("bind profile port \(profilePort) failed") }

        profileFd = rfd
        isRunning = true

        NSLog("[profile] listening profile=%d", profilePort)
        return Codec.makeOK([
            "proxyPort": 0,
            "controlPort": 0,
            "profilePort": Int(profilePort),
            "status": "running",
        ] as [String: Any])
    }

    static func proxyIngressStop(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        guard isRunning else { return Codec.makeOK(["status": "not_running"]) }

        profileSource?.cancel()
        profileSource = nil
        if profileFd >= 0 {
            close(profileFd)
            profileFd = -1
        }

        profileLock.lock()
        profileHtml = nil
        proxyMobileconfig = nil
        cleanupMobileconfig = nil
        caMobileconfig = nil
        caCertificate = nil
        profileLock.unlock()

        isRunning = false
        NSLog("[profile] stopped")
        return Codec.makeOK(["status": "stopped"])
    }

    static func proxyPushProfile(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        let args = try decodeArgs(rawArgs, as: ProxyPushProfileArgs.self)

        guard let caData = Data(base64Encoded: args.caBase64),
              let proxyData = Data(base64Encoded: args.mobileconfigBase64) else {
            return Codec.makeError("invalid profile payload base64")
        }
        let caProfileData = args.caProfileBase64.flatMap { Data(base64Encoded: $0) }
        let cleanupData = args.cleanupMobileconfigBase64.flatMap { Data(base64Encoded: $0) }

        let html = """
        <!DOCTYPE html>
        <html>
        <head><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>ios-use Proxy Setup</title>
        <style>
        body { font-family: -apple-system, sans-serif; padding: 20px; max-width: 420px; margin: auto; }
        h1 { font-size: 22px; }
        .step { margin: 16px 0; padding: 12px; background: #f5f5f5; border-radius: 8px; }
        a.btn { display: block; text-align: center; padding: 14px; background: #007AFF; color: white;
                text-decoration: none; border-radius: 8px; margin: 12px 0; font-size: 16px; }
        a.secondary { background: #5856D6; }
        a.cleanup { background: #FF3B30; }
        .note { font-size: 13px; color: #666; margin-top: 8px; }
        </style>
        </head>
        <body>
        <h1>ios-use Proxy Setup</h1>
        <div class="step">
        <strong>Step 1:</strong> Install the Wi-Fi proxy profile
        <span class="note">This points the current Wi-Fi HTTP proxy to mitmdump on your Mac.</span>
        </div>
        <a class="btn" href="/profile.mobileconfig">Install Proxy Wi-Fi Profile</a>
        <div class="step">
        <strong>Step 2:</strong> First run only: install and trust the CA
        <span class="note">After installing, enable full trust in Settings -> General -> About -> Certificate Trust Settings.</span>
        </div>
        <a class="btn secondary" href="/ca.mobileconfig">Install CA Profile</a>
        <div class="step">
        <strong>Cleanup:</strong> Install this before stopping if the proxy profile is still active.
        </div>
        <a class="btn cleanup" href="/cleanup.mobileconfig">Install Cleanup Profile</a>
        </body>
        </html>
        """

        profileLock.lock()
        profileHtml = html.data(using: .utf8)
        proxyMobileconfig = proxyData
        cleanupMobileconfig = cleanupData
        caMobileconfig = caProfileData
        caCertificate = caData
        profileLock.unlock()

        NSLog("[profile] pushed proxy=%d cleanup=%d caProfile=%d ca=%d",
              proxyData.count, cleanupData?.count ?? 0, caProfileData?.count ?? 0, caData.count)
        return Codec.makeOK(["status": "pushed"])
    }

    // Keep legacy commands for backwards compatibility.
    static func proxyStart(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        return try proxyIngressStart(rawArgs)
    }

    static func proxyStop(_ rawArgs: AnyCodable?) throws -> ResponseFrame {
        return try proxyIngressStop(rawArgs)
    }

    // MARK: - Socket Listener

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
            NSLog("[profile] bind fail: %s", strerror(errno))
            close(fd)
            return -1
        }
        guard listen(fd, 32) == 0 else {
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
        profileSource = src
        return fd
    }

    // MARK: - Profile Page

    private static func handleProfileConn(_ fd: Int32) {
        DispatchQueue.global(qos: .userInitiated).async {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = recv(fd, &buf, buf.count, 0)
            let request = n > 0 ? String(bytes: buf[0..<n], encoding: .utf8) ?? "" : ""
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let path = parts.count >= 2 ? String(parts[1]) : "/"

            profileLock.lock()
            let html = profileHtml
            let proxy = proxyMobileconfig
            let cleanup = cleanupMobileconfig
            let caProfile = caMobileconfig
            let ca = caCertificate
            profileLock.unlock()

            let response: Data
            if path == "/profile.mobileconfig", let body = proxy {
                response = makeResponse(body: body, contentType: "application/x-apple-aspen-config", filename: "ios-use-proxy-wifi.mobileconfig")
            } else if path == "/cleanup.mobileconfig", let body = cleanup {
                response = makeResponse(body: body, contentType: "application/x-apple-aspen-config", filename: "ios-use-proxy-cleanup.mobileconfig")
            } else if path == "/ca.mobileconfig", let body = caProfile {
                response = makeResponse(body: body, contentType: "application/x-apple-aspen-config", filename: "ios-use-ca.mobileconfig")
            } else if path == "/ca.cer", let body = ca {
                response = makeResponse(body: body, contentType: "application/x-x509-ca-cert", filename: "ios-use-ca.cer")
            } else if let body = html {
                response = makeResponse(body: body, contentType: "text/html; charset=utf-8", filename: nil)
            } else {
                let body = "<h1>No profile available</h1><p>Run proxy start first.</p>".data(using: .utf8)!
                response = makeResponse(status: "404 Not Found", body: body, contentType: "text/html", filename: nil)
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

    private static func makeResponse(status: String = "200 OK", body: Data, contentType: String, filename: String?) -> Data {
        var header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let filename = filename {
            header += "Content-Disposition: attachment; filename=\"\(filename)\"\r\n"
        }
        header += "\r\n"
        return header.data(using: .utf8)! + body
    }
}

// MARK: - Args

struct ProxyIngressStartArgs: Codable {
    let proxyPort: Int?
    let controlPort: Int?
    let profilePort: Int?
}

struct ProxyPushProfileArgs: Codable {
    let caBase64: String
    let mobileconfigBase64: String
    let caProfileBase64: String?
    let cleanupMobileconfigBase64: String?
}
