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
