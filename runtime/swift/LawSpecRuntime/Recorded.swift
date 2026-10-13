// Typed text for recorded values. Every target writes a recording the same
// way, so one recorded file checks every implementation. Identities (symbols
// and handles) are numbered within one recording. ref:REQ-law-primitives
// ref:DEC-portable-exact-arithmetic

import Foundation

public enum Recorded {
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The last part of a constructor tag: Shape for example.shapes::type::Shape::Shape.
    public static func lastPart(_ tag: String) -> String {
        guard let range = tag.range(of: "::", options: .backwards) else { return tag }
        return String(tag[range.upperBound...])
    }

    private static func trimDecimal(_ c: BigInt, _ e: Int) -> (BigInt, Int) {
        if c.isZero { return (.zero, 0) }
        var coefficient = c
        var exponent = e
        while true {
            let (q, r) = coefficient.quotientAndRemainder(dividingBy: 10)
            if !r.isZero { return (coefficient, exponent) }
            coefficient = q
            exponent += 1
        }
    }

    private static func hex(_ bits: UInt64, _ digits: Int) -> String {
        let text = String(bits, radix: 16)
        return String(repeating: "0", count: Swift.max(0, digits - text.count)) + text
    }

    private static func floatText(_ value: Value) throws -> String {
        guard case .float(let w, let bits) = value else { throw Fail.with("InvalidRecordedScalar", "float") }
        let name = "float\(w)"
        if try Scalar.floatClass(value) == "nan" { return name + "NaN" }
        return name + "Bits(\"" + hex(bits, w == 32 ? 8 : 16) + "\")"
    }

    private static func units<S: Sequence>(_ name: String, _ values: S) -> String where S.Element == Int {
        name + "([" + values.map(String.init).joined(separator: ", ") + "])"
    }

    private static func scalar(_ value: Value, _ t: String) throws -> String {
        switch (t, value) {
        case ("Bool", .bool(let b)): return b ? "true" : "false"
        case ("Unit", .unit): return "()"
        case ("Null", .null): return "null"
        case ("Undefined", .undefined): return "undefined"
        case ("Text", .text(let s)): return quote(s)
        case ("Char", .int(let n)):
            guard let code = n.exactly(UInt32.self), let scalar = Unicode.Scalar(code) else { throw Fail.with("InvalidRecordedScalar", t) }
            return quote(String(Character(scalar)))
        case ("CodePoint", .int(let n)), ("CodeUnit16", .int(let n)): return n.description
        case ("Bytes", .bytes(let b)): return units("bytes", b.map(Int.init))
        case ("CodePointText", .raw(_, let us)): return units("codePoints", us)
        case ("Utf16Text", .raw(_, let us)): return units("utf16", us)
        case ("Decimal", .decimal(let c, let e)):
            let (tc, te) = trimDecimal(c, e)
            return tc.description + "e" + String(te)
        case ("Rational", .ratio(let n, let d)): return "rational(\(n), \(d))"
        case ("Float32", .float), ("Float64", .float): return try floatText(value)
        case ("Complex64", .complex(_, let r, let i)): return "Complex64(" + (try floatText(r)) + ", " + (try floatText(i)) + ")"
        case ("Complex128", .complex(_, let r, let i)): return "Complex128(" + (try floatText(r)) + ", " + (try floatText(i)) + ")"
        case (_, .int(let n)) where Scalar.isIntegerType(t): return n.description
        default: throw Fail.with("InvalidRecordedScalar", t)
        }
    }

    /// Identities numbered within one recording, by kind.
    private struct Ids {
        var symbols: [ObjectIdentifier] = []
        var handles: [String: [ObjectIdentifier]] = [:]
    }

    private static func render(_ value: Value, _ t: TypeRef, _ schema: Schema?, _ ids: inout Ids) throws -> String {
        switch (t, value) {
        case (.named("List", let args), .list(let items)) where args.count == 1:
            return "[" + (try items.map { try render($0, args[0], schema, &ids) }).joined(separator: ", ") + "]"
        case (.named(let kind, let args), .presence(_, nil)) where args.count == 1:
            return kind == "Nullable" ? "null" : "undefined"
        case (.named(let kind, let args), .presence(_, let v?)) where args.count == 1:
            return (kind == "Nullable" ? "nullable(" : "optional(") + (try render(v, args[0], schema, &ids)) + ")"
        case (.named("Symbol", let args), .symbol(let id, let description)) where args.isEmpty:
            let key = ObjectIdentifier(id)
            if !ids.symbols.contains(key) { ids.symbols.append(key) }
            let n = ids.symbols.firstIndex(of: key)! + 1
            return "symbol(\(n), " + quote(description) + ")"
        case (.named(let name, let args), .handle(_, let id)) where args.isEmpty:
            let key = ObjectIdentifier(id.object)
            var known = ids.handles[name] ?? []
            if !known.contains(key) { known.append(key) }
            ids.handles[name] = known
            return lastPart(name) + "#\(known.firstIndex(of: key)! + 1)"
        case (_, .data(let tag, let fields)):
            var types = [TypeRef]()
            switch (t, tag) {
            case (_, "Maybe::Nothing"): types = []
            case (.named("Maybe", let a), _) where a.count == 1: types = [a[0]]
            case (.named("Either", let a), "Either::Left") where a.count == 2: types = [a[0]]
            case (.named("Either", let a), "Either::Right") where a.count == 2: types = [a[1]]
            default:
                guard let s = schema else { throw Fail.with("RecordingNeedsSchema", tag) }
                types = try Schema.fieldTypes(value, t, s)
            }
            let parts = try zip(fields, types).map { try render($0.0, $0.1, schema, &ids) }
            return parts.isEmpty ? lastPart(tag) : lastPart(tag) + "(" + parts.joined(separator: ", ") + ")"
        case (.named(let name, let args), _) where args.isEmpty:
            return try scalar(value, name)
        default:
            throw Fail.with("InvalidRecordedValue", Scalar.typeKey(t))
        }
    }

