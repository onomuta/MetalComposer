import XCTest
@testable import MetalComposerKit
@testable import MetalComposerEditor

/// Analysis math only — these never open the microphone.
final class AudioTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func sine(_ hz: Double, amplitude: Float = 1, count: Int = AudioAnalyzer.fftSize) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / sampleRate)) }
    }

    func testFullScaleSineReadsAboutOneAtItsBin() {
        let mags = AudioAnalyzer.analyze(sine(1000))
        let binHz = sampleRate / Double(AudioAnalyzer.fftSize)
        let peakBin = mags.indices.max { mags[$0] < mags[$1] }!
        XCTAssertEqual(Double(peakBin) * binHz, 1000, accuracy: binHz)
        XCTAssertEqual(mags[peakBin], 1, accuracy: 0.2)
    }

    func testBandsPickTheRightFrequency() {
        let mags = AudioAnalyzer.analyze(sine(1000, amplitude: 0.5))
        let edges = AudioSpectrumPatch.edges(count: 16, minHz: 40, maxHz: 16000)
        let levels = (0..<16).map { AudioSpectrumPatch.level(mags, from: edges[$0], to: edges[$0 + 1], sampleRate: sampleRate, floorDB: -70) }
        let loudest = levels.indices.max { levels[$0] < levels[$1] }!
        XCTAssertTrue(edges[loudest] <= 1000 && 1000 < edges[loudest + 1], "1 kHz should land in band \(loudest)")
        XCTAssertGreaterThan(levels[loudest], 0.85) // −6 dB on a 70 dB scale
        XCTAssertLessThan(levels[0], 0.3, "far-away bands stay low")
    }

    func testEdgesAreLogSpaced() {
        let e = AudioSpectrumPatch.edges(count: 2, minHz: 100, maxHz: 10000)
        XCTAssertEqual(e[0], 100, accuracy: 1e-9)
        XCTAssertEqual(e[1], 1000, accuracy: 1e-6)
        XCTAssertEqual(e[2], 10000, accuracy: 1e-6)
    }

    func testLevelMappingAndRelease() {
        XCTAssertEqual(normalizedLevel(1, floorDB: -60), 1)
        XCTAssertEqual(normalizedLevel(0.001, floorDB: -60), 0, accuracy: 1e-6) // −60 dB
        XCTAssertEqual(normalizedLevel(0, floorDB: -60), 0)
        XCTAssertEqual(decayed(0.2, toward: 0.8, release: 1, dt: 1 / 60), 0.8, "rises instantly")
        let fallen = decayed(1, toward: 0, release: 0.5, dt: 0.5)
        XCTAssertEqual(fallen, Float(exp(-1.0)), accuracy: 1e-5, "falls with the release time constant")
    }
}

/// The input ring and draw-time analysis (no microphone: samples are fed in directly).
final class AudioResponseTests: XCTestCase {
    func testRingKeepsTheNewestSamplesInOrder() {
        let ring = SampleRing(capacity: 8)
        XCTAssertEqual(ring.newest(4).samples, [0, 0, 0, 0], "zeros before anything arrives")
        [Float](arrayLiteral: 1, 2, 3).withUnsafeBufferPointer { ring.write($0) }
        XCTAssertEqual(ring.newest(4).samples, [0, 1, 2, 3])
        (4...13).map(Float.init).withUnsafeBufferPointer { ring.write($0) } // wraps around
        XCTAssertEqual(ring.newest(4).samples, [10, 11, 12, 13])
        XCTAssertEqual(ring.newest(4).written, 13)
        XCTAssertEqual(ring.newest(10).samples, [0, 0, 6, 7, 8, 9, 10, 11, 12, 13], "never more than it holds")
    }

    func testChannelsAreMixedToMono() {
        let ring = SampleRing(capacity: 8)
        var left: [Float] = [1, 1], right: [Float] = [0, -1]
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                let channels = [l.baseAddress!, r.baseAddress!]
                channels.withUnsafeBufferPointer { ring.write(channels: $0.baseAddress!, channelCount: 2, frames: 2) }
            }
        }
        XCTAssertEqual(ring.newest(2).samples, [0.5, 0])
    }

    func testLevelsFollowTheNewestSound() {
        let analyzer = AudioAnalyzer(startsInput: false)
        let rate = 48_000.0
        // A loud burst, then 50 ms of silence: the peak already reads silence (an input tap
        // delivering ~0.1 s at a time would still show the burst).
        analyzer.receive([Float](repeating: 0.9, count: 2400), sampleRate: rate)
        XCTAssertEqual(analyzer.snapshot().peak, 0.9, accuracy: 0.001)
        analyzer.receive([Float](repeating: 0, count: 2400))
        XCTAssertEqual(analyzer.snapshot().peak, 0)

        // A 1 kHz tone shows in the spectrum as soon as it arrives.
        let tone = (0..<AudioAnalyzer.fftSize).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / rate)) }
        analyzer.receive(tone)
        let snapshot = analyzer.snapshot()
        let loudest = snapshot.magnitudes.indices.max { snapshot.magnitudes[$0] < snapshot.magnitudes[$1] }!
        XCTAssertEqual(Double(loudest) * rate / Double(AudioAnalyzer.fftSize), 1000, accuracy: rate / Double(AudioAnalyzer.fftSize))
        XCTAssertEqual(snapshot.waveform.count, AudioAnalyzer.fftSize)
        XCTAssertGreaterThan(snapshot.rms, 0.3)
    }
}
