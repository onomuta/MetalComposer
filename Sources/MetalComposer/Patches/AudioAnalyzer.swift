import Accelerate
import AVFoundation
import Foundation

/// Captures the default audio input and keeps the latest levels, waveform and FFT magnitudes.
/// One shared instance serves every audio patch. It starts when a patch first asks for data and
/// stops after a few seconds without requests, so the microphone is only on while it's used.
final class AudioAnalyzer {
    static let shared = AudioAnalyzer()

    static let fftSize = 2048
    private static let log2n = vDSP_Length(11)

    struct Snapshot {
        var peak: Float = 0
        var rms: Float = 0
        /// Latest mono samples, oldest first (`fftSize` long).
        var waveform: [Float] = []
        /// Amplitude per FFT bin (0…fftSize/2), where a full-scale sine reads 1.
        var magnitudes: [Float] = []
        var sampleRate: Double = 48_000
        var isRunning = false
        /// Why there is no audio, if there isn't.
        var problem: String?
    }

    private let lock = NSLock()
    private var latest = Snapshot()
    private var engine: AVAudioEngine?
    private var lastRequest = Date.distantPast
    private var idleTimer: Timer?
    private var starting = false

    private let fftSetup = vDSP_create_fftsetup(AudioAnalyzer.log2n, FFTRadix(kFFTRadix2))!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                     count: AudioAnalyzer.fftSize, isHalfWindow: false)
    private var ring = [Float](repeating: 0, count: AudioAnalyzer.fftSize)

    /// Latest analysis. Call from the main thread; it also keeps (or gets) the input running.
    func snapshot() -> Snapshot {
        lastRequest = Date()
        if engine == nil, !starting { start() }
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    // MARK: Lifecycle

    private func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()
        case .notDetermined:
            starting = true
            setProblem("Waiting for microphone permission…")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.starting = false
                    if granted { self.startEngine() } else { self.setProblem("Microphone access was denied. Allow it in System Settings › Privacy & Security › Microphone.") }
                }
            }
        default:
            starting = true // don't ask again every frame
            setProblem("Microphone access is off. Allow it in System Settings › Privacy & Security › Microphone.")
        }
    }

    private func startEngine() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            setProblem("No audio input device.")
            starting = true
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            setProblem("Couldn't start audio input: \(error.localizedDescription)")
            starting = true
            return
        }
        self.engine = engine
        lock.lock()
        latest.sampleRate = format.sampleRate
        latest.isRunning = true
        latest.problem = nil
        lock.unlock()

        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastRequest) > 3 else { return }
            self.stop()
        }
    }

    private func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        lock.lock()
        latest = Snapshot(sampleRate: latest.sampleRate)
        lock.unlock()
    }

    private func setProblem(_ message: String) {
        lock.lock()
        latest.problem = message
        latest.isRunning = false
        lock.unlock()
    }

    // MARK: Analysis (audio thread)

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0 else { return }

        // Mix down to mono.
        var mono = [Float](repeating: 0, count: frames)
        for c in 0..<channelCount {
            vDSP.add(mono, UnsafeBufferPointer(start: channels[c], count: frames), result: &mono)
        }
        if channelCount > 1 { vDSP.multiply(1 / Float(channelCount), mono, result: &mono) }

        let peak = vDSP.maximumMagnitude(mono)
        let rms = vDSP.rootMeanSquare(mono)

        // Keep the last fftSize samples.
        if frames >= ring.count {
            ring = Array(mono.suffix(ring.count))
        } else {
            ring.removeFirst(frames)
            ring.append(contentsOf: mono)
        }
        let magnitudes = Self.spectrum(of: ring, window: window, setup: fftSetup)

        lock.lock()
        latest.peak = peak
        latest.rms = rms
        latest.waveform = ring
        latest.magnitudes = magnitudes
        lock.unlock()
    }

    /// Hann-windowed real FFT; returns bin amplitudes scaled so a full-scale sine reads ≈1.
    static func spectrum(of samples: [Float], window: [Float], setup: FFTSetup) -> [Float] {
        let n = samples.count
        let half = n / 2
        var windowed = vDSP.multiply(samples, window)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeMutableBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(n))), FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        // zrip doubles the result and the Hann window halves a sine's amplitude.
        vDSP.multiply(2 / Float(n), magnitudes, result: &magnitudes)
        return magnitudes
    }

    /// Test hook: the same analysis without an audio device.
    static func analyze(_ samples: [Float]) -> [Float] {
        let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(samples.count))), FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: samples.count, isHalfWindow: false)
        return spectrum(of: samples, window: window, setup: setup)
    }
}

/// Converts an amplitude to 0…1 on a decibel scale where `floorDB` maps to 0 and 0 dBFS to 1.
func normalizedLevel(_ amplitude: Float, floorDB: Float) -> Float {
    guard amplitude > 0 else { return 0 }
    let db = 20 * log10(amplitude)
    return min(max((db - floorDB) / -floorDB, 0), 1)
}

/// Frame-rate independent smoothing: rises instantly, falls with the given time constant.
func decayed(_ current: Float, toward target: Float, release: Double, dt: Double) -> Float {
    guard target < current, release > 0 else { return target }
    let k = Float(exp(-dt / release))
    return target + (current - target) * k
}
