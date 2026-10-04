// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetalComposer",
    platforms: [.macOS(.v14)],
    products: [
        // The engine, for apps that play .mcomp compositions (e.g. a VJ app). No editor UI.
        .library(name: "MetalComposerKit", targets: ["MetalComposerKit"]),
        .executable(name: "MetalComposer", targets: ["MetalComposer"]),
    ],
    targets: [
        // Data model, patches, evaluation and Metal rendering.
        .target(
            name: "MetalComposerKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The editor app's UI and document handling.
        .target(
            name: "MetalComposerEditor",
            dependencies: ["MetalComposerKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Thin executable that launches the editor.
        .executableTarget(
            name: "MetalComposer",
            dependencies: ["MetalComposerEditor"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MetalComposerTests",
            dependencies: ["MetalComposerKit", "MetalComposerEditor"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
