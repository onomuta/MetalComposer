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

/// Preview shape. Free fills the available space; the others letterbox to a fixed ratio.
enum ViewerAspect: String, CaseIterable, Identifiable {
    case free = "Free"
    case r16x9 = "16:9"
    case r4x3 = "4:3"
    case r1x1 = "1:1"
    case r9x16 = "9:16"
    case r21x9 = "21:9"
    case r3x2 = "3:2"

    var id: String { rawValue }

    /// Width / height, or nil for Free.
    var ratio: CGFloat? {
        let parts = rawValue.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 ? CGFloat(parts[0] / parts[1]) : nil
    }

    /// The largest size with this ratio that fits in `space`.
    func fitted(in space: CGSize) -> CGSize {
        guard let ratio, space.width > 0, space.height > 0 else { return space }
        return space.width / space.height > ratio
            ? CGSize(width: space.height * ratio, height: space.height)
            : CGSize(width: space.width, height: space.width / ratio)
    }
}

struct ViewerPanel: View {
    let renderer: Renderer
    @ObservedObject var playback: Playback
    /// True when shown in its own window.
    var isPoppedOut = false
    var onTogglePopOut: () -> Void = {}
    /// Shared by the docked and popped-out viewer, and remembered between launches.
    @AppStorage("viewerAspect") private var aspectName = ViewerAspect.free.rawValue

    private var aspect: ViewerAspect { ViewerAspect(rawValue: aspectName) ?? .free }

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
                Picker(selection: $aspectName) {
                    ForEach(ViewerAspect.allCases) { Text($0.rawValue).tag($0.rawValue) }
                } label: {
                    Image(systemName: "aspectratio")
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Preview aspect ratio")
                Button(action: onTogglePopOut) {
                    Image(systemName: isPoppedOut ? "arrow.down.left.square" : "arrow.up.right.square")
                }
                .help(isPoppedOut ? "Put the viewer back in the main window (⌥⌘V)" : "Open the viewer in its own window (⌥⌘V)")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            GeometryReader { geo in
                let size = aspect.fitted(in: geo.size)
                // Same view in every mode (only its frame changes), so switching never recreates it.
                MetalViewer(renderer: renderer)
                    .frame(width: size.width, height: size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(white: 0.06))
        }
    }
}
