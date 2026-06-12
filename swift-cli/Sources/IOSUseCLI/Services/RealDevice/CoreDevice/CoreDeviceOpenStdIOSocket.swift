import Foundation
import IOSUseProtocol

final class CoreDeviceOpenStdIOSocket {
    static let serviceName = IOSUseProtocol.XCConstants.coreDeviceOpenStdIOServiceName

    let identifier: UUID
    private let stream: DeviceStream
    private let lock = NSLock()
    private var stopped = false
    private var draining = false

    init(identifier: UUID, stream: DeviceStream) {
        self.identifier = identifier
        self.stream = stream
    }

    static func connect(session: CoreDeviceLifecycleTunnelSession) throws -> CoreDeviceOpenStdIOSocket {
        let stream = try session.connectService(serviceName)
        do {
            let uuidData = try stream.readExact(
                byteCount: IOSUseProtocol.XCConstants.openStdIOIdentifierByteCount,
                timeoutSeconds: IOSUseProtocol.XCConstants.openStdIOIdentifierReadTimeoutSeconds
            )
            let identifier = try uuid(from: uuidData)
            return CoreDeviceOpenStdIOSocket(identifier: identifier, stream: stream)
        } catch {
            stream.close()
            throw error
        }
    }

    func startDraining(eventSink: ((String) -> Void)?) {
        lock.lock()
        if draining {
            lock.unlock()
            return
        }
        draining = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.drain(eventSink: eventSink)
        }
    }

    func drainToFile(_ fileHandle: FileHandle, interruptMonitor: InterruptMonitor? = nil) throws {
        lock.lock()
        if draining {
            lock.unlock()
            return
        }
        draining = true
        lock.unlock()

        while !shouldStop {
            try interruptMonitor?.throwIfInterrupted("App log capture interrupted")
            do {
                let data = try stream.readAvailable(
                    maxBytes: IOSUseProtocol.XCConstants.openStdIODrainMaxBytes,
                    timeoutSeconds: IOSUseProtocol.XCConstants.openStdIODrainReadTimeoutSeconds
                )
                guard !data.isEmpty else {
                    usleep(useconds_t(IOSUseProtocol.XCConstants.openStdIODrainIdleSleepMicroseconds))
                    continue
                }
                try fileHandle.write(contentsOf: data)
            } catch let signal as CLIExitSignal {
                throw signal
            } catch {
                if shouldStop {
                    return
                }
                return
            }
        }
    }

    func close() {
        lock.lock()
        stopped = true
        lock.unlock()
        stream.close()
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func drain(eventSink: ((String) -> Void)?) {
        while !shouldStop {
            do {
                let data = try stream.readAvailable(
                    maxBytes: IOSUseProtocol.XCConstants.openStdIODrainMaxBytes,
                    timeoutSeconds: IOSUseProtocol.XCConstants.openStdIODrainReadTimeoutSeconds
                )
                guard !data.isEmpty else {
                    usleep(useconds_t(IOSUseProtocol.XCConstants.openStdIODrainIdleSleepMicroseconds))
                    continue
                }
                emit(data: data, eventSink: eventSink)
            } catch {
                if !shouldStop {
                    eventSink?("runner stdio ended: \(error)")
                }
                return
            }
        }
    }

    private func emit(data: Data, eventSink: ((String) -> Void)?) {
        guard let eventSink else { return }
        let text = String(data: data, encoding: .utf8)
            ?? data.map { String(format: "%02x", $0) }.joined()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines where !line.isEmpty {
            eventSink("runner stdio \(line)")
        }
    }

    private static func uuid(from data: Data) throws -> UUID {
        guard data.count == 16 else {
            throw CLIParseError.invalidValue("openstdio socket returned \(data.count) UUID bytes")
        }
        let bytes = [UInt8](data)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
