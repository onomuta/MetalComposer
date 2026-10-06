import Foundation

package final class PatchTimePatch: Patch {
    package override class var usesTime: Bool { true }
    package override class var typeID: String { "patch-time" }
    package override class var title: String { "Patch Time" }
    package override class var category: PatchCategory { .provider }
    package override class var summary: String { "Seconds since playback started." }
    package override class var outputSpecs: [PortSpec] { [.number("time", "Time")] }

    package override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        ["time": .number(ctx.time)]
    }
}

package final class MousePatch: Patch {
    package override class var typeID: String { "mouse" }
    package override class var title: String { "Mouse" }
    package override class var category: PatchCategory { .provider }
    package override class var summary: String { "Mouse position over the viewer in composition units." }
    package override class var outputSpecs: [PortSpec] {
        [.number("x", "X Position"), .number("y", "Y Position"), .bool("down", "Left Button")]
    }

    package override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        ["x": .number(Double(ctx.mouse.x)), "y": .number(Double(ctx.mouse.y)), "down": .bool(ctx.mouseDown)]
    }
}

package final class RandomPatch: Patch {
    package override class var usesTime: Bool { true }
    package override class var typeID: String { "random" }
    package override class var title: String { "Random" }
    package override class var category: PatchCategory { .provider }
    package override class var summary: String { "Random value that changes a given number of times per second." }
    package override class var inputSpecs: [PortSpec] {
        [.number("min", "Min", 0), .number("max", "Max", 1),
         .number("rate", "Changes / sec", 2, 0...20).limited(min: 0), .number("seed", "Seed", 0),
         .bool("smooth", "Smooth", true)]
    }
    package override class var outputSpecs: [PortSpec] { [.number("value", "Value")] }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let x = ctx.time * i.number("rate")
        let seed = i.number("seed") * 17.31
        let n = floor(x)
        var r = MathExpression.hash(n + seed)
        if i.bool("smooth") {
            let f = x - n, u = f * f * (3 - 2 * f)
            r += (MathExpression.hash(n + 1 + seed) - r) * u
        }
        return ["value": .number(i.number("min") + (i.number("max") - i.number("min")) * r)]
    }
}

package final class RandomStringPatch: Patch {
    package override class var usesTime: Bool { true }
    package override class var typeID: String { "random-string" }
    package override class var title: String { "Random String" }
    package override class var category: PatchCategory { .provider }
    package override class var summary: String { "Random string of a given length from the chosen characters. Same seed and time, same string." }
    package override class var inputSpecs: [PortSpec] {
        [.number("length", "Length", 8, 1...32).limited(0...1024),
         .number("seed", "Seed", 0),
         .number("rate", "Changes / sec", 0, 0...20).limited(min: 0),
         .bool("uppercase", "Uppercase (A–Z)", true), .bool("lowercase", "Lowercase (a–z)", true),
         .bool("digits", "Digits (0–9)", true), .bool("symbols", "Symbols (!#$…)", false),
         .string("extra", "Extra Characters", "")]
    }
    package override class var outputSpecs: [PortSpec] { [.string("string", "String")] }

    package static let symbols = Array("!#$%&()*+-./:;<=>?@[]^_{|}~")

    /// The characters to pick from, in a fixed order (so a seed always gives the same string).
    package static func alphabet(uppercase: Bool, lowercase: Bool, digits: Bool, symbols: Bool, extra: String) -> [Character] {
        var chars: [Character] = []
        if uppercase { chars += Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ") }
        if lowercase { chars += Array("abcdefghijklmnopqrstuvwxyz") }
        if digits { chars += Array("0123456789") }
        if symbols { chars += Self.symbols }
        for c in extra where !chars.contains(c) { chars.append(c) }
        return chars
    }

    /// SplitMix64: a well-mixed 64-bit hash, so nearby seeds and positions give unrelated characters.
    private static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    package static func make(length: Int, seed: Double, step: Int, from chars: [Character]) -> String {
        guard !chars.isEmpty, length > 0 else { return "" }
        let base = mix(seed.bitPattern ^ mix(UInt64(bitPattern: Int64(step))))
        return String((0..<length).map { k in chars[Int(mix(base &+ UInt64(k)) % UInt64(chars.count))] })
    }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let chars = Self.alphabet(uppercase: i.bool("uppercase"), lowercase: i.bool("lowercase"),
                                  digits: i.bool("digits"), symbols: i.bool("symbols"), extra: i.string("extra"))
        // Changes / sec 0 keeps one string; otherwise it changes on a time grid, so stopping or
        // rewinding time (Time Base) shows the same strings again.
        let rate = max(0, i.number("rate"))
        let t = (ctx.time * rate).rounded(.down)
        let step = rate > 0 && t.isFinite ? Int(min(max(t, -9.0e18), 9.0e18)) : 0
        let length = min(max(0, i.int("length")), 1024)
        return ["string": .string(Self.make(length: length, seed: i.number("seed"), step: step, from: chars))]
    }
}

package final class NumberPatch: Patch {
    package override class var typeID: String { "number" }
    package override class var title: String { "Number" }
    package override class var category: PatchCategory { .provider }
    package override class var summary: String { "A constant value you can fan out to many inputs." }
    package override class var inputSpecs: [PortSpec] { [.number("value", "Value", 0)] }
    package override class var outputSpecs: [PortSpec] { [.number("value", "Value")] }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        ["value": .number(i.number("value"))]
    }
}
