import Foundation
import Metal
import simd
import CoreGraphics

package enum PatchCategory: String, CaseIterable, Identifiable {
    case provider = "Providers"
    case processor = "Processors"
    case consumer = "Consumers"
    package var id: String { rawValue }
}

/// Static description of an input or output.
package struct PortSpec {
    package var key: String
    package var name: String
    package var type: PortType
    package var defaultValue: Value
    /// Suggested range for the slider and knob. It never restricts the value; use `limits` for that.
    package var range: ClosedRange<Double>? = nil
    /// Hard bounds the editor keeps the value within (e.g. a count can't go below 1).
    package var limits: ClosedRange<Double>? = nil
    /// Change per point when dragging a knob that has no suggested range.
    package var step: Double? = nil
    package var options: [String]? = nil
    /// `false` means the value is a setting edited only in the inspector (not connectable).
    package var isPort = true
    /// Internal value that is saved but never shown.
    package var hidden = false
    package var multiline = false
    package var isFilePath = false

    package static func number(_ key: String, _ name: String, _ value: Double = 0, _ range: ClosedRange<Double>? = nil) -> PortSpec {
        PortSpec(key: key, name: name, type: .number, defaultValue: .number(value), range: range)
    }
    package static func bool(_ key: String, _ name: String, _ value: Bool = false) -> PortSpec {
        PortSpec(key: key, name: name, type: .bool, defaultValue: .bool(value))
    }
    package static func color(_ key: String, _ name: String, _ value: SIMD4<Float> = .one) -> PortSpec {
        PortSpec(key: key, name: name, type: .color, defaultValue: .color(value))
    }
    package static func string(_ key: String, _ name: String, _ value: String = "", isPort: Bool = true,
                       multiline: Bool = false, isFilePath: Bool = false) -> PortSpec {
        PortSpec(key: key, name: name, type: .string, defaultValue: .string(value),
                 isPort: isPort, multiline: multiline, isFilePath: isFilePath)
    }
    package static func image(_ key: String, _ name: String) -> PortSpec {
        PortSpec(key: key, name: name, type: .image, defaultValue: .image(nil))
    }
    package static func structure(_ key: String, _ name: String) -> PortSpec {
        PortSpec(key: key, name: name, type: .structure, defaultValue: .structure(Structure()))
    }

    /// Accepts any value (QC's virtual port).
    package static func any(_ key: String, _ name: String, _ value: Value = .number(0)) -> PortSpec {
        PortSpec(key: key, name: name, type: .any, defaultValue: value)
    }

    /// A whole number ≥ 0 (indices, counts): knob step 0.1 per point, so 10 points per step.
    package static func index(_ key: String, _ name: String, _ value: Double = 0) -> PortSpec {
        var s = number(key, name, value).limited(min: 0)
        s.step = 0.1
        return s
    }

    /// A coordinate: no range (things move off-screen), knob step 0.005 per point.
    package static func position(_ key: String, _ name: String, _ value: Double = 0) -> PortSpec {
        var s = number(key, name, value)
        s.step = 0.005
        return s
    }

    /// An angle in degrees: no range (it can spin any number of turns), knob step 1° per point.
    package static func angle(_ key: String, _ name: String, _ value: Double = 0) -> PortSpec {
        var s = number(key, name, value)
        s.step = 1
        return s
    }

    package static func menu(_ key: String, _ name: String, _ options: [String], _ value: Int = 0) -> PortSpec {
        PortSpec(key: key, name: name, type: .number, defaultValue: .number(Double(value)), options: options)
    }

    package func setting() -> PortSpec { var s = self; s.isPort = false; return s }
    package func limited(_ bounds: ClosedRange<Double>) -> PortSpec { var s = self; s.limits = bounds; return s }
    package func limited(min: Double) -> PortSpec { limited(min...Double.infinity) }

    /// Applies the hard limits, if any.
    package func clamped(_ v: Double) -> Double {
        guard let limits else { return v }
        return Swift.min(Swift.max(v, limits.lowerBound), limits.upperBound)
    }
    package func hiddenSetting() -> PortSpec { var s = self; s.isPort = false; s.hidden = true; return s }
}

/// Resolved input values handed to a patch for one frame.
package struct Inputs {
    package let values: [String: Value]
    package func number(_ k: String) -> Double { values[k]?.number ?? 0 }
    package func float(_ k: String) -> Float { Float(number(k)) }
    package func int(_ k: String) -> Int { Int(number(k).rounded()) }
    package func bool(_ k: String) -> Bool { values[k]?.bool ?? false }
    package func color(_ k: String) -> SIMD4<Float> { values[k]?.color ?? .one }
    package func string(_ k: String) -> String { values[k]?.string ?? "" }
    package func image(_ k: String) -> MTLTexture? { values[k]?.image }
    package func structure(_ k: String) -> Structure { values[k]?.structure ?? Structure() }
}

