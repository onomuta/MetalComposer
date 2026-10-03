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

/// Serialized form of a graph; also the `.mcomp` file format and the clipboard format.
struct GraphRecord: Codable {
    var version: Int? = 2
    var nodes: [NodeRecord]
    var connections: [Connection]
}

struct NodeRecord: Codable {
    var id: UUID
    var type: String
    var x: Double
    var y: Double
    var name: String?
    var params: [String: Value]
    var subgraph: GraphRecord?
}

/// A set of patches and the wires between them. The root composition and every macro own one.
/// Consumers render in the order they appear in `nodes` (their layer order).
final class Graph {
    var nodes: [Patch] = []
    var connections: [Connection] = []

    func node(_ id: UUID?) -> Patch? {
        guard let id else { return nil }
        return nodes.first { $0.id == id }
    }

    func connection(into input: PortRef) -> Connection? {
        connections.first { $0.to == input }
    }

    var consumers: [Patch] { nodes.filter { $0.category == .consumer } }
    var containsConsumers: Bool { nodes.contains { $0.category == .consumer } }

    func layerIndex(of patch: Patch) -> Int? {
        consumers.firstIndex { $0.id == patch.id }.map { $0 + 1 }
    }

    func canConnect(from output: PortRef, to input: PortRef) -> Bool {
        guard let src = node(output.node), let dst = node(input.node),
              let outSpec = src.outputPorts.first(where: { $0.key == output.port }),
              let inSpec = dst.inputPorts.first(where: { $0.key == input.port }) else { return false }
        // Self-connections are allowed: they form feedback loops (e.g. Render In Image).
        return PortType.canConnect(from: outSpec.type, to: inSpec.type)
    }

    @discardableResult
    func connect(from output: PortRef, to input: PortRef) -> Bool {
        guard canConnect(from: output, to: input) else { return false }
        connections.removeAll { $0.to == input }
        connections.append(Connection(from: output, to: input))
        return true
    }

    func remove(_ ids: Set<UUID>) {
        nodes.removeAll { ids.contains($0.id) }
        connections.removeAll { ids.contains($0.from.node) || ids.contains($0.to.node) }
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

    // MARK: Records

    /// Serializes the graph, or only the given nodes and the wires between them.
    func record(only ids: Set<UUID>? = nil) -> GraphRecord {
        let included = ids.map { set in nodes.filter { set.contains($0.id) } } ?? nodes
        let conns = ids.map { set in connections.filter { set.contains($0.from.node) && set.contains($0.to.node) } } ?? connections
        return GraphRecord(nodes: included.map { $0.record() }, connections: conns)
    }

    func load(_ record: GraphRecord) {
        let made = record.nodes.compactMap(Graph.makePatch)
        let ids = Set(made.map(\.id))
        nodes = made
        connections = record.connections.filter { ids.contains($0.from.node) && ids.contains($0.to.node) }
    }

    static func makePatch(_ r: NodeRecord) -> Patch? {
        guard let type = PatchRegistry.byID[r.type] else { return nil }
        let patch = type.init(id: r.id, position: CGPoint(x: r.x, y: r.y))
        for (k, v) in r.params { patch.params[k] = v }
        if let name = r.name { patch.customTitle = name }
        if let sub = r.subgraph { patch.subgraph?.load(sub) }
        return patch
    }

    // MARK: Building (demos)

    @discardableResult
    func put<T: Patch>(_ type: T.Type, _ x: CGFloat, _ y: CGFloat, _ params: [String: Value] = [:], name: String? = nil) -> T {
        let p = type.init(position: CGPoint(x: x, y: y))
        for (k, v) in params { p.params[k] = v }
        if let name { p.customTitle = name }
        nodes.append(p)
        return p
    }

    func link(_ a: Patch, _ output: String, _ b: Patch, _ input: String) {
        connect(from: PortRef(node: a.id, port: output), to: PortRef(node: b.id, port: input))
    }
}
