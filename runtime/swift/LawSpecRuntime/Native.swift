// The Swift types LawSpec values take at the native boundary, where Swift has
// no exact counterpart: exact fractions and decimals, complex numbers, the
// two kinds of presence, Either, the unit, null and undefined values, symbols
// and handles. Every other LawSpec type maps to a Swift type directly (Int8
// ... UInt64, BigInt, String, [UInt8], arrays, optionals, Unicode.Scalar).
// ref:DEC-swift-runtime-from-scratch ref:DEC-idiomatic-generated-types

/// An exact fraction in lowest terms, with a positive denominator.
public struct Rational: Sendable, Hashable, CustomStringConvertible {
    public let numerator: BigInt
    public let denominator: BigInt

    /// The fraction numerator / denominator, normalized. The denominator
    /// must not be zero.
    public init(_ numerator: BigInt, _ denominator: BigInt) {
        precondition(!denominator.isZero, "a rational's denominator is not zero")
        let g = BigInt.gcd(numerator, denominator)
        let sign: BigInt = denominator.isNegative ? -1 : 1
        self.numerator = sign * numerator / g
        self.denominator = denominator.magnitude / g
    }

    public var description: String { "\(numerator)/\(denominator)" }
}

/// coefficient * 10 ^ exponent, exactly; 1.50 keeps its two places.
public struct ExactDecimal: Sendable, Hashable, CustomStringConvertible {
    public var coefficient: BigInt
    public var exponent: Int

    public init(coefficient: BigInt, exponent: Int) {
        self.coefficient = coefficient
        self.exponent = exponent
    }

    public var description: String { "\(coefficient)e\(exponent)" }

    /// Both decimals at the smaller exponent.
    private static func aligned(_ a: ExactDecimal, _ b: ExactDecimal) -> (BigInt, BigInt, Int) {
        let e = Swift.min(a.exponent, b.exponent)
        func scale(_ d: ExactDecimal) -> BigInt { d.coefficient * BigInt(10).power(d.exponent - e) }
        return (scale(a), scale(b), e)
    }

    /// Exact sum, at the finer of the two scales.
    public static func + (a: ExactDecimal, b: ExactDecimal) -> ExactDecimal {
        let (x, y, e) = aligned(a, b)
        return ExactDecimal(coefficient: x + y, exponent: e)
    }

    /// Exact difference, at the finer of the two scales.
    public static func - (a: ExactDecimal, b: ExactDecimal) -> ExactDecimal {
        let (x, y, e) = aligned(a, b)
        return ExactDecimal(coefficient: x - y, exponent: e)
    }

    /// Exact product.
    public static func * (a: ExactDecimal, b: ExactDecimal) -> ExactDecimal {
        ExactDecimal(coefficient: a.coefficient * b.coefficient, exponent: a.exponent + b.exponent)
    }
}

/// A complex number of two single precision floats.
public struct Complex64: Sendable, Hashable, CustomStringConvertible {
    public var real: Float
    public var imaginary: Float
    public init(real: Float, imaginary: Float) {
        self.real = real
        self.imaginary = imaginary
    }
    public static func == (a: Complex64, b: Complex64) -> Bool {
        a.real.bitPattern == b.real.bitPattern && a.imaginary.bitPattern == b.imaginary.bitPattern
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(real.bitPattern)
        hasher.combine(imaginary.bitPattern)
    }
    public var description: String { "(\(real), \(imaginary))" }
}

/// A complex number of two double precision floats.
public struct Complex128: Sendable, Hashable, CustomStringConvertible {
    public var real: Double
    public var imaginary: Double
    public init(real: Double, imaginary: Double) {
        self.real = real
        self.imaginary = imaginary
    }
    public static func == (a: Complex128, b: Complex128) -> Bool {
        a.real.bitPattern == b.real.bitPattern && a.imaginary.bitPattern == b.imaginary.bitPattern
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(real.bitPattern)
        hasher.combine(imaginary.bitPattern)
    }
    public var description: String { "(\(real), \(imaginary))" }
}

/// A value that may be null, distinct from an undefined Undefinable.
public enum Nullable<Wrapped>: CustomStringConvertible {
    case null
    case present(Wrapped)
    public var description: String {
        switch self {
        case .null: return "null"
        case .present(let value): return "present(\(value))"
        }
    }
}

/// A value that may be undefined (LawSpec's Optional), distinct from a null
/// Nullable.
public enum Undefinable<Wrapped>: CustomStringConvertible {
    case undefined
    case present(Wrapped)
    public var description: String {
        switch self {
        case .undefined: return "undefined"
        case .present(let value): return "present(\(value))"
        }
    }
}

/// Either of two values; left conventionally the failure.
public enum Either<Left, Right>: CustomStringConvertible {
    case left(Left)
    case right(Right)
    public var description: String {
        switch self {
        case .left(let value): return "left(\(value))"
        case .right(let value): return "right(\(value))"
        }
    }
}

extension Nullable: Sendable where Wrapped: Sendable {}
extension Undefinable: Sendable where Wrapped: Sendable {}
extension Either: Sendable where Left: Sendable, Right: Sendable {}
extension Nullable: Equatable where Wrapped: Equatable {}
extension Undefinable: Equatable where Wrapped: Equatable {}
extension Either: Equatable where Left: Equatable, Right: Equatable {}
extension Nullable: Hashable where Wrapped: Hashable {}
extension Undefinable: Hashable where Wrapped: Hashable {}
extension Either: Hashable where Left: Hashable, Right: Hashable {}

/// LawSpec's Unit value.
public struct Unit: Sendable, Hashable, Comparable, CustomStringConvertible {
    public init() {}
    public static func < (_: Unit, _: Unit) -> Bool { false }
    public var description: String { "()" }
}

/// LawSpec's Null value.
public struct Null: Sendable, Hashable, Comparable, CustomStringConvertible {
    public init() {}
    public static func < (_: Null, _: Null) -> Bool { false }
    public var description: String { "null" }
}

/// LawSpec's Undefined value.
public struct Undefined: Sendable, Hashable, Comparable, CustomStringConvertible {
    public init() {}
    public static func < (_: Undefined, _: Undefined) -> Bool { false }
    public var description: String { "undefined" }
}

/// A symbol: equal only to itself.
public struct Symbol: Sendable, Hashable, CustomStringConvertible {
    public let identity: SymbolIdentity
    public let symbolDescription: String
    public init(_ description: String) {
        self.identity = SymbolIdentity()
        self.symbolDescription = description
    }
    public init(identity: SymbolIdentity, description: String) {
        self.identity = identity
        self.symbolDescription = description
    }
    public static func == (a: Symbol, b: Symbol) -> Bool { a.identity === b.identity }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(identity)) }
    public var description: String { "Symbol(\(symbolDescription))" }
}

/// A handle no application type is bound to: a native object LawSpec passes
/// along unopened, equal only to itself.
public struct AnyHandle: @unchecked Sendable, Hashable, CustomStringConvertible {
    public let object: AnyObject
    public init(_ object: AnyObject) { self.object = object }
    public static func == (a: AnyHandle, b: AnyHandle) -> Bool { a.object === b.object }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(object)) }
    public var description: String { "handle(\(type(of: object)))" }
}
