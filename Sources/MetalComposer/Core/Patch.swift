import Foundation
import Metal
import simd
import CoreGraphics

enum PatchCategory: String, CaseIterable, Identifiable {
    case provider = "Providers"
    case processor = "Processors"
    case consumer = "Consumers"
    var id: String { rawValue }
}

/// Static description of an input or output.
struct PortSpec {
    var key: String
    var name: String
    var type: PortType
    var defaultValue: Value
    /// Suggested range for the slider and knob. It never restricts the value; use `limits` for that.
    var range: ClosedRange<Double>? = nil
    /// Hard bounds the editor keeps the value within (e.g. a count can't go below 1).
    var limits: ClosedRange<Double>? = nil
    /// Change per point when dragging a knob that has no suggested range.
    var step: Double? = nil
    var options: [String]? = nil
    /// `false` means the value is a setting edited only in the inspector (not connectable).
    var isPort = true
    /// Internal value that is saved but never shown.
    var hidden = false
    var multiline = false
    var isFilePath = false

    static func number(_ key: String, _ name: String, _ value: Double = 0, _ range: ClosedRange<Double>? = nil) -> PortSpec {
        PortSpec(key: key, name: name, type: .number, defaultValue: .number(value), range: range)
    }
    static func bool(_ key: String, _ name: String, _ value: Bool = false) -> PortSpec {
        PortSpec(key: key, name: name, type: .bool, defaultValue: .bool(value))
    }
    static func color(_ key: String, _ name: String, _ value: SIMD4<Float> = .one) -> PortSpec {
        PortSpec(key: key, name: name, type: .color, defaultValue: .color(value))
    }
    static func string(_ key: String, _ name: String, _ value: String = "", isPort: Bool = true,
                       multiline: Bool = false, isFilePath: Bool = false) -> PortSpec {
        PortSpec(key: key, name: name, type: .string, defaultValue: .string(value),
                 isPort: isPort, multiline: multiline, isFilePath: isFilePath)
    }
    static func image(_ key: String, _ name: String) -> PortSpec {
        PortSpec(key: key, name: name, type: .image, defaultValue: .image(nil))
    }
    /// A coordinate: no range (things move off-screen), knob step 0.005 per point.
    static func position(_ key: String, _ name: String, _ value: Double = 0) -> PortSpec {
        var s = number(key, name, value)
        s.step = 0.005
        return s
    }

    /// An angle in degrees: no range (it can spin any number of turns), knob step 1° per point.
    static func angle(_ key: String, _ name: String, _ value: Double = 0) -> PortSpec {
        var s = number(key, name, value)
        s.step = 1
        return s
    }

    static func menu(_ key: String, _ name: String, _ options: [String], _ value: Int = 0) -> PortSpec {
        PortSpec(key: key, name: name, type: .number, defaultValue: .number(Double(value)), options: options)
    }

    func setting() -> PortSpec { var s = self; s.isPort = false; return s }
    func limited(_ bounds: ClosedRange<Double>) -> PortSpec { var s = self; s.limits = bounds; return s }
    func limited(min: Double) -> PortSpec { limited(min...Double.infinity) }

    /// Applies the hard limits, if any.
    func clamped(_ v: Double) -> Double {
        guard let limits else { return v }
        return Swift.min(Swift.max(v, limits.lowerBound), limits.upperBound)
    }
    func hiddenSetting() -> PortSpec { var s = self; s.isPort = false; s.hidden = true; return s }
}

/// Resolved input values handed to a patch for one frame.
struct Inputs {
    let values: [String: Value]
    func number(_ k: String) -> Double { values[k]?.number ?? 0 }
    func float(_ k: String) -> Float { Float(number(k)) }
    func int(_ k: String) -> Int { Int(number(k).rounded()) }
    func bool(_ k: String) -> Bool { values[k]?.bool ?? false }
    func color(_ k: String) -> SIMD4<Float> { values[k]?.color ?? .one }
    func string(_ k: String) -> String { values[k]?.string ?? "" }
    func image(_ k: String) -> MTLTexture? { values[k]?.image }
}

struct EvalContext {
    let resources: RenderResources
    let commandBuffer: MTLCommandBuffer
    let time: Double
    let deltaTime: Double
    /// Viewer drawable size in pixels.
    let viewportSize: CGSize
    /// Mouse position in composition units (x: -1…1, y: -h/w…h/w).
    let mouse: SIMD2<Float>
    let mouseDown: Bool
    /// Values of the enclosing macro's published inputs, keyed by port key.
    var published: [String: Value] = [:]
    /// Current iteration when evaluated inside an Iterator.
    var iteration: (index: Int, count: Int)? = nil
    /// Patches to evaluate even when nothing consumes them (for the inspector).
    var inspect: Set<UUID> = []

    var device: MTLDevice { resources.device }
    var aspect: Float { Float(viewportSize.width / max(viewportSize.height, 1)) }
}

