import Foundation

struct ExpressionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A tiny recursive-descent parser for numeric expressions such as `sin(t * 2) * a + 0.5`.
final class MathExpression {
    indirect enum Node {
        case number(Double)
        case variable(String)
        case negate(Node)
        case binary(Character, Node, Node)
        case call(String, [Node])
    }

    let root: Node

    init(_ source: String) throws {
        var parser = Parser(chars: Array(source))
        root = try parser.parseExpression()
        parser.skipSpaces()
        if !parser.atEnd { throw ExpressionError(message: "Unexpected '\(parser.chars[parser.i])'") }
        try Self.validate(root)
    }

    func evaluate(_ vars: [String: Double]) -> Double { Self.eval(root, vars) }

    private static let functions: [String: Int] = [
        "sin": 1, "cos": 1, "tan": 1, "asin": 1, "acos": 1, "atan": 1, "atan2": 2,
        "abs": 1, "sqrt": 1, "exp": 1, "log": 1, "floor": 1, "ceil": 1, "round": 1, "fract": 1,
        "sign": 1, "min": 2, "max": 2, "pow": 2, "mod": 2, "step": 2, "clamp": 3, "mix": 3,
        "smoothstep": 3, "noise": 1,
    ]

    private static func validate(_ node: Node) throws {
        switch node {
        case .number, .variable: break
        case .negate(let n): try validate(n)
        case .binary(_, let a, let b): try validate(a); try validate(b)
        case .call(let name, let args):
            guard let arity = functions[name] else { throw ExpressionError(message: "Unknown function '\(name)'") }
            guard arity == args.count else { throw ExpressionError(message: "\(name) expects \(arity) argument(s)") }
            try args.forEach(validate)
        }
    }

    private static func eval(_ node: Node, _ vars: [String: Double]) -> Double {
        switch node {
        case .number(let v): return v
        case .variable(let name):
            switch name {
            case "pi": return .pi
            case "e": return M_E
            default: return vars[name] ?? 0
            }
        case .negate(let n): return -eval(n, vars)
        case .binary(let op, let a, let b):
            let x = eval(a, vars), y = eval(b, vars)
            switch op {
            case "+": return x + y
            case "-": return x - y
            case "*": return x * y
            case "/": return y == 0 ? 0 : x / y
            case "%": return y == 0 ? 0 : x.truncatingRemainder(dividingBy: y)
            case "^": return pow(x, y)
            default: return 0
            }
        case .call(let name, let args):
            let v = args.map { eval($0, vars) }
            switch name {
            case "sin": return sin(v[0])
            case "cos": return cos(v[0])
            case "tan": return tan(v[0])
            case "asin": return asin(v[0])
            case "acos": return acos(v[0])
            case "atan": return atan(v[0])
            case "atan2": return atan2(v[0], v[1])
            case "abs": return abs(v[0])
            case "sqrt": return sqrt(max(0, v[0]))
            case "exp": return exp(v[0])
            case "log": return v[0] > 0 ? log(v[0]) : 0
            case "floor": return floor(v[0])
            case "ceil": return ceil(v[0])
            case "round": return v[0].rounded()
            case "fract": return v[0] - floor(v[0])
            case "sign": return v[0] > 0 ? 1 : (v[0] < 0 ? -1 : 0)
            case "min": return min(v[0], v[1])
            case "max": return max(v[0], v[1])
            case "pow": return pow(v[0], v[1])
            case "mod": return v[1] == 0 ? 0 : v[0] - v[1] * floor(v[0] / v[1])
            case "step": return v[1] < v[0] ? 0 : 1
            case "clamp": return min(max(v[0], v[1]), v[2])
            case "mix": return v[0] + (v[1] - v[0]) * v[2]
            case "smoothstep":
                let t = min(max((v[2] - v[0]) / (v[1] - v[0]), 0), 1)
                return t * t * (3 - 2 * t)
            case "noise": return valueNoise(v[0])
            default: return 0
            }
        }
    }

    static func hash(_ n: Double) -> Double {
        let s = sin(n * 12.9898 + 78.233) * 43758.5453
        return s - floor(s)
    }

    private static func valueNoise(_ x: Double) -> Double {
        let i = floor(x), f = x - i
        let u = f * f * (3 - 2 * f)
        return hash(i) + (hash(i + 1) - hash(i)) * u
    }
}

private struct Parser {
    let chars: [Character]
    var i = 0

    var atEnd: Bool { i >= chars.count }

    mutating func skipSpaces() {
        while i < chars.count, chars[i].isWhitespace { i += 1 }
    }

    mutating func peek() -> Character? {
        skipSpaces()
        return atEnd ? nil : chars[i]
    }

    mutating func parseExpression() throws -> MathExpression.Node {
        var lhs = try parseTerm()
        while let c = peek(), c == "+" || c == "-" {
            i += 1
            lhs = .binary(c, lhs, try parseTerm())
        }
        return lhs
    }

    mutating func parseTerm() throws -> MathExpression.Node {
        var lhs = try parseUnary()
        while let c = peek(), c == "*" || c == "/" || c == "%" {
            i += 1
            lhs = .binary(c, lhs, try parseUnary())
        }
        return lhs
    }

    mutating func parseUnary() throws -> MathExpression.Node {
        if peek() == "-" { i += 1; return .negate(try parseUnary()) }
        if peek() == "+" { i += 1; return try parseUnary() }
        return try parsePower()
    }

    mutating func parsePower() throws -> MathExpression.Node {
        let base = try parsePrimary()
        if peek() == "^" { i += 1; return .binary("^", base, try parseUnary()) }
        return base
    }

    mutating func parsePrimary() throws -> MathExpression.Node {
        guard let c = peek() else { throw ExpressionError(message: "Unexpected end of expression") }
        if c.isNumber || c == "." {
            let start = i
            while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
            guard let v = Double(String(chars[start..<i])) else { throw ExpressionError(message: "Bad number") }
            return .number(v)
        }
        if c.isLetter || c == "_" {
            let start = i
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { i += 1 }
            let name = String(chars[start..<i])
            if peek() == "(" {
                i += 1
                var args: [MathExpression.Node] = []
                if peek() != ")" {
                    repeat {
                        if peek() == "," { i += 1 }
                        args.append(try parseExpression())
                    } while peek() == ","
                }
                guard peek() == ")" else { throw ExpressionError(message: "Expected ')'") }
                i += 1
                return .call(name, args)
            }
            return .variable(name)
        }
        if c == "(" {
            i += 1
            let inner = try parseExpression()
            guard peek() == ")" else { throw ExpressionError(message: "Expected ')'") }
            i += 1
            return inner
        }
        throw ExpressionError(message: "Unexpected '\(c)'")
    }
}
