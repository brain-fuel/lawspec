// Type descriptors and the portable generator over them: models, scenarios
// and channels draw, shrink, render and encode their values exactly as every
// other runtime does, so one seed replays one run on every target, and the
// wire bytes are the same. ref:DEC-portable-seeded-generation
// ref:DEC-distribution-canonical-wire ref:DEC-shrink-within-domain

import Foundation

public enum Descriptors {
    /// A descriptor form: an atom, an integer, a quoted string, the hole `_`, or
    /// a parenthesized list of forms.
    public indirect enum Descriptor: Sendable, Equatable {
        case atom(String)
        case number(BigInt)
        case quoted(String)
        case hole
        case forms([Descriptor])
    }

    public typealias Table = [String: Descriptor]

    private static func fail(_ code: String) -> LawSpecError { Fail.with(code) }

    private static func require(_ condition: Bool, _ code: String) throws {
        if !condition { throw fail(code) }
    }

    /// Read every form of a descriptor text.
    public static func read(_ text: String) throws -> [Descriptor] {
        let points = Scalar.codePoints(text)
        var i = 0
        func isSpace(_ c: Int) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 }
        func skip() { while i < points.count && isSpace(points[i]) { i += 1 } }
        func forms() throws -> [Descriptor] {
            var acc = [Descriptor]()
            skip()
            while i < points.count && points[i] != 41 {
                acc.append(try item())
                skip()
            }
            return acc
        }
        func item() throws -> Descriptor {
            if points[i] == 40 {
                i += 1
                let children = try forms()
                try require(i < points.count && points[i] == 41, "UnclosedDescriptor")
                i += 1
                return .forms(children)
            }
            if points[i] == 34 {
                i += 1
                var chars = [Int]()
                var closed = false
                while !closed {
                    try require(i < points.count, "UnclosedDescriptorString")
                    let c = points[i]
                    if c == 92 && i + 1 < points.count {
                        chars.append(points[i + 1])
                        i += 2
                    } else if c == 34 {
                        closed = true
                        i += 1
                    } else {
                        chars.append(c)
                        i += 1
                    }
                }
                return .quoted(try Scalar.textOfPoints(chars))
            }
            let start = i
            while i < points.count && !isSpace(points[i]) && points[i] != 40 && points[i] != 41 { i += 1 }
            try require(i > start, "EmptyDescriptorAtom")
            let word = try Scalar.textOfPoints(points[start..<i])
            if word == "_" { return .hole }
            if let n = numberOf(word) { return .number(n) }
            return .atom(word)
        }
        let result = try forms()
        try require(i == points.count, "TrailingDescriptorInput")
        return result
    }

    /// An integer atom: an optional sign and decimal digits.
    private static func numberOf(_ word: String) -> BigInt? {
        var digits = Substring(word)
        if digits.first == "-" || digits.first == "+" { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return BigInt(word)
    }

    private static func unquote(_ d: Descriptor) throws -> String {
        switch d {
        case .quoted(let s), .atom(let s): return s
        default: throw fail("InvalidDescriptorName")
        }
    }

    /// The named data descriptors of a text, and its last form.
    public static func fromText(_ text: String) throws -> (Table, Descriptor) {
        let forms = try read(text)
        guard let last = forms.last else { throw fail("EmptyDescriptor") }
        var table = Table()
        for d in forms {
            if case .forms(let parts) = d, parts.count >= 2, case .atom("data") = parts[0] {
                table[try unquote(parts[1])] = d
            }
        }
        return (table, last)
    }

    /// A reference resolved through the table.
    public static func resolve(_ d: Descriptor, _ table: Table) throws -> Descriptor {
        if case .forms(let parts) = d, parts.count == 2, case .atom("ref") = parts[0] {
            guard let found = table[try unquote(parts[1])] else { throw fail("UnknownDescriptorReference") }
            return found
        }
        return d
    }

    private static func bound(_ d: Descriptor) throws -> BigInt? {
        switch d {
        case .number(let n): return n
        case .hole: return nil
        default: throw fail("InvalidDescriptorBound")
        }
    }

    public static func generationBounds(_ lo: BigInt?, _ hi: BigInt?) -> (BigInt, BigInt) {
        let million = BigInt(1_000_000)
        switch (lo, hi) {
        case (nil, nil): return (-million, million)
        case (nil, let h?): return (BigInt.min(-million, h - BigInt(2_000_000)), h)
        case (let l?, nil): return (l, BigInt.max(million, l + BigInt(2_000_000)))
        case let (l?, h?): return (l, h)
        }
    }

    private static func mentionsData(_ d: Descriptor) -> Bool {
        guard case .forms(let parts) = d, let head = parts.first else { return false }
        if case .atom("ref") = head { return true }
        if case .atom("data") = head { return true }
        return parts.dropFirst().contains(where: mentionsData)
    }

    private static func baseConstructors(_ cs: [Descriptor]) -> [Descriptor] {
        let found = cs.filter { c in
            if case .forms(let parts) = c, parts.count >= 2, case .atom("ctor") = parts[0] {
                return !parts.dropFirst(2).contains(where: mentionsData)
            }
            return false
        }
        return found.isEmpty ? cs : found
    }

    /// The parts of a form whose head is an atom.
    private static func shape(_ d: Descriptor) -> (String, [Descriptor])? {
        guard case .forms(let parts) = d, let head = parts.first, case .atom(let name) = head else { return nil }
        return (name, Array(parts.dropFirst()))
    }

    /// A value drawn from a descriptor at a size, and the next state. Every draw,
    /// including each boundary choice, follows the portable algorithm.
    public static func generate(_ d: Descriptor, _ table: Table, _ state: Random.Seed, _ size: Int) throws -> (Value, Random.Seed) {
        let resolved = try resolve(d, table)
        guard let (name, args) = shape(resolved) else { throw Fail.with("UnsupportedGenerationDescriptor", "\(resolved)") }
        switch (name, args.count) {
        case ("int", 3):
            let (lo, hi) = generationBounds(try bound(args[1]), try bound(args[2]))
            let (choice, s1) = Random.below(10, state)
            if choice < 2 {
                let (i, s2) = Random.below(4, s1)
                let options = [lo, hi, BigInt.min(BigInt.max(.zero, lo), hi), BigInt.min(BigInt.max(.one, lo), hi)]
                return (.int(options[i.exactly(Int.self) ?? 0]), s2)
            }
            let (n, s2) = Random.below(hi - lo + .one, s1)
            return (.int(lo + n), s2)
        case ("bool", 0):
            let (n, s) = Random.below(2, state)
            return (.bool(n == .one), s)
        case ("text", 0):
            let (count, s1) = Random.below(BigInt(size + 1), state)
            var s = s1
            var scalars = String.UnicodeScalarView()
            for _ in 0..<(count.exactly(Int.self) ?? 0) {
                let (n, next) = Random.below(95, s)
                s = next
                scalars.append(Unicode.Scalar(UInt8(n.exactly(Int.self)! + 32)))
            }
            return (.text(String(scalars)), s)
        case ("unit", 0):
            return (.unit, state)
        case ("list", 1):
            let (count, s1) = Random.below(BigInt(size + 1), state)
            var s = s1
            var items = [Value]()
            for _ in 0..<(count.exactly(Int.self) ?? 0) {
                let (v, next) = try generate(args[0], table, s, size)
                items.append(v)
                s = next
            }
            return (.list(items), s)
        case ("maybe", 1):
            let (choice, s1) = Random.below(4, state)
            if choice.isZero { return (.data("Maybe::Nothing", []), s1) }
            let (v, s2) = try generate(args[0], table, s1, size)
            return (.data("Maybe::Just", [v]), s2)
        case ("either", 2):
            let (choice, s1) = Random.below(2, state)
            let (tag, inner) = choice.isZero ? ("Either::Left", args[0]) : ("Either::Right", args[1])
            let (v, s2) = try generate(inner, table, s1, size)
            return (.data(tag, [v]), s2)
        case ("data", _) where args.count >= 1:
            let cs = Array(args.dropFirst())
            let choices = size == 0 ? baseConstructors(cs) : cs
            let (i, s1) = Random.below(BigInt(choices.count), state)
            guard let (head, parts) = shape(choices[i.exactly(Int.self) ?? 0]), head == "ctor", let tag = parts.first else {
                throw fail("InvalidConstructorDescriptor")
            }
            var s = s1
            var values = [Value]()
            for field in parts.dropFirst() {
                let (v, next) = try generate(field, table, s, Swift.max(size - 1, 0))
                values.append(v)
                s = next
            }
            return (.data(try unquote(tag), values), s)
        default:
            throw Fail.with("UnsupportedGenerationDescriptor", "\(resolved)")
        }
    }

    /// The smallest value of a descriptor.
    public static func minimal(_ d: Descriptor, _ table: Table) throws -> Value {
        let resolved = try resolve(d, table)
        guard let (name, args) = shape(resolved) else { throw Fail.with("UnsupportedGenerationDescriptor", "\(resolved)") }
        switch (name, args.count) {
        case ("int", 3):
            let (lo, hi) = generationBounds(try bound(args[1]), try bound(args[2]))
            return .int(BigInt.min(BigInt.max(.zero, lo), hi))
        case ("bool", 0): return .bool(false)
        case ("text", 0): return .text("")
        case ("unit", 0): return .unit
        case ("list", 1): return .list([])
        case ("maybe", 1): return .data("Maybe::Nothing", [])
        case ("either", 2): return .data("Either::Left", [try minimal(args[0], table)])
        case ("data", _) where args.count >= 1:
            guard let first = baseConstructors(Array(args.dropFirst())).first, let (head, parts) = shape(first), head == "ctor",
                  let tag = parts.first else { throw fail("InvalidDataDescriptor") }
            return .data(try unquote(tag), try parts.dropFirst().map { try minimal($0, table) })
        default:
            throw Fail.with("UnsupportedGenerationDescriptor", "\(resolved)")
        }
    }

    private static func shrinkSequence<T>(_ values: [T]) -> [[T]] {
        if values.isEmpty { return [] }
        var result: [[T]] = [[], Array(values.prefix(values.count / 2))]
        for i in 0..<values.count {
            var copy = values
            copy.remove(at: i)
            result.append(copy)
        }
        return result
    }

    private static func replaceShrinks(_ values: [Value], _ shrink: (Value) throws -> [Value]) rethrows -> [[Value]] {
        var result = [[Value]]()
        for (i, v) in values.enumerated() {
            for c in try shrink(v) {
                var copy = values
                copy[i] = c
                result.append(copy)
            }
        }
        return result
    }

    private static func constructorOf(_ tag: String, _ cs: [Descriptor]) throws -> Descriptor {
        let found = try cs.filter { c in
            if let (head, parts) = shape(c), head == "ctor", let name = parts.first { return try unquote(name) == tag }
            return false
        }
        guard found.count == 1 else { throw Fail.with("ForeignWireConstructor", tag) }
        return found[0]
    }

    private static func fieldDescriptors(_ c: Descriptor) -> [Descriptor] {
        guard let (head, parts) = shape(c), head == "ctor" else { return [] }
        return Array(parts.dropFirst())
    }

    /// The candidates a value shrinks to, in the portable order, without
    /// duplicates or the value itself.
    public static func shrink(_ d: Descriptor, _ value: Value, _ table: Table) throws -> [Value] {
        let candidates = try shrinkResolved(try resolve(d, table), value, table)
        var seen = [value]
        var result = [Value]()
        for c in candidates where !seen.contains(where: { Recorded.identical($0, c) }) {
            seen.append(c)
            result.append(c)
        }
        return result
    }

    private static func shrinkResolved(_ d: Descriptor, _ value: Value, _ table: Table) throws -> [Value] {
        guard let (name, args) = shape(d) else { throw fail("InvalidShrinkValue") }
        switch (name, args.count, value) {
        case ("int", 3, .int(let v)):
            guard case .int(let target) = try minimal(d, table) else { return [] }
            if v == target { return [] }
            let half = (v - target) / 2
            return [.int(target), .int(v - half), .int(v - (v > target ? BigInt.one : BigInt(-1)))]
        case ("bool", 0, .bool(true)): return [.bool(false)]
        case ("bool", 0, .bool(false)): return []
        case ("text", 0, .text(let s)):
            return try shrinkSequence(Scalar.codePoints(s)).map { .text(try Scalar.textOfPoints($0)) }
        case ("list", 1, .list(let items)):
            return shrinkSequence(items).map { .list($0) } + (try replaceShrinks(items) { try shrink(args[0], $0, table) }).map { .list($0) }
        case ("maybe", 1, .data("Maybe::Just", let fields)) where fields.count == 1:
            return [.data("Maybe::Nothing", [])] + (try shrink(args[0], fields[0], table)).map { .data("Maybe::Just", [$0]) }
        case ("maybe", 1, .data("Maybe::Nothing", _)):
            return []
        case ("either", 2, .data(let tag, let fields)) where fields.count == 1:
            let inner = tag == "Either::Left" ? args[0] : args[1]
            return try shrink(inner, fields[0], table).map { .data(tag, [$0]) }
        case ("data", _, .data(let tag, let fields)) where args.count >= 1:
            let ds = fieldDescriptors(try constructorOf(tag, Array(args.dropFirst())))
            let recursive = Descriptor.forms([.atom("ref"), args[0]])
            var result = [try minimal(d, table)]
            for (f, fd) in zip(fields, ds) where fd == recursive { result.append(f) }
            for (i, fd) in ds.enumerated() where i < fields.count {
                for c in try shrink(fd, fields[i], table) {
                    var copy = fields
                    copy[i] = c
                    result.append(.data(tag, copy))
                }
            }
            return result
        case ("unit", 0, .unit): return []
        default: throw fail("InvalidShrinkValue")
        }
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A value as the portable runtimes print it.
    public static func render(_ value: Value) -> String {
        switch value {
        case .bool(true): return "true"
        case .bool(false): return "false"
        case .unit: return "()"
        case .int(let n): return n.description
        case .text(let s): return quote(s)
        case .list(let items): return "[" + items.map(render).joined(separator: ", ") + "]"
        case .data(let tag, let fields):
            let name = Recorded.lastPart(tag)
            return fields.isEmpty ? name : name + "(" + fields.map(render).joined(separator: ", ") + ")"
        default: return Recorded.debug(value)
        }
    }

    // MARK: The canonical wire: zigzag varints, length-prefixed bytes,
    // constructor indices. ref:DEC-distribution-canonical-wire

    /// A non-negative integer as LEB128.
    public static func varint(_ n: BigInt) throws -> [UInt8] {
        if n.isNegative { throw fail("NegativeVarint") }
        var bytes = [UInt8]()
        var rest = n
        while true {
            let low = UInt8((rest & BigInt(127)).exactly(Int.self)!)
            rest = rest >> 7
            if rest.isZero {
                bytes.append(low)
                return bytes
            }
            bytes.append(low | 128)
        }
    }

    /// A LEB128 integer at a position, and the position after it.
    public static func readVarint(_ bytes: [UInt8], _ start: Int) throws -> (BigInt, Int) {
        var n = BigInt.zero
        var shift = 0
        var i = start
        while true {
            if i >= bytes.count { throw fail("TruncatedWireValue") }
            let b = bytes[i]
            n = n | (BigInt(Int(b & 127)) << shift)
            shift += 7
            i += 1
            if b < 128 { return (n, i) }
        }
    }

    private static func checkInteger(_ v: BigInt, _ lo: Descriptor, _ hi: Descriptor) throws {
        if let l = try bound(lo), v < l { throw fail("WireIntegerOutOfRange") }
        if let h = try bound(hi), v > h { throw fail("WireIntegerOutOfRange") }
    }

    private static func put(_ d: Descriptor, _ value: Value, _ table: Table, _ out: inout [UInt8]) throws {
        let resolved = try resolve(d, table)
        guard let (name, args) = shape(resolved) else { throw Fail.with("InvalidWireValue", "\(resolved)") }
        switch (name, args.count, value) {
        case ("int", 3, .int(let v)):
            try checkInteger(v, args[1], args[2])
            out += try varint(v.isNegative ? -v * 2 - .one : v * 2)
        case ("bool", 0, .bool(let b)): out.append(b ? 1 : 0)
        case ("unit", 0, .unit): break
        case ("text", 0, .text(let s)), ("end", 0, .text(let s)):
            let bytes = Array(s.utf8)
            out += try varint(BigInt(bytes.count))
            out += bytes
        case ("bytes", 0, .bytes(let b)), ("end", 0, .bytes(let b)):
            out += try varint(BigInt(b.count))
            out += b
        case ("list", 1, .list(let items)):
            out += try varint(BigInt(items.count))
            for v in items { try put(args[0], v, table, &out) }
        case ("maybe", 1, .data("Maybe::Nothing", let f)) where f.isEmpty: out.append(0)
        case ("maybe", 1, .data("Maybe::Just", let f)) where f.count == 1:
            out.append(1)
            try put(args[0], f[0], table, &out)
        case ("either", 2, .data("Either::Left", let f)) where f.count == 1:
            out.append(0)
            try put(args[0], f[0], table, &out)
        case ("either", 2, .data("Either::Right", let f)) where f.count == 1:
            out.append(1)
            try put(args[1], f[0], table, &out)
        case ("data", _, .data(let tag, let fields)) where args.count >= 1:
            let cs = Array(args.dropFirst())
            let c = try constructorOf(tag, cs)
            let ds = fieldDescriptors(c)
            try require(ds.count == fields.count, "WireFieldCount")
            guard let index = cs.firstIndex(of: c) else { throw fail("InvalidWireConstructor") }
            out += try varint(BigInt(index))
            for (fd, v) in zip(ds, fields) { try put(fd, v, table, &out) }
        default:
            throw Fail.with("InvalidWireValue", "\(resolved)")
        }
    }

    /// A value's canonical wire bytes.
    public static func encode(_ d: Descriptor, _ value: Value, _ table: Table) throws -> [UInt8] {
        var out = [UInt8]()
        try put(d, value, table, &out)
        return out
    }

    private static func get(_ d: Descriptor, _ bytes: [UInt8], _ i: Int, _ table: Table) throws -> (Value, Int) {
        let resolved = try resolve(d, table)
        guard let (name, args) = shape(resolved) else { throw Fail.with("InvalidWireValue", "\(resolved)") }
        switch (name, args.count) {
        case ("int", 3):
            let (z, next) = try readVarint(bytes, i)
            let v = z.isEven ? z / 2 : -(z + .one) / 2
            try checkInteger(v, args[1], args[2])
            return (.int(v), next)
        case ("bool", 0):
            try require(i < bytes.count && bytes[i] < 2, "InvalidWireValue")
            return (.bool(bytes[i] == 1), i + 1)
        case ("unit", 0):
            return (.unit, i)
        case ("text", 0), ("bytes", 0), ("end", 0):
            let (count, start) = try readVarint(bytes, i)
            guard let n = count.exactly(Int.self), start + n <= bytes.count else { throw fail("TruncatedWireValue") }
            let slice = Array(bytes[start..<(start + n)])
            if name == "bytes" { return (.bytes(slice), start + n) }
            guard let text = String(validating: slice, as: UTF8.self) else { throw fail("WireInvalidUtf8") }
            return (.text(text), start + n)
        case ("list", 1):
            let (count, start) = try readVarint(bytes, i)
            var position = start
            var items = [Value]()
            for _ in 0..<(count.exactly(Int.self) ?? 0) {
                let (v, next) = try get(args[0], bytes, position, table)
                items.append(v)
                position = next
            }
            return (.list(items), position)
        case ("maybe", 1):
            try require(i < bytes.count && bytes[i] < 2, "InvalidWireValue")
            if bytes[i] == 0 { return (.data("Maybe::Nothing", []), i + 1) }
            let (v, next) = try get(args[0], bytes, i + 1, table)
            return (.data("Maybe::Just", [v]), next)
        case ("either", 2):
            try require(i < bytes.count && bytes[i] < 2, "InvalidWireValue")
            let (tag, inner) = bytes[i] == 0 ? ("Either::Left", args[0]) : ("Either::Right", args[1])
            let (v, next) = try get(inner, bytes, i + 1, table)
            return (.data(tag, [v]), next)
        case ("data", _) where args.count >= 1:
            let cs = Array(args.dropFirst())
            let (index, start) = try readVarint(bytes, i)
            guard let k = index.exactly(Int.self), k < cs.count else { throw fail("InvalidWireConstructor") }
            guard let (head, parts) = shape(cs[k]), head == "ctor", let tag = parts.first else { throw fail("InvalidWireConstructor") }
            var position = start
            var fields = [Value]()
            for fd in parts.dropFirst() {
                let (v, next) = try get(fd, bytes, position, table)
                fields.append(v)
                position = next
            }
            return (.data(try unquote(tag), fields), position)
        default:
            throw Fail.with("InvalidWireValue", "\(resolved)")
        }
    }

    /// A value from its wire bytes, and the position after it.
    public static func decodePrefix(_ d: Descriptor, _ bytes: [UInt8], _ start: Int, _ table: Table) throws -> (Value, Int) {
        try get(d, bytes, start, table)
    }

    /// A value from exactly its wire bytes.
    public static func decode(_ d: Descriptor, _ bytes: [UInt8], _ table: Table) throws -> Value {
        let (v, next) = try get(d, bytes, 0, table)
        try require(next == bytes.count, "TrailingWireBytes")
        return v
    }

    /// The values a descriptor text draws from a seed (the generation suite's
    /// conformance vectors).
    public static func generated(_ text: String, _ seed: BigInt, _ size: Int, _ count: Int) throws -> [String] {
        let (table, d) = try fromText(text)
        var state = Random.seed(seed)
        var result = [String]()
        for _ in 0..<Swift.max(0, count) {
            let (v, next) = try generate(d, table, state, size)
            state = next
            result.append(render(v))
        }
        return result
    }

    /// The shrink candidates of the first value a descriptor text draws.
    public static func shrunk(_ text: String, _ seed: BigInt, _ size: Int) throws -> [String] {
        let (table, d) = try fromText(text)
        let (v, _) = try generate(d, table, Random.seed(seed), size)
        return try shrink(d, v, table).map(render)
    }
}
