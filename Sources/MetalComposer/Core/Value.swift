import Foundation
import Metal
import simd

/// The data type carried by a port.
/// New cases go at the end: published ports save their type as an index into `allCases`.
enum PortType: String, Codable, CaseIterable {
    case number, bool, color, string, image
    /// An ordered list of values, each optionally named (QC's Structure).
    case structure
    /// Accepts and passes on any value unchanged (QC's virtual ports).
    case any

    var displayName: String {
        switch self {
        case .number: return "Number"
        case .bool: return "Boolean"
        case .color: return "Color"
        case .string: return "String"
        case .image: return "Image"
        case .structure: return "Structure"
        case .any: return "Virtual"
        }
    }

    var defaultValue: Value {
        switch self {
        case .number: return .number(0)
        case .bool: return .bool(false)
        case .color: return .color(.one)
        case .string: return .string("")
        case .image: return .image(nil)
        case .structure: return .structure(Structure())
        case .any: return .number(0)
        }
    }

    /// Whether an output of type `from` may feed an input of type `to`.
    static func canConnect(from: PortType, to: PortType) -> Bool {
        if from == .any || to == .any { return true }
        if from == .image || to == .image { return from == to }
        return true // everything else coerces (a scalar into a structure becomes a one-member structure)
    }
}

/// An ordered collection of values; members may have a key.
struct Structure {
    struct Member {
        var key: String?
        var value: Value
    }

    var members: [Member] = []

    var count: Int { members.count }

    func value(at index: Int) -> Value? {
        members.indices.contains(index) ? members[index].value : nil
    }

    func value(forKey key: String) -> Value? {
        members.first { $0.key == key }?.value
    }

    var summary: String {
        let shown = members.prefix(8).enumerated().map { i, m in
            "\(m.key ?? "[\(i)]"): \(m.value.isStructure ? "Structure (\(m.value.structure.count))" : m.value.summary)"
        }
        let more = count > 8 ? "\n… \(count - 8) more" : ""
        return count == 0 ? "Empty structure" : shown.joined(separator: "\n") + more
    }
}

/// A value flowing through the graph.
enum Value {
    case number(Double)
    case bool(Bool)
    case color(SIMD4<Float>)
    case string(String)
    case image(MTLTexture?)
    case structure(Structure)

    var number: Double {
        switch self {
        case .number(let v): return v
        case .bool(let b): return b ? 1 : 0
        case .color(let c): return Double((c.x + c.y + c.z) / 3)
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
        case .image(let t): return t == nil ? 0 : 1
        case .structure(let s): return Double(s.count)
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

    /// The value as a structure; a single value becomes a one-member structure.
    var structure: Structure {
        if case .structure(let s) = self { return s }
        return Structure(members: [.init(key: nil, value: self)])
    }

    func coerced(to type: PortType) -> Value {
        switch type {
        case .number: if case .number = self { return self }; return .number(number)
        case .bool: if case .bool = self { return self }; return .bool(bool)
        case .color: return .color(color)
        case .string: return .string(string)
        case .image: return .image(image)
        case .structure: return .structure(structure)
        case .any: return self
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
        case .structure(let s): return s.summary
        }
    }

    var isImage: Bool { if case .image = self { return true }; return false }
    var isStructure: Bool { if case .structure = self { return true }; return false }

    /// Cheap equality used to detect changes (images compare by texture identity).
    func isSame(as other: Value) -> Bool {
        switch (self, other) {
        case (.number(let a), .number(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.color(let a), .color(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.image(let a), .image(let b)): return a === b
        case (.structure(let a), .structure(let b)):
            return a.count == b.count && zip(a.members, b.members).allSatisfy { $0.key == $1.key && $0.value.isSame(as: $1.value) }
        default: return false
        }
    }
}

extension Value: Codable {
    private enum CodingKeys: String, CodingKey { case t, v }
    private struct MemberRecord: Codable { var k: String?; var v: Value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .t) {
        case "n": self = .number(try c.decode(Double.self, forKey: .v))
        case "b": self = .bool(try c.decode(Bool.self, forKey: .v))
        case "c": self = .color(try c.decode(SIMD4<Float>.self, forKey: .v))
        case "s": self = .string(try c.decode(String.self, forKey: .v))
        case "st":
            let members = try c.decode([MemberRecord].self, forKey: .v)
            self = .structure(Structure(members: members.map { .init(key: $0.k, value: $0.v) }))
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
        case .structure(let s):
            try c.encode("st", forKey: .t)
            try c.encode(s.members.map { MemberRecord(k: $0.key, v: $0.value) }, forKey: .v)
        }
    }
}
