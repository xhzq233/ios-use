// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "IOSUseSwiftCLI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "IOSUseProtocol", targets: ["IOSUseProtocol"]),
        .library(name: "IOSUseCLI", targets: ["IOSUseCLI"]),
        .executable(name: "ios-use-swift", targets: ["IOSUseSwiftCLI"])
    ],
    targets: [
        .target(name: "IOSUseProtocol"),
        .target(
            name: "IOSUseCLI",
            dependencies: ["IOSUseProtocol"]
        ),
        .executableTarget(
            name: "IOSUseSwiftCLI",
            dependencies: ["IOSUseCLI"]
        ),
        .testTarget(
            name: "IOSUseCLITests",
            dependencies: ["IOSUseCLI", "IOSUseProtocol"]
        )
    ]
)
