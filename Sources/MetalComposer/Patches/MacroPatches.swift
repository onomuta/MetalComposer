import CoreGraphics
import Foundation
import Metal

// MARK: - Published ports

/// Base of the proxies that expose a port on the enclosing macro. The patch's name is the port name.
class PublishedPortPatch: Patch {
    override class var librarySection: String { "Macros" }
    class var defaultName: String { "Port" }
    override class var inputSpecs: [PortSpec] {
        [PortSpec.menu("type", "Type", PortType.allCases.map(\.displayName)).setting(),
         PortSpec.string("portKey", "Key", isPort: false).hiddenSetting()]
    }

    required init(id: UUID = UUID(), position: CGPoint = .zero) {
        super.init(id: id, position: position)
        customTitle = type(of: self).defaultName
        regenerateKey()
    }

    /// Stable identifier of the published port, independent of the patch ID.
    var portKey: String { params["portKey"]?.string ?? id.uuidString }

    func regenerateKey() { params["portKey"] = .string(UUID().uuidString) }

    var portType: PortType {
        get {
            let i = Int((params["type"] ?? .number(0)).number)
            return PortType.allCases.indices.contains(i) ? PortType.allCases[i] : .number
        }
        set { params["type"] = .number(Double(PortType.allCases.firstIndex(of: newValue) ?? 0)) }
    }

    var publishedSpec: PortSpec {
        PortSpec(key: portKey, name: displayTitle, type: portType, defaultValue: portType.defaultValue)
    }
}

final class PublishedInputPatch: PublishedPortPatch {
    override class var typeID: String { "macro-input" }
    override class var title: String { "Macro Input" }
    override class var category: PatchCategory { .provider }
    override class var defaultName: String { "Input" }
    override class var summary: String { "Inside a macro: adds an input port to the macro. Its name is the port name." }

    override var outputPorts: [PortSpec] {
        [PortSpec(key: "value", name: portType.displayName, type: portType, defaultValue: portType.defaultValue)]
    }
    override var headerTitle: String { "▶ " + displayTitle }

    override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        ["value": ctx.published[portKey] ?? portType.defaultValue]
    }
}

final class PublishedOutputPatch: PublishedPortPatch {
    override class var typeID: String { "macro-output" }
    override class var title: String { "Macro Output" }
    override class var category: PatchCategory { .processor }
    override class var defaultName: String { "Output" }
    override class var summary: String { "Inside a macro: adds an output port to the macro. Its name is the port name." }

    override var allInputs: [PortSpec] {
        type(of: self).inputSpecs
            + [PortSpec(key: "value", name: portType.displayName, type: portType, defaultValue: portType.defaultValue)]
    }
    override var headerTitle: String { displayTitle + " ▶" }
}

// MARK: - Macro

/// A patch containing its own graph. Its ports are the Macro Input / Macro Output patches inside.
/// It renders (and gets a layer) when its contents include consumers.
class MacroPatch: Patch {
    override class var typeID: String { "macro" }
    override class var title: String { "Macro" }
    override class var librarySection: String { "Macros" }
    override class var summary: String { "Groups patches into one. Double-click to open; publish ports with Macro Input/Output." }

    let contents = Graph()
    override var subgraph: Graph? { contents }

    override var category: PatchCategory { contents.containsConsumers ? .consumer : .processor }

    var publishedInputs: [PublishedInputPatch] {
        contents.nodes.compactMap { $0 as? PublishedInputPatch }.sorted { $0.position.y < $1.position.y }
    }
    var publishedOutputs: [PublishedOutputPatch] {
        contents.nodes.compactMap { $0 as? PublishedOutputPatch }.sorted { $0.position.y < $1.position.y }
    }

    override var allInputs: [PortSpec] { type(of: self).inputSpecs + publishedInputs.map(\.publishedSpec) }
    override var outputPorts: [PortSpec] { type(of: self).outputSpecs + publishedOutputs.map(\.publishedSpec) }

    func makeEvaluator(_ inputs: Inputs, _ ctx: EvalContext) -> Evaluator {
        var inner = ctx
        inner.published = [:]
        for proxy in publishedInputs {
            inner.published[proxy.portKey] = inputs.values[proxy.portKey] ?? proxy.portType.defaultValue
        }
        return Evaluator(graph: contents, context: inner)
    }

    func collectOutputs(_ evaluator: Evaluator) -> [String: Value] {
        var out: [String: Value] = [:]
        for proxy in publishedOutputs {
            out[proxy.portKey] = evaluator.inputs(for: proxy).values["value"]
        }
        return out
    }

    override func execute(_ inputs: Inputs, _ ctx: EvalContext) -> PatchResult {
        let evaluator = makeEvaluator(inputs, ctx)
        let commands = evaluator.drawCommands()
        return PatchResult(outputs: collectOutputs(evaluator), commands: commands)
    }

