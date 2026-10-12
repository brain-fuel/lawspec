// Conversions between portable values and the native Swift types adapters
// use. The generated code composes these for each adapter's signature, and
// generates one for each data type, so no reflection is involved.
// ref:DEC-typed-core-boundary ref:DEC-native-bindings-typed-identity

/// To and from a native type.
public struct Codec<Native>: Sendable {
    public let toNative: @Sendable (Value) throws -> Native
    public let fromNative: @Sendable (Native) throws -> Value

    public init(toNative: @escaping @Sendable (Value) throws -> Native, fromNative: @escaping @Sendable (Native) throws -> Value) {
        self.toNative = toNative
        self.fromNative = fromNative
    }
}

public enum Codecs {
    /// A value that is not of a native type's shape.
    public static func invalid(_ expected: String, _ value: Value) -> LawSpecError { wrong(expected, value) }

    static func wrong(_ expected: String, _ value: Value) -> LawSpecError {
        Fail.with("InvalidNativeValue", "expected \(expected), got \(Recorded.debug(value))")
    }

    static func integer(_ name: String, _ value: Value) throws -> BigInt {
        guard case .int(let n) = value else { throw wrong(name, value) }
        return n
    }

    private static func bounded<T: FixedWidthInteger & Sendable>(_ name: String, _ type: T.Type) -> Codec<T> {
        Codec(toNative: { v in
            guard let n = try integer(name, v).exactly(T.self) else { throw wrong(name, v) }
            return n
        }, fromNative: { .int(BigInt($0)) })
    }

    public static let int8 = bounded("Int8", Int8.self)
    public static let int16 = bounded("Int16", Int16.self)
    public static let int32 = bounded("Int32", Int32.self)
    public static let int64 = bounded("Int64", Int64.self)
    public static let uint8 = bounded("UInt8", UInt8.self)
    public static let uint16 = bounded("UInt16", UInt16.self)
    public static let uint32 = bounded("UInt32", UInt32.self)
    public static let uint64 = bounded("UInt64", UInt64.self)
    /// IntSize: Int, checked against the profile by the schema.
    public static let intSize = bounded("IntSize", Int.self)
    /// UIntSize and UIntPtr: UInt, checked against the profile by the schema.
    public static let uintSize = bounded("UIntSize", UInt.self)
    public static let bigInt = Codec<BigInt>(toNative: { try integer("Integer", $0) }, fromNative: { .int($0) })

    public static let bool = Codec<Bool>(toNative: { v in
        guard case .bool(let b) = v else { throw wrong("Bool", v) }
        return b
    }, fromNative: { .bool($0) })

    public static let unit = Codec<Unit>(toNative: { v in
        guard case .unit = v else { throw wrong("Unit", v) }
        return Unit()
    }, fromNative: { _ in .unit })

    public static let null = Codec<Null>(toNative: { v in
        guard case .null = v else { throw wrong("Null", v) }
        return Null()
    }, fromNative: { _ in .null })

    public static let undefined = Codec<Undefined>(toNative: { v in
        guard case .undefined = v else { throw wrong("Undefined", v) }
        return Undefined()
    }, fromNative: { _ in .undefined })

    public static let text = Codec<String>(toNative: { v in
        guard case .text(let s) = v else { throw wrong("Text", v) }
        return s
    }, fromNative: { .text($0) })

    public static let bytes = Codec<[UInt8]>(toNative: { v in
        guard case .bytes(let b) = v else { throw wrong("Bytes", v) }
        return b
    }, fromNative: { .bytes($0) })

    /// Char: a Unicode scalar value.
    public static let char = Codec<Unicode.Scalar>(toNative: { v in
        guard let code = try integer("Char", v).exactly(UInt32.self), let scalar = Unicode.Scalar(code) else { throw wrong("Char", v) }
        return scalar
    }, fromNative: { .int(BigInt(Int($0.value))) })

    public static let codePoint = bounded("CodePoint", UInt32.self)
    public static let codeUnit16 = bounded("CodeUnit16", UInt16.self)

    public static let codePointText = Codec<[UInt32]>(toNative: { v in
        guard case .raw(_, let units) = v else { throw wrong("CodePointText", v) }
        return units.map { UInt32(truncatingIfNeeded: $0) }
    }, fromNative: { .raw(kind: "CodePointText", units: $0.map { Int($0) }) })

