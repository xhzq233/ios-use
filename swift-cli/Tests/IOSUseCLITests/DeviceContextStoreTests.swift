import XCTest
@testable import IOSUseCLI

final class DeviceContextStoreTests: XCTestCase {
    func testTwoRunningContextsRequireExplicitSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IOSUsePaths.resolve(environment: [
            "IOS_USE_HOME": root.path,
        ])
        let first = try paths.deviceContext(
            DeviceContextStore.realDeviceID("DEVICE-1")
        )
        let second = try paths.deviceContext(
            DeviceContextStore.realDeviceID("DEVICE-2")
        )
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "DEVICE-1",
                deviceName: "First",
                deviceVersion: "1",
                deviceType: "real"
            ),
            paths: first
        )
        try SessionService.writeDriverLock(
            info: SessionService.Info(
                udid: "DEVICE-2",
                deviceName: "Second",
                deviceVersion: "1",
                deviceType: "real"
            ),
            paths: second
        )

        XCTAssertEqual(DeviceContextStore.sessions(paths: paths).count, 2)
        XCTAssertThrowsError(
            try DeviceContextStore.activeContext(
                explicitDeviceID: nil,
                paths: paths
            )
        )
        XCTAssertEqual(
            try DeviceContextStore.activeContext(
                explicitDeviceID: "DEVICE-2",
                paths: paths
            ).info.udid,
            "DEVICE-2"
        )
    }

    func testExplicitSelectionPreservesLegacyPriorityAndRefreshesTarget() throws {
        try withTemporaryPaths { paths in
            let targetPaths = try paths.deviceContext("DEVICE-A")
            let legacy = SessionService.Info(
                udid: "DEVICE-A", deviceName: "Legacy", deviceVersion: "1",
                deviceType: "real", startedAt: 1
            )
            let replacement = SessionService.Info(
                udid: "DEVICE-A", deviceName: "Replacement", deviceVersion: "2",
                deviceType: "real", startedAt: 2
            )
            try SessionService.writeDriverLock(info: legacy, paths: paths)
            try SessionService.writeDriverLock(info: replacement, paths: targetPaths)

            let selectedLegacy = try DeviceContextStore.activeContext(
                explicitDeviceID: "DEVICE-A", paths: paths
            )
            XCTAssertEqual(selectedLegacy.paths, paths)
            XCTAssertEqual(selectedLegacy.info, legacy)
            XCTAssertTrue(selectedLegacy.legacy)
            XCTAssertEqual(DeviceContextStore.sessions(paths: paths).count, 1)

            try Data("{".utf8).write(to: URL(fileURLWithPath: paths.driverLock))
            let selectedReplacement = try DeviceContextStore.activeContext(
                explicitDeviceID: "DEVICE-A", paths: paths
            )
            XCTAssertEqual(selectedReplacement.paths, targetPaths)
            XCTAssertEqual(selectedReplacement.info, replacement)
            XCTAssertFalse(selectedReplacement.legacy)

            SessionService.clear(paths: targetPaths)
            XCTAssertThrowsError(try DeviceContextStore.activeContext(
                explicitDeviceID: "DEVICE-A", paths: paths
            ))
        }
    }

    func testExplicitAliasesAndImpliedUDIDKeepTheirSelectionRules() throws {
        try withTemporaryPaths { paths in
            let info = SessionService.Info(
                udid: "F0A52F2D-67F9-4D3B-AD5E-730F4B8D8123",
                deviceName: "Simulator", deviceVersion: "1",
                deviceType: "simulator", startedAt: 1
            )
            let first = try paths.deviceContext("Desk-A")
            let second = try paths.deviceContext("Desk-B")
            try SessionService.writeDriverLock(info: info, paths: first)
            try SessionService.writeDriverLock(info: info, paths: second)

            XCTAssertEqual(try DeviceContextStore.activeContext(
                explicitDeviceID: "Desk-B", impliedUDID: info.udid, paths: paths
            ).paths, second)
            XCTAssertEqual(try DeviceContextStore.activeContext(
                explicitDeviceID: nil, impliedUDID: info.udid, paths: paths
            ).paths, first)
            for selector in [info.udid, "desk-a", "MISSING"] {
                XCTAssertThrowsError(try DeviceContextStore.activeContext(
                    explicitDeviceID: selector, impliedUDID: info.udid, paths: paths
                ))
            }
            XCTAssertThrowsError(try DeviceContextStore.activeContext(
                explicitDeviceID: nil, impliedUDID: "MISSING", paths: paths
            ))

            SessionService.clear(paths: second)
            XCTAssertEqual(try DeviceContextStore.activeContext(
                explicitDeviceID: nil, impliedUDID: "MISSING", paths: paths
            ).paths, first)
            try Data("{".utf8).write(to: URL(fileURLWithPath: first.driverLock))
            XCTAssertThrowsError(try DeviceContextStore.activeContext(
                explicitDeviceID: "Desk-A", paths: paths
            ))
            XCTAssertThrowsError(try DeviceContextStore.activeContext(
                explicitDeviceID: nil, paths: paths
            ))
        }
    }

    func testExplicitSelectionRejectsInvalidIDsBeforeResolvingPaths() throws {
        try withTemporaryPaths { paths in
            let targetPaths = try paths.deviceContext("DEVICE-A")
            try SessionService.writeDriverLock(info: SessionService.Info(
                udid: "DEVICE-A", deviceName: "Phone", deviceVersion: "1",
                deviceType: "real", startedAt: 1
            ), paths: targetPaths)
            for selector in [
                "", ".", "..", "../DEVICE-A", "/DEVICE-A", "DEVICE-A/",
                "DEVICE-A\\", "DEVICE-A\0", " DEVICE-A", "DEVICE-A\n",
                String(repeating: "a", count: 513),
            ] {
                XCTAssertThrowsError(try DeviceContextStore.activeContext(
                    explicitDeviceID: selector, paths: paths
                )) { error in
                    guard case CLIParseError.invalidValue = error else {
                        return XCTFail("Expected an invalid Device ID error")
                    }
                }
            }
            XCTAssertEqual(try DeviceContextStore.activeContext(
                explicitDeviceID: "DEVICE-A", paths: paths
            ).paths, targetPaths)
        }
    }

    func testExplicitMacSelectionPreservesLegacyPriority() throws {
        try withTemporaryPaths { paths in
            let targetPaths = try paths.deviceContext("mac")
            let info = try makeMacSession(paths: paths)
            try SessionService.writeDriverLock(info: info, paths: targetPaths)
            let selected = try DeviceContextStore.activeContext(
                explicitDeviceID: "mac", paths: paths
            )
            XCTAssertEqual(selected.info, info)
            XCTAssertEqual(selected.paths, targetPaths)
            XCTAssertFalse(selected.legacy)
            XCTAssertThrowsError(try DeviceContextStore.activeContext(
                explicitDeviceID: "MAC", paths: paths
            ))

            try SessionService.writeDriverLock(info: info, paths: paths)
            let selectedLegacy = try DeviceContextStore.activeContext(
                explicitDeviceID: "mac", paths: paths
            )
            XCTAssertEqual(selectedLegacy.paths, paths)
            XCTAssertTrue(selectedLegacy.legacy)
        }
    }

    private func withTemporaryPaths(_ body: (IOSUsePaths) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(resolvePlayCoverTestPaths(environment: ["IOS_USE_HOME": root.path]))
    }

    private func makeMacSession(paths: IOSUsePaths) throws -> SessionService.Info {
        let bundleIdentifier = "com.example.context"
        let slot = URL(fileURLWithPath: paths.playcoverApps)
            .appendingPathComponent(bundleIdentifier)
        let app = slot.appendingPathComponent("App.app")
        let executable = app.appendingPathComponent("Demo")
        for relativePath in [
            "Demo", "Frameworks/IOSUsePlayRuntime.framework/IOSUsePlayRuntime",
            "Frameworks/IOSUseFridaEngine.framework/IOSUseFridaEngine",
        ] {
            let file = app.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("fixture".utf8).write(to: file)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path
        )
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": bundleIdentifier, "CFBundleExecutable": "Demo",
        ], format: .binary, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        let metadata = PlayCoverSlotMetadata(
            bundleIdentifier: bundleIdentifier, executableRelativePath: "Demo",
            installRevision: String(repeating: "a", count: 64),
            sourceContentHash: String(repeating: "b", count: 64),
            signingCertificateSHA256: String(repeating: "B", count: 64)
        )
        let metadataURL = slot.appendingPathComponent("slot.json")
        try JSONEncoder().encode(metadata).write(to: metadataURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: metadataURL.path
        )
        try FileManager.default.createDirectory(
            atPath: paths.playcoverRun, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let sessionID = UUID().uuidString
        return SessionService.Info(
            udid: PlayCoverSessionService.deviceType, deviceName: "Mac",
            deviceVersion: "1", deviceType: PlayCoverSessionService.deviceType,
            startedAt: 1, runnerPid: 42, sessionIdentifier: sessionID,
            bundleId: bundleIdentifier, macAppPath: app.path,
            macExecutablePath: executable.path, macInstallRevision: metadata.installRevision,
            macRuntimeSocketPath: try paths.macRuntimeSocketPath(sessionID: sessionID)
        )
    }
}
