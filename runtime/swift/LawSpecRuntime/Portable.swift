// LawSpec's portable equality, hash and order over native Swift values. The
// generated structs and enums use it, so a native value orders as its
// portable value does on every target: text by code point (Swift compares a
// String by canonical equivalence), constructors by their identities, fields
// left to right. Floats compare by their bits for equality, so it is
// reflexive, as Swift's collections require. ref:DEC-portable-exact-arithmetic
// ref:DEC-idiomatic-generated-types

/// A native type with LawSpec's equality, hash and order.
public protocol Portable: Sendable {
    /// Whether two values are the same LawSpec value.
    static func portableEqual(_ a: Self, _ b: Self) -> Bool
    /// LawSpec's order of two values: -1, 0 or 1.
    static func portableCompare(_ a: Self, _ b: Self) -> Int
    /// A hash consistent with portableEqual.
    func portableHash(into hasher: inout Hasher)
}

/// The order of two comparable values, as -1, 0 or 1.
@inlinable func order<T: Comparable>(_ a: T, _ b: T) -> Int { a < b ? -1 : (a == b ? 0 : 1) }

extension Portable where Self: Comparable {
    public static func portableEqual(_ a: Self, _ b: Self) -> Bool { a == b }
    public static func portableCompare(_ a: Self, _ b: Self) -> Int { order(a, b) }
}

extension Portable where Self: Hashable {
    public func portableHash(into hasher: inout Hasher) { hasher.combine(self) }
}

extension Bool: Portable {
    public static func portableEqual(_ a: Bool, _ b: Bool) -> Bool { a == b }
    public static func portableCompare(_ a: Bool, _ b: Bool) -> Int { a == b ? 0 : (a ? 1 : -1) }
}
extension Int8: Portable {}
extension Int16: Portable {}
extension Int32: Portable {}
extension Int64: Portable {}
extension Int: Portable {}
extension UInt8: Portable {}
extension UInt16: Portable {}
extension UInt32: Portable {}
extension UInt64: Portable {}
extension UInt: Portable {}
extension BigInt: Portable {}
extension Unit: Portable {}
extension Null: Portable {}
extension Undefined: Portable {}
extension Duration: Portable {}

extension Unicode.Scalar: Portable {
    public static func portableEqual(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool { a.value == b.value }
    public static func portableCompare(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Int { order(a.value, b.value) }
    public func portableHash(into hasher: inout Hasher) { hasher.combine(value) }
}

extension String: Portable {
    /// Equal code point by code point: Swift's own == treats canonically
    /// equivalent texts (e + U+0301 and U+00E9) as equal; LawSpec does not.
    public static func portableEqual(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }
    public static func portableCompare(_ a: String, _ b: String) -> Int { Scalar.compareText(a, b) }
    public func portableHash(into hasher: inout Hasher) {
        for scalar in unicodeScalars { hasher.combine(scalar.value) }
        hasher.combine(-1)
    }
}

extension Float: Portable {
    public static func portableEqual(_ a: Float, _ b: Float) -> Bool { a.bitPattern == b.bitPattern }
    /// Floats have no portable order; natively they order by IEEE's total order.
    public static func portableCompare(_ a: Float, _ b: Float) -> Int {
        a.bitPattern == b.bitPattern ? 0 : (a.isTotallyOrdered(belowOrEqualTo: b) ? -1 : 1)
    }
    public func portableHash(into hasher: inout Hasher) { hasher.combine(bitPattern) }
}

extension Double: Portable {
    public static func portableEqual(_ a: Double, _ b: Double) -> Bool { a.bitPattern == b.bitPattern }
    /// Floats have no portable order; natively they order by IEEE's total order.
    public static func portableCompare(_ a: Double, _ b: Double) -> Int {
        a.bitPattern == b.bitPattern ? 0 : (a.isTotallyOrdered(belowOrEqualTo: b) ? -1 : 1)
    }
    public func portableHash(into hasher: inout Hasher) { hasher.combine(bitPattern) }
}

extension Complex64: Portable {
    public static func portableEqual(_ a: Complex64, _ b: Complex64) -> Bool { a == b }
    public static func portableCompare(_ a: Complex64, _ b: Complex64) -> Int {
        let c = Float.portableCompare(a.real, b.real)
        return c != 0 ? c : Float.portableCompare(a.imaginary, b.imaginary)
    }
}

extension Complex128: Portable {
    public static func portableEqual(_ a: Complex128, _ b: Complex128) -> Bool { a == b }
    public static func portableCompare(_ a: Complex128, _ b: Complex128) -> Int {
        let c = Double.portableCompare(a.real, b.real)
        return c != 0 ? c : Double.portableCompare(a.imaginary, b.imaginary)
    }
}

extension Rational: Portable {
    public static func portableEqual(_ a: Rational, _ b: Rational) -> Bool { a == b }
    public static func portableCompare(_ a: Rational, _ b: Rational) -> Int {
        BigInt.compare(a.numerator * b.denominator, b.numerator * a.denominator)
    }
}

extension ExactDecimal: Portable {
    public static func portableEqual(_ a: ExactDecimal, _ b: ExactDecimal) -> Bool { a == b }
    /// By value; 1.0 and 1.00 order alike but are distinct decimals.
    public static func portableCompare(_ a: ExactDecimal, _ b: ExactDecimal) -> Int {
        let e = Swift.min(a.exponent, b.exponent)
        let x = a.coefficient * BigInt(10).power(a.exponent - e)
        let y = b.coefficient * BigInt(10).power(b.exponent - e)
        let c = BigInt.compare(x, y)
        return c != 0 ? c : order(a.exponent, b.exponent)
    }
}

extension Symbol: Portable {
    public static func portableEqual(_ a: Symbol, _ b: Symbol) -> Bool { a == b }
    /// Symbols have no portable order; natively they order by identity.
    public static func portableCompare(_ a: Symbol, _ b: Symbol) -> Int {
        order(ObjectIdentifier(a.identity), ObjectIdentifier(b.identity))
    }
}

extension AnyHandle: Portable {
    public static func portableEqual(_ a: AnyHandle, _ b: AnyHandle) -> Bool { a == b }
    /// Handles have no portable order; natively they order by identity.
    public static func portableCompare(_ a: AnyHandle, _ b: AnyHandle) -> Int {
        order(ObjectIdentifier(a.object), ObjectIdentifier(b.object))
    }
}

extension Array: Portable where Element: Portable {
    public static func portableEqual(_ a: [Element], _ b: [Element]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { Element.portableEqual($0, $1) }
    }
    public static func portableCompare(_ a: [Element], _ b: [Element]) -> Int {
        for (x, y) in zip(a, b) {
            let c = Element.portableCompare(x, y)
            if c != 0 { return c }
        }
        return order(a.count, b.count)
    }
    public func portableHash(into hasher: inout Hasher) {
        hasher.combine(count)
        for item in self { item.portableHash(into: &hasher) }
    }
}

extension Optional: Portable where Wrapped: Portable {
    public static func portableEqual(_ a: Wrapped?, _ b: Wrapped?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return Wrapped.portableEqual(x, y)
        default: return false
        }
    }
    /// Nothing before Just, as LawSpec orders Maybe.
    public static func portableCompare(_ a: Wrapped?, _ b: Wrapped?) -> Int {
        switch (a, b) {
        case (nil, nil): return 0
        case (nil, _): return -1
        case (_, nil): return 1
        case let (x?, y?): return Wrapped.portableCompare(x, y)
        }
    }
    public func portableHash(into hasher: inout Hasher) {
        switch self {
        case nil: hasher.combine(0)
        case let x?:
            hasher.combine(1)
            x.portableHash(into: &hasher)
        }
    }
}

extension Nullable: Portable where Wrapped: Portable {
    public static func portableEqual(_ a: Nullable, _ b: Nullable) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.present(x), .present(y)): return Wrapped.portableEqual(x, y)
        default: return false
        }
    }
    public static func portableCompare(_ a: Nullable, _ b: Nullable) -> Int {
        switch (a, b) {
        case (.null, .null): return 0
        case (.null, _): return -1
        case (_, .null): return 1
        case let (.present(x), .present(y)): return Wrapped.portableCompare(x, y)
        }
    }
    public func portableHash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .present(let x):
            hasher.combine(1)
            x.portableHash(into: &hasher)
        }
    }
}

