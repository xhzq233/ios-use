#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation
import XCTest
import IOSUseProtocol
@testable import IOSUseCLI

final class SandboxFileServiceTests: XCTestCase {
    override func tearDown() {
        SandboxFileService.serviceConnectorForTesting = nil
        super.tearDown()
    }

    private func withTempDir(_ body: (String, IOSUsePaths) throws -> Void) throws {
        let root = "/tmp/iu-file-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root])
        try body(root, paths)
    }

    private func writeRemoteDeviceLock(udid: String, alias: String = "phone", paths: IOSUsePaths) throws {
        let scoped = try paths.deviceContext(alias)
        let connection = RemoteDeviceConnection(
            udid: udid,
            driverBundleID: "com.example.driver.xctrunner",
            usbmux: .init(host: "127.0.0.1", port: 27015),
            driver: .init(host: "127.0.0.1", port: 8100)
        )
        try DriverSessionStore.write(
            info: SessionService.Info(
                udid: udid,
                deviceName: "iPhone",
                deviceVersion: "18.5",
                deviceType: "real",
                driverHost: connection.driver.host,
                driverPort: connection.driver.port,
                remoteConnection: connection,
                startMode: "remote"
            ),
            paths: scoped
        )
    }

    func testParsesFileCommandsAndFlags() throws {
        XCTAssertEqual(
            try CLIParser.parse(["file", "ls", "com.example.app"]),
            .file(.ls(bundleID: "com.example.app", remotePath: nil, documents: false, udid: nil))
        )
        XCTAssertEqual(
            try CLIParser.parse(["file", "ls", "com.example.app", "/Documents", "--documents", "--udid", "REAL-1", "--json"]),
            .file(.ls(bundleID: "com.example.app", remotePath: "/Documents", documents: true, udid: "REAL-1"))
        )
        XCTAssertEqual(
            try CLIParser.parse(["file", "pull", "com.example.app", "/Documents/a.txt", "./out.txt"]),
            .file(.pull(bundleID: "com.example.app", remotePath: "/Documents/a.txt", localPath: "./out.txt", documents: false, udid: nil))
        )
        XCTAssertEqual(
            try CLIParser.parse(["file", "push", "com.example.app", "./in.txt", "/Documents/in.txt", "--documents"]),
            .file(.push(bundleID: "com.example.app", localPath: "./in.txt", remotePath: "/Documents/in.txt", documents: true, udid: nil))
        )
        XCTAssertEqual(
            try CLIParser.parse(["file", "rm", "com.example.app", "/Documents/dir", "-r"]),
            .file(.remove(bundleID: "com.example.app", remotePath: "/Documents/dir", recursive: true, documents: false, udid: nil))
        )

        XCTAssertThrowsError(try CLIParser.parse(["file", "ls", "com.example.app", "-r"]))
        XCTAssertThrowsError(try CLIParser.parse(["file", "pull", "com.example.app"]))
        XCTAssertThrowsError(try CLIParser.parse(["file", "unknown", "com.example.app"]))
    }

    func testHouseArrestPathResolutionAndSecurityValidation() throws {
        XCTAssertEqual(try HouseArrestClient.resolveRemotePath(nil, scope: .container), "/")
        XCTAssertEqual(try HouseArrestClient.resolveRemotePath("./Documents/log.txt", scope: .container), "/Documents/log.txt")
        XCTAssertEqual(try HouseArrestClient.resolveRemotePath(nil, scope: .documents), "/Documents")
        XCTAssertEqual(try HouseArrestClient.resolveRemotePath("sub/a.txt", scope: .documents), "/Documents/sub/a.txt")
        XCTAssertEqual(try HouseArrestClient.resolveRemotePath("/Documents/sub/a.txt", scope: .documents), "/Documents/sub/a.txt")

        XCTAssertThrowsError(try HouseArrestClient.resolveRemotePath("../etc/passwd", scope: .container))
        XCTAssertThrowsError(try HouseArrestClient.resolveRemotePath("Documents/../../Library", scope: .documents))
        XCTAssertThrowsError(try HouseArrestClient.resolveRemotePath("bad\0path", scope: .container))

        XCTAssertTrue(HouseArrestClient.isProtectedRoot("/", scope: .container))
        XCTAssertFalse(HouseArrestClient.isProtectedRoot("/Documents", scope: .container))
        XCTAssertTrue(HouseArrestClient.isProtectedRoot("/Documents", scope: .documents))
        XCTAssertFalse(HouseArrestClient.isProtectedRoot("/Documents/foo", scope: .documents))
    }

