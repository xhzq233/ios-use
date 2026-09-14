// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "IOSUseProtocol",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "IOSUseProtocol", targets: ["IOSUseProtocol"])
    ],
    dependencies: [
        .package(url: "https://github.com/apache/fory.git", revision: "affbd38a5869a3ec4deaf51a762bedf2c90400d5")
    ],
    targets: [
        .target(
            name: "IOSUseProtocol",
            dependencies: [
                .product(name: "Fory", package: "fory")
            ],
            swiftSettings: [
                .define("FORY_SWIFT_MACRO")
            ]
        )
    ]
)