    /// A value's recorded text at its type.
    public static func text(_ value: Value, _ t: TypeRef, _ schema: Schema?) throws -> String {
        var ids = Ids()
        return try render(value, t, schema, &ids)
    }

    /// The untyped rendering a model's recorded state uses.
    public static func renderPlain(_ value: Value) -> String {
        switch value {
        case .bool(true): return "true"
        case .bool(false): return "false"
        case .unit: return "()"
        case .int(let n): return n.description
        case .text(let s): return quote(s)
        case .list(let items): return "[" + items.map(renderPlain).joined(separator: ", ") + "]"
        case .data(let tag, let fields) where fields.isEmpty: return lastPart(tag)
        case .data(let tag, let fields): return lastPart(tag) + "(" + fields.map(renderPlain).joined(separator: ", ") + ")"
        default: return debug(value)
        }
    }

    /// Any value, as a diagnostic shows it.
    public static func debug(_ value: Value) -> String {
        switch value {
        case .bool(let b): return "Bool \(b)"
        case .int(let n): return "Int \(n)"
        case .ratio(let n, let d): return "Ratio (\(n), \(d))"
        case .decimal(let c, let e): return "Decimal (\(c), \(e))"
        case .float(let w, let b): return "Float (\(w), \(b))"
        case .complex(let w, let r, let i): return "Complex (\(w), \(debug(r)), \(debug(i)))"
        case .text(let s): return "Text " + quote(s)
        case .bytes(let b): return "Bytes [|" + b.map { "\($0)uy" }.joined(separator: "; ") + "|]"
        case .raw(let kind, let units): return "Raw (\"\(kind)\", [" + units.map(String.init).joined(separator: "; ") + "])"
        case .unit: return "Unit"
        case .null: return "Null"
        case .undefined: return "Undefined"
        case .symbol(_, let description): return "Symbol " + quote(description)
        case .list(let items): return "List [" + items.map(debug).joined(separator: "; ") + "]"
        case .data(let tag, let fields): return "Data (\"\(tag)\", [" + fields.map(debug).joined(separator: "; ") + "])"
        case .presence(let kind, nil): return "Presence (\"\(kind)\", None)"
        case .presence(let kind, let v?): return "Presence (\"\(kind)\", Some (\(debug(v))))"
        case .handle(let name, _): return "Handle \"\(name)\""
        }
    }

    /// Structural identity of two values: floats by their bits, symbols and
    /// handles by identity.
    public static func identical(_ a: Value, _ b: Value) -> Bool {
        switch (a, b) {
        case let (.bool(x), .bool(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.ratio(n1, d1), .ratio(n2, d2)): return n1 == n2 && d1 == d2
        case let (.decimal(c1, e1), .decimal(c2, e2)): return c1 == c2 && e1 == e2
        case let (.float(w1, b1), .float(w2, b2)): return w1 == w2 && b1 == b2
        case let (.complex(w1, r1, i1), .complex(w2, r2, i2)): return w1 == w2 && identical(r1, r2) && identical(i1, i2)
        case let (.text(x), .text(y)): return String.portableEqual(x, y)
        case let (.bytes(x), .bytes(y)): return x == y
        case let (.raw(k1, u1), .raw(k2, u2)): return k1 == k2 && u1 == u2
        case (.unit, .unit), (.null, .null), (.undefined, .undefined): return true
        case let (.symbol(x, d1), .symbol(y, d2)): return x === y && d1 == d2
        case let (.list(x), .list(y)): return x.count == y.count && zip(x, y).allSatisfy { identical($0, $1) }
        case let (.data(t1, f1), .data(t2, f2)): return t1 == t2 && f1.count == f2.count && zip(f1, f2).allSatisfy { identical($0, $1) }
        case let (.presence(k1, nil), .presence(k2, nil)): return k1 == k2
        case let (.presence(k1, x?), .presence(k2, y?)): return k1 == k2 && identical(x, y)
        case let (.handle(n1, i1), .handle(n2, i2)): return n1 == n2 && HandleIdentity.same(i1, i2)
        default: return false
        }
    }
}
