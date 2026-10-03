import Foundation
import Metal
import simd

/// The data type carried by a port.
enum PortType: String, Codable, CaseIterable {
    case number, bool, color, string, image

    var displayName: String {
        switch self {
        case .number: return "Number"
        case .bool: return "Boolean"
        case .color: return "Color"
        case .string: return "String"
        case .image: return "Image"
        }
    }

    var defaultValue: Value {
        switch self {
        case .number: return .number(0)
        case .bool: return .bool(false)
        case .color: return .color(.one)
        case .string: return .string("")
        case .image: return .image(nil)
        }
    }

    /// Whether an output of type `from` may feed an input of type `to`.
    static func canConnect(from: PortType, to: PortType) -> Bool {
        if from == .image || to == .image { return from == to }
        return true // scalar types coerce freely
    }
}

/// A value flowing through the graph.
enum Value {
    case number(Double)
    case bool(Bool)
    case color(SIMD4<Float>)
    case string(String)
    case image(MTLTexture?)

    var number: Double {
        switch self {
        case .number(let v): return v
        case .bool(let b): return b ? 1 : 0
        case .color(let c): return Double((c.x + c.y + c.z) / 3)
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
        case .image(let t): return t == nil ? 0 : 1
        }
    }

    var bool: Bool {
        if case .bool(let b) = self { return b }
        if case .string(let s) = self { return ["true", "yes", "1"].contains(s.lowercased()) }
        return number != 0
    }

    var color: SIMD4<Float> {
        if case .color(let c) = self { return c }
        let v = Float(number)
        return SIMD4(v, v, v, 1)
    }

    var string: String {
        switch self {
        case .string(let s): return s
        default: return summary
        }
    }

    var image: MTLTexture? {
        if case .image(let t) = self { return t }
        return nil
    }

    func coerced(to type: PortType) -> Value {
        switch type {
        case .number: if case .number = self { return self }; return .number(number)
        case .bool: if case .bool = self { return self }; return .bool(bool)
        case .color: return .color(color)
        case .string: return .string(string)
        case .image: return .image(image)
        }
    }

    /// Short human readable representation for the inspector.
    var summary: String {
        switch self {
        case .number(let v):
            if v == v.rounded(), abs(v) < 1e9 { return String(Int(v)) }
            return String(format: "%.3f", v)
        case .bool(let b): return b ? "true" : "false"
        case .color(let c): return String(format: "rgba(%.2f, %.2f, %.2f, %.2f)", c.x, c.y, c.z, c.w)
        case .string(let s): return s
        case .image(let t):
            guard let t else { return "—" }
            return "\(t.width)×\(t.height)"
        }
    }

    var isImage: Bool { if case .image = self { return true }; return false }
}

extension Value: Codable {
    private enum CodingKeys: String, CodingKey { case t, v }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .t) {
        case "n": self = .number(try c.decode(Double.self, forKey: .v))
        case "b": self = .bool(try c.decode(Bool.self, forKey: .v))
        case "c": self = .color(try c.decode(SIMD4<Float>.self, forKey: .v))
        case "s": self = .string(try c.decode(String.self, forKey: .v))
        default: self = .image(nil)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .number(let v): try c.encode("n", forKey: .t); try c.encode(v, forKey: .v)
        case .bool(let v): try c.encode("b", forKey: .t); try c.encode(v, forKey: .v)
        case .color(let v): try c.encode("c", forKey: .t); try c.encode(v, forKey: .v)
        case .string(let v): try c.encode("s", forKey: .t); try c.encode(v, forKey: .v)
        case .image: try c.encode("i", forKey: .t)
        }
    }
}
