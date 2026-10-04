import AppKit
import Foundation
import Metal
import XCTest
@testable import MetalComposerKit

/// Builds .mcomp data with the engine's internal API, for the public-API tests in PlayerTests.
enum PlayerFixtures {
    /// Renders one frame into a 16×16 texture and returns the center pixel as (r, g, b, a).
    static func centerPixel(_ player: CompositionPlayer, engine: MetalComposerEngine, time: Double = 0) throws -> [UInt8] {
        let device = engine.device
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalComposerEngine.pixelFormat, width: 16, height: 16, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        let target = try XCTUnwrap(device.makeTexture(descriptor: desc))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        player.encode(into: target, time: time, commandBuffer: cb)
        if desc.storageMode == .managed, let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        var bgra = [UInt8](repeating: 0, count: 4)
        target.getBytes(&bgra, bytesPerRow: 16 * 4, from: MTLRegionMake2D(8, 8, 1, 1), mipmapLevel: 0)
        return [bgra[2], bgra[1], bgra[0], bgra[3]]
    }

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
