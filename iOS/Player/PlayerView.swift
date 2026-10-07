import MetalKit
import MetalPerformanceShaders
import MetalComposerKit
import SwiftUI

/// Plays one composition: keeps its clock and draws it, on the device's screen or, while one is
/// connected, on the external display (the device then previews that frame). Only one place
/// renders, so time and stateful patches (particles…) advance once per frame.
final class Playback: ObservableObject {
    let player: CompositionPlayer
    @Published var isPlaying = true
    private(set) var time: Double = 0
    private var lastHostTime: CFTimeInterval?
    /// The latest frame drawn for the external display.
    private var frame: MTLTexture?
    private lazy var scaler = MPSImageBilinearScale(device: player.engine.device)

    init(player: CompositionPlayer) {
        self.player = player
    }

    private func tick() -> Double {
        let now = CACurrentMediaTime()
        if isPlaying, let last = lastHostTime { time += now - last }
        lastHostTime = now
        return time
    }

    func restart() {
        time = 0
        player.restart()
    }

    /// Renders the next frame straight into the device's view.
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let commandBuffer = Engine.queue?.makeCommandBuffer() else { return }
        player.encode(into: drawable.texture, time: tick(), commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Renders the next frame for the external display and shows it there.
    func drawExternal(in view: MTKView) {
        guard let drawable = view.currentDrawable, let commandBuffer = Engine.queue?.makeCommandBuffer() else { return }
        let target = drawable.texture
        if frame?.width != target.width || frame?.height != target.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: target.pixelFormat, width: target.width,
                                                                height: target.height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            frame = player.engine.device.makeTexture(descriptor: desc)
        }
        guard let frame, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        player.encode(into: frame, time: tick(), commandBuffer: commandBuffer)
        blit.copy(from: frame, to: target)
        blit.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Shows the external display's latest frame, scaled to the device's view. Both use one
    /// command queue, so this never reads a frame that is still being drawn.
    func drawPreview(in view: MTKView) {
        guard let frame, let drawable = view.currentDrawable,
              let commandBuffer = Engine.queue?.makeCommandBuffer() else { return }
        scaler.encode(commandBuffer: commandBuffer, sourceTexture: frame, destinationTexture: drawable.texture)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// Full-screen playback. Tap to show or hide the controls; touches also drive Mouse patches.
struct PlayerView: View {
    let composition: PlayingComposition
    @EnvironmentObject private var library: Library
    @StateObject private var playback: Playback
    @ObservedObject private var external = ExternalDisplay.shared
    @State private var showsControls = true
    @State private var showsParameters = false
    @State private var showsProblems = false
    @State private var hideTask: Task<Void, Never>?

    init(composition: PlayingComposition) {
        self.composition = composition
        _playback = StateObject(wrappedValue: Playback(player: composition.player))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            let metal = MetalView(playback: playback) {
                withAnimation(.easeInOut(duration: 0.2)) { showsControls.toggle() }
                scheduleHide()
            }
            if let size = external.size {
                // A preview shaped like the external screen, so touches map the same way.
                metal.aspectRatio(size, contentMode: .fit)
            } else {
                metal.ignoresSafeArea()
            }
            if showsControls { controls.transition(.opacity) }
        }
        // Light controls over whatever the composition draws.
        .environment(\.colorScheme, .dark)
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(showsControls ? .automatic : .hidden)
        .sheet(isPresented: $showsParameters) {
            ParametersView(player: composition.player)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .onAppear {
            ExternalDisplay.shared.playback = playback
            UIApplication.shared.isIdleTimerDisabled = true
            scheduleHide()
        }
        .onDisappear {
            if ExternalDisplay.shared.playback === playback { ExternalDisplay.shared.playback = nil }
            UIApplication.shared.isIdleTimerDisabled = false
            hideTask?.cancel()
        }
        .onChange(of: showsParameters) { _, open in if !open { scheduleHide() } }
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 12) {
                RoundButton("xmark", label: "Close") { library.playing = nil }
                Text(composition.title)
                    .font(.headline)
                    .lineLimit(1)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                // Problems show up as patches evaluate (a missing image, a shader error…).
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let problems = composition.player.problems
                    if !problems.isEmpty {
                        RoundButton("exclamationmark.triangle", label: "Problems") { showsProblems = true }
                            .foregroundStyle(.yellow)
                            .alert("Problems", isPresented: $showsProblems) {
                                Button("OK") {}
                            } message: {
                                Text(problems.joined(separator: "\n\n"))
                            }
                    }
                }
                if !composition.player.parameters.isEmpty {
                    RoundButton("slider.horizontal.3", label: "Parameters") {
                        hideTask?.cancel()
                        showsParameters = true
                    }
                }
            }
            Spacer()
            HStack(spacing: 12) {
                RoundButton(playback.isPlaying ? "pause.fill" : "play.fill", label: playback.isPlaying ? "Pause" : "Play") {
                    playback.isPlaying.toggle()
                    scheduleHide()
                }
                RoundButton("backward.end.fill", label: "Restart") {
                    playback.restart()
                    scheduleHide()
                }
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    Text(Self.format(playback.time))
                        .font(.body.monospacedDigit())
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                if let size = external.size {
                    Label("\(Int(size.width))×\(Int(size.height))", systemImage: "tv")
                        .font(.subheadline.monospacedDigit())
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityLabel("Playing on the external display")
                }
            }
        }
        .padding()
    }

    /// Hides the controls after a few seconds without interaction while playing.
    private func scheduleHide() {
        hideTask?.cancel()
        guard showsControls else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, playback.isPlaying, !showsParameters, !showsProblems else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showsControls = false }
        }
    }

    private static func format(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d.%d", s / 60, s % 60, Int((t - Double(s)) * 10))
    }
}

private struct RoundButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(label)
        .buttonStyle(.plain)
    }
}

/// The device's view: the composition itself, or a preview of the external display.
private struct MetalView: UIViewRepresentable {
    let playback: Playback
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(playback: playback) }

    func makeUIView(context: Context) -> TouchMTKView {
        let view = TouchMTKView(frame: .zero, device: playback.player.engine.device)
        view.colorPixelFormat = MetalComposerEngine.pixelFormat
        // The preview is scaled in with a compute kernel, so the drawable can't be framebuffer-only.
        view.framebufferOnly = false
        view.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        view.delegate = context.coordinator
        view.player = playback.player
        view.onTap = onTap
        return view
    }

    func updateUIView(_ view: TouchMTKView, context: Context) {
        view.onTap = onTap
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let playback: Playback

        init(playback: Playback) { self.playback = playback }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            if ExternalDisplay.shared.isConnected {
                playback.drawPreview(in: view)
            } else {
                playback.draw(in: view)
            }
        }
    }
}

/// Reports the first finger to the composition as the mouse, and a tap to `onTap`.
private final class TouchMTKView: MTKView {
    weak var player: CompositionPlayer?
    var onTap: () -> Void = {}

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func tapped() { onTap() }

    private func update(_ touch: UITouch) {
        let p = touch.location(in: self)
        guard bounds.width > 0, bounds.height > 0 else { return }
        // Composition units: x −1…1, y up, scaled like x.
        let x = Float(p.x / bounds.width) * 2 - 1
        let y = (1 - Float(p.y / bounds.height) * 2) * Float(bounds.height / bounds.width)
        player?.pointer = SIMD2(x, y)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.first.map(update)
        player?.isPointerDown = true
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.first.map(update)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.first.map(update)
        player?.isPointerDown = false
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        player?.isPointerDown = false
    }
}
