import Foundation
import Metal

/// Sound level and waveform from the default audio input.
package final class AudioInputPatch: Patch {
    package override class var typeID: String { "audio-input" }
    package override class var title: String { "Audio Input" }
    package override class var category: PatchCategory { .provider }
    package override class var summary: String { "Volume (peak and RMS) and waveform of the microphone / default audio input." }
    package override class var inputSpecs: [PortSpec] {
        [.number("gain", "Gain", 1, 0...8).limited(min: 0),
         .number("release", "Release (s)", 0.15, 0...2).limited(min: 0),
         PortSpec.number("points", "Waveform Points", 128, 8...512).limited(2...2048).setting()]
    }
    package override class var outputSpecs: [PortSpec] {
        [.number("peak", "Volume Peak"), .number("level", "Level (RMS)"),
         .structure("waveform", "Waveform"), .bool("active", "Active")]
    }

    private var peak: Float = 0
    private var level: Float = 0

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let audio = AudioAnalyzer.shared.snapshot()
        setStatus(audio.problem)
        let gain = i.float("gain")
        let release = i.number("release")
        peak = decayed(peak, toward: min(audio.peak * gain, 1), release: release, dt: ctx.deltaTime)
        // RMS of music sits well below its peak; ×2 makes the useful range span roughly 0…1.
        level = decayed(level, toward: min(audio.rms * gain * 2, 1), release: release, dt: ctx.deltaTime)

        let count = min(max(i.int("points"), 2), 2048)
        var points: [Structure.Member] = []
        if !audio.waveform.isEmpty {
            let step = Double(audio.waveform.count - 1) / Double(count - 1)
            points = (0..<count).map { k in
                .init(key: nil, value: .number(Double(audio.waveform[Int((Double(k) * step).rounded())] * gain)))
            }
        }
        return ["peak": .number(Double(peak)), "level": .number(Double(level)),
                "waveform": .structure(Structure(members: points)), "active": .bool(audio.isRunning)]
    }

    package override func reset() { peak = 0; level = 0 }
}

/// Frequency analysis of the default audio input: log-spaced bands as a structure and as a
/// 1-pixel-high image (one texel per band, value in every channel) for shaders and sprites.
package final class AudioSpectrumPatch: Patch {
    package override class var typeID: String { "audio-spectrum" }
    package override class var title: String { "Audio Spectrum" }
    package override class var category: PatchCategory { .provider }
    package override class var summary: String { "Frequency bands (0…1) of the microphone / default input, plus Bass, Mid, Treble and a spectrum image." }
    package override class var inputSpecs: [PortSpec] {
        [.number("gain", "Gain", 1, 0...4).limited(min: 0),
         .number("release", "Release (s)", 0.2, 0...2).limited(min: 0),
         PortSpec.number("bands", "Bands", 16, 1...128).limited(1...512).setting(),
         PortSpec.number("minHz", "Lowest Frequency (Hz)", 40, 20...500).limited(1...20000).setting(),
         PortSpec.number("maxHz", "Highest Frequency (Hz)", 16000, 2000...20000).limited(10...24000).setting(),
         PortSpec.number("floorDB", "Floor (dB)", -70, -120 ... -20).limited(-200 ... -1).setting()]
    }
    package override class var outputSpecs: [PortSpec] {
        [.structure("spectrum", "Spectrum"), .number("bass", "Bass"), .number("mid", "Mid"),
         .number("treble", "Treble"), .image("image", "Image")]
    }

    private var bands: [Float] = []
    private var lows: (bass: Float, mid: Float, treble: Float) = (0, 0, 0)
    /// A few textures used in turn, so the GPU never reads one while it's being rewritten.
    private var textures: [MTLTexture] = []
    private var textureIndex = 0

    /// Band edges in Hz, log-spaced from minHz to maxHz.
    package static func edges(count: Int, minHz: Double, maxHz: Double) -> [Double] {
        let lo = max(minHz, 1), hi = max(maxHz, lo * 1.01)
        return (0...count).map { lo * pow(hi / lo, Double($0) / Double(count)) }
    }

    /// Loudest bin between two frequencies (at least one bin), normalized to 0…1.
    package static func level(_ magnitudes: [Float], from f0: Double, to f1: Double, sampleRate: Double, floorDB: Float) -> Float {
        guard !magnitudes.isEmpty else { return 0 }
        let binHz = sampleRate / Double(magnitudes.count * 2)
        let k0 = min(max(Int(f0 / binHz), 1), magnitudes.count - 1)
        let k1 = min(max(Int(ceil(f1 / binHz)), k0 + 1), magnitudes.count)
        return normalizedLevel(magnitudes[k0..<k1].max() ?? 0, floorDB: floorDB)
    }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let audio = AudioAnalyzer.shared.snapshot()
        setStatus(audio.problem)
        let count = min(max(i.int("bands"), 1), 512)
        let gain = i.float("gain"), release = i.number("release"), floor = i.float("floorDB")
        let edges = Self.edges(count: count, minHz: i.number("minHz"), maxHz: i.number("maxHz"))
        if bands.count != count { bands = [Float](repeating: 0, count: count) }

        func measure(_ f0: Double, _ f1: Double) -> Float {
            min(Self.level(audio.magnitudes, from: f0, to: f1, sampleRate: audio.sampleRate, floorDB: floor) * gain, 1)
        }
        for b in 0..<count {
            bands[b] = decayed(bands[b], toward: measure(edges[b], edges[b + 1]), release: release, dt: ctx.deltaTime)
        }
        lows.bass = decayed(lows.bass, toward: measure(20, 250), release: release, dt: ctx.deltaTime)
        lows.mid = decayed(lows.mid, toward: measure(250, 4000), release: release, dt: ctx.deltaTime)
        lows.treble = decayed(lows.treble, toward: measure(4000, 16000), release: release, dt: ctx.deltaTime)

        return ["spectrum": .structure(Structure(members: bands.map { .init(key: nil, value: .number(Double($0))) })),
                "bass": .number(Double(lows.bass)), "mid": .number(Double(lows.mid)), "treble": .number(Double(lows.treble)),
                "image": .image(makeImage(ctx.device))]
    }

    private func makeImage(_ device: MTLDevice) -> MTLTexture? {
        let width = bands.count
        if textures.first?.width != width {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: 1, mipmapped: false)
            desc.usage = [.shaderRead]
            textures = (0..<3).compactMap { _ in device.makeTexture(descriptor: desc) }
        }
        guard !textures.isEmpty else { return nil }
        textureIndex = (textureIndex + 1) % textures.count
        let texture = textures[textureIndex]
        var bytes = [UInt8](repeating: 255, count: width * 4)
        for (b, v) in bands.enumerated() {
            let byte = UInt8(min(max(v, 0), 1) * 255)
            bytes[b * 4] = byte; bytes[b * 4 + 1] = byte; bytes[b * 4 + 2] = byte
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }

    package override func reset() {
        bands = bands.map { _ in 0 }
        lows = (0, 0, 0)
    }
}
