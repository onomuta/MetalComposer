import Foundation
import simd

package final class LFOPatch: Patch {
    package override class var usesTime: Bool { true }
    package override class var typeID: String { "lfo" }
    package override class var title: String { "LFO" }
    package override class var summary: String { "Low frequency oscillator driven by patch time." }
    package override class var inputSpecs: [PortSpec] {
        [.menu("type", "Type", ["Sine", "Cosine", "Triangle", "Square", "Sawtooth"]),
         .number("period", "Period", 1, 0.1...10).limited(min: 0.001), .number("phase", "Phase", 0, 0...1),
         .number("amplitude", "Amplitude", 0.5), .number("offset", "Offset", 0.5)]
    }
    package override class var outputSpecs: [PortSpec] { [.number("value", "Value")] }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let period = max(i.number("period"), 0.0001)
        let p = ctx.time / period + i.number("phase")
        let f = p - floor(p)
        let wave: Double
        switch i.int("type") {
        case 1: wave = cos(2 * .pi * p)
        case 2: let q = p - 0.25; wave = 4 * abs(q - floor(q) - 0.5) - 1
        case 3: wave = f < 0.5 ? 1 : -1
        case 4: wave = 2 * f - 1
        default: wave = sin(2 * .pi * p)
        }
        return ["value": .number(i.number("offset") + i.number("amplitude") * wave)]
    }
}

package final class InterpolationPatch: Patch {
    package override class var usesTime: Bool { true }
    package override class var typeID: String { "interpolation" }
    package override class var title: String { "Interpolation" }
    package override class var summary: String { "Animates from a start to an end value over time with easing." }
    package override class var inputSpecs: [PortSpec] {
        [.number("start", "Start", 0), .number("end", "End", 1),
         .number("duration", "Duration", 1, 0.1...10).limited(min: 0.001),
         .menu("repeat", "Repeat", ["None", "Loop", "Mirrored Loop"], 1),
         .menu("easing", "Easing", ["Linear", "Ease In", "Ease Out", "Ease In Out", "Exponential Out", "Back Out", "Bounce"], 3)]
    }
    package override class var outputSpecs: [PortSpec] { [.number("value", "Value")] }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        var p = ctx.time / max(i.number("duration"), 0.0001)
        switch i.int("repeat") {
        case 1: p -= floor(p)
        case 2: let m = p.truncatingRemainder(dividingBy: 2); p = m > 1 ? 2 - m : m
        default: p = min(p, 1)
        }
        let e = Self.ease(p, i.int("easing"))
        return ["value": .number(i.number("start") + (i.number("end") - i.number("start")) * e)]
    }

    package static func ease(_ t: Double, _ kind: Int) -> Double {
        switch kind {
        case 1: return t * t * t
        case 2: return 1 - pow(1 - t, 3)
        case 3: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case 4: return t >= 1 ? 1 : 1 - pow(2, -10 * t)
        case 5: let c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        case 6:
            let n1 = 7.5625, d1 = 2.75
            var x = t
            if x < 1 / d1 { return n1 * x * x }
            if x < 2 / d1 { x -= 1.5 / d1; return n1 * x * x + 0.75 }
            if x < 2.5 / d1 { x -= 2.25 / d1; return n1 * x * x + 0.9375 }
            x -= 2.625 / d1; return n1 * x * x + 0.984375
        default: return t
        }
    }
}

package final class MathPatch: Patch {
    package override class var typeID: String { "math" }
    package override class var title: String { "Math" }
    package override class var summary: String { "Applies an arithmetic operation to two values." }
    package override class var inputSpecs: [PortSpec] {
        [.number("a", "Initial Value", 0),
         .menu("op", "Operation", ["Add", "Subtract", "Multiply", "Divide", "Modulo", "Min", "Max", "Power"]),
         .number("b", "Operand", 1)]
    }
    package override class var outputSpecs: [PortSpec] { [.number("result", "Result")] }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let a = i.number("a"), b = i.number("b")
        let r: Double
        switch i.int("op") {
        case 1: r = a - b
        case 2: r = a * b
        case 3: r = b == 0 ? 0 : a / b
        case 4: r = b == 0 ? 0 : a - b * floor(a / b)
        case 5: r = min(a, b)
        case 6: r = max(a, b)
        case 7: r = pow(a, b)
        default: r = a + b
        }
        return ["result": .number(r)]
    }
}

