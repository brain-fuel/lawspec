// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Collections {
    static func dedupe(_ value0: PersistentList<Int32>) -> SortedSet<Int32> {
        SortedSet(value0)
    }

    static func wordCounts(_ value0: PersistentList<String>) -> SortedMap<String, BigInt> {
        var counts = SortedMap<String, BigInt>()
        for word in value0 { counts = counts.putting(word, (counts[word] ?? 0) + 1) }
        return counts
    }

    static func fifo(_ value0: PersistentList<Int8>) -> Queue<Int8> {
        Queue(value: value0)
    }

    /// A Stack's top is its last item.
    static func lifo(_ value0: PersistentList<Int8>) -> Stack<Int8> {
        Stack(value: value0)
    }

    static func rotate(_ value0: Deque<Int8>) -> Deque<Int8> {
        guard let first = value0.value.first else { return value0 }
        return Deque(value: value0.value.rest + [first])
    }

    /// Lists compare by value, so they can be SortedSet elements directly.
    static func distinctRows(_ value0: PersistentList<PersistentList<Int8>>) -> SortedSet<PersistentList<Int8>> {
        SortedSet(value0)
    }
}
