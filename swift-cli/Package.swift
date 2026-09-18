// swift-tools-version: 5.9

import PackageDescription

#if os(Linux)
import Foundation

// Linux shares the remote Driver and Apple device services with macOS.
// Local USB discovery, Simulator and the Mac App runtime remain macOS-only.
let linuxSources = [
    "CLI/CLIHelp.swift",
    "CLI/CLIParser.swift",
    "CLI/CLIResult.swift",
    "CLI/CommandModels.swift",
    "CLI/MachineOutput.swift",
    "CLI/Version.swift",
    "CLI/DriverDispatch.swift",
    "Commands/Driver/DriverCommandExecutor.swift",
    "Commands/Driver/DriverMachineOutput.swift",
    "Commands/Driver/DriverOutput.swift",
    "Commands/Driver/ScreenshotArtifactService.swift",
    "Commands/Host/SessionService.swift",
    "Commands/Host/AppLifecycleService.swift",
    "Services/DriverRuntime/DriverClient.swift",
    "Services/DriverRuntime/DriverSessionStore.swift",
    "Services/DriverRuntime/DeviceContextStore.swift",
    "Services/DriverRuntime/DeviceCommandLock.swift",
    "Services/DriverRuntime/SessionOperationLock.swift",
    "Services/Logs/CLILogService.swift",
    "Support/ArtifactPaths.swift",
    "Support/IOSUsePaths.swift",
    "Support/RuntimeJSONValue.swift",
    "Support/POSIX.swift",
    "Services/RealDevice/TestManager/RealDeviceXCTestDriverLifecycle.swift",
    "Services/RealDevice/TestManager/XCTestManagerAuthorization.swift",
    "Services/RealDevice/TestManager/DTXConnectionIdleListener.swift",
    "Services/RealDevice/TestManager/XCTestConfigurationPayload.swift",
    "Services/RealDevice/TestManager/DVTInstrumentsClient.swift",
    "Services/RealDevice/TestManager/XCTestExecCallbackListener.swift",
    "Services/RealDevice/TestManager/DVTInstrumentsContract.swift",
    "Services/RealDevice/CoreDevice/CoreDeviceAppService.swift",
    "Services/RealDevice/CoreDevice/RemoteXPCClient.swift",
    "Services/RealDevice/CoreDevice/CoreDeviceUserSpaceTCP.swift",
    "Services/RealDevice/CoreDevice/CoreDeviceTunnelClient.swift",
    "Services/RealDevice/CoreDevice/CoreDeviceOpenStdIOSocket.swift",
    "Services/RealDevice/CoreDevice/CoreDeviceRequestBuilder.swift",
    "Services/RealDevice/CoreDevice/CoreDeviceURLLauncher.swift",
    "Services/RealDevice/CoreDevice/CoreDeviceDisplayInfoService.swift",
    "Services/RealDevice/Transport/LockdownClient.swift",
    "Services/RealDevice/Transport/LockdownSession.swift",
    "Services/RealDevice/Transport/RemoteDeviceConnection.swift",
    "Services/RealDevice/Transport/UsbmuxClient.swift",
    "Services/RealDevice/Transport/DeviceStream.swift",
    "Services/RealDevice/Transport/PairRecordStore.swift",
    "Services/RealDevice/Installation/InstallationProxyClient.swift",
    "Services/RealDevice/Installation/AfcClient.swift",
    "Services/DriverRuntime/DriverLifecycleService.swift",
    "Services/DriverRuntime/XCTestSessionHolderService.swift",
    "Services/DriverRuntime/XCTestSessionHolderControlSocket.swift",
    "Services/Logs/AppLogCaptureService.swift",
    "Support/SignalHandling.swift",
    "Commands/Host/AppManagementService.swift",
    "Commands/Host/RemoteDeviceService.swift",
    "Commands/Host/OpenURLService.swift",
    "Support/Shell.swift",
    "Linux/IOSUseCLI.swift",
    "Linux/ScreenshotCaptureCoordinator.swift",
]
let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/IOSUseCLI")
let excludedSources = (FileManager.default.enumerator(atPath: sourceRoot.path)?.allObjects as? [String] ?? [])
    .filter { $0.hasSuffix(".swift") && !linuxSources.contains($0) }
let linuxTests = ["DeviceStreamLifecycleTests.swift", "RemoteDriverConnectionTests.swift", "FakeDriverServer.swift", "CLIParserTests.swift", "LinuxScreenshotTests.swift", "DeviceArchiveDecodingTests.swift"]
let testRoot = sourceRoot.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tests/IOSUseCLITests")
let excludedTests = (FileManager.default.enumerator(atPath: testRoot.path)?.allObjects as? [String] ?? [])
    .filter { $0.hasSuffix(".swift") && !linuxTests.contains($0) }
let package = Package(
    name: "IOSUseSwiftCLI",
    products: [.library(name: "IOSUseCLI", targets: ["IOSUseCLI"]),
               .executable(name: "ios-use-swift", targets: ["IOSUseSwiftCLI"])],
    dependencies: [.package(path: "../shared/IOSUseProtocol"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.28.0")],
    targets: [
        .target(name: "IOSUseCLI", dependencies: [.product(name: "IOSUseProtocol", package: "IOSUseProtocol"), .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"), .product(name: "NIOSSL", package: "swift-nio-ssl")],
                exclude: excludedSources, sources: linuxSources),
        .executableTarget(name: "IOSUseSwiftCLI", dependencies: ["IOSUseCLI"]),
        .testTarget(name: "IOSUseCLITests", dependencies: ["IOSUseCLI", "IOSUseProtocol", .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"), .product(name: "NIOSSL", package: "swift-nio-ssl")],
                    exclude: excludedTests, sources: linuxTests)
    ]
)
#else
let package = Package(
    name: "IOSUseSwiftCLI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "IOSUseCLI", targets: ["IOSUseCLI"]),
        .executable(name: "ios-use-swift", targets: ["IOSUseSwiftCLI"])
    ],
    dependencies: [
        .package(path: "../shared/IOSUseProtocol"),
        .package(path: "../ThirdParty/PlayCover"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.28.0")
    ],
    targets: [
        .target(
            name: "IOSUsePlayDevice",
            path: "Sources/IOSUsePlayDevice",
            publicHeadersPath: "include"
        ),
        .target(
            name: "IOSUseCLI",
            dependencies: [
                "IOSUsePlayDevice",
                .product(
                    name: "PlayCoverUpstream",
                    package: "PlayCover"
                ),
                .product(name: "IOSUseProtocol", package: "IOSUseProtocol"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ],
            exclude: ["Linux"]
        ),
        .executableTarget(
            name: "IOSUseSwiftCLI",
            dependencies: ["IOSUseCLI"]
        ),
        .testTarget(
            name: "IOSUseCLITests",
            dependencies: [
                "IOSUseCLI",
                "IOSUsePlayDevice",
                "IOSUseProtocol",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ]
        )
    ]
)

#endif
