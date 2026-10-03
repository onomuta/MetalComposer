import Foundation
import simd

final class LFOPatch: Patch {
    override class var typeID: String { "lfo" }
    override class var title: String { "LFO" }
    override class var summary: String { "Low frequency oscillator driven by patch time." }
    override class var inputSpecs: [PortSpec] {
        [.menu("type", "Type", ["Sine", "Cosine", "Triangle", "Square", "Sawtooth"]),
         .number("period", "Period", 1, 0.1...10).limited(min: 0.001), .number("phase", "Phase", 0, 0...1),
         .number("amplitude", "Amplitude", 0.5), .number("offset", "Offset", 0.5)]
    }
    override class var outputSpecs: [PortSpec] { [.number("value", "Value")] }

    override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
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

final class InterpolationPatch: Patch {
    override class var typeID: String { "interpolation" }
    override class var title: String { "Interpolation" }
    override class var summary: String { "Animates from a start to an end value over time with easing." }
    override class var inputSpecs: [PortSpec] {
        [.number("start", "Start", 0), .number("end", "End", 1),
         .number("duration", "Duration", 1, 0.1...10).limited(min: 0.001),
         .menu("repeat", "Repeat", ["None", "Loop", "Mirrored Loop"], 1),
         .menu("easing", "Easing", ["Linear", "Ease In", "Ease Out", "Ease In Out", "Exponential Out", "Back Out", "Bounce"], 3)]
    }
    override class var outputSpecs: [PortSpec] { [.number("value", "Value")] }

    override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        var p = ctx.time / max(i.number("duration"), 0.0001)
        switch i.int("repeat") {
        case 1: p -= floor(p)
        case 2: let m = p.truncatingRemainder(dividingBy: 2); p = m > 1 ? 2 - m : m
        default: p = min(p, 1)
        }
        let e = Self.ease(p, i.int("easing"))
        return ["value": .number(i.number("start") + (i.number("end") - i.number("start")) * e)]
    }

    static func ease(_ t: Double, _ kind: Int) -> Double {
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

final class MathPatch: Patch {
    override class var typeID: String { "math" }
    override class var title: String { "Math" }
    override class var summary: String { "Applies an arithmetic operation to two values." }
    override class var inputSpecs: [PortSpec] {
        [.number("a", "Initial Value", 0),
         .menu("op", "Operation", ["Add", "Subtract", "Multiply", "Divide", "Modulo", "Min", "Max", "Power"]),
         .number("b", "Operand", 1)]
    }
    override class var outputSpecs: [PortSpec] { [.number("result", "Result")] }

    override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
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

final class MathExpressionPatch: Patch {
    override class var typeID: String { "math-expression" }
    override class var title: String { "Math Expression" }
    override class var summary: String { "Evaluates a formula of a, b, c, d and t (time). e.g. sin(t*2)*a" }
    override class var inputSpecs: [PortSpec] {
        [.number("a", "a", 0), .number("b", "b", 0), .number("c", "c", 0), .number("d", "d", 0),
         .string("expression", "Expression", "sin(t) * 0.5 + a", isPort: false)]
    }
    override class var outputSpecs: [PortSpec] { [.number("result", "Result")] }

    private var compiledSource: String?
    private var compiled: MathExpression?

    override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
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

final class SmoothPatch: Patch {
    override class var typeID: String { "smooth" }
    override class var title: String { "Smooth" }
    override class var summary: String { "Exponentially smooths a changing value." }
    override class var inputSpecs: [PortSpec] {
        [.number("value", "Value", 0), .number("smoothing", "Smoothing (s)", 0.25, 0...3).limited(min: 0)]
    }
    override class var outputSpecs: [PortSpec] { [.number("value", "Value")] }

    private var current: Double?

    override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let target = i.number("value")
        let tau = i.number("smoothing")
        if let c = current, tau > 0 {
            current = c + (target - c) * (1 - exp(-ctx.deltaTime / tau))
        } else {
            current = target
        }
        return ["value": .number(current ?? target)]
    }

    override func reset() { current = nil }
}

final class ConditionalPatch: Patch {
    override class var typeID: String { "conditional" }
    override class var title: String { "Conditional" }
    override class var summary: String { "Compares two values." }
    override class var inputSpecs: [PortSpec] {
        [.number("a", "First Value", 0),
         .menu("op", "Test", ["Is Equal", "Is Not Equal", "Is Greater Than", "Is Lower Than", "Is ≥", "Is ≤"]),
         .number("b", "Second Value", 0), .number("tolerance", "Tolerance", 0).limited(min: 0)]
    }
    override class var outputSpecs: [PortSpec] { [.bool("result", "Result")] }

    override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
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

final class RGBColorPatch: Patch {
    override class var typeID: String { "rgb-color" }
    override class var title: String { "RGB Color" }
    override class var summary: String { "Builds a color from red, green, blue and alpha." }
    override class var inputSpecs: [PortSpec] {
        [.number("r", "Red", 1, 0...1), .number("g", "Green", 1, 0...1),
         .number("b", "Blue", 1, 0...1), .number("a", "Alpha", 1, 0...1)]
    }
    override class var outputSpecs: [PortSpec] { [.color("color", "Color")] }

    override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        ["color": .color(SIMD4(i.float("r"), i.float("g"), i.float("b"), i.float("a")))]
    }
}

final class HSLColorPatch: Patch {
    override class var typeID: String { "hsl-color" }
    override class var title: String { "HSL Color" }
    override class var summary: String { "Builds a color from hue, saturation and luminosity." }
    override class var inputSpecs: [PortSpec] {
        [.number("hue", "Hue", 0, 0...1), // wraps around, so no limit
         .number("saturation", "Saturation", 1, 0...1).limited(0...1),
         .number("luminosity", "Luminosity", 0.5, 0...1).limited(0...1), .number("alpha", "Alpha", 1, 0...1).limited(0...1)]
    }
    override class var outputSpecs: [PortSpec] { [.color("color", "Color")] }

    override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
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
