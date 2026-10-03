import MetalKit
import SwiftUI

struct MetalViewer: NSViewRepresentable {
    let renderer: Renderer

    func makeNSView(context: Context) -> ComposerMTKView {
        let view = ComposerMTKView(frame: .zero, device: renderer.resources.device)
        view.colorPixelFormat = RenderResources.pixelFormat
        view.depthStencilPixelFormat = RenderResources.depthFormat
        view.clearDepth = 1
        view.preferredFramesPerSecond = 120
        view.renderer = renderer
        view.delegate = renderer
        return view
    }

    func updateNSView(_ view: ComposerMTKView, context: Context) {}
}

struct ViewerPanel: View {
    let renderer: Renderer
    @ObservedObject var playback: Playback
    /// True when shown in its own window.
    var isPoppedOut = false
    var onTogglePopOut: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { playback.isPlaying.toggle() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .help("Play / Pause (⌥⌘P)")
                Button { playback.restart() } label: { Image(systemName: "backward.end.fill") }
                    .help("Restart time")
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    Text(String(format: "%.1f s", playback.time)).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onTogglePopOut) {
                    Image(systemName: isPoppedOut ? "arrow.down.left.square" : "arrow.up.right.square")
                }
                .help(isPoppedOut ? "Put the viewer back in the main window (⌥⌘V)" : "Open the viewer in its own window (⌥⌘V)")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            MetalViewer(renderer: renderer)
        }
    }
}
