import CoreGraphics
import Metal

/// Renders one frame of a graph. Shared by the editor's viewer, movie export and embedding hosts.
package enum FrameRenderer {
    /// Renders one frame of `graph` into the pass's attachments (color must be `RenderResources.pixelFormat`,
    /// depth `RenderResources.depthFormat`).
    package static func encodeFrame(graph: Graph, context ctx: EvalContext, pass: MTLRenderPassDescriptor,
                            targetSize: CGSize, clearAlpha: Double = 1) {
        // Phase 1: execute the graph. Providers/processors run on demand; offscreen work
        // (Render In Image, Core Image, Queue copies) is encoded into the command buffer right away.
        let commands = Evaluator(graph: graph, context: ctx).drawCommands()

        // Phase 2: replay the consumers' draw commands in layer order.
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: clearAlpha)
        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let renderCtx = RenderContext(encoder: encoder, eval: ctx, targetSize: targetSize)
        commands.forEach { $0(renderCtx) }
        encoder.endEncoding()
    }
}