package struct EvalContext {
    package let resources: RenderResources
    package let commandBuffer: MTLCommandBuffer
    /// Seconds on this patch's time base (see `Patch.usesTime`).
    package var time: Double
    /// Seconds since this patch last ran on its time base (0 or negative when time stops or rewinds).
    package var deltaTime: Double
    /// Viewer drawable size in pixels.
    package let viewportSize: CGSize
    /// Mouse position in composition units (x: -1…1, y: -h/w…h/w).
    package let mouse: SIMD2<Float>
    package let mouseDown: Bool
    /// Values of the enclosing macro's published inputs, keyed by port key.
    package var published: [String: Value] = [:]
    /// Current iteration when evaluated inside an Iterator.
    package var iteration: (index: Int, count: Int)? = nil
    /// Patches to evaluate even when nothing consumes them (for the inspector).
    package var inspect: Set<UUID> = []

    package init(resources: RenderResources, commandBuffer: MTLCommandBuffer, time: Double, deltaTime: Double,
                 viewportSize: CGSize, mouse: SIMD2<Float>, mouseDown: Bool,
                 published: [String: Value] = [:], iteration: (index: Int, count: Int)? = nil, inspect: Set<UUID> = []) {
        self.resources = resources
        self.commandBuffer = commandBuffer
        self.time = time
        self.deltaTime = deltaTime
        self.viewportSize = viewportSize
        self.mouse = mouse
        self.mouseDown = mouseDown
        self.published = published
        self.iteration = iteration
        self.inspect = inspect
    }

    package var device: MTLDevice { resources.device }
    package var aspect: Float { Float(viewportSize.width / max(viewportSize.height, 1)) }
}

package struct RenderContext {
    package let encoder: MTLRenderCommandEncoder
    /// The evaluation context of the patch that is drawing (its time base, iteration…).
    package var eval: EvalContext
    /// Size in pixels of the texture being rendered into.
    package let targetSize: CGSize
    /// Model transform accumulated from enclosing 3D Transformation patches.
    package var transform = matrix_identity_float4x4
    package var resources: RenderResources { eval.resources }
    package var aspect: Float { Float(targetSize.width / max(targetSize.height, 1)) }
    package var projection: simd_float4x4 { Camera.projection(aspect: aspect) }
    package var modelView: simd_float4x4 { Camera.view * transform }

    package func transformed(by m: simd_float4x4) -> RenderContext {
        var c = self
        c.transform = transform * m
        return c
    }
}

package typealias DrawCommand = (RenderContext) -> Void

/// Result of executing a patch once: its outputs plus any draw calls to replay in layer order.
package struct PatchResult {
    package var outputs: [String: Value] = [:]
    package var commands: [DrawCommand] = []
}

extension Notification.Name {
    package static let patchStatusChanged = Notification.Name("MetalComposer.patchStatusChanged")
}