extension Undefinable: Portable where Wrapped: Portable {
    public static func portableEqual(_ a: Undefinable, _ b: Undefinable) -> Bool {
        switch (a, b) {
        case (.undefined, .undefined): return true
        case let (.present(x), .present(y)): return Wrapped.portableEqual(x, y)
        default: return false
        }
    }
    public static func portableCompare(_ a: Undefinable, _ b: Undefinable) -> Int {
        switch (a, b) {
        case (.undefined, .undefined): return 0
        case (.undefined, _): return -1
        case (_, .undefined): return 1
        case let (.present(x), .present(y)): return Wrapped.portableCompare(x, y)
        }
    }
    public func portableHash(into hasher: inout Hasher) {
        switch self {
        case .undefined: hasher.combine(0)
        case .present(let x):
            hasher.combine(1)
            x.portableHash(into: &hasher)
        }
    }
}

extension Either: Portable where Left: Portable, Right: Portable {
    public static func portableEqual(_ a: Either, _ b: Either) -> Bool {
        switch (a, b) {
        case let (.left(x), .left(y)): return Left.portableEqual(x, y)
        case let (.right(x), .right(y)): return Right.portableEqual(x, y)
        default: return false
        }
    }
    /// Left before Right, as their constructors' identities order.
    public static func portableCompare(_ a: Either, _ b: Either) -> Int {
        switch (a, b) {
        case let (.left(x), .left(y)): return Left.portableCompare(x, y)
        case let (.right(x), .right(y)): return Right.portableCompare(x, y)
        case (.left, .right): return -1
        case (.right, .left): return 1
        }
    }
    public func portableHash(into hasher: inout Hasher) {
        switch self {
        case .left(let x):
            hasher.combine(0)
            x.portableHash(into: &hasher)
        case .right(let x):
            hasher.combine(1)
            x.portableHash(into: &hasher)
        }
    }
}

/// Helpers the generated data types use for their constructors' fields.
public enum PortableData {
    /// Compare two constructors' ranks and then their fields, given as
    /// comparisons in order.
    public static func compare(_ rankA: Int, _ rankB: Int, _ fields: () -> [Int]) -> Int {
        if rankA != rankB { return order(rankA, rankB) }
        for c in fields() where c != 0 { return c }
        return 0
    }
}

extension Value: Portable {
    /// Values compare as LawSpec does; a value with no portable order (a
    /// float, a symbol) orders natively by its debug text.
    public static func portableEqual(_ a: Value, _ b: Value) -> Bool { Recorded.identical(a, b) }
    public static func portableCompare(_ a: Value, _ b: Value) -> Int {
        if let c = try? Scalar.compareValues(a, b) { return c }
        return Scalar.compareText(Recorded.debug(a), Recorded.debug(b))
    }
    public func portableHash(into hasher: inout Hasher) { hasher.combine(Recorded.debug(self)) }
}
