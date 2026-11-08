// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SoundControl",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "SoundControl", path: "Sources/SoundControl"),
        .testTarget(name: "SoundControlTests", dependencies: ["SoundControl"], path: "Tests/SoundControlTests")
    ]
)
