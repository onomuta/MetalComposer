import Foundation

final class PatchTimePatch: Patch {
    override class var usesTime: Bool { true }
    override class var typeID: String { "patch-time" }
    override class var title: String { "Patch Time" }
    override class var category: PatchCategory { .provider }
    override class var summary: String { "Seconds since playback started." }
    override class var outputSpecs: [PortSpec] { [.number("time", "Time")] }

    override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        ["time": .number(ctx.time)]
    }
}

final class MousePatch: Patch {
    override class var typeID: String { "mouse" }
    override class var title: String { "Mouse" }
    override class var category: PatchCategory { .provider }
    override class var summary: String { "Mouse position over the viewer in composition units." }
    override class var outputSpecs: [PortSpec] {
        [.number("x", "X Position"), .number("y", "Y Position"), .bool("down", "Left Button")]
    }

    override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        ["x": .number(Double(ctx.mouse.x)), "y": .number(Double(ctx.mouse.y)), "down": .bool(ctx.mouseDown)]
    }
}

final class RandomPatch: Patch {
    override class var usesTime: Bool { true }
    override class var typeID: String { "random" }
    override class var title: String { "Random" }
    override class var category: PatchCategory { .provider }
    override class var summary: String { "Random value that changes a given number of times per second." }
    override class var inputSpecs: [PortSpec] {
        [.number("min", "Min", 0), .number("max", "Max", 1),
         .number("rate", "Changes / sec", 2, 0...20).limited(min: 0), .number("seed", "Seed", 0),
         .bool("smooth", "Smooth", true)]
    }
    override class var outputSpecs: [PortSpec] { [.number("value", "Value")] }

    override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
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

final class NumberPatch: Patch {
    override class var typeID: String { "number" }
    override class var title: String { "Number" }
    override class var category: PatchCategory { .provider }
    override class var summary: String { "A constant value you can fan out to many inputs." }
    override class var inputSpecs: [PortSpec] { [.number("value", "Value", 0)] }
    override class var outputSpecs: [PortSpec] { [.number("value", "Value")] }

    override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        ["value": .number(i.number("value"))]
    }
}
