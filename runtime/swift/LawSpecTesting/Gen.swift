// LawSpec's generation plans as generators of shrink trees. No maintained
// Swift property library offers dependent generation whose shrinking stays
// inside a refinement and replays from one seed, so the engine is here: a
// generator draws from the portable SplitMix64 sequence at a size and builds,
// for each value, the rose tree of the smaller values it may shrink to.
// Shrinking a bound input rebuilds the inputs that depend on it from the same
// random state, so every candidate stays inside the domain.
// ref:DEC-swift-property-library ref:DEC-shrink-within-domain
// ref:DEC-planned-generation

import LawSpecRuntime

/// A value and, lazily, the values it shrinks to, best first.
public struct Tree<Element> {
    public let value: Element
    private let makeChildren: () throws -> [Tree<Element>]

    public init(_ value: Element, _ children: @escaping () throws -> [Tree<Element>]) {
        self.value = value
        self.makeChildren = children
    }

    /// The candidates, computed when asked for.
    public func children() throws -> [Tree<Element>] { try makeChildren() }

    public static func leaf(_ value: Element) -> Tree<Element> { Tree(value) { [] } }

    public func map<B>(_ f: @escaping (Element) throws -> B) throws -> Tree<B> {
        let me = self
        return Tree<B>(try f(value)) { try me.children().map { try $0.map(f) } }
    }

    /// Keep only the candidates a predicate accepts, with their own candidates.
    public func filter(_ keep: @escaping (Element) throws -> Bool) -> Tree<Element> {
        let me = self
        return Tree(value) { try me.children().filter { try keep($0.value) }.map { $0.filter(keep) } }
    }

    /// Candidates from a function of a value, unfolded.
    public static func unfold(_ value: Element, _ shrink: @escaping (Element) -> [Element]) -> Tree<Element> {
        Tree(value) { shrink(value).map { unfold($0, shrink) } }
    }

    /// At most a number of shrink steps, each trying at most a number of
    /// candidates.
    public func limit(_ steps: Int, _ width: Int) -> Tree<Element> {
        let me = self
        return Tree(value) { steps <= 0 ? [] : try me.children().prefix(width).map { $0.limit(steps - 1, width) } }
    }
}

/// A generator: from a random state and a size, a value's shrink tree, or nil
/// for an empty domain, which discards the whole tuple of inputs.
public struct Gen<Element> {
    public let generate: (Random.Seed, Int) throws -> Tree<Element>?

    public init(_ generate: @escaping (Random.Seed, Int) throws -> Tree<Element>?) { self.generate = generate }

    public static func constant(_ value: Element) -> Gen<Element> { Gen { _, _ in .leaf(value) } }

    /// An empty domain: the case is discarded and redrawn.
    public static var empty: Gen<Element> { Gen { _, _ in nil } }

    public func map<B>(_ f: @escaping (Element) throws -> B) -> Gen<B> {
        let g = self
        return Gen<B> { seed, size in try g.generate(seed, size)?.map(f) }
    }

    private static func bindTree<B>(_ tree: Tree<Element>, _ k: @escaping (Element) throws -> Tree<B>?) throws -> Tree<B>? {
        guard let inner = try k(tree.value) else { return nil }
        return Tree<B>(inner.value) {
            try tree.children().compactMap { try bindTree($0, k) } + (try inner.children())
        }
    }

    /// A generator that depends on another's value. Shrinking the first value
    /// regenerates the second from the same random state and size.
    public func bind<B>(_ k: @escaping (Element) throws -> Gen<B>) -> Gen<B> {
        let g = self
        return Gen<B> { seed, size in
            let (first, second) = Random.split(seed)
            guard let tree = try g.generate(first, size) else { return nil }
            return try Gen.bindTree(tree) { try k($0).generate(second, size) }
        }
    }

    public static func sized(_ f: @escaping (Int) throws -> Gen<Element>) -> Gen<Element> {
        Gen { seed, size in try f(size).generate(seed, size) }
    }

    public func resize(_ size: Int) -> Gen<Element> {
        let g = self
        return Gen { seed, _ in try g.generate(seed, size) }
    }

    /// Redraw until a predicate accepts the value, at most a number of times;
    /// the accepted tree's candidates are filtered too.
    private func retry(_ predicate: @escaping (Element) throws -> Bool, _ limit: Int, _ exhausted: @escaping () throws -> Tree<Element>?) -> Gen<Element> {
        let g = self
        return Gen { seed, size in
            if limit <= 0 { return try exhausted() }
            var state = seed
            for _ in 0..<limit {
                let (attempt, following) = Random.split(state)
                state = following
                if let tree = try g.generate(attempt, size), try predicate(tree.value) { return tree.filter(predicate) }
            }
            return try exhausted()
        }
    }

    /// Keep values a predicate accepts, redrawing up to a limit; candidates
    /// are filtered too.
    public func constrain(_ limit: Int, _ predicate: @escaping (Element) throws -> Bool) -> Gen<Element> {
        retry(predicate, limit) { nil }
    }

    /// A dependent input's domain: an impossible value discards the tuple, so
    /// an earlier input is redrawn rather than retried in vain.
    public func refine(_ predicate: @escaping (Element) throws -> Bool) -> Gen<Element> {
        bind { value in try predicate(value) ? .constant(value) : .empty }
    }

    /// Draw until a predicate holds, failing the harness after a limit.
    public func suchThat(_ predicate: @escaping (Element) throws -> Bool, _ limit: Int, _ onExhausted: @escaping () throws -> Void) -> Gen<Element> {
        retry(predicate, limit + 1) {
            try onExhausted()
            return nil
        }
    }
}

