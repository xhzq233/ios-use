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
        .package(
            url: "https://github.com/jpsim/Yams.git",
            exact: "5.1.3"
        ),
    ],
    targets: [
        .target(
            name: "PlayCoverUpstream",
            dependencies: [
                .product(name: "Injection", package: "inject"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "PlayCover",
            exclude: ["Model/PlayApp.swift"],
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
                "Model/PlayRules.swift",
                "Headless/PlayCoverUpstreamEngine.swift",
                "Headless/PlayCoverPrepareDifferential.swift",
            ],
            resources: [
                .copy("Rules/default.yaml"),
            ]
        ),
        .testTarget(
            name: "PlayCoverUpstreamTests",
            dependencies: ["PlayCoverUpstream"],
            path: "Tests"
        ),
    ]
)
