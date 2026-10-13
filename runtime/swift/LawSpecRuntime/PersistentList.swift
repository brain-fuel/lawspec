// LawSpec's List in Swift: a persistent singly linked list. Prepending, the
// first item and the rest take constant time and share the rest, as a
// recursive definition over a list expects; Swift's Array would copy the
// whole list at each step. It is a Sequence, so for-in, map, filter and
// Array(list) work, and an array literal makes one. ref:DEC-swift-persistent-list

/// An immutable list whose prepend and rest share structure.
public struct PersistentList<Element> {
    @usableFromInline
    final class Node {
        @usableFromInline let head: Element
        @usableFromInline var tail: Node?

        @inlinable
        init(_ head: Element, _ tail: Node?) {
            self.head = head
            self.tail = tail
        }

        // Releasing a long list one node at a time, not recursively, so
        // dropping a list of a million items never exhausts the stack.
        deinit {
            var next = tail
            tail = nil
            while next != nil && isKnownUniquelyReferenced(&next!) {
                let after = next!.tail
                next!.tail = nil
                next = after
            }
        }
    }

    @usableFromInline let node: Node?
    /// The number of items, kept so counting takes constant time.
    public let count: Int

    @inlinable
    init(node: Node?, count: Int) {
        self.node = node
        self.count = count
    }

    /// The empty list.
    @inlinable
    public init() { self.init(node: nil, count: 0) }

    /// A list of a sequence's items, in order.
    public init<S: Sequence>(_ items: S) where S.Element == Element {
        let array = Array(items)
        var node: Node? = nil
        for item in array.reversed() { node = Node(item, node) }
        self.init(node: node, count: array.count)
    }

    /// Whether the list has no items.
    @inlinable
    public var isEmpty: Bool { node == nil }

    /// The first item, if any.
    @inlinable
    public var first: Element? { node?.head }

    /// The list after its first item, shared, not copied; empty when the list is.
    @inlinable
    public var rest: PersistentList<Element> {
        guard let node else { return self }
        return PersistentList(node: node.tail, count: count - 1)
    }

    /// The list with an item before its first.
    @inlinable
    public func prepending(_ item: Element) -> PersistentList<Element> {
        PersistentList(node: Node(item, node), count: count + 1)
    }

    /// The item at a position from 0, if the list is that long.
    public func item(at index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        var current = node
        for _ in 0..<index { current = current?.tail }
        return current?.head
    }

    /// The items from one position up to, not including, another.
    public func slice(_ from: Int, _ until: Int) -> PersistentList<Element> {
        guard from < until else { return PersistentList() }
        var current = node
        for _ in 0..<from { current = current?.tail }
        var items = [Element]()
        items.reserveCapacity(until - from)
        while items.count < until - from, let n = current {
            items.append(n.head)
            current = n.tail
        }
        return PersistentList(items)
    }

    /// One list's items, then another's: the second list is shared.
    public static func + (a: PersistentList<Element>, b: PersistentList<Element>) -> PersistentList<Element> {
        if b.isEmpty { return a }
        var node = b.node
        for item in Array(a).reversed() { node = Node(item, node) }
        return PersistentList(node: node, count: a.count + b.count)
    }

    /// The list in reverse order.
    public func reversed() -> PersistentList<Element> {
        var node: Node? = nil
        var current = self.node
        while let n = current {
            node = Node(n.head, node)
            current = n.tail
        }
        return PersistentList(node: node, count: count)
    }
}

extension PersistentList: Sequence {
    /// Walks the items in order.
    public struct Iterator: IteratorProtocol {
        @usableFromInline var current: Node?

        @inlinable
        init(current: Node?) { self.current = current }

        @inlinable
        public mutating func next() -> Element? {
            guard let node = current else { return nil }
            current = node.tail
            return node.head
        }
    }

    @inlinable
    public func makeIterator() -> Iterator { Iterator(current: node) }

    @inlinable
    public var underestimatedCount: Int { count }
}

extension PersistentList: ExpressibleByArrayLiteral {
    public init(arrayLiteral items: Element...) { self.init(items) }
}

extension PersistentList: CustomStringConvertible {
    public var description: String { "[" + map { "\($0)" }.joined(separator: ", ") + "]" }
}

// The nodes are immutable once the list is built (only deinit unlinks
// them), so a list of Sendable items is Sendable.
extension PersistentList: @unchecked Sendable where Element: Sendable {}

extension PersistentList: Equatable where Element: Equatable {
    public static func == (a: PersistentList<Element>, b: PersistentList<Element>) -> Bool {
        a.count == b.count && a.elementsEqual(b)
    }
}

extension PersistentList: Hashable where Element: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(count)
        for item in self { hasher.combine(item) }
    }
}

extension PersistentList: Portable where Element: Portable {
    public static func portableEqual(_ a: PersistentList<Element>, _ b: PersistentList<Element>) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { Element.portableEqual($0, $1) }
    }

    public static func portableCompare(_ a: PersistentList<Element>, _ b: PersistentList<Element>) -> Int {
        for (x, y) in zip(a, b) {
            let c = Element.portableCompare(x, y)
            if c != 0 { return c }
        }
        return a.count < b.count ? -1 : (a.count == b.count ? 0 : 1)
    }

    public func portableHash(into hasher: inout Hasher) {
        hasher.combine(count)
        for item in self { item.portableHash(into: &hasher) }
    }
}