/// Generators of LawSpec's building blocks.
public enum Gens {
    private static let int64Range = BigInt(Int64.max) + .one

    /// A uniform integer in [0, n), from the random state.
    static func below(_ n: BigInt, _ seed: Random.Seed) -> BigInt {
        if n <= .one { return .zero }
        if n <= int64Range {
            let (r, _) = Random.below(n, seed)
            return r
        }
        // Enough 64-bit words that the remainder's bias is negligible.
        let words = n.bitLength / 64 + 2
        var total = BigInt.zero
        var state = seed
        for _ in 0..<words {
            let (w, following) = Random.next(state)
            state = following
            total = (total << 64) + BigInt(w)
        }
        return total % n
    }

    private static func towards(_ origin: BigInt, _ value: BigInt) -> [BigInt] {
        if value == origin { return [] }
        var result = [origin]
        var distance = (value - origin) / 2
        while !distance.isZero {
            result.append(value - distance)
            distance = distance / 2
        }
        if (value - origin).magnitude > .one { result.append(value > origin ? value - .one : value + .one) }
        var seen = [BigInt]()
        return result.filter { candidate in
            if seen.contains(candidate) { return false }
            seen.append(candidate)
            return true
        }
    }

    /// An integer in an inclusive range, shrinking towards the value nearest
    /// zero. An open end is limited by the size, exponentially, so large
    /// magnitudes appear as the size grows.
    public static func integer(_ lo: BigInt?, _ hi: BigInt?) -> Gen<BigInt> {
        Gen { seed, size in
            let reach = BigInt.one << Swift.min(64, 2 + size / 2)
            let low = lo ?? (hi.map { BigInt.min(.zero, $0) - reach } ?? -reach)
            let high = hi ?? (lo.map { BigInt.max(.zero, $0) + reach } ?? reach)
            if low > high { return nil }
            let origin = BigInt.min(BigInt.max(.zero, low), high)
            let drawn = low + below(high - low + .one, seed)
            return .unfold(drawn) { towards(origin, $0) }
        }
    }

    public static func range(_ lo: Int, _ hi: Int) -> Gen<Int> {
        integer(BigInt(lo), BigInt(hi)).map { $0.exactly(Int.self)! }
    }

    /// One of several generators, shrinking towards the earlier ones.
    public static func oneOf<A>(_ gens: [Gen<A>]) -> Gen<A> {
        if gens.isEmpty { return .empty }
        return range(0, gens.count - 1).bind { gens[$0] }
    }

    /// A weighted choice, shrinking towards the earlier ones.
    public static func frequency<A>(_ choices: [(Int, Gen<A>)]) -> Gen<A> {
        let total = choices.reduce(0) { $0 + $1.0 }
        if total <= 0 { return .empty }
        return range(0, total - 1).bind { n in
            var rest = n
            for (weight, g) in choices {
                if rest < weight { return g }
                rest -= weight
            }
            return .empty
        }
    }

    private static func sequenceTrees<A>(_ trees: [Tree<A>]) -> Tree<[A]> {
        Tree(trees.map { $0.value }) {
            var candidates = [Tree<[A]>]()
            let n = trees.count
            if n > 0 {
                candidates.append(sequenceTrees([]))
                if n > 1 { candidates.append(sequenceTrees(Array(trees.prefix(n / 2)))) }
                for i in 0..<n {
                    var copy = trees
                    copy.remove(at: i)
                    candidates.append(sequenceTrees(copy))
                }
            }
            for (i, t) in trees.enumerated() {
                for child in try t.children() {
                    var copy = trees
                    copy[i] = child
                    candidates.append(sequenceTrees(copy))
                }
            }
            return candidates
        }
    }

    private static func productTrees<A>(_ trees: [Tree<A>]) -> Tree<[A]> {
        Tree(trees.map { $0.value }) {
            var candidates = [Tree<[A]>]()
            for (i, t) in trees.enumerated() {
                for child in try t.children() {
                    var copy = trees
                    copy[i] = child
                    candidates.append(productTrees(copy))
                }
            }
            return candidates
        }
    }

    /// Each generator's tree in order, or nil when any domain is empty.
    private static func draws<A>(_ gens: [Gen<A>], _ seed: Random.Seed, _ size: Int) throws -> [Tree<A>]? {
        var state = seed
        var trees = [Tree<A>]()
        for g in gens {
            let (one, following) = Random.split(state)
            state = following
            guard let tree = try g.generate(one, size) else { return nil }
            trees.append(tree)
        }
        return trees
    }

    /// A fixed number of values, each shrinking in place.
    public static func vector<A>(_ count: Int, _ g: Gen<A>) -> Gen<[A]> {
        Gen { seed, size in try draws(Array(repeating: g, count: Swift.max(0, count)), seed, size).map(productTrees) }
    }

    /// Values of several generators, in order.
    public static func tuple<A>(_ gens: [Gen<A>]) -> Gen<[A]> {
        Gen { seed, size in try draws(gens, seed, size).map(productTrees) }
    }

    /// A list of a length the size limits, shrinking by removing items and by
    /// shrinking them.
    public static func list<A>(_ g: Gen<A>) -> Gen<[A]> {
        Gen { seed, size in
            let (first, second) = Random.split(seed)
            let count = below(BigInt(size + 1), first).exactly(Int.self)!
            return try draws(Array(repeating: g, count: count), second, size).map(sequenceTrees)
        }
    }

    /// A weighted mix of fixed values and a generator.
    public static func withExamples<A>(_ examples: [A], _ g: Gen<A>) -> Gen<A> {
        if examples.isEmpty { return g }
        return frequency([(1, oneOf(examples.map { Gen.constant($0) })), (9, g)])
    }
}
