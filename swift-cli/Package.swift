// swift-tools-version: 5.9

import PackageDescription

#if os(Linux)
import Foundation

// Linux consumes an externally managed XCTest driver over TCP. Local Apple
// backends are deliberately outside this build; parsing, actions and wire types
// remain shared with the macOS CLI.
let tcpSources = [
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
    "Commands/Host/TCPAttachService.swift",
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
    "Linux/IOSUseCLI.swift",
    "Linux/ScreenshotCaptureCoordinator.swift",
]
let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/IOSUseCLI")
let excludedSources = (FileManager.default.enumerator(atPath: sourceRoot.path)?.allObjects as? [String] ?? [])
    .filter { $0.hasSuffix(".swift") && !tcpSources.contains($0) }
let tcpTests = ["TCPAttachTests.swift", "FakeDriverServer.swift", "CLIParserTests.swift"]
let testRoot = sourceRoot.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tests/IOSUseCLITests")
let excludedTests = (FileManager.default.enumerator(atPath: testRoot.path)?.allObjects as? [String] ?? [])
    .filter { $0.hasSuffix(".swift") && !tcpTests.contains($0) }
let package = Package(
    name: "IOSUseSwiftCLI",
    products: [.library(name: "IOSUseCLI", targets: ["IOSUseCLI"]),
               .executable(name: "ios-use-swift", targets: ["IOSUseSwiftCLI"])],
    dependencies: [.package(path: "../shared/IOSUseProtocol")],
    targets: [
        .target(name: "IOSUseCLI", dependencies: [.product(name: "IOSUseProtocol", package: "IOSUseProtocol")],
                exclude: excludedSources, sources: tcpSources),
        .executableTarget(name: "IOSUseSwiftCLI", dependencies: ["IOSUseCLI"]),
        .testTarget(name: "IOSUseCLITests", dependencies: ["IOSUseCLI", "IOSUseProtocol"],
                    exclude: excludedTests, sources: tcpTests)
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
