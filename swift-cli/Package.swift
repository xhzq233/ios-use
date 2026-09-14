// swift-tools-version: 5.9

import PackageDescription

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
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        // Supplies QuickJS C sources through SPM; MCP embeds the C API directly.
        .package(url: "https://github.com/zqqf16/QuickJS-Swift.git", revision: "50eb132d6bc89736f478cf8336948fb62133a264"),
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
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "QuickJS", package: "QuickJS-Swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ]
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
