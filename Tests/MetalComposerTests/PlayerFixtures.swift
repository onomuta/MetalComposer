import AppKit
import Foundation
@testable import MetalComposerKit

/// Builds .mcomp data with the engine's internal API, for the public-API tests in PlayerTests.
enum PlayerFixtures {
    private static func data(_ build: (Graph) -> Void) -> Data {
        let g = Graph()
        build(g)
        return try! JSONEncoder().encode(g.record())
    }

    /// Clear whose red channel comes from a top-level "Red" parameter (default 0.25).
    static func redParameter() -> Data {
        data { g in
            let red = g.put(PublishedInputPatch.self, 0, 0, ["default": .number(0.25)], name: "Red")
            let flag = g.put(PublishedInputPatch.self, 0, 100, name: "Flag")
            flag.portType = .bool
            let color = g.put(RGBColorPatch.self, 200, 0, ["g": .number(0), "b": .number(0)])
            let clear = g.put(ClearPatch.self, 400, 0)
            g.link(red, "value", color, "r")
            g.link(color, "color", clear, "color")
        }
    }

    /// A full-screen billboard of the image at a relative path.
    static func relativeImage(_ path: String) -> Data {
        data { g in
            let image = g.put(ImageImporterPatch.self, 0, 0, ["path": .string(path)])
            let board = g.put(BillboardPatch.self, 200, 0, ["width": .number(4), "height": .number(4)])
            g.link(image, "image", board, "image")
        }
    }

    static func futureVersion() -> Data {
        Data(#"{"version": 99, "nodes": [], "connections": []}"#.utf8)
    }

    /// Writes a solid-color PNG.
    static func writePNG(to url: URL, red: UInt8, green: UInt8, blue: UInt8) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32)!
        for i in 0..<64 { rep.bitmapData![i] = [red, green, blue, 255][i % 4] }
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}
