// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SoundChannels",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "SoundChannels", targets: ["SoundChannels"])],
    targets: [
        .target(name: "AudioBridge", publicHeadersPath: "include"),
        .executableTarget(name: "SoundChannels", dependencies: ["AudioBridge"]),
        .testTarget(name: "AudioBridgeTests", dependencies: ["AudioBridge"]),
        .testTarget(name: "AudioRouteTests", dependencies: ["SoundChannels", "AudioBridge"])
    ],
    swiftLanguageModes: [.v5]
)
