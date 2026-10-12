// LawSpec's scalar domain in Swift. Exact arithmetic never goes through a
// native float, and IEEE values are rounded once, from an exact ratio, to
// nearest with ties to even. Every generated law and dynamic definition uses
// these operations, so Swift agrees with the other targets.
// ref:DEC-portable-exact-arithmetic ref:ieee-754 ref:DEC-explicit-machine-profile

import Foundation

/// A value guarded by a lock, for the runtime's few shared caches.
public final class Locked<State>: @unchecked Sendable {
    private var state: State
    private let lock = NSLock()
    public init(_ state: State) { self.state = state }
    /// Run a body with the state, under the lock.
    public func with<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

public enum Scalar {
    // MARK: Type keys

    private static func tokenize(_ text: String) -> [String] {
        var tokens = [String]()
        var word = ""
        for c in text {
            switch c {
            case "(", ")":
                if !word.isEmpty { tokens.append(word); word = "" }
                tokens.append(String(c))
            case " ", "\t":
                if !word.isEmpty { tokens.append(word); word = "" }
            default:
                word.append(c)
            }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    private static func application(_ parts: [TypeRef]) throws -> TypeRef {
        guard let first = parts.first else { throw Fail.with("InvalidTypeKey") }
        if parts.count == 1 { return first }
        guard case .named(let name, let args) = first, args.isEmpty else { throw Fail.with("InvalidTypeKey") }
        if ["List", "Maybe", "Optional", "Nullable"].contains(name) {
            return .named(name, [try application(Array(parts.dropFirst()))])
        }
        return .named(name, Array(parts.dropFirst()))
    }

    private static func parts(_ tokens: [String], _ start: Int) throws -> ([TypeRef], Int) {
        var acc = [TypeRef]()
        var i = start
        while i < tokens.count {
            let token = tokens[i]
            if token == ")" { return (acc, i) }
            if token == "(" {
                let (inner, after) = try parts(tokens, i + 1)
                guard after < tokens.count, tokens[after] == ")" else { throw Fail.with("InvalidTypeKey") }
                acc.append(try application(inner))
                i = after + 1
            } else if token.hasPrefix("$") {
                guard let index = Int(token.dropFirst()) else { throw Fail.with("InvalidTypeKey", token) }
                acc.append(.parameter(index))
                i += 1
            } else {
                acc.append(.named(token, []))
                i += 1
            }
        }
        return (acc, i)
    }

    private static let typeCache = Locked([String: TypeRef]())

    /// The type a key names: `Either (Int8) (Text)`, `List Int8`, `Maybe (List Text)`.
    /// Parentheses keep nested Either and presence arguments apart.
    public static func typeOf(_ key: String) throws -> TypeRef {
        if let known = typeCache.with({ $0[key] }) { return known }
        let tokens = tokenize(key)
        let (found, rest) = try parts(tokens, 0)
        if rest != tokens.count { throw Fail.with("InvalidTypeKey", key) }
        let t = try application(found)
        typeCache.with { $0[key] = t }
        return t
    }

    /// The key of a type, as typeOf reads it.
    public static func typeKey(_ t: TypeRef) -> String {
        switch t {
        case .named(let name, let args) where args.isEmpty: return name
        case .named(let name, let args): return name + args.map { " (" + typeKey($0) + ")" }.joined()
        case .parameter(let i): return "$\(i)"
        }
    }

    // MARK: Integers

    private static let integerTypes: Set<String> = [
        "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64",
        "IntSize", "UIntSize", "UIntPtr", "Integer", "BigInt", "BigUInt",
    ]

    /// Whether a scalar name is one of LawSpec's integer types.
    public static func isIntegerType(_ name: String) -> Bool { integerTypes.contains(name) }

    static func pow2(_ n: Int) -> BigInt { BigInt.one << n }

    private static func signed(_ width: Int) -> (BigInt?, BigInt?) { (-pow2(width - 1), pow2(width - 1) - .one) }

    /// An integer type's inclusive bounds under a machine profile (32 or 64 bits).
    public static func bounds(_ name: String, _ bits: Int) throws -> (BigInt?, BigInt?) {
        if bits != 32 && bits != 64 { throw Fail.with("InvalidMachineBits", "\(bits)") }
        switch name {
        case "Integer", "BigInt": return (nil, nil)
        case "BigUInt": return (.zero, nil)
        case "IntSize": return signed(bits)
        case "UIntSize", "UIntPtr": return (.zero, pow2(bits) - .one)
        default:
            if name.hasPrefix("UInt"), let width = Int(name.dropFirst(4)) { return (.zero, pow2(width) - .one) }
            if name.hasPrefix("Int"), let width = Int(name.dropFirst(3)) { return signed(width) }
            throw Fail.with("UnknownInteger", name)
        }
    }

    private static func checkBounds(_ value: BigInt, _ name: String, _ bits: Int) throws -> Value {
        let (lo, hi) = try bounds(name, bits)
        if let l = lo, value < l { throw Fail.with("IntegerOutOfRange", "\(name) \(value)") }
        if let h = hi, value > h { throw Fail.with("IntegerOutOfRange", "\(name) \(value)") }
        return .int(value)
    }

    // MARK: Exact numbers

    /// A normalized fraction.
    public static func ratio(_ n: BigInt, _ d: BigInt) throws -> Value {
        if d.isZero { throw Fail.with("InvalidRational", "zero denominator") }
        let (a, b) = normalized(n, d)
        return .ratio(a, b)
    }

    static func normalized(_ n: BigInt, _ d: BigInt) -> (BigInt, BigInt) {
        let g = BigInt.gcd(n, d)
        let s: BigInt = d.isNegative ? -1 : 1
        return (s * n / g, d.magnitude / g)
    }

    static func pow10(_ n: Int) -> BigInt { BigInt(10).power(n) }

    // IEEE layouts: fraction bits, exponent bits, bias.
    private static func format(_ width: Int) throws -> (Int, Int, Int) {
        switch width {
        case 32: return (23, 8, 127)
        case 64: return (52, 11, 1023)
        default: throw Fail.with("InvalidIeeeWidth", "\(width)")
        }
    }

    private enum Decoded {
        case finite(sign: Int, mantissa: BigInt, exponent: Int)
        case infinity(sign: Int)
        case nan
    }

    private static func decode(_ width: Int, _ bits: UInt64) throws -> Decoded {
        let (p, e, bias) = try format(width)
        let sign = Int((bits >> UInt64(width - 1)) & 1)
        let exponent = Int((bits >> UInt64(p)) & ((1 << UInt64(e)) - 1))
        let fraction = bits & ((1 << UInt64(p)) - 1)
        let top = (1 << e) - 1
        if exponent == top { return fraction == 0 ? .infinity(sign: sign) : .nan }
        if exponent == 0 { return .finite(sign: sign, mantissa: BigInt(fraction), exponent: 1 - bias - p) }
        return .finite(sign: sign, mantissa: BigInt((1 << UInt64(p)) + fraction), exponent: exponent - bias - p)
    }

    /// The exact ratio of an exact number or a finite float.
    public static func exact(_ value: Value) throws -> (BigInt, BigInt) {
        switch value {
        case .int(let n): return (n, .one)
        case .ratio(let n, let d): return (n, d)
        case .decimal(let c, _) where c.isZero: return (.zero, .one)
        case .decimal(let c, let e) where e >= 0: return (c * pow10(e), .one)
        case .decimal(let c, let e): return normalized(c, pow10(-e))
        case .float(let w, let b):
            switch try decode(w, b) {
            case .finite(let sign, let m, let e):
                let signedM = sign == 0 ? m : -m
                return e >= 0 ? (signedM << e, .one) : normalized(signedM, pow2(-e))
            default:
                throw Fail.with("NonFiniteExactConversion")
            }
        default:
            throw Fail.with("ExactNumberRequired", "\(value)")
        }
    }

    static func isExact(_ value: Value) -> Bool {
        switch value {
        case .int, .ratio, .decimal: return true
        default: return false
        }
    }

    private static func factors(_ n: BigInt, _ factor: BigInt) -> (BigInt, Int) {
        var rest = n
        var count = 0
        while true {
            let (q, r) = rest.quotientAndRemainder(dividingBy: factor)
            if !r.isZero { return (rest, count) }
            rest = q
            count += 1
        }
    }

    /// A decimal for an exact ratio, when its expansion terminates in base ten.
    static func finiteDecimal(_ n: BigInt, _ d: BigInt) throws -> Value {
        let (rn, rd) = normalized(n, d)
        let (d2, twos) = factors(rd, 2)
        let (d5, fives) = factors(d2, 5)
        if d5 != .one { throw Fail.with("NonTerminatingDecimal") }
        let scale = Swift.max(twos, fives)
        return .decimal(rn * BigInt(2).power(scale - twos) * BigInt(5).power(scale - fives), -scale)
    }

    // MARK: IEEE floats

    private static func floatValue(_ width: Int, _ bits: UInt64) throws -> Value {
        if width == 32 && bits > 0xFFFF_FFFF { throw Fail.with("InvalidIeeeBits") }
        return .float(width: width, bits: bits)
    }

    private static func zero(_ width: Int, _ sign: Int) -> Value { .float(width: width, bits: UInt64(sign) << UInt64(width - 1)) }

    private static func infinity(_ width: Int, _ sign: Int) -> Value {
        let (p, e) = width == 32 ? (23, 8) : (52, 11)
        return .float(width: width, bits: (UInt64(sign) << UInt64(width - 1)) | (((1 << UInt64(e)) - 1) << UInt64(p)))
    }

    private static func nan(_ width: Int) -> Value {
        let p = width == 32 ? 23 : 52
        guard case .float(_, let inf) = infinity(width, 0) else { return .float(width: width, bits: 0) }
        return .float(width: width, bits: inf | (1 << UInt64(p - 1)))
    }

    private static func floorLog2(_ n: BigInt, _ d: BigInt) -> Int {
        let guess = n.bitLength - d.bitLength
        let below = guess >= 0 ? n < (d << guess) : (n << -guess) < d
        return below ? guess - 1 : guess
    }

    static func roundRatio(_ n: BigInt, _ d: BigInt) -> BigInt {
        let (q, r) = n.quotientAndRemainder(dividingBy: d)
        let twice = BigInt(2) * r
        if twice > d || (twice == d && !q.isEven) { return q + .one }
        return q
    }

    /// The float of a width nearest an exact ratio; a zero takes the given sign.
    public static func floatFromRatio(_ width: Int, _ n: BigInt, _ d: BigInt, _ zeroSign: Int) throws -> Value {
        if d.isZero { throw Fail.with("ZeroDenominator") }
        if n.isZero { return zero(width, zeroSign) }
        let (p, _, bias) = try format(width)
        let s = (n.isNegative != d.isNegative) ? 1 : 0
        let an = n.magnitude
        let ad = d.magnitude
        let exponent = Swift.max(1 - bias, floorLog2(an, ad))
        let shift = p - exponent
        let mantissa = shift >= 0 ? roundRatio(an << shift, ad) : roundRatio(an, ad << -shift)
        var m = mantissa
        var e = exponent
        if mantissa >= pow2(p + 1) {
            m = mantissa >> 1
            e = exponent + 1
        }
        if e > bias { return infinity(width, s) }
        let encoded: UInt64 = m < pow2(p) ? 0 : UInt64(e + bias)
        let fraction = (m & (pow2(p) - .one)).exactly(UInt64.self) ?? 0
        return .float(width: width, bits: (UInt64(s) << UInt64(width - 1)) | (encoded << UInt64(p)) | fraction)
    }

    /// A float's class: "nan", "infinity", "zero" or "finite".
    public static func floatClass(_ value: Value) throws -> String {
        guard case .float(let w, let b) = value else { throw Fail.with("FloatRequired") }
        switch try decode(w, b) {
        case .nan: return "nan"
        case .infinity: return "infinity"
        case .finite(_, let m, _) where m.isZero: return "zero"
        case .finite: return "finite"
        }
    }

    static func floatSign(_ value: Value) -> Int {
        guard case .float(let w, let b) = value else { return 0 }
        return Int((b >> UInt64(w - 1)) & 1)
    }

    /// A value as a float of a width: exact numbers round once, floats keep NaN
    /// and infinity and otherwise round their exact value.
    public static func toFloat(_ value: Value, _ width: Int) throws -> Value {
        if case .float(let w, let b) = value {
            if w == width { return value }
            switch try decode(w, b) {
            case .nan: return nan(width)
            case .infinity(let s): return infinity(width, s)
            default:
                let (n, d) = try exact(value)
                return try floatFromRatio(width, n, d, floatSign(value))
            }
        }
        let (n, d) = try exact(value)
        return try floatFromRatio(width, n, d, 0)
    }

    /// A complex literal of two floats of a width.
    public static func complexOf(_ width: Int, _ real: Value, _ imaginary: Value) -> Value {
        .complex(width: width, real: real, imaginary: imaginary)
    }

    public static func floatFromSingle(_ value: Float) -> Value { .float(width: 32, bits: UInt64(value.bitPattern)) }
    public static func floatFromDouble(_ value: Double) -> Value { .float(width: 64, bits: value.bitPattern) }

    public static func toSingle(_ value: Value) throws -> Float {
        guard case .float(_, let b) = try toFloat(value, 32) else { return 0 }
        return Float(bitPattern: UInt32(truncatingIfNeeded: b))
    }

    public static func toDouble(_ value: Value) throws -> Double {
        guard case .float(_, let b) = try toFloat(value, 64) else { return 0 }
        return Double(bitPattern: b)
    }

    private static func negateFloat(_ value: Value) -> Value {
        guard case .float(let w, let b) = value else { return value }
        return .float(width: w, bits: b ^ (1 << UInt64(w - 1)))
    }

    private static func floatOp(_ op: String, _ width: Int, _ a: Value, _ b: Value) throws -> Value {
        let ca = try floatClass(a)
        let cb = try floatClass(b)
        if ca == "nan" || cb == "nan" { return nan(width) }
        switch op {
        case "-": return try floatOp("+", width, a, negateFloat(b))
        case "+" where ca == "infinity" && cb == "infinity": return floatSign(a) == floatSign(b) ? a : nan(width)
        case "+" where ca == "infinity": return a
        case "+" where cb == "infinity": return b
        case "*" where (ca == "infinity" && cb == "zero") || (ca == "zero" && cb == "infinity"): return nan(width)
        case "*" where ca == "infinity" || cb == "infinity": return infinity(width, floatSign(a) ^ floatSign(b))
        case "/" where ca == "infinity" && cb == "infinity": return nan(width)
        case "/" where ca == "zero" && cb == "zero": return nan(width)
        case "/" where ca == "infinity": return infinity(width, floatSign(a) ^ floatSign(b))
        case "/" where cb == "zero": return infinity(width, floatSign(a) ^ floatSign(b))
        case "/" where cb == "infinity": return zero(width, floatSign(a) ^ floatSign(b))
        default:
            let (an, ad) = try exact(a)
            let (bn, bd) = try exact(b)
            switch op {
            case "+": return try floatFromRatio(width, an * bd + bn * ad, ad * bd, floatSign(a) & floatSign(b))
            case "*": return try floatFromRatio(width, an * bn, ad * bd, floatSign(a) ^ floatSign(b))
            case "/": return try floatFromRatio(width, an * bd, ad * bn, floatSign(a) ^ floatSign(b))
            default: throw Fail.with("UnknownFloatOperation", op)
            }
        }
    }

    /// IEEE arithmetic at the wider of the two widths.
    public static func floatBinary(_ op: String, _ a: Value, _ b: Value) throws -> Value {
        guard case .float(let wa, _) = a, case .float(let wb, _) = b else { throw Fail.with("FloatRequired", op) }
        let w = Swift.max(wa, wb)
        return try floatOp(op, w, toFloat(a, w), toFloat(b, w))
    }

    private static func compareRatios(_ x: (BigInt, BigInt), _ y: (BigInt, BigInt)) -> Int {
        BigInt.compare(x.0 * y.1, y.0 * x.1)
    }

    /// The order of two floats, or nil when one is NaN.
    public static func floatCompare(_ a: Value, _ b: Value) throws -> Int? {
        guard case .float(let wa, let ba) = a, case .float(let wb, let bb) = b else { throw Fail.with("FloatRequired") }
        switch (try decode(wa, ba), try decode(wb, bb)) {
        case (.nan, _), (_, .nan): return nil
        case let (.infinity(s), .infinity(t)) where s == t: return 0
        case (.infinity(1), _): return -1
        case (_, .infinity(1)): return 1
        case (.infinity, _): return 1
        case (_, .infinity): return -1
        default: return compareRatios(try exact(a), try exact(b))
        }
    }

    private static func toComplex(_ value: Value, _ width: Int) throws -> Value {
        if case .complex(_, let r, let i) = value {
            return .complex(width: width, real: try toFloat(r, width), imaginary: try toFloat(i, width))
        }
        return .complex(width: width, real: try toFloat(value, width), imaginary: zero(width, 0))
    }

    // MARK: Text

    /// Whether a string is well-formed: a Swift String always is.
    public static func isWellFormed(_ text: String) -> Bool { true }

    /// A text's Unicode scalar values.
    public static func codePoints(_ text: String) -> [Int] { text.unicodeScalars.map { Int($0.value) } }

    private static func validUnit(_ kind: String, _ n: Int) -> Bool {
        switch kind {
        case "Bytes": return n >= 0 && n <= 255
        case "CodeUnit16", "Utf16Text": return n >= 0 && n <= 65535
        case "CodePoint", "CodePointText": return n >= 0 && n <= 0x10FFFF
        default: return n >= 0 && n <= 0x10FFFF && (n < 0xD800 || n > 0xDFFF)
        }
    }

    private static func checkedUnit(_ kind: String, _ n: Int) throws -> Int {
        if !validUnit(kind, n) { throw Fail.with("InvalidCharacter", kind) }
        return n
    }

    /// The text of Unicode scalar values.
    public static func textOfPoints<S: Sequence>(_ points: S) throws -> String where S.Element == Int {
        var scalars = String.UnicodeScalarView()
        for p in points {
            guard let scalar = Unicode.Scalar(UInt32(try checkedUnit("Text", p))) else { throw Fail.with("InvalidCharacter", "Text") }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Compare two strings by code point, which is UTF-8's byte order and
    /// LawSpec's text order.
    public static func compareText(_ a: String, _ b: String) -> Int {
        var x = a.utf8.makeIterator()
        var y = b.utf8.makeIterator()
        while true {
            switch (x.next(), y.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case let (p?, q?): if p != q { return p < q ? -1 : 1 }
            }
        }
    }

    /// Compare two byte arrays as unsigned octets.
    public static func compareBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
        for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
        return order(a.count, b.count)
    }

    // MARK: Validation and conversion

    /// Check that a value belongs to a scalar or built-in container type under a
    /// machine profile, and return it.
    public static func validate(_ value: Value, _ t: TypeRef, _ bits: Int) throws -> Value {
        guard case .named(let name, let args) = t else { throw Fail.with("InvalidValue", typeKey(t)) }
        switch (name, args.count, value) {
        case ("Bool", 0, .bool), ("Text", 0, .text), ("Bytes", 0, .bytes), ("Decimal", 0, .decimal),
             ("Symbol", 0, .symbol), ("Unit", 0, .unit), ("Null", 0, .null), ("Undefined", 0, .undefined):
            return value
        case ("Char", 0, .int(let n)), ("CodePoint", 0, .int(let n)), ("CodeUnit16", 0, .int(let n)):
            guard let small = n.exactly(Int.self), small >= 0, small <= 0x10FFFF else { throw Fail.with("InvalidCharacter", name) }
            _ = try checkedUnit(name, small)
            return value
        case ("CodePointText", 0, .raw(let kind, let units)), ("Utf16Text", 0, .raw(let kind, let units)):
            guard kind == name else { break }
            for u in units { _ = try checkedUnit(name, u) }
            return value
        case ("Rational", 0, .ratio(let n, let d)):
            return try ratio(n, d)
        case ("Float32", 0, .float(32, _)), ("Float64", 0, .float(64, _)):
            return value
        case ("Complex64", 0, .complex(32, let r, let i)):
            return .complex(width: 32, real: try validate(r, .named("Float32", []), bits), imaginary: try validate(i, .named("Float32", []), bits))
        case ("Complex128", 0, .complex(64, let r, let i)):
            return .complex(width: 64, real: try validate(r, .named("Float64", []), bits), imaginary: try validate(i, .named("Float64", []), bits))
        case (_, 0, .int(let n)) where isIntegerType(name):
            return try checkBounds(n, name, bits)
        case ("List", 1, .list(let items)):
            return .list(try items.map { try validate($0, args[0], bits) })
        case ("Maybe", 1, .data("Maybe::Nothing", let fields)) where fields.isEmpty:
            return value
        case ("Maybe", 1, .data("Maybe::Just", let fields)) where fields.count == 1:
            return .data("Maybe::Just", [try validate(fields[0], args[0], bits)])
        case ("Either", 2, .data("Either::Left", let fields)) where fields.count == 1:
            return .data("Either::Left", [try validate(fields[0], args[0], bits)])
        case ("Either", 2, .data("Either::Right", let fields)) where fields.count == 1:
            return .data("Either::Right", [try validate(fields[0], args[1], bits)])
        case ("Nullable", 1, .presence(let kind, let present)), ("Optional", 1, .presence(let kind, let present)):
            guard kind == name else { break }
            return .presence(kind: kind, value: try present.map { try validate($0, args[0], bits) })
        default:
            break
        }
        throw Fail.with("InvalidValue", typeKey(t))
    }

    /// An explicit conversion (`x :: T`): exact numbers convert exactly or fail,
    /// floats round once, and anything else is validated.
    public static func convert(_ value: Value, _ t: TypeRef, _ bits: Int) throws -> Value {
        guard case .named(let name, let args) = t else { return try validate(value, t, bits) }
        switch (name, args.count) {
        case ("Rational", 0):
            let (n, d) = try exact(value)
            return try ratio(n, d)
        case ("Decimal", 0):
            let (n, d) = try exact(value)
            return try finiteDecimal(n, d)
        case ("Float32", 0): return try toFloat(value, 32)
        case ("Float64", 0): return try toFloat(value, 64)
        case ("Complex64", 0): return try toComplex(value, 32)
        case ("Complex128", 0): return try toComplex(value, 64)
        case (_, 0) where isIntegerType(name):
            let (n, d) = try exact(value)
            let (q, r) = n.quotientAndRemainder(dividingBy: d)
            if !r.isZero { throw Fail.with("FractionalConversion", name) }
            return try checkBounds(q, name, bits)
        case ("Nullable", 1), ("Optional", 1):
            if name == "Nullable", case .null = value { return .presence(kind: "Nullable", value: nil) }
            if name == "Optional", case .undefined = value { return .presence(kind: "Optional", value: nil) }
            if case .presence(let kind, let present) = value, kind == name {
                return .presence(kind: kind, value: try present.map { try convert($0, args[0], bits) })
            }
            return try validate(value, t, bits)
        default:
            return try validate(value, t, bits)
        }
    }

    // MARK: Equality, order and arithmetic

    /// LawSpec equality: structural, exact across exact numbers, and false for a
    /// NaN, even inside a container.
    public static func equal(_ a: Value, _ b: Value) -> Bool {
        switch (a, b) {
        case (.float, .float): return ((try? floatCompare(a, b)) ?? nil) == 0
        case let (.complex(_, r1, i1), .complex(_, r2, i2)): return equal(r1, r2) && equal(i1, i2)
        case let (.complex(w, r, i), .float): return equal(r, b) && equal(i, zero(w, 0))
        case (.float, .complex): return equal(b, a)
        case let (.symbol(x, _), .symbol(y, _)): return x === y
        case let (.presence(k1, x?), .presence(k2, y?)): return k1 == k2 && equal(x, y)
        case let (.presence(k1, nil), .presence(k2, nil)): return k1 == k2
        case let (.data(t1, f1), .data(t2, f2)): return t1 == t2 && equalLists(f1, f2)
        case let (.list(x), .list(y)): return equalLists(x, y)
        case _ where isExact(a) && isExact(b):
            guard let x = try? exact(a), let y = try? exact(b) else { return false }
            return compareRatios(x, y) == 0
        case let (.bytes(x), .bytes(y)): return x == y
        case let (.raw(k1, u1), .raw(k2, u2)): return k1 == k2 && u1 == u2
        case let (.handle(n1, i1), .handle(n2, i2)): return n1 == n2 && HandleIdentity.same(i1, i2)
        case let (.bool(x), .bool(y)): return x == y
        case let (.text(x), .text(y)): return String.portableEqual(x, y)
        case (.unit, .unit), (.null, .null), (.undefined, .undefined): return true
        default: return false
        }
    }

    private static func equalLists(_ xs: [Value], _ ys: [Value]) -> Bool {
        xs.count == ys.count && zip(xs, ys).allSatisfy { equal($0, $1) }
    }

    /// LawSpec's portable total order of keys. Floats, symbols and distinct
    /// handles have no portable order.
    public static func compareValues(_ a: Value, _ b: Value) throws -> Int {
        switch (a, b) {
        case let (.bool(x), .bool(y)): return x == y ? 0 : (x ? 1 : -1)
        case let (.text(x), .text(y)): return compareText(x, y)
        case let (.bytes(x), .bytes(y)): return compareBytes(x, y)
        case let (.raw(k1, x), .raw(k2, y)) where k1 == k2: return [Int].portableCompare(x, y)
        case let (.presence(k1, nil), .presence(k2, nil)) where k1 == k2: return 0
        case let (.presence(k1, nil), .presence(k2, _?)) where k1 == k2: return -1
        case let (.presence(k1, _?), .presence(k2, nil)) where k1 == k2: return 1
        case let (.presence(k1, x?), .presence(k2, y?)) where k1 == k2: return try compareValues(x, y)
        case (.data("Maybe::Nothing", let f), .data("Maybe::Just", _)) where f.isEmpty: return -1
        case (.data("Maybe::Just", _), .data("Maybe::Nothing", let f)) where f.isEmpty: return 1
        case let (.data(t1, f1), .data(t2, f2)) where t1 == t2: return try compareLists(f1, f2)
        case let (.data(t1, _), .data(t2, _)): return compareText(t1, t2)
        case let (.list(x), .list(y)): return try compareLists(x, y)
        case let (.handle(n1, i1), .handle(n2, i2)) where n1 == n2 && HandleIdentity.same(i1, i2): return 0
        case (.unit, .unit), (.null, .null), (.undefined, .undefined): return 0
        case _ where isExact(a) && isExact(b): return compareRatios(try exact(a), try exact(b))
        default: throw Fail.with("NoPortableOrder")
        }
    }

    private static func compareLists(_ xs: [Value], _ ys: [Value]) throws -> Int {
        for (x, y) in zip(xs, ys) {
            let c = try compareValues(x, y)
            if c != 0 { return c }
        }
        return order(xs.count, ys.count)
    }

    /// A value's negation.
    public static func negate(_ value: Value) throws -> Value {
        switch value {
        case .int(let n): return .int(-n)
        case .ratio(let n, let d): return try ratio(-n, d)
        case .decimal(let c, let e): return .decimal(-c, e)
        case .float: return negateFloat(value)
        case .complex(let w, let r, let i): return .complex(width: w, real: try negate(r), imaginary: try negate(i))
        default: throw Fail.with("NumberRequired", "negate")
        }
    }

    private static func inexactWidth(_ key: String) -> Int {
        switch key {
        case "Float32", "Complex64": return 32
        case "Float64", "Complex128": return 64
        default: return 0
        }
    }

    private static func isComplexType(_ key: String) -> Bool { key == "Complex64" || key == "Complex128" }

    private static func relation(_ op: String, _ ordering: Int?) throws -> Bool {
        guard let n = ordering else { return false }
        switch op {
        case "<": return n < 0
        case "<=": return n <= 0
        case ">": return n > 0
        case ">=": return n >= 0
        default: throw Fail.with("UnknownRelation", op)
        }
    }

    private static func exactBinary(_ op: String, _ a: Value, _ b: Value, _ ta: String, _ tb: String) throws -> Value {
        if case .int(let x) = a, case .int(let y) = b {
            switch op {
            case "pow" where !y.isNegative:
                guard let e = y.exactly(Int.self), e <= Int(Int32.max) else { throw Fail.with("InvalidExactOperation", op) }
                return .int(x.power(e))
            case "quot" where !y.isZero: return .int(x / y)
            case "rem" where !y.isZero: return .int(x % y)
            default: break
            }
        }
        let (an, ad) = try exact(a)
        let (bn, bd) = try exact(b)
        let n: BigInt
        let d: BigInt
        switch op {
        case "+": (n, d) = (an * bd + bn * ad, ad * bd)
        case "-": (n, d) = (an * bd - bn * ad, ad * bd)
        case "*": (n, d) = (an * bn, ad * bd)
        case "/": (n, d) = (an * bd, ad * bn)
        default: throw Fail.with("InvalidExactOperation", op)
        }
        let r = try ratio(n, d)
        if op == "/" || ta == "Rational" || tb == "Rational" { return r }
        if ta == "Decimal" || tb == "Decimal" { return try finiteDecimal(n, d) }
        if case .ratio(let i, _) = r { return .int(i) }
        return r
    }

    private static func complexBinary(_ op: String, _ a: Value, _ b: Value) throws -> Value {
        guard case .complex(let w, let x, let y) = a, case .complex(_, let u, let v) = b else { throw Fail.with("ComplexRequired", op) }
        let f = floatBinary
        let r: Value
        let i: Value
        switch op {
        case "+", "-":
            r = try f(op, x, u)
            i = try f(op, y, v)
        case "*":
            r = try f("-", f("*", x, u), f("*", y, v))
            i = try f("+", f("*", x, v), f("*", y, u))
        case "/":
            let den = try f("+", f("*", u, u), f("*", v, v))
            r = try f("/", f("+", f("*", x, u), f("*", y, v)), den)
            i = try f("/", f("-", f("*", y, u), f("*", x, v)), den)
        default:
            throw Fail.with("UnknownComplexOperation", op)
        }
        return .complex(width: w, real: r, imaginary: i)
    }

    /// A binary operator on two values of the given types (by key).
    public static func binary(_ op: String, _ a: Value, _ b: Value, _ ta: String, _ tb: String) throws -> Value {
        switch op {
        case "==": return .bool(equal(a, b))
        case "!=": return .bool(!equal(a, b))
        case "<", "<=", ">", ">=":
            let ordering = (inexactWidth(ta) > 0 || inexactWidth(tb) > 0) ? try floatCompare(a, b) : try compareValues(a, b)
            return .bool(try relation(op, ordering))
        default:
            if (inexactWidth(ta) > 0) != (inexactWidth(tb) > 0) { throw Fail.with("ExactInexactMixing", op) }
            let width = Swift.max(inexactWidth(ta), inexactWidth(tb))
            if width == 0 { return try exactBinary(op, a, b, ta, tb) }
            if isComplexType(ta) || isComplexType(tb) { return try complexBinary(op, toComplex(a, width), toComplex(b, width)) }
            return try floatBinary(op, a, b)
        }
    }

    // MARK: Helpers

    private static func sequenceItems(_ value: Value, _ kind: String) throws -> [Value] {
        switch value {
        case .list(let items): return items
        case .text(let s) where kind == "Text": return s.unicodeScalars.map { .int(BigInt(Int($0.value))) }
        case .text(let s): return s.utf8.map { .int(BigInt(Int($0))) }
        case .bytes(let b): return b.map { .int(BigInt(Int($0))) }
        default: throw Fail.with("SequenceRequired", kind)
        }
    }

    private static func sequenceLike(_ value: Value, _ kind: String, _ items: [Value]) throws -> Value {
        // Only text and bytes are made of integers; a list keeps its items.
        func ints() throws -> [Int] {
            try items.map { item in
                guard case .int(let n) = item, let small = n.exactly(Int.self) else { throw Fail.with("SequenceRequired", kind) }
                return small
            }
        }
        switch value {
        case .list: return .list(items)
        case .text where kind == "Text": return .text(try textOfPoints(ints()))
        default: return .bytes(try ints().map { UInt8(truncatingIfNeeded: $0) })
        }
    }

    private static func integer(_ value: Value) throws -> BigInt {
        guard case .int(let n) = value else { throw Fail.with("IntegerRequired") }
        return n
    }

    private static func text(_ value: Value) throws -> String {
        guard case .text(let s) = value else { throw Fail.with("TextRequired") }
        return s
    }

    private static func clamp(_ n: BigInt, _ lo: BigInt, _ hi: BigInt) -> BigInt { n < lo ? lo : (n > hi ? hi : n) }

    /// A built-in helper by name, with its arguments and their type keys.
    public static func helper(_ name: String, _ values: [Value], _ types: [String], _ bits: Int) throws -> Value {
        switch (name, values.count) {
        case ("isNaN", 1): return .bool(try floatClass(values[0]) == "nan")
        case ("isInfinite", 1): return .bool(try floatClass(values[0]) == "infinity")
        case ("isFinite", 1):
            let c = try floatClass(values[0])
            return .bool(c == "finite" || c == "zero")
        case ("isNegativeZero", 1): return .bool(try floatClass(values[0]) == "zero" && floatSign(values[0]) == 1)
        case ("length", 1):
            switch values[0] {
            case .list(let items): return .int(BigInt(items.count))
            case .bytes(let b): return .int(BigInt(b.count))
            case .text(let s): return .int(BigInt(s.unicodeScalars.count))
            case .raw(_, let units): return .int(BigInt(units.count))
            default: break
            }
        case ("real", 1):
            if case .complex(_, let r, _) = values[0] { return r }
        case ("imag", 1), ("imaginary", 1):
            if case .complex(_, _, let i) = values[0] { return i }
        case ("conjugate", 1):
            if case .complex(let w, let r, let i) = values[0] { return .complex(width: w, real: r, imaginary: try negate(i)) }
        case ("abs", 1):
            if isExact(values[0]) { return try exact(values[0]).0.isNegative ? try negate(values[0]) : values[0] }
            if case .float(let w, let b) = values[0] { return .float(width: w, bits: b & ((1 << UInt64(w - 1)) - 1)) }
        case ("round", 2):
            if case .int(let placesValue) = values[1], let places = placesValue.exactly(Int.self) {
                let (n, d) = try exact(values[0])
                let (sn, sd) = places >= 0 ? (n * pow10(places), d) : (n, d * pow10(-places))
                let q = roundRatio(sn.magnitude, sd)
                return .decimal(sn.isNegative ? -q : q, -places)
            }
        case ("startsWith", 2):
            if case .text(let t) = values[0], case .text(let p) = values[1] { return .bool(t.unicodeScalars.starts(with: p.unicodeScalars)) }
        case ("endsWith", 2):
            if case .text(let t) = values[0], case .text(let s) = values[1] {
                return .bool(t.unicodeScalars.reversed().starts(with: s.unicodeScalars.reversed()))
            }
        case ("textContains", 2):
            if case .text(let t) = values[0], case .text(let p) = values[1] { return .bool(Typed.contains(t, p)) }
        case ("checked", 1): return .bool(true)
        case ("select", 3):
            if case .bool(let c) = values[0] { return c ? values[1] : values[2] }
        case ("compare", 2):
            let c = try compareValues(values[0], values[1])
            let tag = c < 0 ? "Less" : (c == 0 ? "Equal" : "Greater")
            return .data("lawspec.collections::type::Ordering::" + tag, [])
        case ("isPresent", 1):
            if case .presence(_, let p) = values[0] { return .bool(p != nil) }
        case ("presentValue", 1):
            if case .presence(_, let p) = values[0] {
                guard let v = p else { throw Fail.with("AbsentPresenceValue") }
                return v
            }
        case ("negate", 1): return try negate(values[0])
        case ("append", 2):
            switch (values[0], values[1]) {
            case let (.list(a), .list(b)): return .list(a + b)
            case let (.text(a), .text(b)): return .text(a + b)
            case let (.bytes(a), .bytes(b)): return .bytes(a + b)
            default: break
            }
        case ("slice", 3):
            if case .int(let from) = values[1], case .int(let until) = values[2] {
                let kind = types.first ?? ""
                let items = try sequenceItems(values[0], kind)
                let count = BigInt(items.count)
                let i = clamp(from, .zero, count)
                let j = clamp(until, i, count)
                let lo = i.exactly(Int.self) ?? 0
                let hi = j.exactly(Int.self) ?? 0
                return try sequenceLike(values[0], kind, Array(items[lo..<hi]))
            }
        case ("at", 2):
            if case .int(let i) = values[1] {
                let items = try sequenceItems(values[0], types.first ?? "")
                if !i.isNegative, let k = i.exactly(Int.self), k < items.count { return .data("Maybe::Just", [items[k]]) }
                return .data("Maybe::Nothing", [])
            }
        case ("range", 2):
            if case .int(let lo) = values[0], case .int(let hi) = values[1] {
                var result = [Value]()
                var n = lo
                while n < hi {
                    result.append(.int(n))
                    n += .one
                }
                return .list(result)
            }
        case ("octets", 1):
            if case .bytes(let b) = values[0] { return .list(b.map { .int(BigInt(Int($0))) }) }
        case ("bytesOf", 1):
            if case .list(let items) = values[0] {
                return .bytes(try items.map { UInt8(truncatingIfNeeded: try integer($0).truncated(Int.self)) })
            }
        case ("utf8", 1):
            if case .text(let t) = values[0] { return .bytes(Array(t.utf8)) }
        case ("textOf", 1):
            if case .int(let n) = values[0] { return .text(n.description) }
        case ("join", 2):
            if case .text(let separator) = values[0], case .list(let parts) = values[1] {
                return .text(try parts.map(text).joined(separator: separator))
            }
        case ("quot", 2), ("rem", 2), ("pow", 2):
            return try binary(name, values[0], values[1], types[0], types[1])
        default:
            break
        }
        if values.count == 1 { return try convert(values[0], typeOf(name), bits) }
        throw Fail.with("UnknownHelper", name)
    }

    // MARK: Symbols

    /// A fresh symbol with a description.
    public static func newSymbol(_ description: String) -> Value { .symbol(SymbolIdentity(), description) }

    /// A literal symbol, interned in its context.
    public static func symbol(_ context: SymbolContext, _ id: String, _ description: String) -> Value {
        .symbol(context.identity(id), description)
    }

    // MARK: Literals, as the generated code writes them

    public static func integerLiteral(_ digits: String) throws -> Value {
        guard let n = BigInt(digits) else { throw Fail.with("InvalidIntegerLiteral", digits) }
        return .int(n)
    }

    public static func decimalOf(_ coefficient: String, _ exponent: Int) throws -> Value {
        guard let c = BigInt(coefficient) else { throw Fail.with("InvalidDecimalLiteral", coefficient) }
        return .decimal(c, exponent)
    }

    public static func rationalOf(_ numerator: String, _ denominator: String) throws -> Value {
        guard let n = BigInt(numerator), let d = BigInt(denominator) else { throw Fail.with("InvalidRationalLiteral") }
        return try ratio(n, d)
    }

    public static func floatBits(_ width: Int, _ hex: String) throws -> Value {
        guard let bits = UInt64(hex, radix: 16) else { throw Fail.with("InvalidIeeeBits", hex) }
        return try floatValue(width, bits)
    }

    public static func textUnits(_ points: [Int]) throws -> Value { .text(try textOfPoints(points)) }

    public static func bytesOf(_ units: [Int]) throws -> Value {
        .bytes(try units.map { UInt8(try checkedUnit("Bytes", $0)) })
    }

    public static func rawOf(_ kind: String, _ units: [Int]) throws -> Value {
        .raw(kind: kind, units: try units.map { try checkedUnit(kind, $0) })
    }
}

/// Literal symbols share identities within one context (a law's run).
public final class SymbolContext: Sendable {
    private let symbols = Locked([String: SymbolIdentity]())
    public init() {}
    public func identity(_ id: String) -> SymbolIdentity {
        symbols.with { table in
            if let known = table[id] { return known }
            let made = SymbolIdentity()
            table[id] = made
            return made
        }
    }
}