    public static let utf16Text = Codec<[UInt16]>(toNative: { v in
        guard case .raw(_, let units) = v else { throw wrong("Utf16Text", v) }
        return units.map { UInt16(truncatingIfNeeded: $0) }
    }, fromNative: { .raw(kind: "Utf16Text", units: $0.map { Int($0) }) })

    public static let float32 = Codec<Float>(toNative: { v in
        guard case .float(32, let b) = v else { throw wrong("Float32", v) }
        return Float(bitPattern: UInt32(truncatingIfNeeded: b))
    }, fromNative: { Scalar.floatFromSingle($0) })

    public static let float64 = Codec<Double>(toNative: { v in
        guard case .float(64, let b) = v else { throw wrong("Float64", v) }
        return Double(bitPattern: b)
    }, fromNative: { Scalar.floatFromDouble($0) })

    public static let complex64 = Codec<Complex64>(toNative: { v in
        guard case .complex(_, let r, let i) = v else { throw wrong("Complex64", v) }
        return Complex64(real: try float32.toNative(r), imaginary: try float32.toNative(i))
    }, fromNative: { .complex(width: 32, real: Scalar.floatFromSingle($0.real), imaginary: Scalar.floatFromSingle($0.imaginary)) })

    public static let complex128 = Codec<Complex128>(toNative: { v in
        guard case .complex(_, let r, let i) = v else { throw wrong("Complex128", v) }
        return Complex128(real: try float64.toNative(r), imaginary: try float64.toNative(i))
    }, fromNative: { .complex(width: 64, real: Scalar.floatFromDouble($0.real), imaginary: Scalar.floatFromDouble($0.imaginary)) })

    public static let rational = Codec<Rational>(toNative: { v in
        guard case .ratio(let n, let d) = v else { throw wrong("Rational", v) }
        return Rational(n, d)
    }, fromNative: { try Scalar.ratio($0.numerator, $0.denominator) })

    public static let decimal = Codec<ExactDecimal>(toNative: { v in
        guard case .decimal(let c, let e) = v else { throw wrong("Decimal", v) }
        return ExactDecimal(coefficient: c, exponent: e)
    }, fromNative: { .decimal($0.coefficient, $0.exponent) })

    public static let symbol = Codec<Symbol>(toNative: { v in
        guard case .symbol(let id, let d) = v else { throw wrong("Symbol", v) }
        return Symbol(identity: id, description: d)
    }, fromNative: { .symbol($0.identity, $0.symbolDescription) })

    public static func list<T>(_ item: Codec<T>) -> Codec<PersistentList<T>> {
        Codec<PersistentList<T>>(toNative: { v in
            guard case .list(let items) = v else { throw wrong("List", v) }
            return PersistentList(try items.map(item.toNative))
        }, fromNative: { .list(try $0.map(item.fromNative)) })
    }

    public static func maybe<T>(_ item: Codec<T>) -> Codec<T?> {
        Codec<T?>(toNative: { v in
            switch v {
            case .data("Maybe::Nothing", _): return nil
            case .data("Maybe::Just", let f) where f.count == 1: return try item.toNative(f[0])
            default: throw wrong("Maybe", v)
            }
        }, fromNative: { native in
            guard let x = native else { return .data("Maybe::Nothing", []) }
            return .data("Maybe::Just", [try item.fromNative(x)])
        })
    }

    public static func either<L, R>(_ left: Codec<L>, _ right: Codec<R>) -> Codec<Either<L, R>> {
        Codec<Either<L, R>>(toNative: { v in
            switch v {
            case .data("Either::Left", let f) where f.count == 1: return .left(try left.toNative(f[0]))
            case .data("Either::Right", let f) where f.count == 1: return .right(try right.toNative(f[0]))
            default: throw wrong("Either", v)
            }
        }, fromNative: { native in
            switch native {
            case .left(let x): return .data("Either::Left", [try left.fromNative(x)])
            case .right(let x): return .data("Either::Right", [try right.fromNative(x)])
            }
        })
    }