package final class MathExpressionPatch: Patch {
    package override class var usesTime: Bool { true }
    package override class var typeID: String { "math-expression" }
    package override class var title: String { "Math Expression" }
    package override class var summary: String { "Evaluates a formula of a, b, c, d and t (time). e.g. sin(t*2)*a" }
    package override class var inputSpecs: [PortSpec] {
        [.number("a", "a", 0), .number("b", "b", 0), .number("c", "c", 0), .number("d", "d", 0),
         .string("expression", "Expression", "sin(t) * 0.5 + a", isPort: false)]
    }
    package override class var outputSpecs: [PortSpec] { [.number("result", "Result")] }

    private var compiledSource: String?
    private var compiled: MathExpression?

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let source = i.string("expression")
        if source != compiledSource {
            compiledSource = source
            do { compiled = try MathExpression(source); setStatus(nil) }
            catch { compiled = nil; setStatus(error.localizedDescription) }
        }
        let vars = ["a": i.number("a"), "b": i.number("b"), "c": i.number("c"), "d": i.number("d"), "t": ctx.time]
        return ["result": .number(compiled?.evaluate(vars) ?? 0)]
    }
}

/// Follows its input gradually, with separate times for rising and falling and a choice of curve.
package final class SmoothPatch: Patch {
    package override class var usesTime: Bool { true }
    package override class var typeID: String { "smooth" }
    package override class var title: String { "Smooth" }
    package override class var summary: String { "Follows a changing value gradually; separate durations for increasing and decreasing." }
    package override class var inputSpecs: [PortSpec] {
        [.number("value", "Value", 0),
         .number("up", "Increasing Duration (s)", 0.25, 0...3).limited(min: 0),
         .number("down", "Decreasing Duration (s)", 0.25, 0...3).limited(min: 0),
         PortSpec.menu("curve", "Curve", ["Exponential", "Linear", "Ease In Out"]).setting()]
    }
    package override class var outputSpecs: [PortSpec] { [.number("value", "Value")] }

    private var current: Double?
    /// Linear / Ease In Out: the move in progress, from `from` to `to`, `elapsed` seconds in.
    private var segment: (from: Double, to: Double, elapsed: Double)?

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let target = i.number("value")
        guard let c = current else {
            current = target
            return ["value": .number(target)]
        }
        // Time stopped or rewound (External time base): hold the current value.
        let dt = ctx.deltaTime
        guard dt > 0 else { return ["value": .number(c)] }

        let rising = target > c
        let duration = i.number(rising ? "up" : "down")
        let next: Double
        switch i.int("curve") {
        case 1, 2:
            // Start a new move whenever the target changes; it takes `duration` to arrive.
            if segment == nil || segment!.to != target { segment = (c, target, 0) }
            segment!.elapsed += dt
            let p = duration > 0 ? min(segment!.elapsed / duration, 1) : 1
            let eased = i.int("curve") == 2 ? p * p * (3 - 2 * p) : p
            next = segment!.from + (segment!.to - segment!.from) * eased
        default:
            // Exponential: within 1% of the target after `duration` (time constant = duration / 5).
            segment = nil
            next = duration > 0 ? c + (target - c) * (1 - exp(-dt * 5 / duration)) : target
        }
        current = next
        return ["value": .number(next)]
    }

    package override func reset() {
        current = nil
        segment = nil
    }
}

/// Accumulates its input over time: Value is a rate per second (QC's Integrator).
package final class IntegratorPatch: Patch {
    package override class var usesTime: Bool { true }
    package override class var typeID: String { "integrator" }
    package override class var title: String { "Integrator" }
    package override class var summary: String { "Adds up Value × elapsed time (Value is a rate per second). Reset returns to 0." }
    package override class var inputSpecs: [PortSpec] {
        [.number("value", "Value", 0, -1...1), .bool("reset", "Reset", false)]
    }
    package override class var outputSpecs: [PortSpec] { [.number("integral", "Integrated Value")] }

    private var total: Double = 0

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        if i.bool("reset") {
            total = 0
        } else {
            // On its time base: paused time adds nothing; rewound External time subtracts.
            total += i.number("value") * ctx.deltaTime
        }
        return ["integral": .number(total)]
    }

    package override func reset() { total = 0 }
}

