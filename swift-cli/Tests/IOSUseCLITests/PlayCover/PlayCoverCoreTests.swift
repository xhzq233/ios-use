import Foundation
import XCTest
@testable import IOSUseCLI

final class PlayCoverCoreTests: XCTestCase {
    func testVPhoneProfileIsInternallyConsistentAndStable() throws {
        let profile = PlayCoverDeviceProfile.vphoneDefault

        XCTAssertNoThrow(try profile.validate())
        XCTAssertEqual(profile.logicalWidth, 430)
        XCTAssertEqual(profile.logicalHeight, 932)
        XCTAssertEqual(profile.nativeWidth, 1290)
        XCTAssertEqual(profile.nativeHeight, 2796)
        XCTAssertEqual(profile.scale, 3)
        XCTAssertEqual(try profile.stableHash().count, 64)
        XCTAssertEqual(try profile.stableHash(), try profile.stableHash())
    }

    func testProfileRejectsInconsistentNativeGeometry() {
        let profile = PlayCoverDeviceProfile(
            identifier: "bad",
            productType: "iPhone16,2",
            hardwareTarget: "A2849",
            logicalWidth: 430,
            logicalHeight: 932,
            nativeWidth: 1289,
            nativeHeight: 2796,
            scale: 3,
            pixelsPerInch: 460,
            orientation: "portrait"
        )

        XCTAssertThrowsError(try profile.validate()) { error in
            XCTAssertEqual(
                error as? PlayCoverBackendError,
                .invalidProfile("native size must equal logical size multiplied by scale")
            )
        }
    }

    func testMachOConversionUsesVerifiedPaddingAndIsIdempotent() throws {
        let url = try makeTemporaryMachO()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let originalPayload = try payloadByte(at: url)

        let before = try PlayCoverMachO.inspect(at: url)
        XCTAssertEqual(before.platform, PlayCoverMachO.platformIPhoneOS)
        XCTAssertFalse(before.runtimeInjected)
        XCTAssertFalse(before.encrypted)

        let converted = try PlayCoverMachO.convert(at: url, injectRuntime: true)
        XCTAssertTrue(converted.isMacCatalyst)
        XCTAssertTrue(converted.runtimeInjected)
        XCTAssertEqual(converted.commandCount, before.commandCount + 1)
        XCTAssertEqual(try payloadByte(at: url), originalPayload)

        let convertedAgain = try PlayCoverMachO.convert(at: url, injectRuntime: true)
        XCTAssertEqual(convertedAgain.commandCount, converted.commandCount)
        XCTAssertEqual(convertedAgain.commandBytes, converted.commandBytes)
        XCTAssertEqual(try payloadByte(at: url), originalPayload)
    }

