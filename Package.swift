// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetalComposer",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // The engine, for apps that play .mcomp compositions (e.g. a VJ app). No editor UI.
        .library(name: "MetalComposerKit", targets: ["MetalComposerKit"]),
        // The editor UI, shared by the Mac app and the iPad app.
        .library(name: "MetalComposerEditor", targets: ["MetalComposerEditor"]),
        .executable(name: "MetalComposer", targets: ["MetalComposer"]),
        // MCP server that lets an AI build and render compositions (docs/decisions/0001-mcp-server.md).
        .executable(name: "mirage-mcp", targets: ["MirageMCP"]),
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
        // The MCP server's protocol handling and tools (a separate target so tests can use them).
        .target(
            name: "MirageMCPCore",
            dependencies: ["MetalComposerKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MirageMCP",
            dependencies: ["MirageMCPCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MetalComposerTests",
            dependencies: ["MetalComposerKit", "MetalComposerEditor", "MirageMCPCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
