// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Collections {
    static func dedupe(_ value0: [Int32]) -> SortedSet<Int32> {
        SortedSet(value0)
    }

    static func wordCounts(_ value0: [String]) -> SortedMap<String, BigInt> {
        var counts = SortedMap<String, BigInt>()
        for word in value0 { counts = counts.putting(word, (counts[word] ?? 0) + 1) }
        return counts
    }

    static func fifo(_ value0: [Int8]) -> Queue<Int8> {
        Queue(items: value0)
    }

    /// A Stack's top is its last item.
    static func lifo(_ value0: [Int8]) -> Stack<Int8> {
        Stack(items: value0)
    }

    static func rotate(_ value0: Deque<Int8>) -> Deque<Int8> {
        guard let first = value0.items.first else { return value0 }
        return Deque(items: Array(value0.items.dropFirst()) + [first])
    }

    /// Arrays compare by value, so they can be SortedSet elements directly.
    static func distinctRows(_ value0: [[Int8]]) -> SortedSet<[Int8]> {
        SortedSet(value0)
    }
}
