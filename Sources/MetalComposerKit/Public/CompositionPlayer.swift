import CoreGraphics
import Foundation
import Metal

/// GPU state shared by every `CompositionPlayer` on one device (render pipelines, samplers,
/// texture loader). Create one per `MTLDevice` and reuse it.
public final class MetalComposerEngine {
    /// Color format players render into. Targets passed to `CompositionPlayer.encode` must use it.
    public static let pixelFormat: MTLPixelFormat = RenderResources.pixelFormat

    package let resources: RenderResources

    public var device: MTLDevice { resources.device }

    public init(device: MTLDevice) throws {
        resources = try RenderResources(device: device)
    }
}

/// The type of a composition parameter.
public enum CompositionParameterType: String, Sendable {
    case number, boolean, color, string, image, structure, any

    init(_ type: PortType) {
        switch type {
        case .number: self = .number
        case .bool: self = .boolean
        case .color: self = .color
        case .string: self = .string
        case .image: self = .image
        case .structure: self = .structure
        case .any: self = .any
        }
    }
}

/// A value for a composition parameter.
public enum CompositionValue {
    case number(Double)
    case boolean(Bool)
    case color(SIMD4<Float>)
    case string(String)
    case image(MTLTexture?)

    init(_ value: Value) {
        switch value {
        case .number(let v): self = .number(v)
        case .bool(let v): self = .boolean(v)
        case .color(let v): self = .color(v)
        case .string(let v): self = .string(v)
        case .image(let v): self = .image(v)
        case .structure(let s): self = .string(s.summary)
        }
    }

    var value: Value {
        switch self {
        case .number(let v): return .number(v)
        case .boolean(let v): return .bool(v)
        case .color(let v): return .color(v)
        case .string(let v): return .string(v)
        case .image(let v): return .image(v)
        }
    }
}

/// A Macro Input placed at the top level of a composition. Hosts show these as controls
/// (and can map them to MIDI); values set with `CompositionPlayer.setValue` reach the patches.
public struct CompositionParameter: Identifiable {
    public let key: String
    public let name: String
    public let type: CompositionParameterType
    public let defaultValue: CompositionValue
    public var id: String { key }
}

/// Plays one `.mcomp` composition inside another app: renders it at a given time into a
/// texture, inside the host's command buffer.
///
/// Use it on the main thread, like the editor does. Time is the composition's own clock in
/// seconds; it may stop, jump or run backwards (stateful patches such as particles follow it).
public final class CompositionPlayer {
    /// Newest `.mcomp` format this engine reads.
    public static let supportedFormatVersion = 2

    public enum LoadError: LocalizedError {
        case unsupportedVersion(Int)
        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                return "This composition was saved by a newer Metal Composer (format \(v)); this engine reads up to \(CompositionPlayer.supportedFormatVersion)."
            }
        }
    }

    public let engine: MetalComposerEngine
    /// Top-level Macro Input patches, top to bottom.
    public let parameters: [CompositionParameter]

    private let graph = Graph()
    /// Patch types the file uses that this engine doesn't know; those patches are skipped.
    private let unknownPatchTypes: [String]
    private let baseDirectory: URL?
    private var values: [String: Value] = [:]
    private var lastTime: Double?
    private var depth: MTLTexture?

    /// Loads a composition file. Relative file paths inside it resolve against its folder.
    public convenience init(engine: MetalComposerEngine, contentsOf url: URL) throws {
        try self.init(engine: engine, data: Data(contentsOf: url), baseDirectory: url.deletingLastPathComponent())
    }

    public init(engine: MetalComposerEngine, data: Data, baseDirectory: URL? = nil) throws {
        let record = try JSONDecoder().decode(GraphRecord.self, from: data)
        if let version = record.version, version > Self.supportedFormatVersion {
            throw LoadError.unsupportedVersion(version)
        }
        self.engine = engine
        self.baseDirectory = baseDirectory
        unknownPatchTypes = record.unknownPatchTypes
        graph.load(record)
        parameters = graph.nodes.compactMap { $0 as? PublishedInputPatch }
            .sorted { $0.position.y < $1.position.y }
            .map { CompositionParameter(key: $0.portKey, name: $0.displayTitle,
                                        type: CompositionParameterType($0.portType),
                                        defaultValue: CompositionValue($0.defaultValue)) }
    }

    /// Sets a parameter; it applies from the next `encode`. Unknown keys are ignored.
    public func setValue(_ value: CompositionValue, forParameter key: String) {
        guard parameters.contains(where: { $0.key == key }) else { return }
        values[key] = value.value
    }

    /// The parameter's current value (its default until set).
    public func value(forParameter key: String) -> CompositionValue? {
        if let v = values[key] { return CompositionValue(v) }
        return parameters.first { $0.key == key }?.defaultValue
    }

    /// Clears every patch's state (particles, queues, counters…), like restarting playback.
    public func restart() {
        graph.nodes.forEach { $0.restart() }
        lastTime = nil
    }

    /// Problems for the host's UI: patches this engine doesn't know (skipped when loading), and
    /// problems reported by patches (missing image, shader compile error…).
    public var problems: [String] {
        func collect(_ g: Graph) -> [String] {
            g.nodes.flatMap { node in
                (node.statusMessage.map { ["\(node.displayTitle): \($0)"] } ?? []) + (node.subgraph.map(collect) ?? [])
            }
        }
        let unknown = unknownPatchTypes.map {
            "Unknown patch \"\($0)\" (saved by a newer Metal Composer?); it was skipped along with its connections."
        }
        return unknown + collect(graph)
    }

    /// Renders the composition at `time` into `target` (format `MetalComposerEngine.pixelFormat`)
    /// by encoding into `commandBuffer`. The target is cleared first; `clearAlpha` 0 keeps areas
    /// the composition doesn't draw transparent, 1 makes them opaque black.
    public func encode(into target: MTLTexture, time: Double, commandBuffer: MTLCommandBuffer, clearAlpha: Double = 1) {
        precondition(target.pixelFormat == MetalComposerEngine.pixelFormat,
                     "CompositionPlayer renders into \(MetalComposerEngine.pixelFormat) textures")
        let resources = engine.resources
        resources.baseDirectory = baseDirectory
        let size = CGSize(width: target.width, height: target.height)

        if depth?.width != target.width || depth?.height != target.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderResources.depthFormat,
                                                                width: target.width, height: target.height, mipmapped: false)
            desc.usage = [.renderTarget]
            desc.storageMode = .private
            depth = resources.device.makeTexture(descriptor: desc)
        }

        var published: [String: Value] = [:]
        for p in parameters { published[p.key] = values[p.key] ?? p.defaultValue.value }
        let ctx = EvalContext(resources: resources, commandBuffer: commandBuffer, time: time,
                              deltaTime: lastTime.map { time - $0 } ?? 0, viewportSize: size,
                              mouse: .zero, mouseDown: false, published: published)
        lastTime = time

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        FrameRenderer.encodeFrame(graph: graph, context: ctx, pass: pass, targetSize: size, clearAlpha: clearAlpha)
    }
}