/// Counts rising edges: +1 when Increasing turns on, −1 when Decreasing turns on (QC's Counter).
package final class CounterPatch: Patch {
    package override class var typeID: String { "counter" }
    package override class var title: String { "Counter" }
    package override class var summary: String { "Counts up or down each time a signal turns on (e.g. mouse clicks). Stays at 0 while Reset Signal is on." }
    package override class var inputSpecs: [PortSpec] {
        [.bool("up", "Increasing Signal"), .bool("down", "Decreasing Signal"), .bool("reset", "Reset Signal")]
    }
    package override class var outputSpecs: [PortSpec] { [.number("count", "Count")] }

    private var count = 0
    /// Signal states from the previous evaluation, to detect off → on changes.
    private var was = (up: false, down: false)

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let now = (up: i.bool("up"), down: i.bool("down"))
        if i.bool("reset") {
            count = 0 // held at 0 while Reset Signal is on
        } else {
            if now.up && !was.up { count += 1 }
            if now.down && !was.down { count -= 1 }
        }
        was = now
        return ["count": .number(Double(count))]
    }

    package override func reset() {
        count = 0
        was = (false, false)
    }
}

package final class ConditionalPatch: Patch {
    package override class var typeID: String { "conditional" }
    package override class var title: String { "Conditional" }
    package override class var summary: String { "Compares two values." }
    package override class var inputSpecs: [PortSpec] {
        [.number("a", "First Value", 0),
         .menu("op", "Test", ["Is Equal", "Is Not Equal", "Is Greater Than", "Is Lower Than", "Is ≥", "Is ≤"]),
         .number("b", "Second Value", 0), .number("tolerance", "Tolerance", 0).limited(min: 0)]
    }
    package override class var outputSpecs: [PortSpec] { [.bool("result", "Result")] }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let a = i.number("a"), b = i.number("b"), tol = abs(i.number("tolerance"))
        let r: Bool
        switch i.int("op") {
        case 1: r = abs(a - b) > tol
        case 2: r = a > b
        case 3: r = a < b
        case 4: r = a >= b
        case 5: r = a <= b
        default: r = abs(a - b) <= tol
        }
        return ["result": .bool(r)]
    }
}

package final class LogicPatch: Patch {
    package override class var typeID: String { "logic" }
    package override class var title: String { "Logic" }
    package override class var summary: String { "Combines two booleans with AND, OR, XOR, NOT, NAND or NOR." }
    package override class var inputSpecs: [PortSpec] {
        [.bool("a", "First Value", false),
         .menu("op", "Operation", ["AND", "OR", "XOR", "NOT", "NAND", "NOR"]),
         .bool("b", "Second Value", false)]
    }
    package override class var outputSpecs: [PortSpec] { [.bool("result", "Result")] }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let a = i.bool("a"), b = i.bool("b")
        let r: Bool
        switch i.int("op") {
        case 1: r = a || b
        case 2: r = a != b
        case 3: r = !a
        case 4: r = !(a && b)
        case 5: r = !(a || b)
        default: r = a && b
        }
        return ["result": .bool(r)]
    }
}

package final class RangePatch: Patch {
    package override class var typeID: String { "range" }
    package override class var title: String { "Range" }
    package override class var summary: String { "Keeps a value inside a range by clamping, wrapping or mirroring." }
    package override class var inputSpecs: [PortSpec] {
        [.number("value", "Value", 0),
         .number("min", "Minimum", 0), .number("max", "Maximum", 1),
         .menu("mode", "Mode", ["Clamp", "Wrap", "Mirror"])]
    }
    package override class var outputSpecs: [PortSpec] { [.number("result", "Result")] }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let lo = min(i.number("min"), i.number("max")), hi = max(i.number("min"), i.number("max"))
        let v = i.number("value"), span = hi - lo
        guard span > 0, v.isFinite else { return ["result": .number(lo)] }
        let r: Double
        switch i.int("mode") {
        case 1:
            r = lo + (v - lo - span * ((v - lo) / span).rounded(.down))
        case 2:
            let t = (v - lo).truncatingRemainder(dividingBy: span * 2)
            let u = t < 0 ? t + span * 2 : t
            r = lo + (u <= span ? u : span * 2 - u)
        default:
            r = Swift.min(Swift.max(v, lo), hi)
        }
        return ["result": .number(r)]
    }
}

