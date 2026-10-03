import AppKit
import MetalKit
import QuartzCore

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

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = resources.queue.makeCommandBuffer() else { return }

        let clock = playback.tick()
        let ctx = EvalContext(resources: resources, commandBuffer: commandBuffer, time: clock.time,
                              deltaTime: clock.delta, viewportSize: view.drawableSize,
                              mouse: mouse, mouseDown: mouseDown)

        // Phase 1: pull every consumer's inputs (runs providers/processors, may encode compute work).
        let evaluator = Evaluator(composition: composition, context: ctx)
        let layers = composition.consumers.map { ($0, evaluator.inputs(for: $0)) }
        // Keep the inspector live for the selected patch even if nothing consumes it.
        if let selected = composition.selectedNode, selected.category != .consumer {
            _ = evaluator.outputs(of: selected)
        }

        // Phase 2: render consumers in layer order.
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let renderCtx = RenderContext(encoder: encoder, eval: ctx)
        for (patch, inputs) in layers {
            patch.render(inputs, renderCtx)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// MTKView that reports the mouse position in composition units.
final class ComposerMTKView: MTKView {
    weak var renderer: Renderer?

    override var acceptsFirstResponder: Bool { true }

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
