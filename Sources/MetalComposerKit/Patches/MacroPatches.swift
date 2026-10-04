import CoreGraphics
import Foundation
import Metal
import simd

// MARK: - Published ports

/// Base of the proxies that expose a port on the enclosing macro. The patch's name is the port name.
package class PublishedPortPatch: Patch {
    package override class var librarySection: String { "Macros" }
    package class var defaultName: String { "Port" }
    package override class var inputSpecs: [PortSpec] {
        [PortSpec.menu("type", "Type", PortType.allCases.map(\.displayName)).setting(),
         PortSpec.string("portKey", "Key", isPort: false).hiddenSetting()]
    }

    package required init(id: UUID = UUID(), position: CGPoint = .zero) {
        super.init(id: id, position: position)
        customTitle = type(of: self).defaultName
        regenerateKey()
    }

    /// Stable identifier of the published port, independent of the patch ID.
    package var portKey: String { params["portKey"]?.string ?? id.uuidString }

    package func regenerateKey() { params["portKey"] = .string(UUID().uuidString) }

    package var portType: PortType {
        get {
            let i = Int((params["type"] ?? .number(0)).number)
            return PortType.allCases.indices.contains(i) ? PortType.allCases[i] : .number
        }
        set { params["type"] = .number(Double(PortType.allCases.firstIndex(of: newValue) ?? 0)) }
    }

    /// Value used when nothing is connected to the port (and, at the top of a composition, until a host sets it).
    package var defaultValue: Value { params["default"]?.coerced(to: portType) ?? portType.defaultValue }

    package var publishedSpec: PortSpec {
        PortSpec(key: portKey, name: displayTitle, type: portType, defaultValue: defaultValue)
    }
}

package final class PublishedInputPatch: PublishedPortPatch {
    package override class var typeID: String { "macro-input" }
    package override class var title: String { "Macro Input" }
    package override class var category: PatchCategory { .provider }
    package override class var defaultName: String { "Input" }
    package override class var summary: String { "Inside a macro: adds an input port to the macro. Its name is the port name." }

    package override var outputPorts: [PortSpec] {
        [PortSpec(key: "value", name: portType.displayName, type: portType, defaultValue: portType.defaultValue)]
    }
    package override var headerTitle: String { "▶ " + displayTitle }

    /// A Default Value setting for types the inspector can edit. At the top of a composition these
    /// inputs are the composition's parameters (see `CompositionPlayer`).
    package override var ownInputs: [PortSpec] {
        var specs = type(of: self).inputSpecs
        if portType != .image && portType != .structure {
            specs.append(PortSpec(key: "default", name: "Default Value", type: portType, defaultValue: portType.defaultValue).setting())
        }
        return specs
    }

    package override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        ["value": ctx.published[portKey] ?? defaultValue]
    }
}

package final class PublishedOutputPatch: PublishedPortPatch {
    package override class var typeID: String { "macro-output" }
    package override class var title: String { "Macro Output" }
    package override class var category: PatchCategory { .processor }
    package override class var defaultName: String { "Output" }
    package override class var summary: String { "Inside a macro: adds an output port to the macro. Its name is the port name." }

    package override var ownInputs: [PortSpec] {
        type(of: self).inputSpecs
            + [PortSpec(key: "value", name: portType.displayName, type: portType, defaultValue: portType.defaultValue)]
    }
    package override var headerTitle: String { displayTitle + " ▶" }
}

// MARK: - Macro

/// A patch containing its own graph. Its ports are the Macro Input / Macro Output patches inside.
/// It renders (and gets a layer) when its contents include consumers.
package class MacroPatch: Patch {
    package override class var usesTime: Bool { true }
    package override class var typeID: String { "macro" }
    package override class var title: String { "Macro" }
    package override class var librarySection: String { "Macros" }
    package override class var summary: String { "Groups patches into one. Double-click to open; publish ports with Macro Input/Output." }

    package let contents = Graph()
    package override var subgraph: Graph? { contents }

    package override var category: PatchCategory { contents.containsConsumers ? .consumer : .processor }

    package var publishedInputs: [PublishedInputPatch] {
        contents.nodes.compactMap { $0 as? PublishedInputPatch }.sorted { $0.position.y < $1.position.y }
    }
    package var publishedOutputs: [PublishedOutputPatch] {
        contents.nodes.compactMap { $0 as? PublishedOutputPatch }.sorted { $0.position.y < $1.position.y }
    }

    package override var ownInputs: [PortSpec] { type(of: self).inputSpecs + publishedInputs.map(\.publishedSpec) }
    package override var outputPorts: [PortSpec] { type(of: self).outputSpecs + publishedOutputs.map(\.publishedSpec) }

    package func makeEvaluator(_ inputs: Inputs, _ ctx: EvalContext) -> Evaluator {
        var inner = ctx
        inner.published = [:]
        for proxy in publishedInputs {
            inner.published[proxy.portKey] = inputs.values[proxy.portKey] ?? proxy.defaultValue
        }
        return Evaluator(graph: contents, context: inner)
    }

    package func collectOutputs(_ evaluator: Evaluator) -> [String: Value] {
        var out: [String: Value] = [:]
        for proxy in publishedOutputs {
            out[proxy.portKey] = evaluator.inputs(for: proxy).values["value"]
        }
        return out
    }

    package override func execute(_ inputs: Inputs, _ ctx: EvalContext) -> PatchResult {
        let evaluator = makeEvaluator(inputs, ctx)
        let commands = evaluator.drawCommands()
        return PatchResult(outputs: collectOutputs(evaluator), commands: commands)
    }

    package override func reset() { contents.nodes.forEach { $0.reset() } }
}

