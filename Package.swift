// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetalComposer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MetalComposer",
            path: "Sources/MetalComposer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MetalComposerTests",
            dependencies: ["MetalComposer"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
