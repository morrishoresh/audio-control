// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AudioControl",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(name: "AudioControl", path: "Sources/AudioControl")
    ]
)