/// Base class of every node. Subclasses override the class-level description
/// plus `evaluate` (providers/processors) or `render` (consumers).
/// Patches with dynamic ports (macros, published ports) override the instance-level accessors.
package class Patch: ObservableObject, Identifiable {
    package class var typeID: String { "patch" }
    package class var title: String { "Patch" }
    package class var category: PatchCategory { .processor }
    package class var librarySection: String { category.rawValue }
    package class var summary: String { "" }
    package class var inputSpecs: [PortSpec] { [] }
    package class var outputSpecs: [PortSpec] { [] }
    /// Time-based patches get QC's Time Base setting: Parent, Local or External (a Patch Time input).
    package class var usesTime: Bool { false }

    package static let timeBaseOptions = ["Parent", "Local", "External"]

    package let id: UUID
    package var position: CGPoint
    @Published package var params: [String: Value] = [:]
    @Published package var customTitle: String?
    @Published package private(set) var statusMessage: String?
    /// Outputs produced during the most recent evaluation (for the inspector and feedback loops).
    package var lastOutputs: [String: Value] = [:]

    package required init(id: UUID = UUID(), position: CGPoint = .zero) {
        self.id = id
        self.position = position
        var p: [String: Value] = [:]
        for spec in type(of: self).inputSpecs { p[spec.key] = spec.defaultValue }
        params = p
    }

    package var typeID: String { type(of: self).typeID }
    package var title: String { type(of: self).title }
    package var summary: String { type(of: self).summary }
    package var category: PatchCategory { type(of: self).category }
    /// The patch's own inputs; patches with dynamic ports override this.
    package var ownInputs: [PortSpec] { type(of: self).inputSpecs }
    /// Every input, including the Time Base setting and Patch Time port of time-based patches.
    package var allInputs: [PortSpec] { ownInputs + timeBaseInputs }

    package var usesTime: Bool { type(of: self).usesTime }
    /// 0 Parent, 1 Local, 2 External.
    package var timeBase: Int { usesTime ? Int((params["timeBase"]?.number ?? 0).rounded()) : 0 }

    private var timeBaseInputs: [PortSpec] {
        guard usesTime else { return [] }
        var specs = [PortSpec.menu("timeBase", "Time Base", Patch.timeBaseOptions).setting()]
        if timeBase == 2 {
            var patchTime = PortSpec.number("patchTime", "Patch Time")
            patchTime.step = 0.01
            specs.append(patchTime)
        }
        return specs
    }

    private var localStart: Double?
    private var lastExternalTime: Double?

    /// The context this patch runs in, with time replaced according to its Time Base.
    package func timeContext(_ inputs: Inputs, _ ctx: EvalContext) -> EvalContext {
        var c = ctx
        switch timeBase {
        case 1:
            if localStart == nil { localStart = ctx.time }
            c.time = ctx.time - (localStart ?? ctx.time)
        case 2:
            let t = inputs.number("patchTime")
            c.deltaTime = lastExternalTime.map { t - $0 } ?? 0
            lastExternalTime = t
            c.time = t
        default:
            break
        }
        return c
    }

    /// Playback restart: clears state here and in any child graph.
    package func restart() {
        localStart = nil
        lastExternalTime = nil
        reset()
        subgraph?.nodes.forEach { $0.restart() }
    }
    package var outputPorts: [PortSpec] { type(of: self).outputSpecs }
    package var inputPorts: [PortSpec] { allInputs.filter(\.isPort) }
    /// Child graph for macro-like patches.
    package var subgraph: Graph? { nil }

    package var displayTitle: String {
        if let t = customTitle, !t.isEmpty { return t }
        return title
    }
    package var headerTitle: String { displayTitle }

    /// Runs the patch for one frame. Consumers defer their drawing into a command.
    package func execute(_ inputs: Inputs, _ ctx: EvalContext) -> PatchResult {
        if category == .consumer {
            // Draw on this patch's own time base, not the viewer's.
            return PatchResult(commands: [{ [self] rc in
                var context = rc
                context.eval = ctx
                self.render(inputs, context)
            }])
        }
        return PatchResult(outputs: evaluate(inputs, ctx))
    }

    package func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] { [:] }
    package func render(_ inputs: Inputs, _ ctx: RenderContext) {}
    /// Values seen by a downstream patch that loops back into this one before it has run this frame.
    package func feedbackOutputs(_ ctx: EvalContext) -> [String: Value] { lastOutputs }
    /// Called when playback restarts.
    package func reset() {}

    package func setStatus(_ message: String?) {
        guard message != statusMessage else { return }
        statusMessage = message
        NotificationCenter.default.post(name: .patchStatusChanged, object: self)
    }

    package func record() -> NodeRecord {
        NodeRecord(id: id, type: typeID, x: position.x, y: position.y, name: customTitle,
                   params: params.filter { !$0.value.isImage }, subgraph: subgraph?.record())
    }
}

package enum PatchRegistry {
    package static let all: [Patch.Type] = [
        // Providers
        PatchTimePatch.self, MousePatch.self, RandomPatch.self, NumberPatch.self,
        ImageImporterPatch.self, TextImagePatch.self, AudioInputPatch.self, AudioSpectrumPatch.self,
        // Processors
        LFOPatch.self, InterpolationPatch.self, MathPatch.self, MathExpressionPatch.self,
        SmoothPatch.self, IntegratorPatch.self, CounterPatch.self, ConditionalPatch.self, MultiplexerPatch.self, DemultiplexerPatch.self,
        RGBColorPatch.self, HSLColorPatch.self,
        CoreImageFilterPatch.self,
        // Consumers
        ClearPatch.self, BillboardPatch.self, SpritePatch.self, ParticleSystemPatch.self, MetalShaderPatch.self,
        // Macros
        MacroPatch.self, IteratorPatch.self, RenderInImagePatch.self, Transform3DPatch.self,
        PublishedInputPatch.self, PublishedOutputPatch.self, IteratorVariablesPatch.self,
        // Structures
        StructureMakerPatch.self, StructureIndexMemberPatch.self, StructureKeyMemberPatch.self,
        StructureCountPatch.self, QueuePatch.self,
        // Utility
        CommentPatch.self,
    ]
    package static let byID: [String: Patch.Type] = Dictionary(uniqueKeysWithValues: all.map { ($0.typeID, $0) })
    package static let sections = ["Providers", "Processors", "Consumers", "Structures", "Macros", "Utility"]
}
