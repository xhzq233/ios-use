import Foundation
import IOSUseProtocol
import XCTest
@testable import IOSUseCLI

final class MCPRuntimeTests: XCTestCase {
    func testResetDoesNotWaitForDriverAndDropsQueuedDeviceRequests() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-mcp-\(UUID().uuidString)")
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root.path])
        let devicePaths = try paths.deviceContext("MCP-SIM")
        try SessionService.writeDriverLock(info: .init(
            udid: "MCP-SIM", deviceName: "Test", deviceVersion: "26.0",
            deviceType: "simulator", startedAt: 1
        ), paths: devicePaths)
        let payload = try ForyRegistry.create().serialize(ForyDomPayload(app: "test"))
        let server = try FakeDriverServer(
            responses: Array(repeating: ForyResponseFrame(ok: true, payload: payload), count: 2),
            responseDelay: 2
        )
        let runtime = MCPJavaScriptRuntime(paths: paths)
        DriverCommandExecution.clientFactoryForTesting = { _ in DriverClient(port: UInt16(server.port)) }
        defer {
            runtime.close()
            server.stop()
            DriverCommandExecution.clientFactoryForTesting = nil
            try? FileManager.default.removeItem(at: root)
        }

        let running = Task {
            await runtime.execute(code: """
                await Promise.all([
                  cua.getDevice("MCP-SIM", {emit:false}),
                  cua.getDevice("MCP-SIM", {emit:false})
                ]);
                """, timeoutMS: 10_000)
        }
        for _ in 0..<200 where server.requestFrames.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(server.requestFrames.count, 1, "first request must be inside the Driver before reset")
        let start = ContinuousClock.now
        let reset = await runtime.reset()
        XCTAssertNotEqual(reset.isError, true)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let interrupted = await running.value
        XCTAssertEqual(interrupted.isError, true)
        let fresh = await runtime.execute(code: "nodeRepl.write(7 * 6);", timeoutMS: 1000)
        XCTAssertNotEqual(fresh.isError, true)
        XCTAssertTrue(server.waitForDisconnect(timeout: 4))
        XCTAssertEqual(server.requestFrames.count, 1, "queued request must not act after cancellation")
    }
}
