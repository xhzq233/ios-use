import Foundation
import IOSUseProtocol
import XCTest
@testable import IOSUseCLI

final class MCPRuntimeTests: XCTestCase {
    func testStructuredWaitReturnsMatchingSnapshotWithoutAnExtraRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-mcp-\(UUID().uuidString)")
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root.path])
        try SessionService.writeDriverLock(info: .init(
            udid: "MCP-SIM", deviceName: "Test", deviceVersion: "26.0", deviceType: "simulator", startedAt: 1
        ), paths: try paths.deviceContext("MCP-SIM"))
        let fory = ForyRegistry.create()
        let responses = try [1, 2, 3].map { generation in
            ForyResponseFrame(ok: true, payload: try fory.serialize(ForyDomPayload(
                app: "test", snapshotGeneration: Int64(generation), elements: [
                    ForyDomElement(traits: ["App"], childCount: 1),
                    ForyDomElement(traits: generation > 1 ? ["Switch", "selected"] : ["Switch"]),
                ]
            )))
        }
        let server = try FakeDriverServer(responses: responses)
        let runtime = MCPJavaScriptRuntime(paths: paths)
        DriverCommandExecution.clientFactoryForTesting = { _ in DriverClient(port: UInt16(server.port)) }
        defer {
            runtime.close(); server.stop()
            DriverCommandExecution.clientFactoryForTesting = nil
            try? FileManager.default.removeItem(at: root)
        }
        let matched = await runtime.execute(code: """
            let d = await cua.getDevice("MCP-SIM", {observe:false, emit:false});
            let same = await cua.getDevice("MCP-SIM", {observe:false, emit:false});
            if (same !== d) throw new Error("Device handles must share AX state");
            let attempts = 0;
            let ax = await d.waitFor(snapshot => { attempts++; return snapshot.elements[1].selected; });
            if (attempts !== 2 || ax.snapshotGeneration !== 2) throw new Error("Wait did not stop at matching state");
            if (ax.elements[1].parent_index !== 0 || ax.elements[0].children[0] !== 1) throw new Error("Hierarchy lost");
            if (d.get(1) !== ax.elements[1]) throw new Error("Matching observation must be current");
            """, timeoutMS: 3000)
        XCTAssertNotEqual(matched.isError, true, "\(matched.content)")
        XCTAssertTrue(matched.content.isEmpty, "Intermediate snapshots must not emit full AX")
        XCTAssertEqual(server.requestFrames.count, 2)

        let timeout = await runtime.execute(code: "await d.waitFor(() => false, {timeout:0.000001});", timeoutMS: 3000)
        XCTAssertEqual(timeout.isError, true)
        let retained = await runtime.execute(code: "if (!d.get(1).selected) throw new Error('Last observation lost');", timeoutMS: 3000)
        XCTAssertNotEqual(retained.isError, true)
        XCTAssertEqual(server.requestFrames.count, 3)
        XCTAssertEqual(server.acceptCount, 1)
    }

    func testAppSelectionReusesReadinessAXAndDriverConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-use-mcp-\(UUID().uuidString)")
        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root.path])
        try SessionService.writeDriverLock(info: .init(
            udid: "MCP-SIM", deviceName: "Test", deviceVersion: "26.0", deviceType: "simulator", startedAt: 1
        ), paths: try paths.deviceContext("MCP-SIM"))
        let fory = ForyRegistry.create()
        let dom = ForyDomPayload(app: "test", snapshotGeneration: 7, elements: [ForyDomElement(traits: ["App"], childCount: 1), ForyDomElement(traits: ["Button"])])
        let ready = ForyWaitAppForegroundPayload(expectedBundleId: "test", activeBundleId: "test", appState: IOSUseAppState.foreground.rawValue, snapshotReady: true, dom: dom)
        let server = try FakeDriverServer(responses: [
            ForyResponseFrame(ok: true, payload: try fory.serialize(ready)),
            ForyResponseFrame(ok: true, payload: try fory.serialize(dom)),
            ForyResponseFrame(ok: true, payload: try fory.serialize(ForyWaitAppForegroundPayload(snapshotReady: false))),
        ])
        let runtime = MCPJavaScriptRuntime(paths: paths)
        var launches = 0
        AppLifecycleService.simulatorRunnerForTesting = { _, _ in
            launches += 1
            return AppLifecycleService.Result(message: "activated")
        }
        AppManagementService.appsProviderForTesting = { _, includeSystem in
            XCTAssertTrue(includeSystem)
            return [AppManagementService.AppInfo(bundleID: "test", displayName: "Test", version: "1", applicationType: "System")]
        }
        DriverCommandExecution.clientFactoryForTesting = { _ in DriverClient(port: UInt16(server.port)) }
        defer {
            runtime.close(); server.stop()
            AppLifecycleService.simulatorRunnerForTesting = nil
            AppManagementService.appsProviderForTesting = nil
            DriverCommandExecution.clientFactoryForTesting = nil
            try? FileManager.default.removeItem(at: root)
        }
        let selected = await runtime.execute(code: """
            let d = await cua.getDevice("MCP-SIM", {observe:false, emit:false});
            let apps = await d.listApps({includeSystem:true, emit:false});
            if (apps.length !== 1) throw new Error("Missing installed App");
            let app = await d.getApp(apps[0].bundleId, {emit:false});
            if (app !== d || d.get().length !== 2) throw new Error("Ready AX not reused");
            let ax = await d.getAXSnapshot();
            if (ax.snapshotGeneration !== 7) throw new Error("Snapshot generation lost");
            """, timeoutMS: 3000)
        XCTAssertNotEqual(selected.isError, true, "\(selected.content)")
        XCTAssertTrue(selected.content.isEmpty)
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(server.requestFrames.count, 2)
        XCTAssertEqual(server.acceptCount, 1)
        let failed = await runtime.execute(code: """
            let failed = false;
            try { await d.getApp("test", {emit:false}); }
            catch (error) { failed = error.mutationMayHaveApplied; }
            if (!failed) throw new Error("Readiness failure lost mutation warning");
            let stale = false;
            try { d.get(0); } catch { stale = true; }
            if (!stale) throw new Error("Failed App selection retained stale AX");
            """, timeoutMS: 3000)
        XCTAssertNotEqual(failed.isError, true, "\(failed.content)")
        XCTAssertEqual(launches, 2)
        XCTAssertEqual(server.requestFrames.count, 3)
        XCTAssertEqual(server.acceptCount, 1)
    }

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
