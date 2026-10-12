// Persistent sorted collections for LawSpec's Set and KeyVal: balanced trees
// whose nodes are shared, never copied, between a collection and the ones
// made from it, kept in LawSpec's portable order of their keys, so iteration
// is the order every target observes. ref:DEC-typed-native-definitions
// ref:DEC-swift-runtime-from-scratch

/// A node of an AVL tree. Nodes never change once made.
@usableFromInline final class SortedNode<Key: Portable, Element>: @unchecked Sendable {
    @usableFromInline let key: Key
    @usableFromInline let element: Element
    @usableFromInline let left: SortedNode?
    @usableFromInline let right: SortedNode?
    @usableFromInline let height: Int
    @usableFromInline let count: Int

    @usableFromInline init(_ key: Key, _ element: Element, _ left: SortedNode?, _ right: SortedNode?) {
        self.key = key
        self.element = element
        self.left = left
        self.right = right
        self.height = Swift.max(left?.height ?? 0, right?.height ?? 0) + 1
        self.count = (left?.count ?? 0) + (right?.count ?? 0) + 1
    }
}

/// The tree operations both collections share.
@usableFromInline enum SortedTree {
    typealias Node<K: Portable, E> = SortedNode<K, E>

    static func height<K, E>(_ n: Node<K, E>?) -> Int { n?.height ?? 0 }

    static func balance<K, E>(_ key: K, _ element: E, _ left: Node<K, E>?, _ right: Node<K, E>?) -> Node<K, E> {
        let hl = height(left)
        let hr = height(right)
        if hl > hr + 1, let l = left {
            if height(l.left) >= height(l.right) {
                return Node(l.key, l.element, l.left, Node(key, element, l.right, right))
            }
            let lr = l.right!
            return Node(lr.key, lr.element, Node(l.key, l.element, l.left, lr.left), Node(key, element, lr.right, right))
        }
        if hr > hl + 1, let r = right {
            if height(r.right) >= height(r.left) {
                return Node(r.key, r.element, Node(key, element, left, r.left), r.right)
            }
            let rl = r.left!
            return Node(rl.key, rl.element, Node(key, element, left, rl.left), Node(r.key, r.element, rl.right, r.right))
        }
        return Node(key, element, left, right)
    }

    static func insert<K, E>(_ node: Node<K, E>?, _ key: K, _ element: E) -> Node<K, E> {
        guard let n = node else { return Node(key, element, nil, nil) }
        let c = K.portableCompare(key, n.key)
        if c < 0 { return balance(n.key, n.element, insert(n.left, key, element), n.right) }
        if c > 0 { return balance(n.key, n.element, n.left, insert(n.right, key, element)) }
        return Node(key, element, n.left, n.right)
    }

    static func removeMinimum<K, E>(_ n: Node<K, E>) -> (Node<K, E>?, Node<K, E>) {
        guard let l = n.left else { return (n.right, n) }
        let (rest, minimum) = removeMinimum(l)
        return (balance(n.key, n.element, rest, n.right), minimum)
    }

    static func remove<K, E>(_ node: Node<K, E>?, _ key: K) -> Node<K, E>? {
        guard let n = node else { return nil }
        let c = K.portableCompare(key, n.key)
        if c < 0 { return balance(n.key, n.element, remove(n.left, key), n.right) }
        if c > 0 { return balance(n.key, n.element, n.left, remove(n.right, key)) }
        guard let r = n.right else { return n.left }
        guard n.left != nil else { return r }
        let (rest, minimum) = removeMinimum(r)
        return balance(minimum.key, minimum.element, n.left, rest)
    }

    static func find<K, E>(_ node: Node<K, E>?, _ key: K) -> Node<K, E>? {
        var current = node
        while let n = current {
            let c = K.portableCompare(key, n.key)
            if c == 0 { return n }
            current = c < 0 ? n.left : n.right
        }
        return nil
    }

    static func inOrder<K, E>(_ node: Node<K, E>?, _ visit: (Node<K, E>) -> Void) {
        guard let n = node else { return }
        inOrder(n.left, visit)
        visit(n)
        inOrder(n.right, visit)
    }

    static func nodes<K, E>(_ node: Node<K, E>?) -> [Node<K, E>] {
        var result = [Node<K, E>]()
        result.reserveCapacity(node?.count ?? 0)
        inOrder(node) { result.append($0) }
        return result
    }
}

/// LawSpec's Set: distinct items in their portable order. Adding or removing
/// an item makes a new set that shares the rest.
public struct SortedSet<Element: Portable>: Sendable, Sequence, ExpressibleByArrayLiteral, CustomStringConvertible {
    @usableFromInline let root: SortedNode<Element, Unit>?

    @usableFromInline init(root: SortedNode<Element, Unit>?) { self.root = root }

    public init() { root = nil }

    /// The set of a sequence's items.
    public init<S: Sequence>(_ items: S) where S.Element == Element {
        var node: SortedNode<Element, Unit>? = nil
        for item in items { node = SortedTree.insert(node, item, Unit()) }
        root = node
    }

