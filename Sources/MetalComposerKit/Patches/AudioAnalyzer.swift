import Accelerate
import AVFoundation
import Foundation

/// Captures the default audio input and analyzes the newest sound when a frame asks for it.
/// One shared instance serves every audio patch. It starts when a patch first asks for data and
/// stops after a few seconds without requests, so the microphone is only on while it's used.
///
/// The input is received in small blocks (a few milliseconds, through `AVAudioSinkNode`) into a
/// ring of recent samples, and the levels and spectrum are computed from the newest samples at
/// draw time. An input tap would deliver ~0.1 s at a time on macOS, so values would step 10 times
/// a second and lag behind the sound.
package final class AudioAnalyzer {
    package static let shared = AudioAnalyzer()

    package static let fftSize = 2048
    private static let log2n = vDSP_Length(11)
    /// Peak and RMS are measured over this much of the newest sound (seconds).
    package static let levelWindow = 0.02

    package struct Snapshot {
        package var peak: Float = 0
        package var rms: Float = 0
        /// Latest mono samples, oldest first (`fftSize` long).
        package var waveform: [Float] = []
        /// Amplitude per FFT bin (0…fftSize/2), where a full-scale sine reads 1.
        package var magnitudes: [Float] = []
        package var sampleRate: Double = 48_000
        package var isRunning = false
        /// Why there is no audio, if there isn't.
        package var problem: String?
    }

    private let lock = NSLock()
    /// Status, sample rate and the last analysis (main thread, under `lock` for the status).
    private var latest = Snapshot()
    private let ring = SampleRing(capacity: 16_384)
    /// Samples written when `latest` was last analyzed, so several patches in one frame share it.
    private var analyzedCount = -1
    private let startsInput: Bool
    private var engine: AVAudioEngine?
    private var lastRequest = Date.distantPast
    private var idleTimer: Timer?
    private var starting = false

    private let fftSetup = vDSP_create_fftsetup(AudioAnalyzer.log2n, FFTRadix(kFFTRadix2))!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                     count: AudioAnalyzer.fftSize, isHalfWindow: false)

    /// `startsInput` false: never touches the microphone; samples come from `receive` (tests).
    package init(startsInput: Bool = true) {
        self.startsInput = startsInput
    }

    /// Latest analysis. Call from the main thread; it also keeps (or gets) the input running.
    package func snapshot() -> Snapshot {
        lastRequest = Date()
        if startsInput, engine == nil, !starting { start() }
        let (samples, written) = ring.newest(Self.fftSize)
        lock.lock(); defer { lock.unlock() }
        if written != analyzedCount {
            analyzedCount = written
            let recent = samples.suffix(max(1, Int(latest.sampleRate * Self.levelWindow)))
            latest.peak = vDSP.maximumMagnitude(Array(recent))
            latest.rms = vDSP.rootMeanSquare(Array(recent))
            latest.waveform = samples
            latest.magnitudes = Self.spectrum(of: samples, window: window, setup: fftSetup)
        }
        return latest
    }

    /// Adds mono samples as if they came from the input (tests and the tap fallback).
    package func receive(_ mono: [Float], sampleRate: Double? = nil) {
        if let sampleRate {
            lock.lock(); latest.sampleRate = sampleRate; lock.unlock()
        }
        mono.withUnsafeBufferPointer { ring.write($0) }
    }

    // MARK: Lifecycle

    private func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()
        case .notDetermined:
            starting = true
            setProblem(loc("Waiting for microphone permission…"))
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.starting = false
                    if granted { self.startEngine() } else { self.setProblem(loc("Microphone access was denied. Allow it in %@.", loc(Self.settingsPath))) }
                }
            }
        default:
            starting = true // don't ask again every frame
            setProblem(loc("Microphone access is off. Allow it in %@.", loc(Self.settingsPath)))
        }
    }

    #if os(iOS)
    private static let settingsPath = "Settings › Privacy & Security › Microphone"
    #else
    private static let settingsPath = "System Settings › Privacy & Security › Microphone"
    #endif

    private func startEngine() {
        #if os(iOS)
        // Mix with other apps so music playing elsewhere keeps going while the mic listens.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            // Small hardware blocks, so new sound reaches the analysis quickly (a request; iOS may round it).
            try? session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            setProblem(loc("Couldn't start audio input: %@", error.localizedDescription))
            starting = true
            return
        }
        #endif
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            setProblem(loc("No audio input device."))
            starting = true
            return
        }
        // A sink node gets every render block (a few ms). It needs plain float samples, one buffer
        // per channel; anything else uses a tap, which arrives in larger chunks.
        var usesTap = true
        if format.commonFormat == .pcmFormatFloat32, !format.isInterleaved {
            let ring = self.ring
            let sink = AVAudioSinkNode { _, frameCount, audioBufferList in
                ring.write(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList)),
                           frames: Int(frameCount))
                return noErr
            }
            engine.attach(sink)
            engine.connect(input, to: sink, format: format)
            usesTap = false
        }
        if usesTap {
            input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
                self?.receiveTap(buffer)
            }
        }
        do {
            try engine.start()
        } catch {
            if usesTap { input.removeTap(onBus: 0) }
            setProblem(loc("Couldn't start audio input: %@", error.localizedDescription))
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
        ring.clear()
        lock.lock()
        latest = Snapshot(sampleRate: latest.sampleRate)
        analyzedCount = -1
        lock.unlock()
    }

    private func setProblem(_ message: String) {
        lock.lock()
        latest.problem = message
        latest.isRunning = false
        lock.unlock()
    }

    /// The tap fallback (audio thread).
    private func receiveTap(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        ring.write(channels: channels, channelCount: Int(buffer.format.channelCount), frames: Int(buffer.frameLength))
    }

    /// Hann-windowed real FFT; returns bin amplitudes scaled so a full-scale sine reads ≈1.
    package static func spectrum(of samples: [Float], window: [Float], setup: FFTSetup) -> [Float] {
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
    package static func analyze(_ samples: [Float]) -> [Float] {
        let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(samples.count))), FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: samples.count, isHalfWindow: false)
        return spectrum(of: samples, window: window, setup: setup)
    }
}

