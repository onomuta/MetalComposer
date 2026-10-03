import AVFoundation
import Metal
import XCTest
@testable import MetalComposer

final class MovieExportTests: XCTestCase {
    private func redComposition() -> GraphRecord {
        let g = Graph()
        g.put(ClearPatch.self, 0, 0, ["color": .color(SIMD4(1, 0, 0, 1))])
        return g.record()
    }

    private func export(_ settings: MovieSettings, ext: String) async throws -> URL {
        let resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-export-\(UUID().uuidString).\(ext)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try await MovieExporter().export(record: redComposition(), resources: resources, settings: settings.normalized, to: url)
        return url
    }

    private func sampleCount(_ asset: AVURLAsset) async throws -> Int {
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        // Decode, so only buffers that carry a picture are counted (pass-through also yields markers).
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        var n = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { n += 1 }
        }
        return n
    }

    @MainActor
    func testH264HasRequestedLengthSizeAndContent() async throws {
        var s = MovieSettings()
        s.duration = 1
        s.width = 161 // odd: must be rounded down to even
        s.height = 90
        s.fps = 30
        let url = try await export(s, ext: "mp4")

        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 160, height: 90))
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.05)
        let frames = try await sampleCount(asset)
        XCTAssertEqual(frames, 30)

        // The rendered Clear color must come out red.
        let generator = AVAssetImageGenerator(asset: asset)
        let image = try await generator.image(at: CMTime(value: 15, timescale: 30)).image
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(pixel[0], 200)
        XCTAssertLessThan(pixel[1], 40)
        XCTAssertLessThan(pixel[2], 40)
    }

    @MainActor
    func testProRes4444WritesMov() async throws {
        var s = MovieSettings()
        s.duration = 0.5
        s.width = 128
        s.height = 128
        s.fps = 24
        s.codec = .proRes4444
        let url = try await export(s, ext: "mov")
        let frames = try await sampleCount(AVURLAsset(url: url))
        XCTAssertEqual(frames, 12)
    }

    /// Drives the same path as the Export sheet: start → exporting → finished, pausing the live view.
    @MainActor
    func testStartReportsProgressAndBusyState() async throws {
        let resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-start-\(UUID().uuidString).mp4")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let exporter = MovieExporter()
        exporter.settings = MovieSettings(duration: 0.5, width: 64, height: 64, fps: 20)
        var busy: [Bool] = []
        exporter.onBusyChange = { busy.append($0) }

        exporter.start(record: redComposition(), resources: resources, to: url)
        XCTAssertTrue(exporter.isExporting)
        for _ in 0..<500 where exporter.isExporting { try await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertEqual(exporter.state, .finished(url))
        XCTAssertEqual(busy, [true, false])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testCancelRemovesPartialFile() async throws {
        let resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-cancel-\(UUID().uuidString).mov")
        let exporter = MovieExporter()
        exporter.settings = MovieSettings(duration: 60, width: 640, height: 360, fps: 60, codec: .proRes422HQ)
        exporter.start(record: redComposition(), resources: resources, to: url)
        try await Task.sleep(nanoseconds: 50_000_000)
        exporter.cancel()
        for _ in 0..<500 where exporter.isExporting { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(exporter.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSettingsNormalize() {
        var s = MovieSettings()
        s.width = 9999
        s.height = 7
        s.codec = .h264
        let n = s.normalized
        XCTAssertEqual(n.width, 4096)
        XCTAssertEqual(n.height, 16)
        s.duration = 2.5
        s.fps = 24
        XCTAssertEqual(s.frameCount, 60)
    }
}
