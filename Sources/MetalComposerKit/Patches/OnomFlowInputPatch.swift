import Foundation
import Metal

/// Everything ONOM FLOW (the VJ app that plays compositions as generator materials) passes in, in one patch:
/// BPM, Beat, Gain, Input 1–4, Text 1–2, Image 1–2, Main Color and Sub Color.
///
/// While a composition contains this patch (anywhere, also inside macros), `CompositionPlayer.parameters`
/// lists these values under the names ONOM FLOW sends, so the host sets them like Macro Inputs; inside the
/// graph they arrive through `EvalContext.host`, which reaches every macro unchanged. Played elsewhere, the
/// outputs keep their defaults, and Beat follows the BPM on the composition's clock so the preview moves.
package final class OnomFlowInputPatch: Patch {
    package override class var typeID: String { "onom-flow-input" }
    package override class var title: String { "ONOM FLOW Input" }
    package override class var category: PatchCategory { .provider }
    package override class var summary: String {
        "Values ONOM FLOW passes in: BPM, beat, gain, Input 1–4, texts, images and its main and sub colors."
    }

    /// One value the host sets: its host key, the name the host matches, and the output it drives.
    package struct HostValue {
        package let key: String
        package let name: String
        package let port: String
        package let type: PortType
        package let defaultValue: Value
    }

    package static let defaultBPM = 120.0

    package static let hostValues: [HostValue] = {
        var values: [HostValue] = [
            HostValue(key: "onom-flow.bpm", name: "BPM", port: "bpm", type: .number, defaultValue: .number(defaultBPM)),
            HostValue(key: "onom-flow.beat", name: "Beat", port: "beat", type: .number, defaultValue: .number(0)),
            HostValue(key: "onom-flow.gain", name: "Gain", port: "gain", type: .number, defaultValue: .number(0)),
        ]
        for i in 1...4 {
            values.append(HostValue(key: "onom-flow.input\(i)", name: "Input \(i)", port: "input\(i)", type: .number, defaultValue: .number(0)))
        }
        for i in 1...2 {
            // A visible default: an empty string draws nothing useful in Text Image.
            values.append(HostValue(key: "onom-flow.text\(i)", name: "Text \(i)", port: "text\(i)", type: .string, defaultValue: .string("Text \(i)")))
        }
        for i in 1...2 {
            values.append(HostValue(key: "onom-flow.image\(i)", name: "Image \(i)", port: "image\(i)", type: .image, defaultValue: .image(nil)))
        }
        values.append(HostValue(key: "onom-flow.main-color", name: "Main Color", port: "mainColor", type: .color, defaultValue: .color(.one)))
        values.append(HostValue(key: "onom-flow.sub-color", name: "Sub Color", port: "subColor", type: .color, defaultValue: .color(.one)))
        return values
    }()

    package override class var outputSpecs: [PortSpec] {
        hostValues.map { PortSpec(key: $0.port, name: $0.name, type: $0.type, defaultValue: $0.defaultValue) }
    }

    package override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        var out: [String: Value] = [:]
        for value in Self.hostValues {
            out[value.port] = ctx.host[value.key]?.coerced(to: value.type) ?? value.defaultValue
        }
        // Without a host, Beat runs at the BPM on the composition's clock (0 at each beat, rising to 1).
        if ctx.host["onom-flow.beat"] == nil {
            let bpm = out["bpm"]?.number ?? Self.defaultBPM
            let beats = ctx.time * max(bpm, 0) / 60
            out["beat"] = .number(beats.isFinite ? beats - beats.rounded(.down) : 0)
        }
        return out
    }

    /// Whether a graph uses the patch anywhere, also inside macros.
    package static func isUsed(in graph: Graph) -> Bool {
        graph.nodes.contains { $0 is OnomFlowInputPatch || ($0.subgraph.map(isUsed) ?? false) }
    }
}