// MARK: - Iterator

package final class IteratorPatch: MacroPatch {
    package override class var typeID: String { "iterator" }
    package override class var title: String { "Iterator" }
    package override class var summary: String { "Runs its contents N times per frame. Use Iterator Variables inside for index/position." }
    package override class var inputSpecs: [PortSpec] { [.number("iterations", "Iterations", 8, 0...100).limited(0...2000)] }

    package required init(id: UUID = UUID(), position: CGPoint = .zero) {
        super.init(id: id, position: position)
        contents.nodes.append(IteratorVariablesPatch(position: CGPoint(x: 40, y: 40)))
    }

    package override func execute(_ inputs: Inputs, _ ctx: EvalContext) -> PatchResult {
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

package final class IteratorVariablesPatch: Patch {
    package override class var typeID: String { "iterator-variables" }
    package override class var title: String { "Iterator Variables" }
    package override class var category: PatchCategory { .provider }
    package override class var librarySection: String { "Macros" }
    package override class var summary: String { "Inside an Iterator: current index, count and position (0…1)." }
    package override class var outputSpecs: [PortSpec] {
        [.number("index", "Current Index"), .number("count", "Iterations"), .number("position", "Current Position")]
    }

    package override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let (i, n) = ctx.iteration ?? (0, 1)
        return ["index": .number(Double(i)), "count": .number(Double(n)),
                "position": .number(n > 1 ? Double(i) / Double(n - 1) : 0)]
    }
}

// MARK: - Render In Image

/// Renders its contents into a texture instead of the viewer. Connecting its output back into
/// one of its own image inputs creates a feedback loop (the input sees the previous frame).
package final class RenderInImagePatch: MacroPatch {
    package override class var typeID: String { "render-in-image" }
    package override class var title: String { "Render In Image" }
    package override class var summary: String { "Renders its contents offscreen and outputs the image. Loop the output back in for feedback." }
    package override class var inputSpecs: [PortSpec] {
        [.number("width", "Width (0 = viewer)", 0, 0...2048).limited(0...8192),
         .number("height", "Height (0 = viewer)", 0, 0...2048).limited(0...8192),
         .color("clear", "Clear Color", SIMD4(0, 0, 0, 0))]
    }
    package override class var outputSpecs: [PortSpec] { [.image("image", "Image")] }

    package override var category: PatchCategory { .processor }
    package override var outputPorts: [PortSpec] { type(of: self).outputSpecs }

    // Two targets, alternated each frame, so the previous frame can be read while drawing the next.
    private var targets: [MTLTexture] = []
    private var depth: MTLTexture?
    private var current = 0

    package override func feedbackOutputs(_ ctx: EvalContext) -> [String: Value] {
        lastOutputs.isEmpty ? ["image": .image(ctx.resources.transparentTexture)] : lastOutputs
    }

    package override func execute(_ inputs: Inputs, _ ctx: EvalContext) -> PatchResult {
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
            let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderResources.depthFormat,
                                                              width: w, height: h, mipmapped: false)
            dd.usage = [.renderTarget]
            dd.storageMode = .private
            depth = ctx.device.makeTexture(descriptor: dd)
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
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return PatchResult(outputs: ["image": .image(nil)])
        }
        encoder.label = "Render In Image"
        let rc = RenderContext(encoder: encoder, eval: ctx, targetSize: CGSize(width: w, height: h))
        commands.forEach { $0(rc) }
        encoder.endEncoding()
        return PatchResult(outputs: ["image": .image(target)])
    }

    package override func reset() {
        super.reset()
        targets = []
        depth = nil
        lastOutputs = [:]
    }
}

// MARK: - 3D Transformation

/// Environment macro: everything rendered inside is translated, rotated and scaled in 3D.
/// Nested transformations multiply, so they can be stacked to build hierarchies.
package final class Transform3DPatch: MacroPatch {
    package override class var typeID: String { "3d-transformation" }
    package override class var title: String { "3D Transformation" }
    package override class var summary: String { "Moves, rotates and scales everything rendered inside it in 3D." }
    package override class var inputSpecs: [PortSpec] {
        [.position("tx", "X Translation"), .position("ty", "Y Translation"), .position("tz", "Z Translation"),
         .angle("rx", "X Rotation (°)"), .angle("ry", "Y Rotation (°)"), .angle("rz", "Z Rotation (°)"),
         .number("sx", "X Scale", 1, 0...2), .number("sy", "Y Scale", 1, 0...2), .number("sz", "Z Scale", 1, 0...2), // negative mirrors
         .position("ox", "Origin X").setting(), .position("oy", "Origin Y").setting(),
         .position("oz", "Origin Z").setting()]
    }

    package static func matrix(_ i: Inputs) -> simd_float4x4 {
        let origin = SIMD3(i.float("ox"), i.float("oy"), i.float("oz"))
        return simd_float4x4.translation(SIMD3(i.float("tx"), i.float("ty"), i.float("tz")) + origin)
            * simd_float4x4.rotation(degrees: SIMD3(i.float("rx"), i.float("ry"), i.float("rz")))
            * simd_float4x4.scale(SIMD3(i.float("sx"), i.float("sy"), i.float("sz")))
            * simd_float4x4.translation(-origin)
    }

    package override func execute(_ inputs: Inputs, _ ctx: EvalContext) -> PatchResult {
        var result = super.execute(inputs, ctx)
        let m = Self.matrix(inputs)
        result.commands = result.commands.map { command -> DrawCommand in { rc in command(rc.transformed(by: m)) } }
        return result
    }
}
