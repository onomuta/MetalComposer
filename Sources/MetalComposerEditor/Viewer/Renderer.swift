import MetalKit
import QuartzCore
import MetalComposerKit

/// Playback clock shared by the viewer and toolbar.
final class Playback: ObservableObject {
    @Published var isPlaying = true
    private(set) var time: Double = 0
    private var lastHostTime: CFTimeInterval?
    var onRestart: (() -> Void)?

    func tick() -> (time: Double, delta: Double) {
        let now = CACurrentMediaTime()
        let delta = lastHostTime.map { now - $0 } ?? 0
        lastHostTime = now
        let step = isPlaying ? delta : 0
        time += step
        return (time, step)
    }

    func restart() {
        time = 0
        onRestart?()
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    let resources: RenderResources
    let composition: Composition
    let playback: Playback

    var mouse = SIMD2<Float>(0, 0)
    var mouseDown = false

    init(resources: RenderResources, composition: Composition, playback: Playback) {
        self.resources = resources
        self.composition = composition
        self.playback = playback
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Set while a movie export is running so the GPU isn't shared with the live preview.
    var isSuspended = false

    func draw(in view: MTKView) {
        guard !isSuspended,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = resources.queue.makeCommandBuffer() else { return }

        let clock = playback.tick()
        let ctx = EvalContext(resources: resources, commandBuffer: commandBuffer, time: clock.time,
                              deltaTime: clock.delta, viewportSize: view.drawableSize,
                              mouse: mouse, mouseDown: mouseDown, inspect: composition.selection)
        FrameRenderer.encodeFrame(graph: composition.root, context: ctx, pass: pass, targetSize: view.drawableSize)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

#if os(macOS)
/// MTKView that reports the mouse position in composition units.
final class ComposerMTKView: MTKView {
    weak var renderer: Renderer?

    override var acceptsFirstResponder: Bool { true }

    /// Windows that are closed and reopened (SwiftUI reuses them) can leave the view's draw loop
    /// stopped, so pause explicitly when leaving a window and resume when entering one.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isPaused = window == nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func update(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0 else { return }
        let x = Float(p.x / bounds.width) * 2 - 1
        let y = (Float(p.y / bounds.height) * 2 - 1) * Float(bounds.height / bounds.width)
        renderer?.mouse = SIMD2(x, y)
    }

    override func mouseMoved(with event: NSEvent) { update(event) }
    override func mouseDragged(with event: NSEvent) { update(event) }
    override func mouseDown(with event: NSEvent) { update(event); renderer?.mouseDown = true }
    override func mouseUp(with event: NSEvent) { update(event); renderer?.mouseDown = false }
}
#else
/// MTKView that reports the first finger (or the pointer, with a trackpad) in composition units.
final class ComposerMTKView: MTKView {
    weak var renderer: Renderer?

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func update(_ p: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        // UIKit's y runs down; composition units run up.
        let x = Float(p.x / bounds.width) * 2 - 1
        let y = (1 - Float(p.y / bounds.height) * 2) * Float(bounds.height / bounds.width)
        renderer?.mouse = SIMD2(x, y)
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) { update(g.location(in: self)) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.first.map { update($0.location(in: self)) }
        renderer?.mouseDown = true
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.first.map { update($0.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.first.map { update($0.location(in: self)) }
        renderer?.mouseDown = false
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        renderer?.mouseDown = false
    }
}
#endif
