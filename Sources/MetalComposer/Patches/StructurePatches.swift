import Foundation
import Metal

/// Builds a structure from a configurable number of virtual inputs; keys name the members.
final class StructureMakerPatch: Patch {
    override class var typeID: String { "structure-maker" }
    override class var title: String { "Structure Maker" }
    override class var librarySection: String { "Structures" }
    override class var summary: String { "Combines its inputs (any type) into one structure. Optional keys name the members." }
    override class var inputSpecs: [PortSpec] {
        [PortSpec.number("count", "Inputs", 3, 1...16).limited(1...64).setting(),
         PortSpec.string("keys", "Keys (comma separated)", "", isPort: false)]
    }
    override class var outputSpecs: [PortSpec] { [.structure("structure", "Structure")] }

    var memberCount: Int { min(max(Int((params["count"]?.number ?? 3).rounded()), 1), 64) }

    /// Key for each member, or nil when none was given for that position.
    var keys: [String?] {
        let names = (params["keys"]?.string ?? "").split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return (0..<memberCount).map { i in names.indices.contains(i) && !names[i].isEmpty ? names[i] : nil }
    }

    override var ownInputs: [PortSpec] {
        type(of: self).inputSpecs + keys.enumerated().map { i, key in .any("m\(i)", key ?? "Member \(i + 1)") }
    }

    override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let members = keys.enumerated().map { i, key in
            Structure.Member(key: key, value: inputs.values["m\(i)"] ?? .number(0))
        }
        return ["structure": .structure(Structure(members: members))]
    }
}

final class StructureIndexMemberPatch: Patch {
    override class var typeID: String { "structure-index-member" }
    override class var title: String { "Structure Index Member" }
    override class var librarySection: String { "Structures" }
    override class var summary: String { "Picks the member at an index (0-based). Out of range outputs nothing." }
    override class var inputSpecs: [PortSpec] { [.structure("structure", "Structure"), .index("index", "Index")] }
    override class var outputSpecs: [PortSpec] { [.any("member", "Member")] }

    override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        guard let member = inputs.structure("structure").value(at: inputs.int("index")) else { return [:] }
        return ["member": member]
    }
}

final class StructureKeyMemberPatch: Patch {
    override class var typeID: String { "structure-key-member" }
    override class var title: String { "Structure Key Member" }
    override class var librarySection: String { "Structures" }
    override class var summary: String { "Picks the member with a given key. Missing keys output nothing." }
    override class var inputSpecs: [PortSpec] { [.structure("structure", "Structure"), .string("key", "Key")] }
    override class var outputSpecs: [PortSpec] { [.any("member", "Member")] }

    override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        guard let member = inputs.structure("structure").value(forKey: inputs.string("key")) else { return [:] }
        return ["member": member]
    }
}

final class StructureCountPatch: Patch {
    override class var typeID: String { "structure-count" }
    override class var title: String { "Structure Count" }
    override class var librarySection: String { "Structures" }
    override class var summary: String { "Number of members in a structure." }
    override class var inputSpecs: [PortSpec] { [.structure("structure", "Structure")] }
    override class var outputSpecs: [PortSpec] { [.number("count", "Count")] }

    override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        ["count": .number(Double(inputs.structure("structure").count))]
    }
}

/// Collects a value over time into a structure, dropping the oldest entries past Size.
/// Images are copied on the GPU when queued: producers such as Render In Image reuse their
/// textures every frame, so keeping references would make every entry show the latest frame.
final class QueuePatch: Patch {
    override class var typeID: String { "queue" }
    override class var title: String { "Queue" }
    override class var librarySection: String { "Structures" }
    override class var summary: String { "Builds a time series of its input (numbers, images…). Oldest entries drop off past Size." }
    override class var inputSpecs: [PortSpec] {
        [.any("value", "Value"), PortSpec.index("size", "Size", 10).limited(1...10000),
         .bool("filling", "Filling", true), .bool("reset", "Reset", false),
         PortSpec.menu("order", "Order", ["Oldest First", "Newest First"]).setting(),
         PortSpec.menu("add", "Add", ["Every Frame", "When Changed"]).setting()]
    }
    override class var outputSpecs: [PortSpec] { [.structure("queue", "Queue")] }

    private var items: [Value] = []
    private var lastAdded: Value?
    /// Copies of images that fell off the queue, reused for new copies of the same shape.
    private var pool: [MTLTexture] = []
    /// Textures this queue created; only these may be recycled (others belong to their producers).
    private var owned: Set<ObjectIdentifier> = []

    override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let size = min(max(inputs.int("size"), 1), 10000)
        if inputs.bool("reset") {
            items.forEach(recycle)
            items = []
            lastAdded = nil
        } else if inputs.bool("filling"), let value = inputs.values["value"] {
            let onlyChanges = inputs.int("add") == 1
            if !onlyChanges || lastAdded.map({ !value.isSame(as: $0) }) ?? true {
                items.append(stored(value, ctx))
                lastAdded = value
            }
        }
        while items.count > size { recycle(items.removeFirst()) }

        let ordered = inputs.int("order") == 1 ? items.reversed() : items
        return ["queue": .structure(Structure(members: ordered.map { .init(key: nil, value: $0) }))]
    }

    override func reset() {
        items = []
        lastAdded = nil
        pool = []
        owned = []
    }

    private func stored(_ value: Value, _ ctx: EvalContext) -> Value {
        guard case .image(let source?) = value, source.textureType == .type2D, source.mipmapLevelCount == 1,
              let copy = copyTexture(source, ctx) else { return value }
        return .image(copy)
    }

    private func copyTexture(_ source: MTLTexture, _ ctx: EvalContext) -> MTLTexture? {
        let target: MTLTexture
        if let i = pool.firstIndex(where: { $0.width == source.width && $0.height == source.height && $0.pixelFormat == source.pixelFormat }) {
            target = pool.remove(at: i)
        } else {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat, width: source.width,
                                                                height: source.height, mipmapped: false)
            desc.usage = [.shaderRead]
            desc.storageMode = .private
            guard let t = ctx.device.makeTexture(descriptor: desc) else { return nil }
            owned.insert(ObjectIdentifier(t))
            target = t
        }
        // Encoded before this frame's render pass, after earlier frames' reads of the reused texture.
        guard let blit = ctx.commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: source, to: target)
        blit.endEncoding()
        return target
    }

    private func recycle(_ value: Value) {
        guard case .image(let texture?) = value, owned.contains(ObjectIdentifier(texture)) else { return }
        if pool.count < 8 {
            pool.append(texture)
        } else {
            owned.remove(ObjectIdentifier(texture))
        }
    }
}
