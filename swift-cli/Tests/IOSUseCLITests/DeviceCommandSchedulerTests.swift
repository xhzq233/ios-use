import XCTest
@testable import IOSUseDaemonRuntime

final class DeviceCommandSchedulerTests: XCTestCase {
    func testSameDeviceJobsRunSerially() async throws {
        let scheduler = DeviceCommandScheduler()
        let recorder = SchedulerRecorder()

        async let first: Void = scheduler.enqueue(udid: "SIM-1", kind: .ui) {
            await recorder.append("first-start")
            try await Task.sleep(nanoseconds: 120_000_000)
            await recorder.append("first-end")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        async let second: Void = scheduler.enqueue(udid: "SIM-1", kind: .ui) {
            await recorder.append("second-start")
            await recorder.append("second-end")
        }

        _ = try await (first, second)

        let events = await recorder.events
        let hasQueuedWork = await scheduler.hasQueuedWork(for: "SIM-1")
        XCTAssertEqual(events, ["first-start", "first-end", "second-start", "second-end"])
        XCTAssertFalse(hasQueuedWork)
    }

    func testDifferentDevicesCanRunConcurrently() async throws {
        let scheduler = DeviceCommandScheduler()
        let recorder = SchedulerRecorder()

        async let first: Void = scheduler.enqueue(udid: "SIM-1", kind: .ui) {
            await recorder.append("first-start")
            try await Task.sleep(nanoseconds: 150_000_000)
            await recorder.append("first-end")
        }
        async let second: Void = scheduler.enqueue(udid: "SIM-2", kind: .ui) {
            await recorder.append("second-start")
            await recorder.append("second-end")
        }

        _ = try await (first, second)

        let events = await recorder.events
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "second-start")), try XCTUnwrap(events.firstIndex(of: "first-end")))
    }

    func testStreamingJobsDoNotOccupyDeviceQueue() async throws {
        let scheduler = DeviceCommandScheduler()
        let recorder = SchedulerRecorder()

        async let streaming: Void = scheduler.enqueue(udid: "SIM-1", kind: .streaming) {
            await recorder.append("stream-start")
            try await Task.sleep(nanoseconds: 120_000_000)
            await recorder.append("stream-end")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        async let ui: Void = scheduler.enqueue(udid: "SIM-1", kind: .ui) {
            await recorder.append("ui-start")
            await recorder.append("ui-end")
        }

        _ = try await (streaming, ui)

        let events = await recorder.events
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "ui-start")), try XCTUnwrap(events.firstIndex(of: "stream-end")))
    }
}

private actor SchedulerRecorder {
    private var storedEvents: [String] = []

    var events: [String] {
        storedEvents
    }

    func append(_ event: String) {
        storedEvents.append(event)
    }
}
