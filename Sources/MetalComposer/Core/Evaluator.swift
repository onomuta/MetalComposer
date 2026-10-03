import Foundation

/// Pull-based evaluation for one frame: a patch is executed only when something
/// downstream (a consumer, or the inspector) asks for its outputs, and at most once per frame.
final class Evaluator {
    private let ctx: EvalContext
    private let lookup: [UUID: Patch]
    private let incoming: [PortRef: PortRef]
    private var cache: [UUID: [String: Value]] = [:]
    private var visiting: Set<UUID> = []

    init(composition: Composition, context: EvalContext) {
        ctx = context
        lookup = Dictionary(uniqueKeysWithValues: composition.nodes.map { ($0.id, $0) })
        incoming = Dictionary(composition.connections.map { ($0.to, $0.from) }, uniquingKeysWith: { a, _ in a })
    }

    func inputs(for node: Patch) -> Inputs {
        var values: [String: Value] = [:]
        for spec in node.allInputs {
            var value = node.params[spec.key] ?? spec.defaultValue
            if spec.isPort, let src = incoming[PortRef(node: node.id, port: spec.key)],
               let srcNode = lookup[src.node], let out = outputs(of: srcNode)[src.port] {
                value = out
            }
            values[spec.key] = value.coerced(to: spec.type)
        }
        return Inputs(values: values)
    }

    func outputs(of node: Patch) -> [String: Value] {
        if let cached = cache[node.id] { return cached }
        // A feedback loop returns the previous frame's values instead of recursing forever.
        guard !visiting.contains(node.id) else { return node.lastOutputs }
        visiting.insert(node.id)
        let result = node.evaluate(inputs(for: node), ctx)
        visiting.remove(node.id)
        node.lastOutputs = result
        cache[node.id] = result
        return result
    }
}
