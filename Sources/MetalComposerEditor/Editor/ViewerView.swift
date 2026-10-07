import MetalKit
import SwiftUI
import MetalComposerKit

struct MetalViewer {
    let renderer: Renderer

    fileprivate func makeView() -> ComposerMTKView {
        let view = ComposerMTKView(frame: .zero, device: renderer.resources.device)
        view.colorPixelFormat = RenderResources.pixelFormat
        view.depthStencilPixelFormat = RenderResources.depthFormat
        view.clearDepth = 1
        view.preferredFramesPerSecond = 120
        view.renderer = renderer
        view.delegate = renderer
        return view
    }
}

#if os(macOS)
extension MetalViewer: NSViewRepresentable {
    func makeNSView(context: Context) -> ComposerMTKView { makeView() }
    func updateNSView(_ view: ComposerMTKView, context: Context) {}
}
#else
extension MetalViewer: UIViewRepresentable {
    func makeUIView(context: Context) -> ComposerMTKView { makeView() }
    func updateUIView(_ view: ComposerMTKView, context: Context) {}
}
#endif

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

/// How the viewer sits in the phone layout.
enum PhoneViewerMode: String {
    /// Above the editor (beside it in landscape).
    case expanded
    /// A thin bar with the controls and a small live preview.
    case collapsed
    /// The editor fills the screen; the viewer floats in a corner.
    case floating
}

struct ViewerPanel: View {
    let renderer: Renderer
    @ObservedObject var playback: Playback
    /// True when shown in its own window.
    var isPoppedOut = false
    /// Moves the viewer to or from its own window; nil where there is only one window (iOS).
    var onTogglePopOut: (() -> Void)?
    /// The phone layout's viewer mode, switched from the viewer's bar; nil elsewhere.
    var phoneMode: Binding<PhoneViewerMode>?
    /// Shared by the docked and popped-out viewer, and remembered between launches.
    @AppStorage("viewerAspect") private var aspectName = ViewerAspect.free.rawValue

    private var aspect: ViewerAspect { ViewerAspect(rawValue: aspectName) ?? .free }

    var body: some View {
        if phoneMode?.wrappedValue == .collapsed {
            collapsedBar
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    transportControls
                    Spacer()
                    Picker(selection: $aspectName) {
                        ForEach(ViewerAspect.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    } label: {
                        Image(systemName: "aspectratio")
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("Preview aspect ratio")
                    if let onTogglePopOut {
                        Button(action: onTogglePopOut) {
                            Image(systemName: isPoppedOut ? "arrow.down.left.square" : "arrow.up.right.square")
                        }
                        .help(isPoppedOut ? "Put the viewer back in the main window (⌥⌘V)" : "Open the viewer in its own window (⌥⌘V)")
                    }
                    phoneModeButtons
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .gesture(phoneSwipe)
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

    private var transportControls: some View {
        Group {
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
        }
    }

    /// The controls and a small live preview: the composition keeps rendering, so time and
    /// stateful patches go on as before.
    private var collapsedBar: some View {
        HStack(spacing: 10) {
            transportControls
            Spacer()
            MetalViewer(renderer: renderer)
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            phoneModeButtons
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .gesture(phoneSwipe)
    }

    @ViewBuilder private var phoneModeButtons: some View {
        if let phoneMode {
            let collapsed = phoneMode.wrappedValue == .collapsed
            Button { withAnimation { phoneMode.wrappedValue = collapsed ? .expanded : .collapsed } } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
            }
            .accessibilityLabel(collapsed ? "Expand Viewer" : "Collapse Viewer")
            Button { withAnimation { phoneMode.wrappedValue = .floating } } label: {
                Image(systemName: "pip.enter")
            }
            .accessibilityLabel("Float Viewer")
        }
    }

    /// Phone: swipe the bar up to collapse the viewer, down to expand it.
    private var phoneSwipe: some Gesture {
        DragGesture(minimumDistance: 15).onEnded { value in
            guard let phoneMode, abs(value.translation.height) > abs(value.translation.width) else { return }
            withAnimation { phoneMode.wrappedValue = value.translation.height < 0 ? .collapsed : .expanded }
        }
    }
}