    func testHouseArrestHandshakeErrorsMapClearly() throws {
        try withTempDir { _, paths in
            try writeRemoteDeviceLock(udid: "REAL-UDID", paths: paths)
            let server = FakeHouseArrestAFCServer(
                handshakeResponse: ["Status": "Error", "Error": "InstallationLookupFailed"]
            )
            SandboxFileService.serviceConnectorForTesting = { serviceName, _ in
                XCTAssertEqual(serviceName, IOSUseProtocol.XCConstants.houseArrestServiceName)
                return try server.connect()
            }

            let cli = IOSUseCLI(environment: ["IOS_USE_HOME": paths.root])
            let result = cli.run(arguments: ["file", "ls", "com.example.app", "--udid", "REAL-UDID"])

            XCTAssertEqual(result.exitCode, 1)
            XCTAssertTrue(result.stderr.contains("get-task-allow"))
            XCTAssertTrue(result.stderr.contains("--documents"))
            XCTAssertEqual(server.handshakeCommand, "VendContainer")
            XCTAssertEqual(server.handshakeBundleID, "com.example.app")
        }

        try withTempDir { _, paths in
            try writeRemoteDeviceLock(udid: "REAL-UDID", paths: paths)
            let server = FakeHouseArrestAFCServer(
                handshakeResponse: ["Status": "Error", "Error": "ApplicationLookupFailed"]
            )
            SandboxFileService.serviceConnectorForTesting = { _, _ in try server.connect() }

            let cli = IOSUseCLI(environment: ["IOS_USE_HOME": paths.root])
            let result = cli.run(arguments: ["file", "ls", "com.missing.app", "--documents", "--udid", "REAL-UDID"])

            XCTAssertEqual(result.exitCode, 1)
            XCTAssertTrue(result.stderr.contains("not installed"))
            XCTAssertEqual(server.handshakeCommand, "VendDocuments")
        }
    }

