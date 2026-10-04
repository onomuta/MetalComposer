import Foundation
import CoreGraphics

package struct PortRef: Codable, Hashable {
    package var node: UUID
    package var port: String

    package init(node: UUID, port: String) {
        self.node = node
        self.port = port
    }
}

package struct Connection: Codable, Hashable, Identifiable {
    package var id = UUID()
    package var from: PortRef // an output
    package var to: PortRef   // an input

    package init(id: UUID = UUID(), from: PortRef, to: PortRef) {
        self.id = id
        self.from = from
        self.to = to
    }
}

/// Serialized form of a graph; also the `.mcomp` file format and the clipboard format.
package struct GraphRecord: Codable {
    package var version: Int? = 2
    package var nodes: [NodeRecord]
    package var connections: [Connection]

    /// Patch types this build doesn't know (saved by a newer Metal Composer), including inside
    /// macros, without duplicates and in the order they appear. Loading skips these patches.
    package var unknownPatchTypes: [String] {
        var seen = Set<String>()
        func walk(_ r: GraphRecord) -> [String] {
            r.nodes.flatMap { n -> [String] in
                let own = PatchRegistry.byID[n.type] == nil && seen.insert(n.type).inserted ? [n.type] : []
                return own + (n.subgraph.map(walk) ?? [])
            }
        }
        return walk(self)
    }
}

package struct NodeRecord: Codable {
    package var id: UUID
    package var type: String
    package var x: Double
    package var y: Double
    package var name: String?
    package var params: [String: Value]
    package var subgraph: GraphRecord?
}

/// A set of patches and the wires between them. The root composition and every macro own one.
/// Consumers render in the order they appear in `nodes` (their layer order).
package final class Graph {
    package var nodes: [Patch] = []
    package var connections: [Connection] = []

    package init() {}

    package func node(_ id: UUID?) -> Patch? {
        guard let id else { return nil }
        return nodes.first { $0.id == id }
    }

    package func connection(into input: PortRef) -> Connection? {
        connections.first { $0.to == input }
    }

    package var consumers: [Patch] { nodes.filter { $0.category == .consumer } }
    package var containsConsumers: Bool { nodes.contains { $0.category == .consumer } }

    package func layerIndex(of patch: Patch) -> Int? {
        consumers.firstIndex { $0.id == patch.id }.map { $0 + 1 }
    }

    package func canConnect(from output: PortRef, to input: PortRef) -> Bool {
        guard let src = node(output.node), let dst = node(input.node),
              let outSpec = src.outputPorts.first(where: { $0.key == output.port }),
              let inSpec = dst.inputPorts.first(where: { $0.key == input.port }) else { return false }
        // Self-connections are allowed: they form feedback loops (e.g. Render In Image).
        return PortType.canConnect(from: outSpec.type, to: inSpec.type)
    }

    @discardableResult
    package func connect(from output: PortRef, to input: PortRef) -> Bool {
        guard canConnect(from: output, to: input) else { return false }
        connections.removeAll { $0.to == input }
        connections.append(Connection(from: output, to: input))
        return true
    }

    package func remove(_ ids: Set<UUID>) {
        nodes.removeAll { ids.contains($0.id) }
        connections.removeAll { ids.contains($0.from.node) || ids.contains($0.to.node) }
    }

    /// Moves a consumer up (+1) or down (-1) in the rendering order.
    package func moveLayer(_ patch: Patch, by delta: Int) {
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
    package func record(only ids: Set<UUID>? = nil) -> GraphRecord {
        let included = ids.map { set in nodes.filter { set.contains($0.id) } } ?? nodes
        let conns = ids.map { set in connections.filter { set.contains($0.from.node) && set.contains($0.to.node) } } ?? connections
        return GraphRecord(nodes: included.map { $0.record() }, connections: conns)
    }

    package func load(_ record: GraphRecord) {
        let made = record.nodes.compactMap(Graph.makePatch)
        let ids = Set(made.map(\.id))
        nodes = made
        connections = record.connections.filter { ids.contains($0.from.node) && ids.contains($0.to.node) }
    }

    package static func makePatch(_ r: NodeRecord) -> Patch? {
        guard let type = PatchRegistry.byID[r.type] else { return nil }
        let patch = type.init(id: r.id, position: CGPoint(x: r.x, y: r.y))
        for (k, v) in r.params { patch.params[k] = v }
        if let name = r.name { patch.customTitle = name }
        if let sub = r.subgraph { patch.subgraph?.load(sub) }
        return patch
    }

    // MARK: Building (demos)

    @discardableResult
    package func put<T: Patch>(_ type: T.Type, _ x: CGFloat, _ y: CGFloat, _ params: [String: Value] = [:], name: String? = nil) -> T {
        let p = type.init(position: CGPoint(x: x, y: y))
        for (k, v) in params { p.params[k] = v }
        if let name { p.customTitle = name }
        nodes.append(p)
        return p
    }

    package func link(_ a: Patch, _ output: String, _ b: Patch, _ input: String) {
        connect(from: PortRef(node: a.id, port: output), to: PortRef(node: b.id, port: input))
    }
}
