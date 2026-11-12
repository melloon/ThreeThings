// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OneThing",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "OneThing", path: "Sources/OneThing"),
        .testTarget(name: "OneThingTests", dependencies: ["OneThing"], path: "Tests/OneThingTests"),
    ]
)
