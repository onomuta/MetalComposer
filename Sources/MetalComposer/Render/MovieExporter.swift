import AVFoundation
import CoreVideo
import Metal

struct MovieSettings: Equatable {
    var duration: Double = 10
    var width = 1920
    var height = 1080
    var fps = 30
    var codec: Codec = .h264
    var quality: Quality = .high

    enum Codec: String, CaseIterable, Identifiable {
        case h264 = "H.264"
        case hevc = "HEVC (H.265)"
        case proRes422HQ = "ProRes 422 HQ"
        case proRes4444 = "ProRes 4444 (with alpha)"

        var id: String { rawValue }

        var avCodec: AVVideoCodecType {
            switch self {
            case .h264: return .h264
            case .hevc: return .hevc
            case .proRes422HQ: return .proRes422HQ
            case .proRes4444: return .proRes4444
            }
        }

        var fileType: AVFileType { usesBitrate ? .mp4 : .mov }
        var fileExtension: String { usesBitrate ? "mp4" : "mov" }
        /// ProRes is intra-frame at a fixed quality; the delivery codecs take a bitrate.
        var usesBitrate: Bool { self == .h264 || self == .hevc }
        var hasAlpha: Bool { self == .proRes4444 }
        var maxSide: Int { self == .h264 ? 4096 : 8192 }
    }

    enum Quality: String, CaseIterable, Identifiable {
        case standard = "Standard", high = "High", maximum = "Maximum"
        var id: String { rawValue }
        var bitsPerPixel: Double {
            switch self {
            case .standard: return 0.07
            case .high: return 0.14
            case .maximum: return 0.3
            }
        }
    }

    static let presets: [(name: String, width: Int, height: Int)] = [
        ("720p", 1280, 720), ("1080p", 1920, 1080), ("1440p", 2560, 1440), ("4K UHD", 3840, 2160),
        ("Square 1080", 1080, 1080), ("Vertical 1080×1920", 1080, 1920),
    ]
    static let frameRates = [24, 25, 30, 48, 50, 60, 120]

    var frameCount: Int { max(1, Int((duration * Double(fps)).rounded())) }

    /// Encoders need even dimensions within the codec's limits.
    var normalized: MovieSettings {
        var s = self
        func fit(_ v: Int) -> Int { min(max(v - v % 2, 16), codec.maxSide) }
        s.width = fit(width)
        s.height = fit(height)
        s.fps = min(max(fps, 1), 240)
        s.duration = min(max(duration, 1 / Double(s.fps)), 3600)
        return s
    }

    var bitrate: Int {
        let s = normalized
        let factor = codec == .hevc ? 0.6 : 1 // HEVC needs less for the same quality
        return Int(Double(s.width * s.height * s.fps) * quality.bitsPerPixel * factor)
    }

    /// Rough output size, for the dialog.
    var estimatedBytes: Int? {
        guard codec.usesBitrate else { return nil }
        return Int(Double(bitrate) / 8 * normalized.duration)
    }
}

/// Renders a composition offline, frame by frame at exact time steps, into a movie file.
/// Works on a copy of the graph so the editor's live state is untouched.
final class MovieExporter: ObservableObject {
    enum State: Equatable {
        case idle
        case exporting(frame: Int, total: Int)
        case finished(URL)
        case failed(String)
        case cancelled
    }

    struct ExportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published var settings = MovieSettings()
    @Published private(set) var state: State = .idle
    /// Called with `true` when an export starts and `false` when it ends.
    var onBusyChange: ((Bool) -> Void)?

    private var cancelRequested = false

    var isExporting: Bool { if case .exporting = state { return true }; return false }

    func start(record: GraphRecord, resources: RenderResources, to url: URL) {
        guard !isExporting else { return }
        let settings = settings.normalized
        cancelRequested = false
        state = .exporting(frame: 0, total: settings.frameCount)
        onBusyChange?(true)
        Task { @MainActor in
            do {
                try await export(record: record, resources: resources, settings: settings, to: url)
                state = .finished(url)
            } catch is CancellationError {
                state = .cancelled
            } catch {
                state = .failed(error.localizedDescription)
            }
            onBusyChange?(false)
        }
    }

    func cancel() { cancelRequested = true }

    func resetState() { if !isExporting { state = .idle } }

    /// Runs on the main actor: patches aren't thread-safe, and awaiting the GPU between frames
    /// keeps the UI responsive anyway.
    @MainActor
    func export(record: GraphRecord, resources: RenderResources, settings s: MovieSettings, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: s.codec.fileType)

        var video: [String: Any] = [
            AVVideoCodecKey: s.codec.avCodec,
            AVVideoWidthKey: s.width,
            AVVideoHeightKey: s.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if s.codec.usesBitrate {
            video[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: s.bitrate,
                AVVideoExpectedSourceFrameRateKey: s.fps,
                AVVideoMaxKeyFrameIntervalKey: s.fps * 2,
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: video)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: s.width,
            kCVPixelBufferHeightKey as String: s.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(input) else { throw ExportError(message: "These settings aren't supported by the encoder.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ExportError(message: "Couldn't start writing the movie.")
        }
        writer.startSession(atSourceTime: .zero)

        func abandon() {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
        }

        let device = resources.device
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        guard let textureCache else { abandon(); throw ExportError(message: "Couldn't create a Metal texture cache.") }

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderResources.depthFormat,
                                                                 width: s.width, height: s.height, mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        let depth = device.makeTexture(descriptor: depthDesc)

        // A private copy of the composition, starting from a clean state at t = 0.
        let graph = Graph()
        graph.load(record)
        let size = CGSize(width: s.width, height: s.height)
        let total = s.frameCount

        for frame in 0..<total {
            if cancelRequested { abandon(); throw CancellationError() }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
                if cancelRequested { abandon(); throw CancellationError() }
            }

            guard let pool = adaptor.pixelBufferPool else { abandon(); throw writer.error ?? ExportError(message: "The encoder has no buffers.") }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            var cvTexture: CVMetalTexture?
            if let pixelBuffer {
                CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, RenderResources.pixelFormat,
                                                          s.width, s.height, 0, &cvTexture)
            }
            guard let pixelBuffer, let cvTexture, let target = CVMetalTextureGetTexture(cvTexture),
                  let commandBuffer = resources.queue.makeCommandBuffer() else {
                abandon()
                throw ExportError(message: "Couldn't allocate frame \(frame + 1).")
            }

            // Exact time steps, so stateful patches (particles, queues…) behave the same on every export.
            let ctx = EvalContext(resources: resources, commandBuffer: commandBuffer,
                                  time: Double(frame) / Double(s.fps), deltaTime: frame == 0 ? 0 : 1 / Double(s.fps),
                                  viewportSize: size, mouse: .zero, mouseDown: false)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .dontCare
            pass.depthAttachment.clearDepth = 1
            Renderer.encodeFrame(graph: graph, context: ctx, pass: pass, targetSize: size,
                                 clearAlpha: s.codec.hasAlpha ? 0 : 1)

            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                commandBuffer.addCompletedHandler { _ in done.resume() }
                commandBuffer.commit()
            }
            if let error = commandBuffer.error { abandon(); throw error }

            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(s.fps))) else {
                abandon()
                throw writer.error ?? ExportError(message: "Couldn't write frame \(frame + 1).")
            }
            withExtendedLifetime(cvTexture) {}
            state = .exporting(frame: frame + 1, total: total)
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? ExportError(message: "Couldn't finish the movie.")
        }
    }
}
