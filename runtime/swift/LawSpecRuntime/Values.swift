// LawSpec's portable values, as the generated laws and the dynamic
// definitions see them. Native Swift code never handles these directly:
// generated codecs convert at the boundary to structs, enums and the Swift
// types the adapters use. ref:DEC-swift-runtime-from-scratch
// ref:DEC-typed-core-boundary

/// A symbol's identity: two symbols are equal when they share one.
public final class SymbolIdentity: Sendable {
    public init() {}
}

/// A handle's native value, compared by identity.
public struct HandleIdentity: @unchecked Sendable {
    /// The native object; a handle crosses the boundary unchanged.
    public let object: AnyObject
    public init(_ object: AnyObject) { self.object = object }
    public static func same(_ a: HandleIdentity, _ b: HandleIdentity) -> Bool { a.object === b.object }
}

/// A value in LawSpec's portable domain. Exact numbers stay exact, IEEE
/// values keep their bits (so a NaN payload and a negative zero survive), and
/// data is a constructor tag with its fields in declaration order.
public indirect enum Value: Sendable, CustomStringConvertible {
    case bool(Bool)
    case int(BigInt)
    /// A normalized fraction: positive denominator, lowest terms.
    case ratio(BigInt, BigInt)
    /// coefficient * 10 ^ exponent, with the scale it was written with.
    case decimal(BigInt, Int)
    case float(width: Int, bits: UInt64)
    case complex(width: Int, real: Value, imaginary: Value)
    /// Unicode text; it never holds a lone surrogate.
    case text(String)
    case bytes([UInt8])
    /// CodePointText and Utf16Text: their units, without validation as text.
    case raw(kind: String, units: [Int])
    case unit
    case null
    case undefined
    /// Two symbols are equal when they share an identity.
    case symbol(SymbolIdentity, String)
    case list([Value])
    case data(String, [Value])
    /// Nullable or Optional: absent, or present with a value.
    case presence(kind: String, value: Value?)
    /// A handle's identity crosses the native boundary unchanged.
    case handle(String, HandleIdentity)

    public var description: String { Recorded.debug(self) }
}

/// A type as the runtime checks it: a name applied to arguments, or a data
/// declaration's parameter by position.
public indirect enum TypeRef: Sendable, Hashable, CustomStringConvertible {
    case named(String, [TypeRef])
    case parameter(Int)

    public var description: String { Scalar.typeKey(self) }
}

/// A broken contract, an unmet law or a malformed value. The code names the
/// kind of failure (StrategyOutsideRefinement, EquationFailed, ...), so test
/// output names it the same way on every target.
public struct LawSpecError: Error, Sendable, CustomStringConvertible {
    public let code: String
    public let detail: String
    /// The definitions and laws it happened in, innermost first.
    public let context: [String]
    /// The failure that caused this one, if any.
    public let cause: String?

    public init(_ code: String, _ detail: String = "", context: [String] = [], cause: String? = nil) {
        self.code = code
        self.detail = detail
        self.context = context
        self.cause = cause
    }

    /// The same failure, inside one more definition or law.
    public func within(_ identity: String) -> LawSpecError {
        LawSpecError(code, detail, context: [identity] + context, cause: cause)
    }

    public var description: String {
        let prefix = context.isEmpty ? "" : context.reversed().joined(separator: ": ") + ": "
        return prefix + code + (detail.isEmpty ? "" : " " + detail)
    }
}

/// A failure an operation raised with `raise`, carrying its portable value
/// until an `attempt` catches it. ref:DEC-typed-native-definitions
public struct RaisedFailure: Error, Sendable, CustomStringConvertible {
    public let ability: String
    public let failure: Value
    public init(_ ability: String, _ failure: Value) {
        self.ability = ability
        self.failure = failure
    }
    public var description: String { "LawSpec failure raised by \(ability): \(Recorded.debug(failure))" }
}

/// Helpers for raising LawSpec's failures.
public enum Fail {
    /// A LawSpec failure with a code and detail.
    public static func with(_ code: String, _ detail: String = "") -> LawSpecError {
        LawSpecError(code, detail)
    }

    /// Fail unless the condition holds.
    public static func require(_ condition: Bool, _ code: String, _ detail: String = "") throws {
        if !condition { throw LawSpecError(code, detail) }
    }

    /// Any error as the failure a law reports: LawSpec's own pass unchanged.
    public static func describe(_ error: any Error) -> String {
        String(describing: error)
    }
}