    public static func nullable<T>(_ item: Codec<T>) -> Codec<Nullable<T>> {
        Codec<Nullable<T>>(toNative: { v in
            switch v {
            case .presence(_, nil): return .null
            case .presence(_, let x?): return .present(try item.toNative(x))
            default: throw wrong("Nullable", v)
            }
        }, fromNative: { native in
            switch native {
            case .null: return .presence(kind: "Nullable", value: nil)
            case .present(let x): return .presence(kind: "Nullable", value: try item.fromNative(x))
            }
        })
    }

    /// LawSpec's Optional as Undefinable.
    public static func optional<T>(_ item: Codec<T>) -> Codec<Undefinable<T>> {
        Codec<Undefinable<T>>(toNative: { v in
            switch v {
            case .presence(_, nil): return .undefined
            case .presence(_, let x?): return .present(try item.toNative(x))
            default: throw wrong("Optional", v)
            }
        }, fromNative: { native in
            switch native {
            case .undefined: return .presence(kind: "Optional", value: nil)
            case .present(let x): return .presence(kind: "Optional", value: try item.fromNative(x))
            }
        })
    }

    /// A handle's object crosses unchanged.
    public static func handle<T>(_ name: String, _ type: T.Type) -> Codec<T> {
        Codec<T>(toNative: { v in
            guard case .handle(_, let identity) = v, let native = identity.object as? T else { throw wrong(name, v) }
            return native
        }, fromNative: { native in .handle(name, HandleIdentity(native as AnyObject)) })
    }

    /// A handle no type is bound to, as AnyHandle.
    public static func anyHandle(_ name: String) -> Codec<AnyHandle> {
        Codec<AnyHandle>(toNative: { v in
            guard case .handle(_, let identity) = v else { throw wrong(name, v) }
            return AnyHandle(identity.object)
        }, fromNative: { .handle(name, HandleIdentity($0.object)) })
    }

    /// The value itself, for a type with no native form.
    public static let portable = Codec<Value>(toNative: { $0 }, fromNative: { $0 })

    /// A Set as a SortedSet: canonical (sorted, distinct) in the portable order.
    public static func set<T: Portable>(_ item: Codec<T>) -> Codec<SortedSet<T>> {
        Codec<SortedSet<T>>(toNative: { v in
            guard case .data(_, let f) = v, f.count == 1, case .list(let items) = f[0] else { throw wrong("Set", v) }
            return SortedSet(try items.map(item.toNative))
        }, fromNative: { native in
            .data("lawspec.collections::type::Set::SetItems", [.list(try native.items.map(item.fromNative))])
        })
    }

    /// A KeyVal as a SortedMap, its entries in the portable order of their keys.
    public static func keyVal<K: Portable, V>(_ key: Codec<K>, _ value: Codec<V>) -> Codec<SortedMap<K, V>> {
        Codec<SortedMap<K, V>>(toNative: { v in
            guard case .data(_, let f) = v, f.count == 1, case .list(let entries) = f[0] else { throw wrong("KeyVal", v) }
            return SortedMap(try entries.map { entry -> (K, V) in
                guard case .data(_, let pair) = entry, pair.count == 2 else { throw wrong("Entry", entry) }
                return (try key.toNative(pair[0]), try value.toNative(pair[1]))
            })
        }, fromNative: { native in
            let entries = try native.entries.map { entry -> Value in
                .data("lawspec.collections::type::Entry::Entry", [try key.fromNative(entry.key), try value.fromNative(entry.value)])
            }
            return .data("lawspec.collections::type::KeyVal::KeyValEntries", [.list(entries)])
        })
    }

    /// A Duration as Swift's Duration of whole microseconds.
    public static let duration = Codec<Duration>(toNative: { v in
        guard case .data(_, let f) = v, f.count == 1, case .int(let micros) = f[0], let n = micros.exactly(Int64.self) else {
            throw wrong("Duration", v)
        }
        return .microseconds(n)
    }, fromNative: { span in
        let (seconds, attoseconds) = span.components
        if attoseconds % 1_000_000_000_000 != 0 {
            throw Fail.with("InvalidNativeValue", "a Duration is a whole number of microseconds")
        }
        let micros = BigInt(seconds) * BigInt(1_000_000) + BigInt(attoseconds / 1_000_000_000_000)
        return .data("lawspec.time::type::Duration::Duration", [.int(micros)])
    })
}