package final class MapRangePatch: Patch {
    package override class var typeID: String { "map-range" }
    package override class var title: String { "Map Range" }
    package override class var summary: String { "Maps a value from one range to another." }
    package override class var inputSpecs: [PortSpec] {
        [.number("value", "Value", 0),
         .number("inMin", "Input Minimum", 0), .number("inMax", "Input Maximum", 1),
         .number("outMin", "Output Minimum", 0), .number("outMax", "Output Maximum", 1),
         .bool("clamp", "Clamp", false)]
    }
    package override class var outputSpecs: [PortSpec] { [.number("result", "Result")] }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let inMin = i.number("inMin"), inMax = i.number("inMax")
        let outMin = i.number("outMin"), outMax = i.number("outMax")
        var t = inMax == inMin ? 0 : (i.number("value") - inMin) / (inMax - inMin)
        if i.bool("clamp") { t = Swift.min(Swift.max(t, 0), 1) }
        return ["result": .number(outMin + (outMax - outMin) * t)]
    }
}

package final class RoundPatch: Patch {
    package override class var typeID: String { "round" }
    package override class var title: String { "Round" }
    package override class var summary: String { "Rounds a value, optionally to a multiple of a step." }
    package override class var inputSpecs: [PortSpec] {
        [.number("value", "Value", 0),
         .menu("mode", "Mode", ["Round", "Floor", "Ceil", "Truncate"]),
         .number("step", "Step", 1, 0...10).limited(min: 0)]
    }
    package override class var outputSpecs: [PortSpec] { [.number("result", "Result")] }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let rule: FloatingPointRoundingRule
        switch i.int("mode") {
        case 1: rule = .down
        case 2: rule = .up
        case 3: rule = .towardZero
        default: rule = .toNearestOrAwayFromZero
        }
        let step = i.number("step"), v = i.number("value")
        let r = step > 0 ? (v / step).rounded(rule) * step : v.rounded(rule)
        return ["result": .number(r)]
    }
}

package final class RGBColorPatch: Patch {
    package override class var typeID: String { "rgb-color" }
    package override class var title: String { "RGB Color" }
    package override class var summary: String { "Builds a color from red, green, blue and alpha." }
    package override class var inputSpecs: [PortSpec] {
        [.number("r", "Red", 1, 0...1), .number("g", "Green", 1, 0...1),
         .number("b", "Blue", 1, 0...1), .number("a", "Alpha", 1, 0...1)]
    }
    package override class var outputSpecs: [PortSpec] { [.color("color", "Color")] }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        ["color": .color(SIMD4(i.float("r"), i.float("g"), i.float("b"), i.float("a")))]
    }
}

package final class HSLColorPatch: Patch {
    package override class var typeID: String { "hsl-color" }
    package override class var title: String { "HSL Color" }
    package override class var summary: String { "Builds a color from hue, saturation and luminosity." }
    package override class var inputSpecs: [PortSpec] {
        [.number("hue", "Hue", 0, 0...1), // wraps around, so no limit
         .number("saturation", "Saturation", 1, 0...1).limited(0...1),
         .number("luminosity", "Luminosity", 0.5, 0...1).limited(0...1), .number("alpha", "Alpha", 1, 0...1).limited(0...1)]
    }
    package override class var outputSpecs: [PortSpec] { [.color("color", "Color")] }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let h = i.float("hue"), s = i.float("saturation"), l = i.float("luminosity")
        let c = (1 - abs(2 * l - 1)) * s
        func channel(_ n: Float) -> Float {
            let k = (n + h * 12).truncatingRemainder(dividingBy: 12)
            let kk = k < 0 ? k + 12 : k
            return l - c / 2 * max(-1, min(kk - 3, 9 - kk, 1))
        }
        return ["color": .color(SIMD4(channel(0), channel(8), channel(4), i.float("alpha")))]
    }
}
