import Foundation
import Metal
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
    var range: ClosedRange<Double>? = nil
    var options: [String]? = nil
    /// `false` means the value is a setting edited only in the inspector (not connectable).
    var isPort = true
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
    static func menu(_ key: String, _ name: String, _ options: [String], _ value: Int = 0) -> PortSpec {
        PortSpec(key: key, name: name, type: .number, defaultValue: .number(Double(value)), options: options)
    }
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
    /// Drawable size in pixels.
    let viewportSize: CGSize
    /// Mouse position in composition units (x: -1…1, y: -h/w…h/w).
    let mouse: SIMD2<Float>
    let mouseDown: Bool

    var device: MTLDevice { resources.device }
    var aspect: Float { Float(viewportSize.width / max(viewportSize.height, 1)) }
}

struct RenderContext {
    let encoder: MTLRenderCommandEncoder
    let eval: EvalContext
    var resources: RenderResources { eval.resources }
}

/// Base class of every node. Subclasses override the class-level description
/// plus `evaluate` (providers/processors) or `render` (consumers).
class Patch: ObservableObject, Identifiable {
    class var typeID: String { "patch" }
    class var title: String { "Patch" }
    class var category: PatchCategory { .processor }
    class var summary: String { "" }
    class var inputSpecs: [PortSpec] { [] }
    class var outputSpecs: [PortSpec] { [] }

    let id: UUID
    var position: CGPoint
    @Published var params: [String: Value] = [:]
    @Published private(set) var statusMessage: String?
    /// Outputs produced during the most recent evaluation (for the inspector).
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
    var category: PatchCategory { type(of: self).category }
    var summary: String { type(of: self).summary }
    var allInputs: [PortSpec] { type(of: self).inputSpecs }
    var inputPorts: [PortSpec] { type(of: self).inputSpecs.filter(\.isPort) }
    var outputPorts: [PortSpec] { type(of: self).outputSpecs }

    func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] { [:] }
    func render(_ inputs: Inputs, _ ctx: RenderContext) {}
    /// Called when playback restarts.
    func reset() {}

    func setStatus(_ message: String?) {
        if message != statusMessage { statusMessage = message }
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
        ClearPatch.self, SpritePatch.self, ParticleSystemPatch.self, MetalShaderPatch.self,
    ]
    static let byID: [String: Patch.Type] = Dictionary(uniqueKeysWithValues: all.map { ($0.typeID, $0) })
}
