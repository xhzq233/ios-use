// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SelfRunnerCore", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "SelfRunnerCore", targets: ["SelfRunnerCore"])],
    targets: [.target(name: "SelfRunnerCore"), .testTarget(name: "SelfRunnerCoreTests", dependencies: ["SelfRunnerCore"])])
