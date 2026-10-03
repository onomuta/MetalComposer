import Foundation
import CoreGraphics

struct PortRef: Codable, Hashable {
    var node: UUID
    var port: String
}

struct Connection: Codable, Hashable, Identifiable {
    var id = UUID()
    var from: PortRef // an output
    var to: PortRef   // an input
}

/// The patch graph. Consumers are rendered in the order they appear in `nodes` (their layer order).
final class Composition: ObservableObject {
    @Published var nodes: [Patch] = []
    @Published var connections: [Connection] = []
    @Published var selection: UUID?
    @Published var fileURL: URL?
    /// Visible center of the editor in graph coordinates, used to place new patches.
    var visibleCenter = CGPoint(x: 300, y: 200)

    func node(_ id: UUID?) -> Patch? {
        guard let id else { return nil }
        return nodes.first { $0.id == id }
    }

    var selectedNode: Patch? { node(selection) }

    // MARK: Editing

    @discardableResult
    func add(_ type: Patch.Type, at position: CGPoint) -> Patch {
        let patch = type.init(position: position)
        nodes.append(patch)
        selection = patch.id
        return patch
    }

    func remove(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        connections.removeAll { $0.from.node == id || $0.to.node == id }
        if selection == id { selection = nil }
    }

    func connection(into input: PortRef) -> Connection? {
        connections.first { $0.to == input }
    }

    @discardableResult
    func connect(from output: PortRef, to input: PortRef) -> Bool {
        guard output.node != input.node,
              let src = node(output.node), let dst = node(input.node),
              let outSpec = src.outputPorts.first(where: { $0.key == output.port }),
              let inSpec = dst.inputPorts.first(where: { $0.key == input.port }),
              PortType.canConnect(from: outSpec.type, to: inSpec.type)
        else { return false }
        connections.removeAll { $0.to == input }
        connections.append(Connection(from: output, to: input))
        return true
    }

    func disconnect(_ connection: Connection) {
        connections.removeAll { $0.id == connection.id }
    }

    var consumers: [Patch] { nodes.filter { $0.category == .consumer } }

    func layerIndex(of patch: Patch) -> Int? {
        consumers.firstIndex { $0.id == patch.id }.map { $0 + 1 }
    }

    /// Moves a consumer up (+1) or down (-1) in the rendering order.
    func moveLayer(_ patch: Patch, by delta: Int) {
        let layers = consumers
        guard let i = layers.firstIndex(where: { $0.id == patch.id }) else { return }
        let j = i + delta
        guard layers.indices.contains(j),
              let a = nodes.firstIndex(where: { $0.id == layers[i].id }),
              let b = nodes.firstIndex(where: { $0.id == layers[j].id }) else { return }
        nodes.swapAt(a, b)
    }

    func touch() { objectWillChange.send() }

    // MARK: Persistence

    struct Document: Codable {
        var version = 1
        var nodes: [NodeRecord]
        var connections: [Connection]
    }

    struct NodeRecord: Codable {
        var id: UUID
        var type: String
        var x: Double
        var y: Double
        var params: [String: Value]
    }

    func encoded() throws -> Data {
        let doc = Document(
            nodes: nodes.map { n in
                NodeRecord(id: n.id, type: n.typeID, x: n.position.x, y: n.position.y,
                           params: n.params.filter { !$0.value.isImage })
            },
            connections: connections)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(doc)
    }

    func load(_ data: Data) throws {
        let doc = try JSONDecoder().decode(Document.self, from: data)
        var loaded: [Patch] = []
        for record in doc.nodes {
            guard let type = PatchRegistry.byID[record.type] else { continue }
            let patch = type.init(id: record.id, position: CGPoint(x: record.x, y: record.y))
            for (k, v) in record.params where patch.params[k] != nil { patch.params[k] = v }
            loaded.append(patch)
        }
        let ids = Set(loaded.map(\.id))
        replace(nodes: loaded, connections: doc.connections.filter { ids.contains($0.from.node) && ids.contains($0.to.node) })
    }

    func replace(nodes: [Patch], connections: [Connection]) {
        selection = nil
        self.nodes = nodes
        self.connections = connections
        DispatchQueue.main.async { NotificationCenter.default.post(name: .compositionReplaced, object: self) }
    }
}

// MARK: - Demo

extension Composition {
    func loadDemo() {
        fileURL = nil
        replace(nodes: [], connections: [])

        func put<T: Patch>(_ t: T.Type, _ x: CGFloat, _ y: CGFloat, _ params: [String: Value] = [:]) -> T {
            let p = t.init(position: CGPoint(x: x, y: y))
            for (k, v) in params { p.params[k] = v }
            nodes.append(p)
            return p
        }
        func link(_ a: Patch, _ out: String, _ b: Patch, _ inp: String) {
            connect(from: PortRef(node: a.id, port: out), to: PortRef(node: b.id, port: inp))
        }

        let clear = put(ClearPatch.self, 640, 40, ["color": .color(SIMD4(0.02, 0.02, 0.05, 1))])
        let shader = put(MetalShaderPatch.self, 640, 110)
        let sprite = put(SpritePatch.self, 640, 300, ["width": .number(1.3), "height": .number(0)])
        let particles = put(ParticleSystemPatch.self, 640, 520)

        let hueLFO = put(LFOPatch.self, 40, 40, ["type": .number(4), "period": .number(10), "amplitude": .number(0.5), "offset": .number(0.5)])
        let text = put(TextImagePatch.self, 40, 190, ["text": .string("Metal Composer"), "size": .number(120)])
        let bob = put(LFOPatch.self, 40, 300, ["period": .number(4), "amplitude": .number(0.06), "offset": .number(0)])
        let wobble = put(MathExpressionPatch.self, 40, 450, ["expression": .string("sin(t * 1.3) * 3 + a")])
        let mouse = put(MousePatch.self, 40, 590)
        let hsl = put(HSLColorPatch.self, 320, 600, ["saturation": .number(0.8), "luminosity": .number(0.6)])

        link(hueLFO, "value", shader, "p2")
        link(hueLFO, "value", hsl, "hue")
        link(text, "image", sprite, "image")
        link(bob, "value", sprite, "y")
        link(wobble, "result", sprite, "rotation")
        link(mouse, "x", particles, "x")
        link(mouse, "y", particles, "y")
        link(hsl, "color", particles, "color")
        _ = clear
        selection = shader.id
    }
}

extension Notification.Name {
    static let compositionReplaced = Notification.Name("MetalComposer.compositionReplaced")
}
