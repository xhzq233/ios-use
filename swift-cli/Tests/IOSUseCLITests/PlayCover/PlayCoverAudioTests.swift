import XCTest
@testable import IOSUseCLI

final class PlayCoverAudioTests: XCTestCase {
    func testStrictAudioParsing() throws {
        guard case .config(let options) = try CLIParser.parse(["config", "--mac", "--volume", "25", "--mute", "on"]) else {
            return XCTFail("Expected config")
        }
        XCTAssertEqual(options.macVolume, 25)
        XCTAssertEqual(options.macMute, true)
        for value in ["-1", "101", "1.5", "NaN", "inf", "1e1", "+1", "２５", "", " 2"] {
            XCTAssertThrowsError(try CLIParser.parse(["config", "--mac", "--volume", value]), value)
        }
        XCTAssertThrowsError(try CLIParser.parse(["config", "--volume", "25"]))
        XCTAssertThrowsError(try CLIParser.parse(["config", "--mac", "--mute", "yes"]))
        XCTAssertThrowsError(try CLIParser.parse(["input", "--volume", "25"]))
    }

    func testAudioPersistenceMuteRestoreAndIndependentHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["IOS_USE_HOME": root.path]
        let paths = IOSUsePaths.resolve(environment: environment)
        let cli = IOSUseCLI(environment: environment)
        func state() throws -> PlayCoverAudioState { try .load(file: .init(fileURLWithPath: paths.playcover + "/audio.json")) }
        XCTAssertEqual(try state(), PlayCoverAudioState(volume: 100, muted: false))
        XCTAssertEqual(cli.run(arguments: ["config", "--mac", "--volume", "25", "--mute", "on"]).exitCode, 0)
        XCTAssertEqual(try state(), PlayCoverAudioState(volume: 25, muted: true))
        XCTAssertEqual(cli.run(arguments: ["config", "--mac", "--volume", "60"]).exitCode, 0)
        XCTAssertEqual(try state(), PlayCoverAudioState(volume: 60, muted: true))
        let restartedCLI = IOSUseCLI(environment: environment)
        XCTAssertEqual(restartedCLI.run(arguments: ["config", "--mac", "--mute", "off"]).exitCode, 0)
        XCTAssertEqual(try state(), PlayCoverAudioState(volume: 60, muted: false))
        XCTAssertNotEqual(cli.run(arguments: ["config", "--mac", "--volume", "25", "--device-model", "unknown"]).exitCode, 0)
        XCTAssertEqual(try state().volume, 60)
        XCTAssertEqual(cli.run(arguments: ["config", "--mac", "--volume", "35", "--device-model", "iphone-se", "--json"]).exitCode, 0)
        XCTAssertEqual(try state().volume, 35)
        XCTAssertEqual(try PlayCoverDevicePreset.configured(paths: paths).name, "iphone-se")
        let other = IOSUsePaths.resolve(environment: ["IOS_USE_HOME": root.appendingPathComponent("other").path])
        XCTAssertEqual(try PlayCoverAudioState.load(file: PlayCoverAudioState.file(paths: other)).volume, 100)
        let launch = PlayCoverSlotLauncher.launchEnvironmentForTesting(source: [:],
            sessionID: "audio-test", runtimeSocketPath: "/tmp/audio-test.sock", installRevision: "test",
            playChainPath: "/tmp/audio-test-chain", deviceConfigurationPath: paths.playcover + "/device.json")
        XCTAssertEqual(launch["IOS_USE_MAC_VOLUME"], "35")
        XCTAssertEqual(launch["IOS_USE_MAC_MUTE"], "0")
    }
}
