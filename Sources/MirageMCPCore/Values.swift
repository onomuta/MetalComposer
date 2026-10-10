import Foundation
import MetalComposerKit

/// A problem with a tool call, reported to the client as a tool error (not a protocol error).
struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Plain JSON for values and port descriptions, as the tools show and accept them.
enum JSONValues {
    /// A value as JSON: numbers, booleans, strings, colors as [r, g, b, a]; images and structures
    /// can't be written out, so they are described.
    static func json(_ value: Value, options: [String]? = nil) -> Any {
        switch value {
        case .number(let n):
            if let options, options.indices.contains(Int(n.rounded())) { return options[Int(n.rounded())] }
            return n.isFinite ? n : 0
        case .bool(let b): return b
        case .string(let s): return s
        case .color(let c): return [c.x, c.y, c.z, c.w].map { (Double($0) * 1000).rounded() / 1000 }
        case .image(let t): return t.map { "image \($0.width)×\($0.height)" } ?? NSNull()
        case .structure(let s): return "structure (\(s.count) members)"
        }
    }

    /// A port as JSON: key, name, type, default, and for numbers their range and menu options.
    static func json(_ spec: PortSpec) -> [String: Any] {
        var out: [String: Any] = [
            "key": spec.key, "name": spec.name,
            "type": spec.options == nil ? spec.type.rawValue : "menu",
            "default": json(spec.defaultValue, options: spec.options),
        ]
        if let options = spec.options { out["options"] = options }
        if let range = spec.range { out["range"] = [range.lowerBound, range.upperBound] }
        if let limits = spec.limits {
            out["limits"] = [limits.lowerBound, limits.upperBound].map { $0.isFinite ? $0 : NSNull() as Any }
        }
        if !spec.isPort { out["setting"] = true } // set with set_params, can't be connected
        return out
    }

    /// A JSON value for an input. Menus take an option name or index; colors take [r, g, b(, a)]
    /// or "#RRGGBB(AA)".
    static func value(_ raw: Any, for spec: PortSpec) throws -> Value {
        if let options = spec.options {
            if let name = raw as? String {
                guard let i = options.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw ToolError("\(spec.key): \"\(name)\" is not one of \(options)")
                }
                return .number(Double(i))
            }
            guard let n = number(raw), options.indices.contains(Int(n.rounded())) else {
                throw ToolError("\(spec.key): expected one of \(options) (or its index)")
            }
            return .number(n.rounded())
        }
        switch spec.type {
        case .number:
            guard let n = number(raw) else { throw ToolError("\(spec.key): expected a number") }
            return .number(spec.clamped(n))
        case .bool:
            if let b = raw as? NSNumber { return .bool(b.boolValue) }
            throw ToolError("\(spec.key): expected true or false")
        case .string:
            if let s = raw as? String { return .string(s) }
            if let n = number(raw) { return .string(n.rounded() == n ? String(Int(n)) : String(n)) }
            throw ToolError("\(spec.key): expected a string")
        case .color:
            if let c = color(raw) { return .color(c) }
            throw ToolError("\(spec.key): expected a color as [r, g, b, a] from 0 to 1, or \"#RRGGBB\"")
        case .any:
            if let s = raw as? String { return .string(s) }
            if let b = raw as? NSNumber, isBool(b) { return .bool(b.boolValue) }
            if let n = number(raw) { return .number(n) }
            if let c = color(raw) { return .color(c) }
            throw ToolError("\(spec.key): expected a number, boolean, string or color")
        case .image, .structure:
            throw ToolError("\(spec.key) is a \(spec.type.rawValue) input: connect a patch to it instead")
        }
    }

    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    private static func number(_ raw: Any) -> Double? {
        guard let n = raw as? NSNumber else { return nil }
        return isBool(n) ? (n.boolValue ? 1 : 0) : n.doubleValue
    }

    private static func color(_ raw: Any) -> SIMD4<Float>? {
        if let parts = raw as? [Any] {
            let n = parts.compactMap(number)
            guard n.count == parts.count, n.count == 3 || n.count == 4 else { return nil }
            return SIMD4(Float(n[0]), Float(n[1]), Float(n[2]), n.count == 4 ? Float(n[3]) : 1)
        }
        if let hex = raw as? String {
            let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard digits.count == 6 || digits.count == 8, let v = UInt64(digits, radix: 16) else { return nil }
            func byte(_ shift: UInt64) -> Float { Float((v >> shift) & 0xFF) / 255 }
            return digits.count == 6 ? SIMD4(byte(16), byte(8), byte(0), 1) : SIMD4(byte(24), byte(16), byte(8), byte(0))
        }
        return nil
    }
}
