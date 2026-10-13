// LawSpec's portable regex grammar, on Unicode scalar values rather than
// Swift's regex engine and its character classes. A match covers the whole
// text, and matching tracks reachable positions, so an ambiguous repeat
// never backtracks exponentially. ref:DEC-typed-core-boundary

public enum Regex {
    /// A compiled pattern.
    public indirect enum Node: Sendable {
        /// A character set: negated, and items each (negated, ranges).
        case set(negated: Bool, items: [(Bool, [(Int, Int)])])
        case sequence([Node])
        case alternatives([Node])
        case repeated(Node, low: Int, high: Int?)
    }

    private static func fail(_ reason: String) -> LawSpecError { Fail.with("NonPortableRegex", reason) }

    private static func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw fail(reason) }
    }

    private static func code(_ c: Character) -> Int { Int(c.unicodeScalars.first!.value) }

    private static func contains(_ text: String, _ c: Int) -> Bool { text.unicodeScalars.contains { Int($0.value) == c } }

    /// A parser over a pattern's code points.
    private struct Parser {
        let cs: [Int]
        var i = 0

        var current: Int? { i < cs.count ? cs[i] : nil }
        func peek(_ k: Int) -> Int? { i + k < cs.count ? cs[i + k] : nil }

        mutating func escape() throws -> (Bool, [(Int, Int)]) {
            guard let c = current else { throw Regex.fail("TrailingEscape") }
            i += 1
            switch c {
            case code("d"), code("D"): return (c == code("D"), [(48, 57)])
            case code("w"), code("W"): return (c == code("W"), [(48, 57), (65, 90), (95, 95), (97, 122)])
            case code("s"), code("S"): return (c == code("S"), [(9, 13), (32, 32)])
            case code("n"): return (false, [(10, 10)])
            case code("t"): return (false, [(9, 9)])
            case code("r"): return (false, [(13, 13)])
            case code("f"): return (false, [(12, 12)])
            case code("v"): return (false, [(11, 11)])
            default:
                try Regex.require(Regex.contains("\\.^$|?*+()[]{}-/", c), "UnsupportedEscape")
                return (false, [(c, c)])
            }
        }

        mutating func classItem() throws -> (Bool, [(Int, Int)]) {
            guard let c = current else { throw Regex.fail("UnclosedClass") }
            if c == code("\\") {
                i += 1
                return try escape()
            }
            if c == code("[") { throw Regex.fail("UnescapedClassOpen") }
            i += 1
            return (false, [(c, c)])
        }

        mutating func charClass(_ negated: Bool) throws -> Node {
            var acc = [(Bool, [(Int, Int)])]()
            while true {
                guard let c = current else { throw Regex.fail("UnclosedClass") }
                if c == code("]") {
                    if acc.isEmpty { throw Regex.fail("EmptyClass") }
                    i += 1
                    return .set(negated: negated, items: acc)
                }
                let item = try classItem()
                if !item.0, item.1.count == 1, item.1[0].0 == item.1[0].1,
                   current == code("-"), let next = peek(1), next != code("]") {
                    let lo = item.1[0].0
                    i += 1
                    let hiItem = try classItem()
                    guard !hiItem.0, hiItem.1.count == 1, hiItem.1[0].0 == hiItem.1[0].1, hiItem.1[0].0 >= lo else {
                        throw Regex.fail("InvalidClassRange")
                    }
                    acc.append((false, [(lo, hiItem.1[0].0)]))
                } else {
                    acc.append(item)
                }
            }
        }

        mutating func count() throws -> Int {
            var value = 0
            var digits = 0
            while let c = current, c >= code("0"), c <= code("9") {
                value = value * 10 + (c - code("0"))
                digits += 1
                i += 1
            }
            try Regex.require(digits > 0, "MissingRepetitionCount")
            return value
        }

        mutating func repeated(_ node: Node, _ low: Int, _ high: Int?) throws -> Node {
            try Regex.require(low <= 1000 && (high.map { $0 <= 1000 && $0 >= low } ?? true), "InvalidRepetitionCount")
            if let c = current { try Regex.require(!Regex.contains("*+?{", c), "RepeatedQuantifier") }
            return .repeated(node, low: low, high: high)
        }

        mutating func quantified(_ node: Node) throws -> Node {
            guard let c = current else { return node }
            switch c {
            case code("*"):
                i += 1
                return try repeated(node, 0, nil)
            case code("+"):
                i += 1
                return try repeated(node, 1, nil)
            case code("?"):
                i += 1
                return try repeated(node, 0, 1)
            case code("{"):
                i += 1
                let low = try count()
                if current == code("}") {
                    i += 1
                    return try repeated(node, low, low)
                }
                if current == code(","), peek(1) == code("}") {
                    i += 2
                    return try repeated(node, low, nil)
                }
                if current == code(",") {
                    i += 1
                    let high = try count()
                    guard current == code("}") else { throw Regex.fail("UnclosedRepetition") }
                    i += 1
                    return try repeated(node, low, high)
                }
                throw Regex.fail("InvalidRepetition")
            default:
                return node
            }
        }

        mutating func alternatives() throws -> Node {
            var branches = [try sequence()]
            while current == code("|") {
                i += 1
                branches.append(try sequence())
            }
            return branches.count == 1 ? branches[0] : .alternatives(branches)
        }

        mutating func sequence() throws -> Node {
            var acc = [Node]()
            while let c = current, c != code(")"), c != code("|") {
                let a = try atom()
                acc.append(try quantified(a))
            }
            return .sequence(acc)
        }

        mutating func atom() throws -> Node {
            guard let c = current else { throw Regex.fail("MissingAtom") }
            if c == code("(") {
                if peek(1) == code("?") {
                    if peek(2) == code(":") {
                        i += 3
                        return try group()
                    }
                    throw Regex.fail("UnsupportedGroup")
                }
                i += 1
                return try group()
            }
            if c == code("[") {
                if peek(1) == code("^") {
                    i += 2
                    return try charClass(true)
                }
                i += 1
                return try charClass(false)
            }
            if c == code(".") {
                i += 1
                return .set(negated: true, items: [(false, [(10, 10)])])
            }
            if c == code("\\") {
                i += 1
                return .set(negated: false, items: [try escape()])
            }
            try Regex.require(!Regex.contains("*+?{^$]}", c), "UnexpectedCharacter")
            i += 1
            return .set(negated: false, items: [(false, [(c, c)])])
        }

        mutating func group() throws -> Node {
            let node = try alternatives()
            guard current == code(")") else { throw Regex.fail("UnclosedGroup") }
            i += 1
            return node
        }
    }

    private static let cache = Locked([String: Node]())

    /// Compile a pattern once; compiled patterns are shared.
    public static func compile(_ pattern: String) throws -> Node {
        if let known = cache.with({ $0[pattern] }) { return known }
        var parser = Parser(cs: Scalar.codePoints(pattern))
        let node = try parser.alternatives()
        try require(parser.i == parser.cs.count, "UnmatchedClosingParenthesis")
        cache.with { $0[pattern] = node }
        return node
    }

    private static func inSet(_ c: Int, _ items: [(Bool, [(Int, Int)])]) -> Bool {
        items.contains { negated, ranges in negated != ranges.contains { c >= $0.0 && c <= $0.1 } }
    }

    private static func reach(_ node: Node, _ text: [Int], _ positions: Set<Int>) -> Set<Int> {
        switch node {
        case .set(let negated, let items):
            return Set(positions.filter { $0 < text.count && inSet(text[$0], items) != negated }.map { $0 + 1 })
        case .sequence(let nodes):
            return nodes.reduce(positions) { reach($1, text, $0) }
        case .alternatives(let nodes):
            return nodes.reduce(into: Set<Int>()) { $0.formUnion(reach($1, text, positions)) }
        case .repeated(let inner, let low, let high):
            var required = positions
            var i = 0
            while i < low && !required.isEmpty {
                required = reach(inner, text, required)
                i += 1
            }
            var seen = required
            var frontier = required
            var remaining = high.map { $0 - low }
            while !frontier.isEmpty && remaining != 0 {
                let next = reach(inner, text, frontier).subtracting(seen)
                seen.formUnion(next)
                frontier = next
                remaining = remaining.map { $0 - 1 }
            }
            return seen
        }
    }

    /// Whether a compiled pattern matches the whole text.
    public static func run(_ node: Node, _ text: String) -> Bool {
        let points = Scalar.codePoints(text)
        return reach(node, points, [0]).contains(points.count)
    }

    /// Whether a pattern matches the whole text.
    public static func matches(_ pattern: String, _ text: String) throws -> Bool { run(try compile(pattern), text) }
}

