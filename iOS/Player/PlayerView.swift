import MetalKit
import MetalComposerKit
import SwiftUI

/// The composition's clock: runs while playing, can be reset to 0.
final class Clock: ObservableObject {
    @Published var isPlaying = true
    private(set) var time: Double = 0
    private var lastHostTime: CFTimeInterval?

    func tick() -> Double {
        let now = CACurrentMediaTime()
        if isPlaying, let last = lastHostTime { time += now - last }
        lastHostTime = now
        return time
    }

    func restart() { time = 0 }
}

/// Full-screen playback. Tap to show or hide the controls; touches also drive Mouse patches.
struct PlayerView: View {
    let composition: PlayingComposition
    @EnvironmentObject private var library: Library
    @StateObject private var clock = Clock()
    @State private var showsControls = true
    @State private var showsParameters = false
    @State private var showsProblems = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MetalView(player: composition.player, clock: clock) {
                withAnimation(.easeInOut(duration: 0.2)) { showsControls.toggle() }
                scheduleHide()
            }
            .ignoresSafeArea()
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
            UIApplication.shared.isIdleTimerDisabled = true
            scheduleHide()
        }
        .onDisappear {
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
                RoundButton(clock.isPlaying ? "pause.fill" : "play.fill", label: clock.isPlaying ? "Pause" : "Play") {
                    clock.isPlaying.toggle()
                    scheduleHide()
                }
                RoundButton("backward.end.fill", label: "Restart") {
                    clock.restart()
                    composition.player.restart()
                    scheduleHide()
                }
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    Text(Self.format(clock.time))
                        .font(.body.monospacedDigit())
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
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
            guard !Task.isCancelled, clock.isPlaying, !showsParameters, !showsProblems else { return }
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

/// Draws the composition every frame into an MTKView.
private struct MetalView: UIViewRepresentable {
    let player: CompositionPlayer
    let clock: Clock
    let onTap: () -> Void

    func makeCoordinator() -> Renderer { Renderer(player: player, clock: clock) }

    func makeUIView(context: Context) -> TouchMTKView {
        let view = TouchMTKView(frame: .zero, device: player.engine.device)
        view.colorPixelFormat = MetalComposerEngine.pixelFormat
        view.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        view.delegate = context.coordinator
        view.player = player
        view.onTap = onTap
        return view
    }

    func updateUIView(_ view: TouchMTKView, context: Context) {
        view.onTap = onTap
    }
}

private final class Renderer: NSObject, MTKViewDelegate {
    let player: CompositionPlayer
    let clock: Clock
    private let queue: MTLCommandQueue?

    init(player: CompositionPlayer, clock: Clock) {
        self.player = player
        self.clock = clock
        queue = player.engine.device.makeCommandQueue()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let commandBuffer = queue?.makeCommandBuffer() else { return }
        player.encode(into: drawable.texture, time: clock.tick(), commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
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
