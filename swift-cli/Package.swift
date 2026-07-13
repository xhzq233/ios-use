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
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.28.0")
    ],
    targets: [
        .target(
            name: "IOSUseCLI",
            dependencies: [
                .product(name: "IOSUseProtocol", package: "IOSUseProtocol"),
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
                "IOSUseProtocol",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ]
        )
    ]
)
