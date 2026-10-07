import MetalKit
#if os(iOS)
import MetalPerformanceShaders
#endif
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
        // Mirror previews copy the frame out of the drawable.
        view.framebufferOnly = false
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
                    ParametersButton(composition: renderer.composition, parameters: renderer.parameters)
                    if let onTogglePopOut {
                        Button(action: onTogglePopOut) {
                            Image(systemName: isPoppedOut ? "arrow.down.left.square" : "arrow.up.right.square")
                        }
                        .help(loc(isPoppedOut ? "Put the viewer back in the main window (⌥⌘V)" : "Open the viewer in its own window (⌥⌘V)"))
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
            ParametersButton(composition: renderer.composition, parameters: renderer.parameters)
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
            .accessibilityLabel(loc(collapsed ? "Expand Viewer" : "Collapse Viewer"))
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

#if os(iOS)
/// A small copy of what the viewer shows (for the phone layout's inspector sheet). It draws no
/// frames of its own, only scales the viewer's latest one, so playback isn't doubled.
struct MirrorViewer: View {
    let renderer: Renderer
    /// Width / height of the viewer's frames, checked now and then (the viewer can be resized).
    @State private var aspect: CGFloat = 16 / 9

    var body: some View {
        MirrorMetalView(renderer: renderer)
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
                if let frame = renderer.lastFrame, frame.height > 0 {
                    let new = CGFloat(frame.width) / CGFloat(frame.height)
                    if abs(new - aspect) > 0.01 { aspect = new }
                }
            }
    }
}

private struct MirrorMetalView: UIViewRepresentable {
    let renderer: Renderer

    func makeCoordinator() -> Coordinator { Coordinator(renderer: renderer) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.resources.device)
        view.colorPixelFormat = RenderResources.pixelFormat
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 30
        view.delegate = context.coordinator
        renderer.mirrorCount += 1
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.renderer.mirrorCount -= 1
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let renderer: Renderer
        private lazy var scaler = MPSImageBilinearScale(device: renderer.resources.device)

        init(renderer: Renderer) { self.renderer = renderer }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let commandBuffer = renderer.resources.queue.makeCommandBuffer() else { return }
            if let frame = renderer.lastFrame {
                // The view is shaped like the frame (see `aspect`), so the frame just fills it.
                scaler.encode(commandBuffer: commandBuffer, sourceTexture: frame, destinationTexture: drawable.texture)
            } else {
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
#endif
