import Foundation

/// Pull-based evaluation of one graph for one frame: a patch is executed only when something
/// downstream (a consumer, a macro output, or the inspector) asks for it, and at most once.
package final class Evaluator {
    package let graph: Graph
    package let ctx: EvalContext
    private let lookup: [UUID: Patch]
    private let incoming: [PortRef: PortRef]
    private var cache: [UUID: PatchResult] = [:]
    private var visiting: Set<UUID> = []

    package init(graph: Graph, context: EvalContext) {
        self.graph = graph
        ctx = context
        lookup = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        incoming = Dictionary(graph.connections.map { ($0.to, $0.from) }, uniquingKeysWith: { a, _ in a })
    }

    package func inputs(for node: Patch) -> Inputs {
        var values: [String: Value] = [:]
        let params = node.params // read once: it's @Published, so each access goes through Combine
        for spec in node.allInputs {
            var value = params[spec.key] ?? spec.defaultValue
            if spec.isPort, let src = incoming[PortRef(node: node.id, port: spec.key)],
               let srcNode = lookup[src.node], let out = outputs(of: srcNode)[src.port] {
                value = out
            }
            values[spec.key] = value.coerced(to: spec.type)
        }
        return Inputs(values: values)
    }

    package func result(of node: Patch) -> PatchResult {
        if let cached = cache[node.id] { return cached }
        // A feedback loop sees the previous frame's values instead of recursing forever.
        guard !visiting.contains(node.id) else { return PatchResult(outputs: node.feedbackOutputs(ctx)) }
        visiting.insert(node.id)
        let resolved = inputs(for: node)
        let result = node.execute(resolved, node.usesTime ? node.timeContext(resolved, ctx) : ctx)
        visiting.remove(node.id)
        node.lastOutputs = result.outputs
        cache[node.id] = result
        return result
    }

    package func outputs(of node: Patch) -> [String: Value] { result(of: node).outputs }

    /// Executes every consumer in layer order and returns their draw commands.
    package func drawCommands() -> [DrawCommand] {
        let commands = graph.consumers.flatMap { result(of: $0).commands }
        // Keep the inspector live for selected patches even if nothing consumes them.
        for node in graph.nodes where ctx.inspect.contains(node.id) && node.category != .consumer {
            _ = result(of: node)
        }
        return commands
    }
}
