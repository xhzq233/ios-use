// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PlayCoverUpstream",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "PlayCoverUpstream",
            targets: ["PlayCoverUpstream"]
        )
    ],
    dependencies: [
        .package(path: "../inject"),
    ],
    targets: [
        .target(
            name: "PlayCoverUpstream",
            dependencies: [
                .product(name: "Injection", package: "inject"),
            ],
            path: "PlayCover",
            exclude: [
                "Model/PlayApp.swift",
                "Utils/Extensions/PlayAppExtensions.swift",
            ],
            sources: [
                "PlayCoverError.swift",
                "AppInstaller/Installer.swift",
                "Headless/HeadlessSupport.swift",
                "Utils/Extensions/DataExtensions.swift",
                "Utils/Extensions/FileExtensions.swift",
                "Utils/Extensions/URLExtensions.swift",
                "Utils/Macho.swift",
                "Utils/Shell.swift",
                "Utils/Entitlements.swift",
                "Utils/KeyCover.swift",
                "Utils/PlayTools.swift",
                "Utils/SystemConfig.swift",
                "Model/AppInfo.swift",
                "Model/BaseApp.swift",
                "Headless/PlayCoverUpstreamEngine.swift",
                "Headless/PlayCoverPrepareDifferential.swift",
            ]
        ),
        .testTarget(
            name: "PlayCoverUpstreamTests",
            dependencies: ["PlayCoverUpstream"],
            path: "Tests"
        ),
    ]
)