/// The newest mono samples, written by the audio thread and read at draw time. Writing only takes
/// a short lock and doesn't allocate, as the audio thread requires.
final class SampleRing: @unchecked Sendable {
    private let capacity: Int
    private let samples: UnsafeMutablePointer<Float>
    /// Samples written so far (the next write goes at `count % capacity`).
    private var count = 0
    /// Allocated separately: an os_unfair_lock must not move in memory.
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    init(capacity: Int) {
        self.capacity = capacity
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        samples.deallocate()
        lock.deallocate()
    }

    private func append(_ value: Float) {
        samples[count % capacity] = value
        count &+= 1
    }

    func write(_ mono: UnsafeBufferPointer<Float>) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        for v in mono { append(v) }
    }

    /// Mixes channels (separate buffers) down to mono.
    func write(channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frames: Int) {
        guard channelCount > 0 else { return }
        let scale = 1 / Float(channelCount)
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<channelCount { sum += channels[c][f] }
            append(sum * scale)
        }
    }

    /// Mixes the buffers of a non-interleaved float buffer list down to mono.
    func write(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let buffers = list.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
        guard !buffers.isEmpty else { return }
        let scale = 1 / Float(buffers.count)
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        for f in 0..<frames {
            var sum: Float = 0
            for b in buffers { sum += b[f] }
            append(sum * scale)
        }
    }

    /// The newest `n` samples, oldest first (zeros before anything was written), and the number
    /// of samples written so far.
    func newest(_ n: Int) -> (samples: [Float], written: Int) {
        var out = [Float](repeating: 0, count: n)
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        let available = min(count, n, capacity)
        for k in 0..<available {
            out[n - available + k] = samples[(count - available + k) % capacity]
        }
        return (out, count)
    }

    func clear() {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        samples.update(repeating: 0, count: capacity)
        count = 0
    }
}

/// Converts an amplitude to 0…1 on a decibel scale where `floorDB` maps to 0 and 0 dBFS to 1.
package func normalizedLevel(_ amplitude: Float, floorDB: Float) -> Float {
    guard amplitude > 0 else { return 0 }
    let db = 20 * log10(amplitude)
    return min(max((db - floorDB) / -floorDB, 0), 1)
}

/// Frame-rate independent smoothing: rises instantly, falls with the given time constant.
package func decayed(_ current: Float, toward target: Float, release: Double, dt: Double) -> Float {
    guard target < current, release > 0 else { return target }
    let k = Float(exp(-dt / release))
    return target + (current - target) * k
}
