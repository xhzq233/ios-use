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
        let firstStarted = expectation(description: "first started")
        let secondStarted = expectation(description: "second started")
        let releaseFirst = SchedulerTestGate()

        async let first: Void = scheduler.enqueue(udid: "SIM-1", kind: .ui) {
            firstStarted.fulfill()
            await releaseFirst.wait()
        }
        await fulfillment(of: [firstStarted], timeout: 1)

        async let second: Void = scheduler.enqueue(udid: "SIM-2", kind: .ui) {
            secondStarted.fulfill()
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        await releaseFirst.open()

        _ = try await (first, second)
    }

    func testStreamingJobsDoNotOccupyDeviceQueue() async throws {
        let scheduler = DeviceCommandScheduler()
        let streamStarted = expectation(description: "stream started")
        let uiStarted = expectation(description: "ui started")
        let releaseStream = SchedulerTestGate()

        async let streaming: Void = scheduler.enqueue(udid: "SIM-1", kind: .streaming) {
            streamStarted.fulfill()
            await releaseStream.wait()
        }
        await fulfillment(of: [streamStarted], timeout: 1)

        async let ui: Void = scheduler.enqueue(udid: "SIM-1", kind: .ui) {
            uiStarted.fulfill()
        }
        await fulfillment(of: [uiStarted], timeout: 1)
        await releaseStream.open()

        _ = try await (streaming, ui)
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

private actor SchedulerTestGate {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            if opened {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }

    func open() {
        guard !opened else { return }
        opened = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