    override func reset() { contents.nodes.forEach { $0.reset() } }
}

// MARK: - Iterator

final class IteratorPatch: MacroPatch {
    override class var typeID: String { "iterator" }
    override class var title: String { "Iterator" }
    override class var summary: String { "Runs its contents N times per frame. Use Iterator Variables inside for index/position." }
    override class var inputSpecs: [PortSpec] { [.number("iterations", "Iterations", 8, 0...200)] }

    required init(id: UUID = UUID(), position: CGPoint = .zero) {
        super.init(id: id, position: position)
        contents.nodes.append(IteratorVariablesPatch(position: CGPoint(x: 40, y: 40)))
    }

    override func execute(_ inputs: Inputs, _ ctx: EvalContext) -> PatchResult {
        let count = max(0, min(inputs.int("iterations"), 2000))
        var result = PatchResult()
        for i in 0..<count {
            var c = ctx
            c.iteration = (i, count)
            let evaluator = makeEvaluator(inputs, c)
            result.commands += evaluator.drawCommands()
            result.outputs = collectOutputs(evaluator) // outputs of the last iteration
        }
        return result
    }
}

final class IteratorVariablesPatch: Patch {
    override class var typeID: String { "iterator-variables" }
    override class var title: String { "Iterator Variables" }
    override class var category: PatchCategory { .provider }
    override class var librarySection: String { "Macros" }
    override class var summary: String { "Inside an Iterator: current index, count and position (0…1)." }
    override class var outputSpecs: [PortSpec] {
        [.number("index", "Current Index"), .number("count", "Iterations"), .number("position", "Current Position")]
    }

    override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let (i, n) = ctx.iteration ?? (0, 1)
        return ["index": .number(Double(i)), "count": .number(Double(n)),
                "position": .number(n > 1 ? Double(i) / Double(n - 1) : 0)]
    }
}

// MARK: - Render In Image

/// Renders its contents into a texture instead of the viewer. Connecting its output back into
/// one of its own image inputs creates a feedback loop (the input sees the previous frame).
final class RenderInImagePatch: MacroPatch {
    override class var typeID: String { "render-in-image" }
    override class var title: String { "Render In Image" }
    override class var summary: String { "Renders its contents offscreen and outputs the image. Loop the output back in for feedback." }
    override class var inputSpecs: [PortSpec] {
        [.number("width", "Width (0 = viewer)", 0, 0...4096), .number("height", "Height (0 = viewer)", 0, 0...4096),
         .color("clear", "Clear Color", SIMD4(0, 0, 0, 0))]
    }
    override class var outputSpecs: [PortSpec] { [.image("image", "Image")] }

    override var category: PatchCategory { .processor }
    override var outputPorts: [PortSpec] { type(of: self).outputSpecs }

    // Two targets, alternated each frame, so the previous frame can be read while drawing the next.
    private var targets: [MTLTexture] = []
    private var current = 0

    override func feedbackOutputs(_ ctx: EvalContext) -> [String: Value] {
        lastOutputs.isEmpty ? ["image": .image(ctx.resources.transparentTexture)] : lastOutputs
    }

    override func execute(_ inputs: Inputs, _ ctx: EvalContext) -> PatchResult {
        let evaluator = makeEvaluator(inputs, ctx)
        let commands = evaluator.drawCommands()

        var w = inputs.int("width"), h = inputs.int("height")
        if w <= 0 { w = Int(ctx.viewportSize.width) }
        if h <= 0 { h = Int(ctx.viewportSize.height) }
        w = min(max(w, 1), 8192)
        h = min(max(h, 1), 8192)

        if targets.count != 2 || targets[0].width != w || targets[0].height != h {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderResources.pixelFormat,
                                                                width: w, height: h, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            targets = (0..<2).compactMap { _ in ctx.device.makeTexture(descriptor: desc) }
        }
        guard targets.count == 2 else { return PatchResult(outputs: ["image": .image(nil)]) }
        current ^= 1
        let target = targets[current]

        let pass = MTLRenderPassDescriptor()
        let clear = inputs.color("clear")
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(clear.x), green: Double(clear.y),
                                                            blue: Double(clear.z), alpha: Double(clear.w))
        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return PatchResult(outputs: ["image": .image(nil)])
        }
        encoder.label = "Render In Image"
        let rc = RenderContext(encoder: encoder, eval: ctx, targetSize: CGSize(width: w, height: h))
        commands.forEach { $0(rc) }
        encoder.endEncoding()
        return PatchResult(outputs: ["image": .image(target)])
    }

    override func reset() {
        super.reset()
        targets = []
        lastOutputs = [:]
    }
}
