import Foundation

/// Shared settings of the (de)multiplexers: how many ports, and what type they carry.
private enum Switching {
    static let typeNames = PortType.allCases.map(\.displayName)
    static let virtualIndex = PortType.allCases.firstIndex(of: .any)!

    static func settings(_ countName: String) -> [PortSpec] {
        [PortSpec.number("count", countName, 2, 2...8).limited(2...64).setting(),
         PortSpec.menu("type", "Type", typeNames, virtualIndex).setting()]
    }

    static func count(_ patch: Patch) -> Int {
        min(max(Int((patch.params["count"]?.number ?? 2).rounded()), 2), 64)
    }

    static func type(_ patch: Patch) -> PortType {
        let i = Int((patch.params["type"]?.number ?? Double(virtualIndex)).rounded())
        return PortType.allCases.indices.contains(i) ? PortType.allCases[i] : .any
    }

    static func port(_ key: String, _ name: String, _ type: PortType) -> PortSpec {
        PortSpec(key: key, name: name, type: type, defaultValue: type.defaultValue)
    }

    /// Indices outside the ports select the nearest one, like QC.
    static func clampedIndex(_ inputs: Inputs, _ key: String, count: Int) -> Int {
        min(max(inputs.int(key), 0), count - 1)
    }
}

/// Passes on the input chosen by Source Index.
package final class MultiplexerPatch: Patch {
    package override class var typeID: String { "multiplexer" }
    package override class var title: String { "Multiplexer" }
    package override class var summary: String { "Outputs the input selected by Source Index (0-based)." }
    package override class var inputSpecs: [PortSpec] {
        Switching.settings("Inputs") + [PortSpec.index("index", "Source Index")]
    }

    package override var ownInputs: [PortSpec] {
        let portType = Switching.type(self)
        return type(of: self).inputSpecs + (0..<Switching.count(self)).map { Switching.port("i\($0)", "Source \($0)", portType) }
    }

    package override var outputPorts: [PortSpec] { [Switching.port("output", "Output", Switching.type(self))] }

    package override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let i = Switching.clampedIndex(inputs, "index", count: Switching.count(self))
        return inputs.values["i\(i)"].map { ["output": $0] } ?? [:]
    }
}

/// Sends its input to the output chosen by Destination Index.
package final class DemultiplexerPatch: Patch {
    package override class var typeID: String { "demultiplexer" }
    package override class var title: String { "Demultiplexer" }
    package override class var summary: String { "Routes the input to the output selected by Destination Index (0-based)." }
    package override class var inputSpecs: [PortSpec] {
        Switching.settings("Outputs")
            + [PortSpec.menu("inactive", "Inactive Outputs", ["Keep Last Value", "Reset to Default"]).setting(),
               PortSpec.index("index", "Destination Index")]
    }

    package override var ownInputs: [PortSpec] {
        type(of: self).inputSpecs + [Switching.port("input", "Input", Switching.type(self))]
    }

    package override var outputPorts: [PortSpec] {
        let type = Switching.type(self)
        return (0..<Switching.count(self)).map { Switching.port("o\($0)", "Destination \($0)", type) }
    }

    /// Last value each output received, for "Keep Last Value".
    private var held: [String: Value] = [:]

    package override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let count = Switching.count(self)
        let type = Switching.type(self)
        let active = Switching.clampedIndex(inputs, "index", count: count)
        let keep = inputs.int("inactive") == 0
        var out: [String: Value] = [:]
        for i in 0..<count {
            let key = "o\(i)"
            if i == active, let value = inputs.values["input"] {
                held[key] = value
                out[key] = value
            } else {
                out[key] = keep ? (held[key] ?? type.defaultValue) : type.defaultValue
            }
        }
        return out
    }

    package override func reset() { held = [:] }
}
