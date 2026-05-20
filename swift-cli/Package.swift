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
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.28.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3")
    ],
    targets: [
        .target(
            name: "IOSUseCLI",
            dependencies: [
                .product(name: "IOSUseProtocol", package: "IOSUseProtocol"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Yams", package: "Yams")
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