struct RenderContext {
    let encoder: MTLRenderCommandEncoder
    let eval: EvalContext
    /// Size in pixels of the texture being rendered into.
    let targetSize: CGSize
    /// Model transform accumulated from enclosing 3D Transformation patches.
    var transform = matrix_identity_float4x4
    var resources: RenderResources { eval.resources }
    var aspect: Float { Float(targetSize.width / max(targetSize.height, 1)) }
    var projection: simd_float4x4 { Camera.projection(aspect: aspect) }
    var modelView: simd_float4x4 { Camera.view * transform }

    func transformed(by m: simd_float4x4) -> RenderContext {
        var c = self
        c.transform = transform * m
        return c
    }
}

typealias DrawCommand = (RenderContext) -> Void

/// Result of executing a patch once: its outputs plus any draw calls to replay in layer order.
struct PatchResult {
    var outputs: [String: Value] = [:]
    var commands: [DrawCommand] = []
}

extension Notification.Name {
    static let patchStatusChanged = Notification.Name("MetalComposer.patchStatusChanged")
}

/// Base class of every node. Subclasses override the class-level description
/// plus `evaluate` (providers/processors) or `render` (consumers).
/// Patches with dynamic ports (macros, published ports) override the instance-level accessors.
class Patch: ObservableObject, Identifiable {
    class var typeID: String { "patch" }
    class var title: String { "Patch" }
    class var category: PatchCategory { .processor }
    class var librarySection: String { category.rawValue }
    class var summary: String { "" }
    class var inputSpecs: [PortSpec] { [] }
    class var outputSpecs: [PortSpec] { [] }

    let id: UUID
    var position: CGPoint
    @Published var params: [String: Value] = [:]
    @Published var customTitle: String?
    @Published private(set) var statusMessage: String?
    /// Outputs produced during the most recent evaluation (for the inspector and feedback loops).
    var lastOutputs: [String: Value] = [:]

    required init(id: UUID = UUID(), position: CGPoint = .zero) {
        self.id = id
        self.position = position
        var p: [String: Value] = [:]
        for spec in type(of: self).inputSpecs { p[spec.key] = spec.defaultValue }
        params = p
    }

    var typeID: String { type(of: self).typeID }
    var title: String { type(of: self).title }
    var summary: String { type(of: self).summary }
    var category: PatchCategory { type(of: self).category }
    var allInputs: [PortSpec] { type(of: self).inputSpecs }
    var outputPorts: [PortSpec] { type(of: self).outputSpecs }
    var inputPorts: [PortSpec] { allInputs.filter(\.isPort) }
    /// Child graph for macro-like patches.
    var subgraph: Graph? { nil }

    var displayTitle: String {
        if let t = customTitle, !t.isEmpty { return t }
        return title
    }
    var headerTitle: String { displayTitle }

    /// Runs the patch for one frame. Consumers defer their drawing into a command.
    func execute(_ inputs: Inputs, _ ctx: EvalContext) -> PatchResult {
        if category == .consumer {
            return PatchResult(commands: [{ [self] rc in self.render(inputs, rc) }])
        }
        return PatchResult(outputs: evaluate(inputs, ctx))
    }

    func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] { [:] }
    func render(_ inputs: Inputs, _ ctx: RenderContext) {}
    /// Values seen by a downstream patch that loops back into this one before it has run this frame.
    func feedbackOutputs(_ ctx: EvalContext) -> [String: Value] { lastOutputs }
    /// Called when playback restarts.
    func reset() {}

    func setStatus(_ message: String?) {
        guard message != statusMessage else { return }
        statusMessage = message
        NotificationCenter.default.post(name: .patchStatusChanged, object: self)
    }

    func record() -> NodeRecord {
        NodeRecord(id: id, type: typeID, x: position.x, y: position.y, name: customTitle,
                   params: params.filter { !$0.value.isImage }, subgraph: subgraph?.record())
    }
}

enum PatchRegistry {
    static let all: [Patch.Type] = [
        // Providers
        PatchTimePatch.self, MousePatch.self, RandomPatch.self, NumberPatch.self,
        ImageImporterPatch.self, TextImagePatch.self,
        // Processors
        LFOPatch.self, InterpolationPatch.self, MathPatch.self, MathExpressionPatch.self,
        SmoothPatch.self, ConditionalPatch.self, RGBColorPatch.self, HSLColorPatch.self,
        CoreImageFilterPatch.self,
        // Consumers
        ClearPatch.self, BillboardPatch.self, SpritePatch.self, ParticleSystemPatch.self, MetalShaderPatch.self,
        // Macros
        MacroPatch.self, IteratorPatch.self, RenderInImagePatch.self, Transform3DPatch.self,
        PublishedInputPatch.self, PublishedOutputPatch.self, IteratorVariablesPatch.self,
        // Utility
        CommentPatch.self,
    ]
    static let byID: [String: Patch.Type] = Dictionary(uniqueKeysWithValues: all.map { ($0.typeID, $0) })
    static let sections = ["Providers", "Processors", "Consumers", "Macros", "Utility"]
}