    public init(arrayLiteral items: Element...) { self.init(items) }

    public var count: Int { root?.count ?? 0 }
    public var isEmpty: Bool { root == nil }

    public func contains(_ item: Element) -> Bool { SortedTree.find(root, item) != nil }
    public func inserting(_ item: Element) -> SortedSet { SortedSet(root: SortedTree.insert(root, item, Unit())) }
    public func removing(_ item: Element) -> SortedSet { SortedSet(root: SortedTree.remove(root, item)) }

    public func union(_ other: SortedSet) -> SortedSet {
        var node = root
        for item in other { node = SortedTree.insert(node, item, Unit()) }
        return SortedSet(root: node)
    }
    public func intersection(_ other: SortedSet) -> SortedSet { SortedSet(filter { other.contains($0) }) }
    public func subtracting(_ other: SortedSet) -> SortedSet {
        var node = root
        for item in other { node = SortedTree.remove(node, item) }
        return SortedSet(root: node)
    }

    /// The items in their portable order.
    public var items: [Element] { SortedTree.nodes(root).map { $0.key } }

    public func makeIterator() -> IndexingIterator<[Element]> { items.makeIterator() }

    public var description: String { "[" + items.map { "\($0)" }.joined(separator: ", ") + "]" }
}

extension SortedSet: Portable {
    public static func portableEqual(_ a: SortedSet, _ b: SortedSet) -> Bool { [Element].portableEqual(a.items, b.items) }
    public static func portableCompare(_ a: SortedSet, _ b: SortedSet) -> Int { [Element].portableCompare(a.items, b.items) }
    public func portableHash(into hasher: inout Hasher) { items.portableHash(into: &hasher) }
}

extension SortedSet: Equatable, Hashable {
    public static func == (a: SortedSet, b: SortedSet) -> Bool { portableEqual(a, b) }
    public func hash(into hasher: inout Hasher) { portableHash(into: &hasher) }
}

/// LawSpec's KeyVal: distinct keys in their portable order, each with a
/// value. Putting or deleting a key makes a new map that shares the rest.
public struct SortedMap<Key: Portable, Value>: Sequence, ExpressibleByDictionaryLiteral, CustomStringConvertible {
    @usableFromInline let root: SortedNode<Key, Value>?

    @usableFromInline init(root: SortedNode<Key, Value>?) { self.root = root }

    public init() { root = nil }

    /// The map of entries; a later entry's value wins.
    public init<S: Sequence>(_ entries: S) where S.Element == (Key, Value) {
        var node: SortedNode<Key, Value>? = nil
        for (key, value) in entries { node = SortedTree.insert(node, key, value) }
        root = node
    }

    public init(dictionaryLiteral entries: (Key, Value)...) { self.init(entries) }

    public var count: Int { root?.count ?? 0 }
    public var isEmpty: Bool { root == nil }

    public subscript(key: Key) -> Value? { SortedTree.find(root, key)?.element }
    public func contains(_ key: Key) -> Bool { SortedTree.find(root, key) != nil }
    public func putting(_ key: Key, _ value: Value) -> SortedMap { SortedMap(root: SortedTree.insert(root, key, value)) }
    public func removing(_ key: Key) -> SortedMap { SortedMap(root: SortedTree.remove(root, key)) }

    /// The entries in their keys' portable order.
    public var entries: [(key: Key, value: Value)] { SortedTree.nodes(root).map { (key: $0.key, value: $0.element) } }
    public var keys: [Key] { SortedTree.nodes(root).map { $0.key } }
    public var values: [Value] { SortedTree.nodes(root).map { $0.element } }

    public func makeIterator() -> IndexingIterator<[(key: Key, value: Value)]> { entries.makeIterator() }

    public var description: String {
        "[" + entries.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "]"
    }
}

extension SortedMap: @unchecked Sendable where Value: Sendable {}

extension SortedMap: Portable where Value: Portable {
    public static func portableEqual(_ a: SortedMap, _ b: SortedMap) -> Bool {
        a.count == b.count && zip(a.entries, b.entries).allSatisfy {
            Key.portableEqual($0.key, $1.key) && Value.portableEqual($0.value, $1.value)
        }
    }
    public static func portableCompare(_ a: SortedMap, _ b: SortedMap) -> Int {
        for (x, y) in zip(a.entries, b.entries) {
            let k = Key.portableCompare(x.key, y.key)
            if k != 0 { return k }
            let v = Value.portableCompare(x.value, y.value)
            if v != 0 { return v }
        }
        return order(a.count, b.count)
    }
    public func portableHash(into hasher: inout Hasher) {
        hasher.combine(count)
        for (key, value) in entries {
            key.portableHash(into: &hasher)
            value.portableHash(into: &hasher)
        }
    }
}

extension SortedMap: Equatable, Hashable where Value: Portable {
    public static func == (a: SortedMap, b: SortedMap) -> Bool { portableEqual(a, b) }
    public func hash(into hasher: inout Hasher) { portableHash(into: &hasher) }
}