    func testEncryptedMachOIsRejectedWithoutMutation() throws {
        let url = try makeTemporaryMachO(encrypted: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(try PlayCoverMachO.convert(at: url, injectRuntime: true)) { error in
            XCTAssertEqual(error as? PlayCoverBackendError, .encryptedMachO(url.path))
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testNonZeroConsumedPaddingIsRejectedWithoutMutation() throws {
        let url = try makeTemporaryMachO(nonZeroPadding: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(try PlayCoverMachO.convert(at: url, injectRuntime: true)) { error in
            XCTAssertEqual(error as? PlayCoverBackendError, .nonZeroLoadCommandPadding(url.path))
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testInsufficientPaddingIsRejectedWithoutMutation() throws {
        let url = try makeTemporaryMachO(firstSectionOffset: 248)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(try PlayCoverMachO.convert(at: url, injectRuntime: true)) { error in
            guard case .insufficientLoadCommandSpace = error as? PlayCoverBackendError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testAppInspectionIsReadOnlyAndUsesIOSUsePathsForBackendState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-playcover-app-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = app.appendingPathComponent("Demo")
        let fixture = makeMachOData()
        try fixture.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.demo",
            "CFBundleExecutable": "Demo",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Info.plist"))
        let before = try Data(contentsOf: executable)

        let inspection = try PlayCoverService.inspect(appPath: app.path)
        XCTAssertEqual(inspection.bundleIdentifier, "com.example.demo")
        XCTAssertEqual(inspection.profile.logicalWidth, 430)
        XCTAssertEqual(try Data(contentsOf: executable), before)

        let paths = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root.path])
        XCTAssertEqual(paths.playcover, root.appendingPathComponent("playcover").path)
        XCTAssertEqual(paths.playcoverHello, root.appendingPathComponent("playcover/hello").path)
        XCTAssertEqual(
            paths.playcoverLastPrepared,
            root.appendingPathComponent("playcover/last-prepared.json").path
        )
        XCTAssertEqual(
            paths.playcoverPrepared,
            root.appendingPathComponent("playcover/prepared").path
        )
        XCTAssertEqual(
            paths.playcoverRuntime,
            root.appendingPathComponent(
                "playcover/IOSUsePlayRuntime.framework"
            ).path
        )
    }

    func testRuntimeCandidatesPreferManagedHomeThenExecutableLayouts() {
        let paths = IOSUsePaths.resolve(
            environment: ["IOS_USE_HOME": "/state/ios-use"]
        )

        XCTAssertEqual(
            PlayCoverManagedAppService.runtimeCandidates(
                paths: paths,
                executablePath: "/opt/ios-use/bin/ios-use"
            ),
            [
                "/state/ios-use/playcover/IOSUsePlayRuntime.framework",
                "/opt/ios-use/bin/.ios-use/playcover/IOSUsePlayRuntime.framework",
                "/opt/ios-use/share/ios-use/playcover/IOSUsePlayRuntime.framework",
            ]
        )
    }

    func testLaunchEnvironmentDoesNotForwardUnrelatedCredentials() {
        let environment = PlayCoverService.sanitizedLaunchEnvironment(source: [
            "HOME": "/Users/test",
            "TMPDIR": "/tmp/example",
            "PATH": "/private/tooling",
            "API_TOKEN": "do-not-forward",
            "IOS_USE_HOME": "/private/state",
        ])

        XCTAssertEqual(environment["HOME"], "/Users/test")
        XCTAssertEqual(environment["TMPDIR"], "/tmp/example")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertNil(environment["API_TOKEN"])
        XCTAssertNil(environment["IOS_USE_HOME"])
    }

    private func makeTemporaryMachO(
        encrypted: Bool = false,
        nonZeroPadding: Bool = false,
        firstSectionOffset: Int = 4096
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-use-playcover-macho-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Demo")
        try makeMachOData(
            encrypted: encrypted,
            nonZeroPadding: nonZeroPadding,
            firstSectionOffset: firstSectionOffset
        ).write(to: url)
        return url
    }

    private func makeMachOData(
        encrypted: Bool = false,
        nonZeroPadding: Bool = false,
        firstSectionOffset: Int = 4096
    ) -> Data {
        let segmentCommandSize = 72 + 80
        let buildVersionSize = 24
        let encryptionSize = 24
        let commandsSize = segmentCommandSize + buildVersionSize + encryptionSize
        var data = Data(repeating: 0, count: max(firstSectionOffset + 16, 512))

        writeUInt32(0xfeedfacf, to: &data, at: 0)
        writeUInt32(0x0100_000c, to: &data, at: 4)
        writeUInt32(0, to: &data, at: 8)
        writeUInt32(2, to: &data, at: 12)
        writeUInt32(3, to: &data, at: 16)
        writeUInt32(UInt32(commandsSize), to: &data, at: 20)

        var cursor = 32
        writeUInt32(0x19, to: &data, at: cursor)
        writeUInt32(UInt32(segmentCommandSize), to: &data, at: cursor + 4)
        writeUInt32(1, to: &data, at: cursor + 64)
        writeUInt32(UInt32(firstSectionOffset), to: &data, at: cursor + 72 + 48)
        cursor += segmentCommandSize

        writeUInt32(0x32, to: &data, at: cursor)
        writeUInt32(UInt32(buildVersionSize), to: &data, at: cursor + 4)
        writeUInt32(2, to: &data, at: cursor + 8)
        writeUInt32(0x000d_0000, to: &data, at: cursor + 12)
        writeUInt32(0x001a_0000, to: &data, at: cursor + 16)
        cursor += buildVersionSize

        writeUInt32(0x2c, to: &data, at: cursor)
        writeUInt32(UInt32(encryptionSize), to: &data, at: cursor + 4)
        writeUInt32(encrypted ? 1 : 0, to: &data, at: cursor + 16)
        cursor += encryptionSize

        if nonZeroPadding {
            data[cursor] = 0x7f
        }
        data[firstSectionOffset] = 0xaa
        return data
    }

    private func payloadByte(at url: URL) throws -> UInt8 {
        try Data(contentsOf: url)[4096]
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