    func testFilePushLsPullAndRmEndToEndOverAFCWireProtocol() throws {
        try withTempDir { root, paths in
            try writeRemoteDeviceLock(udid: "REAL-SANDBOX", paths: paths)

            let server = FakeHouseArrestAFCServer()
            SandboxFileService.serviceConnectorForTesting = { _, _ in try server.connect() }
            let cli = IOSUseCLI(environment: ["IOS_USE_HOME": root])

            // 1. Push a multi-chunk file into /Documents/payload.bin
            let payloadBytes = Data((0..<(600 * 1024)).map { UInt8($0 & 0xff) })
            let localUpload = URL(fileURLWithPath: root).appendingPathComponent("upload.bin")
            try payloadBytes.write(to: localUpload)

            let pushRes = cli.run(arguments: ["file", "push", "com.example.app", localUpload.path, "/Documents/payload.bin", "--json"])
            XCTAssertEqual(pushRes.exitCode, 0, pushRes.stderr)
            XCTAssertTrue(pushRes.stdout.contains(#""type" : "file""#))
            XCTAssertTrue(pushRes.stdout.contains(#""byteCount" : 614400"#))

            // 2. Push a directory recursively
            let localDir = URL(fileURLWithPath: root).appendingPathComponent("bundle")
            try FileManager.default.createDirectory(at: localDir.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: localDir.appendingPathComponent("a.txt"))
            try Data("world".utf8).write(to: localDir.appendingPathComponent("nested/b.txt"))

            let pushDirRes = cli.run(arguments: ["file", "push", "com.example.app", localDir.path, "/Documents/bundle", "--json"])
            XCTAssertEqual(pushDirRes.exitCode, 0, pushDirRes.stderr)
            XCTAssertTrue(pushDirRes.stdout.contains(#""fileCount" : 2"#))

            // 3. List /Documents with JSON and human formats
            let lsJSON = cli.run(arguments: ["file", "ls", "com.example.app", "/Documents", "--json"])
            XCTAssertEqual(lsJSON.exitCode, 0, lsJSON.stderr)
            XCTAssertTrue(lsJSON.stdout.contains(#""name" : "payload.bin""#))
            XCTAssertTrue(lsJSON.stdout.contains(#""name" : "bundle""#))

            let lsText = cli.run(arguments: ["file", "ls", "com.example.app", "/Documents"])
            XCTAssertEqual(lsText.exitCode, 0, lsText.stderr)
            XCTAssertTrue(lsText.stdout.contains("payload.bin"))
            XCTAssertTrue(lsText.stdout.contains("bundle"))

            // 4. Pull file back and confirm byte-for-byte integrity across chunked AFC read (0x0f)
            let pulledFile = URL(fileURLWithPath: root).appendingPathComponent("pulled/payload.bin")
            let pullRes = cli.run(arguments: ["file", "pull", "com.example.app", "/Documents/payload.bin", pulledFile.path, "--json"])
            XCTAssertEqual(pullRes.exitCode, 0, pullRes.stderr)
            XCTAssertEqual(try Data(contentsOf: pulledFile), payloadBytes)

            // 5. Pull directory (including symlink warning check without host symlink creation)
            server.addSymlink(path: "/Documents/bundle/escape", target: "/etc/passwd")
            let pulledDir = URL(fileURLWithPath: root).appendingPathComponent("pulled-bundle")
            let pullDirRes = cli.run(arguments: ["file", "pull", "com.example.app", "/Documents/bundle", pulledDir.path, "--json"])
            XCTAssertEqual(pullDirRes.exitCode, 0, pullDirRes.stderr)
            XCTAssertTrue(pullDirRes.stdout.contains("Skipped symbolic link /Documents/bundle/escape"))
            XCTAssertEqual(try String(contentsOf: pulledDir.appendingPathComponent("nested/b.txt"), encoding: .utf8), "world")
            XCTAssertFalse(FileManager.default.fileExists(atPath: pulledDir.appendingPathComponent("escape").path))

            // 6. Remove protections and execution
            let rmRoot = cli.run(arguments: ["file", "rm", "com.example.app", "/"])
            XCTAssertEqual(rmRoot.exitCode, 1)
            XCTAssertTrue(rmRoot.stderr.contains("Refusing to remove the sandbox container root"))

            let rmDocsRoot = cli.run(arguments: ["file", "rm", "com.example.app", "/Documents", "--documents"])
            XCTAssertEqual(rmDocsRoot.exitCode, 1)

            let rmDirWithoutRecursive = cli.run(arguments: ["file", "rm", "com.example.app", "/Documents/bundle"])
            XCTAssertEqual(rmDirWithoutRecursive.exitCode, 1)
            XCTAssertTrue(rmDirWithoutRecursive.stderr.contains("--recursive"))

            let rmDirRecursive = cli.run(arguments: ["file", "rm", "com.example.app", "/Documents/bundle", "-r", "--json"])
            XCTAssertEqual(rmDirRecursive.exitCode, 0, rmDirRecursive.stderr)
            XCTAssertTrue(rmDirRecursive.stdout.contains(#""recursive" : true"#))

            let rmFile = cli.run(arguments: ["file", "rm", "com.example.app", "/Documents/payload.bin"])
            XCTAssertEqual(rmFile.exitCode, 0, rmFile.stderr)

            let lsMissing = cli.run(arguments: ["file", "ls", "com.example.app", "/Documents/payload.bin"])
            XCTAssertEqual(lsMissing.exitCode, 1)
            XCTAssertTrue(lsMissing.stderr.contains("Remote path not found"))
        }
    }

    func testPullRejectsMaliciousChildEntryNameOutsideTargetDirectory() throws {
        try withTempDir { root, paths in
            try writeRemoteDeviceLock(udid: "REAL-1", paths: paths)
            let server = FakeHouseArrestAFCServer()
            server.injectDirectoryChild(directory: "/Documents", childName: "../evil.txt")
            SandboxFileService.serviceConnectorForTesting = { _, _ in try server.connect() }
            let cli = IOSUseCLI(environment: ["IOS_USE_HOME": root])

            let dest = URL(fileURLWithPath: root).appendingPathComponent("safe-out").path
            let res = cli.run(arguments: ["file", "pull", "com.example.app", "/Documents", dest, "--udid", "REAL-1"])

            XCTAssertEqual(res.exitCode, 1)
            XCTAssertTrue(res.stderr.contains("Unsafe remote entry name"))
        }
    }
}

private final class FakeHouseArrestAFCServer {
    private enum Entry {
        case directory
        case file(Data)
        case symlink(String)
    }

    private let lock = NSLock()
    private let handshakeResponse: [String: Any]
    private var entries: [String: Entry] = [
        "/": .directory,
        "/Documents": .directory,
        "/Library": .directory,
        "/tmp": .directory,
    ]
    private var injectedChildren: [String: [String]] = [:]
    private var openHandles: [UInt64: (path: String, offset: Int)] = [:]
    private var nextHandle: UInt64 = 1

    private(set) var handshakeCommand: String?
    private(set) var handshakeBundleID: String?

    init(handshakeResponse: [String: Any] = ["Status": "Complete"]) {
        self.handshakeResponse = handshakeResponse
    }

    func addSymlink(path: String, target: String) {
        lock.lock()
        entries[path] = .symlink(target)
        lock.unlock()
    }

    func injectDirectoryChild(directory: String, childName: String) {
        lock.lock()
        injectedChildren[directory, default: []].append(childName)
        lock.unlock()
    }

    func connect() throws -> DeviceStream {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, posixStreamSocketType, 0, &fds) == 0 else {
            throw CLIParseError.invalidValue("socketpair failed: \(errno)")
        }
        let clientStream = PlainDeviceStream(fd: fds[0])
        let serverStream = PlainDeviceStream(fd: fds[1])
        Thread { [self] in
            self.serve(stream: serverStream)
        }.start()
        return clientStream
    }

    private func serve(stream: DeviceStream) {
        defer { stream.close() }
        do {
            let header = try stream.readExact(byteCount: 4, timeoutSeconds: 5)
            let length = Int(readUInt32BE(header, 0))
            let reqData = try stream.readExact(byteCount: length, timeoutSeconds: 5)
            let req = try parsePlist(reqData)
            lock.lock()
            handshakeCommand = req["Command"] as? String
            handshakeBundleID = req["Identifier"] as? String
            lock.unlock()

            let respData = try serializePlist(handshakeResponse)
            try stream.write(uint32BE(UInt32(respData.count)) + respData)
            guard (handshakeResponse["Status"] as? String) == "Complete" else {
                return
            }

            while true {
                let afcHeader: Data
                do {
                    afcHeader = try stream.readExact(byteCount: IOSUseProtocol.XCConstants.afcHeaderByteCount, timeoutSeconds: 5)
                } catch {
                    return
                }
                let entireLength = readUInt64LE(afcHeader, 8)
                let thisLength = readUInt64LE(afcHeader, 16)
                let packetNumber = readUInt64LE(afcHeader, 24)
                let opcode = readUInt64LE(afcHeader, 32)
                let payloadLength = Int(entireLength - UInt64(IOSUseProtocol.XCConstants.afcHeaderByteCount))
                let payload = payloadLength > 0 ? try stream.readExact(byteCount: payloadLength, timeoutSeconds: 5) : Data()

                let response = handleAfc(opcode: opcode, thisLength: thisLength, payload: payload)
                let respEntire = UInt64(IOSUseProtocol.XCConstants.afcHeaderByteCount) + UInt64(response.payload.count)
                var packet = Data(IOSUseProtocol.XCConstants.afcPacketMagic.utf8)
                packet.append(uint64LE(respEntire))
                packet.append(uint64LE(respEntire))
                packet.append(uint64LE(packetNumber))
                packet.append(uint64LE(response.opcode))
                packet.append(response.payload)
                try stream.write(packet)
            }
        } catch {
            return
        }
    }

    private func handleAfc(opcode: UInt64, thisLength: UInt64, payload: Data) -> (opcode: UInt64, payload: Data) {
        lock.lock()
        defer { lock.unlock() }

        switch AfcOpcode(rawValue: opcode) {
        case .getFileInfo:
            let path = decodeCString(payload)
            guard let entry = entries[path] else {
                return statusPacket(AfcStatus.objectNotFound.rawValue)
            }
            var fields: [String] = []
            switch entry {
            case .directory:
                fields += ["st_ifmt", "S_IFDIR", "st_size", "0", "st_mtime", "1732300000000000000"]
            case .file(let data):
                fields += ["st_ifmt", "S_IFREG", "st_size", "\(data.count)", "st_mtime", "1732300000000000000"]
            case .symlink(let target):
                fields += ["st_ifmt", "S_IFLNK", "st_size", "\(target.utf8.count)", "LinkTarget", target]
            }
            return (AfcOpcode.data.rawValue, encodeCStrings(fields))

        case .readDirectory:
            let dir = decodeCString(payload)
            guard case .directory? = entries[dir] else {
                return statusPacket(AfcStatus.objectNotFound.rawValue)
            }
            let prefix = dir == "/" ? "/" : "\(dir)/"
            var names: Set<String> = [".", ".."]
            for key in entries.keys where key.hasPrefix(prefix) && key != dir {
                let rest = String(key.dropFirst(prefix.count))
                if !rest.contains("/"), !rest.isEmpty {
                    names.insert(rest)
                }
            }
            for extra in injectedChildren[dir] ?? [] {
                names.insert(extra)
            }
            return (AfcOpcode.data.rawValue, encodeCStrings(names.sorted()))

        case .makeDirectory:
            let dir = decodeCString(payload)
            if entries[dir] != nil {
                return statusPacket(AfcStatus.objectExists.rawValue)
            }
            entries[dir] = .directory
            return statusPacket(AfcStatus.success.rawValue)

        case .fileOpen:
            let mode = readUInt64LE(payload, 0)
            let path = decodeCString(Data(payload.dropFirst(8)))
            let handle = nextHandle
            nextHandle += 1
            if mode == IOSUseProtocol.XCConstants.afcFileOpenModeReadOnly {
                guard case .file? = entries[path] else {
                    return statusPacket(AfcStatus.objectNotFound.rawValue)
                }
                openHandles[handle] = (path, 0)
            } else {
                entries[path] = .file(Data())
                openHandles[handle] = (path, 0)
            }
            return (AfcOpcode.fileOpenResult.rawValue, uint64LE(handle))

        case .read:
            let handle = readUInt64LE(payload, 0)
            let maxLen = Int(readUInt64LE(payload, 8))
            guard let state = openHandles[handle], case .file(let content)? = entries[state.path] else {
                return statusPacket(AfcStatus.invalidArgument.rawValue)
            }
            guard state.offset < content.count else {
                return statusPacket(AfcStatus.success.rawValue)
            }
            let end = min(state.offset + maxLen, content.count)
            let slice = content.subdata(in: state.offset..<end)
            openHandles[handle] = (state.path, end)
            return (AfcOpcode.data.rawValue, slice)

        case .write:
            _ = thisLength
            let handle = readUInt64LE(payload, 0)
            let chunk = Data(payload.dropFirst(8))
            guard let state = openHandles[handle], case .file(var existing)? = entries[state.path] else {
                return statusPacket(AfcStatus.invalidArgument.rawValue)
            }
            existing.append(chunk)
            entries[state.path] = .file(existing)
            return statusPacket(AfcStatus.success.rawValue)

        case .close:
            let handle = readUInt64LE(payload, 0)
            openHandles.removeValue(forKey: handle)
            return statusPacket(AfcStatus.success.rawValue)

        case .removePath:
            let path = decodeCString(payload)
            guard entries[path] != nil else {
                return statusPacket(AfcStatus.objectNotFound.rawValue)
            }
            if case .directory? = entries[path] {
                let prefix = path == "/" ? "/" : "\(path)/"
                if entries.keys.contains(where: { $0.hasPrefix(prefix) }) {
                    return statusPacket(AfcStatus.directoryNotEmpty.rawValue)
                }
            }
            entries.removeValue(forKey: path)
            return statusPacket(AfcStatus.success.rawValue)

        default:
            return statusPacket(AfcStatus.operationNotSupported.rawValue)
        }
    }

    private func statusPacket(_ code: UInt64) -> (opcode: UInt64, payload: Data) {
        (AfcOpcode.status.rawValue, uint64LE(code))
    }

    private func decodeCString(_ data: Data) -> String {
        let prefix = data.prefix { $0 != 0 }
        return String(data: prefix, encoding: .utf8) ?? ""
    }

    private func encodeCStrings(_ strings: [String]) -> Data {
        var out = Data()
        for value in strings {
            out.append(contentsOf: value.utf8)
            out.append(0)
        }
        return out
    }
}
