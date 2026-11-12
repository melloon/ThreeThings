// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ThreeThings",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ThreeThings", path: "Sources/ThreeThings"),
        .testTarget(name: "ThreeThingsTests", dependencies: ["ThreeThings"], path: "Tests/ThreeThingsTests"),
    ]
)
